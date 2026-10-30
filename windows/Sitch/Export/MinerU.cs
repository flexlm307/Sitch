using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Windows;
using System.Windows.Media.Imaging;
using Sitch.Shell;

namespace Sitch.Export;

/// <summary>
/// "Restore as Markdown": MinerU (an external document parser, set up by the user) turns a capture of a
/// complex page — tables, formulas, columns, figures — into Markdown plus cropped images. Its models take
/// tens of seconds to load, so one <c>mineru-api</c> server (localhost, a free port) starts on first use
/// and serves later requests in a few seconds; it exits after 15 idle minutes and with Sitch.
/// </summary>
public static class MinerU
{
    private static readonly TimeSpan StartTimeout = TimeSpan.FromMinutes(3);
    private static readonly TimeSpan ParseTimeout = TimeSpan.FromMinutes(10);
    private static readonly TimeSpan IdleExit = TimeSpan.FromMinutes(15);

    private static readonly SemaphoreSlim Gate = new(1, 1);
    private static readonly HttpClient Http = new() { Timeout = Timeout.InfiniteTimeSpan };
    private static Process? _server;
    private static Uri? _base;
    private static Timer? _idle;
    private static readonly Queue<string> Log = new();

    /// <summary>The MinerU virtual environment (an ASCII path: MinerU's fastText can't open models under
    /// non-ASCII paths, so a junction like %USERPROFILE%\.local\mineru-x.y.z is the usual entry).</summary>
    private static string Folder => App.Settings.MinerUFolder.Trim();

    private static string Python => Path.Combine(Folder, "Scripts", "python.exe");

    public static bool Configured => Folder.Length > 0 && File.Exists(Python);

    /// <summary>Parses the image and opens the result; progress and errors go to toasts.</summary>
    public static async void Restore(BitmapSource image)
    {
        if (!Configured)
        {
            NotifyPopup.Show(Loc.T("Set the MinerU folder in Settings > Editor first."));
            return;
        }
        if (!await Gate.WaitAsync(0))
        {
            NotifyPopup.Show(Loc.T("MinerU is still working on the previous capture."));
            return;
        }
        try
        {
            _idle?.Dispose();
            NotifyPopup.Show(Loc.T(_server is { HasExited: false }
                ? "Restoring as Markdown…"
                : "Starting MinerU (the first run loads its models, about half a minute)…"));
            var png = EncodePng(image);
            var zip = await Task.Run(async () =>
            {
                if (_server is not { HasExited: false }) await StartAsync();
                try { return await ParseAsync(png); }
                finally { ClearWorkDir(); } // the capture and MinerU's copy of the result
            });
            var (folder, mdPath, markdown) = Unpack(zip);
            try { Clipboard.SetText(markdown); } catch { /* busy: the file is there anyway */ }
            NotifyPopup.Show(Loc.F("Restored as Markdown in {0} — the text is on the clipboard", Path.GetFileName(folder)));
            Process.Start("explorer.exe", $"/select,\"{mdPath}\"");
        }
        catch (Exception ex)
        {
            NotifyPopup.Show(Loc.T("MinerU failed.") + $"\n{ex.Message}");
        }
        finally
        {
            _idle = new Timer(_ => Stop(), null, IdleExit, Timeout.InfiniteTimeSpan);
            Gate.Release();
        }
    }

    public static void RestoreFile(string path)
    {
        try
        {
            var bmp = new BitmapImage();
            bmp.BeginInit();
            bmp.CacheOption = BitmapCacheOption.OnLoad;
            bmp.UriSource = new Uri(Path.GetFullPath(path));
            bmp.EndInit();
            bmp.Freeze();
            Restore(bmp);
        }
        catch (Exception ex) { NotifyPopup.Show(Loc.F("Couldn't open {0}", Path.GetFileName(path)) + $"\n{ex.Message}"); }
    }

    public static void Stop()
    {
        var server = Interlocked.Exchange(ref _server, null);
        if (server is null) return;
        try { if (!server.HasExited) server.Kill(entireProcessTree: true); } catch { }
        server.Dispose();
    }

