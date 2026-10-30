using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Windows;
using Sitch.Shell;

namespace Sitch.Export;

/// <summary>
/// Optional post-save compression through MediaMini, an external Python tool. Its cli.py contract: one
/// image, optimized in place, one UTF-8 JSON line on stdout (status, orig_size, new_size, message); it
/// keeps the file as it was when the saving is under 2% or anything fails. Runs off the UI thread.
/// </summary>
public static class MediaMini
{
    private static readonly TimeSpan Timeout = TimeSpan.FromMinutes(2);

    /// <param name="done">Runs on the UI thread after a successful compression (e.g. reload a thumbnail).</param>
    public static void CompressLater(string path, Action? done = null)
    {
        var s = App.Settings;
        if (!s.CompressWithMediaMini) return;
        if (Path.GetExtension(path).ToLowerInvariant() is not (".png" or ".jpg" or ".jpeg")) return;
        var name = Path.GetFileName(path);
        var cli = Path.Combine(s.MediaMiniFolder, "cli.py");
        if (!File.Exists(cli))
        {
            NotifyPopup.Show(Loc.F("MediaMini could not compress {0}: {1}", name, Loc.F("cli.py not found in {0}", s.MediaMiniFolder)));
            return;
        }

        var dispatcher = Application.Current.Dispatcher;
        Task.Run(() =>
        {
            string? error = null;
            long before = 0, after = 0;
            try
            {
                using var doc = JsonDocument.Parse(Run(cli, path));
                var r = doc.RootElement;
                var status = r.GetProperty("status").GetString();
                before = r.GetProperty("orig_size").GetInt64();
                after = r.GetProperty("new_size").GetInt64();
                if (status == "ERROR") error = r.GetProperty("message").GetString();
                else if (status != "SUCCESS") after = before; // already optimal / skipped: nothing to report
            }
            catch (Exception ex) { error = ex.Message; }

            dispatcher.BeginInvoke(() =>
            {
                if (error is not null)
                    NotifyPopup.Show(Loc.F("MediaMini could not compress {0}: {1}", name, error));
                else if (after < before)
                {
                    NotifyPopup.Show(Loc.F("Compressed {0}: {1} → {2}", name, Size(before), Size(after)));
                    done?.Invoke();
                }
            });
        });
    }

    private static string Run(string cli, string image)
    {
        // "python" from PATH first; the py launcher covers installs that only registered that.
        foreach (var (exe, prefix) in new[] { ("python", Array.Empty<string>()), ("py", new[] { "-3" }) })
        {
            var psi = new ProcessStartInfo(exe)
            {
                WorkingDirectory = Path.GetDirectoryName(cli)!,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            foreach (var a in prefix) psi.ArgumentList.Add(a);
            foreach (var a in new[] { cli, "optimize", image, "--in-place", "--no-backup", "--json" }) psi.ArgumentList.Add(a);

            Process p;
            try { p = Process.Start(psi)!; }
            catch (Win32Exception) { continue; } // not installed under this name

            using (p)
            {
                var stdout = p.StandardOutput.ReadToEndAsync();
                var stderr = p.StandardError.ReadToEndAsync();
                if (!p.WaitForExit(Timeout))
                {
                    try { p.Kill(entireProcessTree: true); } catch { }
                    throw new TimeoutException("MediaMini took longer than 2 minutes");
                }
                var json = stdout.Result.Trim();
                if (json.Length == 0) throw new InvalidOperationException(stderr.Result.Trim());
                return json;
            }
        }
        throw new InvalidOperationException("Python was not found (python / py)");
    }

    private static string Size(long bytes) =>
        bytes < 1024 * 1024 ? $"{bytes / 1024.0:0.#} KB" : $"{bytes / (1024.0 * 1024):0.##} MB";
}
