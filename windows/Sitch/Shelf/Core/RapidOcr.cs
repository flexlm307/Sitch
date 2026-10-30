using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;

namespace Sitch.Shelf.Core;

/// <summary>
/// OCR through RapidOCR (PaddleOCR models on ONNX Runtime, <c>pip install rapidocr</c>): far better than
/// Windows' engine on mixed Chinese/English. Loading the models costs seconds, so one Python worker
/// starts on first use, reads image paths from stdin and answers one JSON line each, and exits after
/// ten idle minutes (or when Sitch's stdin pipe closes).
/// </summary>
public static class RapidOcr
{
    private static readonly TimeSpan StartTimeout = TimeSpan.FromSeconds(90);
    private static readonly TimeSpan ReadTimeout = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan IdleExit = TimeSpan.FromMinutes(10);

    private static readonly SemaphoreSlim Gate = new(1, 1);
    private static Process? _worker;
    private static Timer? _idle;
    private static readonly Queue<string> StderrTail = new();

    // Rows: boxes whose vertical centres sit within half a box height share a line, read left to right.
    // Scores under 0.6 are mostly icons read as letters.
    private const string Worker = """
        import sys, json
        sys.stdin.reconfigure(encoding="utf-8")
        sys.stdout.reconfigure(encoding="utf-8")
        from rapidocr import RapidOCR
        engine = RapidOCR()

        def text_of(r):
            items = []
            for box, txt, score in zip(r.boxes, r.txts, r.scores):
                txt = txt.strip()
                if score < 0.6 or not txt:
                    continue
                ys = [p[1] for p in box]
                items.append((min(ys), max(ys), min(p[0] for p in box), txt))
            items.sort(key=lambda i: (i[0] + i[1]) / 2)
            rows = []
            for top, bottom, left, txt in items:
                mid = (top + bottom) / 2
                if rows and abs(mid - rows[-1][0]) < (bottom - top) / 2:
                    rows[-1][1].append((left, txt))
                else:
                    rows.append((mid, [(left, txt)]))
            return "\n".join("  ".join(t for _, t in sorted(cells)) for _, cells in rows)

        print(json.dumps({"ready": True}), flush=True)
        for line in sys.stdin:
            path = line.strip()
            if not path:
                continue
            try:
                r = engine(path)
                out = {"text": text_of(r) if r.txts else ""}
            except Exception as e:
                out = {"error": str(e)}
            print(json.dumps(out, ensure_ascii=False), flush=True)
        """;

    /// <returns>The recognised text, rows joined by new lines (empty when nothing was found).</returns>
    public static async Task<string> ReadAsync(string imagePath)
    {
        await Gate.WaitAsync();
        try
        {
            _idle?.Dispose();
            var worker = _worker is { HasExited: false } ? _worker : _worker = await StartAsync();
            await worker.StandardInput.WriteLineAsync(imagePath);
            await worker.StandardInput.FlushAsync();
            var line = await ReadLineAsync(worker, ReadTimeout);
            using var doc = JsonDocument.Parse(line);
            if (doc.RootElement.TryGetProperty("error", out var error)) throw new InvalidOperationException(error.GetString());
            return doc.RootElement.GetProperty("text").GetString() ?? "";
        }
        catch
        {
            Stop(); // a confused worker would answer the next request with this one's reply
            throw;
        }
        finally
        {
            _idle = new Timer(_ => Stop(), null, IdleExit, Timeout.InfiniteTimeSpan);
            Gate.Release();
        }
    }

    public static void Stop()
    {
        var worker = Interlocked.Exchange(ref _worker, null);
        if (worker is null) return;
        try { if (!worker.HasExited) worker.Kill(entireProcessTree: true); } catch { }
        worker.Dispose();
    }

    private static async Task<Process> StartAsync()
    {
        lock (StderrTail) StderrTail.Clear();
        foreach (var (exe, prefix) in new[] { ("python", Array.Empty<string>()), ("py", new[] { "-3" }) })
        {
            var psi = new ProcessStartInfo(exe)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardInputEncoding = new UTF8Encoding(false),
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            psi.Environment["PYTHONIOENCODING"] = "utf-8";
            foreach (var a in prefix) psi.ArgumentList.Add(a);
            psi.ArgumentList.Add("-c");
            psi.ArgumentList.Add(Worker);

            Process p;
            try { p = Process.Start(psi)!; }
            catch (Win32Exception) { continue; } // no Python under this name

            // RapidOCR logs to stderr; keep draining it (a full pipe would stall the worker) and keep
            // the tail for error messages.
            p.ErrorDataReceived += (_, e) =>
            {
                if (e.Data is null) return;
                lock (StderrTail)
                {
                    StderrTail.Enqueue(e.Data);
                    while (StderrTail.Count > 6) StderrTail.Dequeue();
                }
            };
            p.BeginErrorReadLine();
            try
            {
                await ReadLineAsync(p, StartTimeout); // {"ready": true}
                return p;
            }
            catch
            {
                try { p.Kill(entireProcessTree: true); } catch { }
                p.Dispose();
                throw;
            }
        }
        throw new InvalidOperationException("Python was not found (python / py)");
    }

    private static async Task<string> ReadLineAsync(Process p, TimeSpan timeout)
    {
        string? line;
        try { line = await p.StandardOutput.ReadLineAsync().WaitAsync(timeout); }
        catch (TimeoutException) { throw new TimeoutException($"RapidOCR did not answer within {timeout.TotalSeconds:0} s"); }
        if (line is not null) return line;
        string tail;
        lock (StderrTail) tail = string.Join("\n", StderrTail);
        // The usual cause: "No module named 'rapidocr'".
        throw new InvalidOperationException(tail.Length > 0 ? tail : "RapidOCR exited");
    }
}