    private static async Task StartAsync()
    {
        Stop();
        int port = FreePort();
        var psi = new ProcessStartInfo(Python)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        // Through "python -m": the mineru-api.exe launcher resolves the junction back to the real
        // (possibly non-ASCII) path, where fastText fails to load its language model.
        foreach (var a in new[] { "-m", "mineru.cli.fast_api", "--host", "127.0.0.1", "--port", port.ToString() })
            psi.ArgumentList.Add(a);
        psi.Environment["PYTHONIOENCODING"] = "utf-8";
        ApplyLocalModels(psi);
        // The server keeps every upload and result under ./output by default — wherever Sitch was started.
        ClearWorkDir();
        psi.WorkingDirectory = WorkDir;
        psi.Environment["MINERU_API_OUTPUT_ROOT"] = WorkDir;

        lock (Log) Log.Clear();
        Process p;
        try { p = Process.Start(psi)!; }
        catch (Win32Exception ex) { throw new InvalidOperationException($"{Python}: {ex.Message}"); }
        // Unlike the stdin-fed tools, a server outlives a crashed or killed Sitch, holding GPU memory:
        // the job ends it (and the venv launcher's child) whenever Sitch's process ends.
        AssignToJob(p);
        DataReceivedEventHandler keep = (_, e) =>
        {
            if (e.Data is null) return;
            lock (Log)
            {
                Log.Enqueue(e.Data);
                while (Log.Count > 8) Log.Dequeue();
            }
        };
        p.OutputDataReceived += keep;
        p.ErrorDataReceived += keep;
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        _server = p;
        _base = new Uri($"http://127.0.0.1:{port}/");

        var clock = Stopwatch.StartNew();
        while (clock.Elapsed < StartTimeout)
        {
            if (p.HasExited) throw new InvalidOperationException(Tail());
            try
            {
                using var ok = await Http.GetAsync(new Uri(_base, "health"));
                if (ok.IsSuccessStatusCode) return;
            }
            catch (HttpRequestException) { /* not listening yet */ }
            await Task.Delay(500);
        }
        Stop();
        throw new TimeoutException("MinerU did not start within 3 minutes");
    }

    /// <summary>
    /// The environment's own model setup, as its parse scripts use it: <c>mineru-hf.json</c> beside the
    /// environment (local models) and a sibling <c>mineru-model-cache\huggingface</c>. Absent: MinerU's defaults.
    /// </summary>
    private static void ApplyLocalModels(ProcessStartInfo psi)
    {
        var real = Folder;
        try { if (Directory.ResolveLinkTarget(Folder, returnFinalTarget: true) is { } target) real = target.FullName; }
        catch (IOException) { }
        var config = Path.Combine(real, "mineru-hf.json");
        if (File.Exists(config))
        {
            psi.Environment["MINERU_TOOLS_CONFIG_JSON"] = config;
            psi.Environment["MINERU_MODEL_SOURCE"] = "local";
        }
        var cache = Path.Combine(Path.GetDirectoryName(real.TrimEnd('\\'))!, "mineru-model-cache", "huggingface");
        if (Directory.Exists(cache)) psi.Environment["HF_HOME"] = cache;
    }

    private static async Task<byte[]> ParseAsync(byte[] png)
    {
        using var form = new MultipartFormDataContent();
        var file = new ByteArrayContent(png);
        file.Headers.ContentType = new("image/png");
        form.Add(file, "files", "capture.png");
        foreach (var (k, v) in new[]
        {
            ("backend", "pipeline"), ("lang_list", "ch"), ("parse_method", "auto"),
            ("formula_enable", "true"), ("table_enable", "true"),
            ("return_md", "true"), ("return_images", "true"), ("response_format_zip", "true"),
        })
            form.Add(new StringContent(v), k);

        using var cts = new CancellationTokenSource(ParseTimeout);
        using var response = await Http.PostAsync(new Uri(_base!, "file_parse"), form, cts.Token);
        var body = await response.Content.ReadAsByteArrayAsync(cts.Token);
        if (response.StatusCode != HttpStatusCode.OK)
        {
            // Errors come back as JSON with an "error" field; show what MinerU said.
            var text = Encoding.UTF8.GetString(body);
            try
            {
                using var doc = System.Text.Json.JsonDocument.Parse(text);
                if (doc.RootElement.TryGetProperty("error", out var e)) text = e.GetString() ?? text;
            }
            catch (System.Text.Json.JsonException) { }
            throw new InvalidOperationException($"HTTP {(int)response.StatusCode}: {text}");
        }
        return body;
    }

