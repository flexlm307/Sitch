using System.ComponentModel;
using System.Diagnostics;
using System.IO;

namespace Sitch.Export;

/// <summary>
/// FFmpeg, an external tool found on the PATH (<c>winget install Gyan.FFmpeg</c>), for screen recordings.
/// <see cref="Encoder"/> takes raw frames on stdin; <see cref="RunAsync"/> runs one-shot conversions.
/// stderr is drained continuously (a full pipe would stall FFmpeg) and its tail kept for error messages.
/// </summary>
public sealed class Ffmpeg : IDisposable
{
    private readonly Process _process;
    private readonly Queue<string> _tail = new();

    private Ffmpeg(Process process)
    {
        _process = process;
        _process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data is null) return;
            lock (_tail)
            {
                _tail.Enqueue(e.Data);
                while (_tail.Count > 8) _tail.Dequeue();
            }
        };
        _process.BeginErrorReadLine();
    }

    public static bool Available
    {
        get
        {
            try
            {
                using var p = Process.Start(new ProcessStartInfo("ffmpeg", "-hide_banner -version")
                { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true });
                return p is not null && p.WaitForExit(5000) && p.ExitCode == 0;
            }
            catch (Win32Exception) { return false; }
        }
    }

    public Stream Input => _process.StandardInput.BaseStream;

    public string Tail
    {
        get { lock (_tail) return string.Join("\n", _tail); }
    }

    /// <summary>Starts FFmpeg reading raw BGRA frames from stdin.</summary>
    public static Ffmpeg Encoder(int width, int height, int fps, IEnumerable<string> outputArgs)
    {
        string[] input = ["-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "bgra",
            "-s", $"{width}x{height}", "-framerate", fps.ToString(), "-i", "-"];
        return new Ffmpeg(Start(input.Concat(outputArgs), stdin: true));
    }

    /// <summary>Runs FFmpeg to completion; throws with its last error lines when it fails.</summary>
    public static async Task RunAsync(IEnumerable<string> args)
    {
        using var f = new Ffmpeg(Start(new[] { "-hide_banner", "-loglevel", "error", "-y" }.Concat(args), stdin: false));
        await f._process.WaitForExitAsync();
        if (f._process.ExitCode != 0) throw new InvalidOperationException(f.Tail);
    }

    /// <summary>Closes stdin (end of the stream) and waits for the file to be finished.</summary>
    public async Task FinishAsync()
    {
        try { _process.StandardInput.Close(); } catch (IOException) { }
        await _process.WaitForExitAsync();
        if (_process.ExitCode != 0) throw new InvalidOperationException(Tail);
    }

    public void Kill()
    {
        try { if (!_process.HasExited) _process.Kill(entireProcessTree: true); } catch { }
    }

    public void Dispose() => _process.Dispose();

    private static Process Start(IEnumerable<string> args, bool stdin)
    {
        var psi = new ProcessStartInfo("ffmpeg")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = stdin,
            RedirectStandardError = true,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        return Process.Start(psi) ?? throw new InvalidOperationException("FFmpeg did not start");
    }
}