    /// <summary>The ZIP's Markdown and images go to "Sitch … (Markdown)" in the save folder.</summary>
    private static (string Folder, string MdPath, string Markdown) Unpack(byte[] zip)
    {
        var root = App.Settings.DefaultSaveFolder;
        if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))
            root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "Sitch");
        var name = $"Sitch {DateTime.Now:yyyy-MM-dd 'at' HH.mm.ss}";
        var folder = Path.Combine(root, $"{name} (Markdown)");
        for (int n = 2; Directory.Exists(folder); n++) folder = Path.Combine(root, $"{name} ({n}) (Markdown)");
        Directory.CreateDirectory(folder);

        string? mdPath = null, markdown = null;
        using var archive = new ZipArchive(new MemoryStream(zip));
        foreach (var entry in archive.Entries)
        {
            if (entry.FullName.EndsWith('/')) continue;
            // Flatten MinerU's "<name>/auto/" prefix; keep "images/…" so the Markdown's links resolve.
            var parts = entry.FullName.Replace('\\', '/').Split('/');
            int images = Array.IndexOf(parts, "images");
            var relative = images >= 0 ? string.Join('\\', parts[images..]) : parts[^1];
            if (relative.Contains("..")) continue;
            var target = Path.Combine(folder, relative);
            if (relative.EndsWith(".md", StringComparison.OrdinalIgnoreCase))
            {
                target = Path.Combine(folder, $"{name}.md");
                using var reader = new StreamReader(entry.Open(), Encoding.UTF8);
                markdown = reader.ReadToEnd();
                File.WriteAllText(target, markdown, new UTF8Encoding(false));
                mdPath = target;
                continue;
            }
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            entry.ExtractToFile(target, overwrite: true);
        }
        if (mdPath is null || markdown is null) throw new InvalidOperationException("MinerU returned no Markdown");
        return (folder, mdPath, markdown);
    }

    private static byte[] EncodePng(BitmapSource image)
    {
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(image));
        using var ms = new MemoryStream();
        encoder.Save(ms);
        return ms.ToArray();
    }

    private static string WorkDir => Path.Combine(Path.GetTempPath(), "Sitch", "mineru");

    private static void ClearWorkDir()
    {
        try
        {
            if (Directory.Exists(WorkDir))
                foreach (var dir in Directory.GetDirectories(WorkDir)) Directory.Delete(dir, recursive: true);
            Directory.CreateDirectory(WorkDir);
        }
        catch (IOException) { } // a file still open on MinerU's side goes next time
        catch (UnauthorizedAccessException) { }
    }

    private static int FreePort()
    {
        var l = new TcpListener(IPAddress.Loopback, 0);
        l.Start();
        int port = ((IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return port;
    }

    private static string Tail()
    {
        lock (Log) return Log.Count > 0 ? string.Join("\n", Log) : "MinerU exited";
    }

    private static IntPtr _job;

    private static void AssignToJob(Process p)
    {
        if (_job == IntPtr.Zero)
        {
            var job = CreateJobObject(IntPtr.Zero, null);
            var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION { BasicLimitInformation = { LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE } };
            int size = System.Runtime.InteropServices.Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>();
            if (job == IntPtr.Zero || !SetInformationJobObject(job, JobObjectExtendedLimitInformation, ref info, size)) return;
            _job = job; // never closed: the handle closes with Sitch, and that ends the job's processes
        }
        AssignProcessToJobObject(_job, p.Handle);
    }

    private const int JobObjectExtendedLimitInformation = 9;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct IO_COUNTERS { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string? name);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, int size);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
}
