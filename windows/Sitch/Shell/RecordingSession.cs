using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Sitch.Capture;
using Sitch.Export;

namespace Sitch.Shell;

/// <summary>
/// Screen recording of one region to MP4 or GIF through FFmpeg. A worker thread grabs the region (with
/// the pointer) at a steady rate and pipes raw frames to FFmpeg; a frame that comes late is written
/// again so the clip keeps real time. MP4 is encoded on the fly. GIF is first recorded as a near-lossless
/// temporary MP4, then converted in two passes — palettegen over the whole clip, then paletteuse —
/// for far better colours than one fixed palette, without holding every frame in memory.
/// </summary>
public sealed class RecordingSession
{
    private static RecordingSession? _current;

    public static bool IsActive => _current is not null;

    private const int GifFps = 12, Mp4Fps = 30;
    private static readonly TimeSpan GifLimit = TimeSpan.FromMinutes(1), Mp4Limit = TimeSpan.FromMinutes(30);

    private readonly bool _gif;
    private readonly int _fps;
    private readonly string _output, _temp;
    private readonly FrameGrabber _grabber;
    private readonly Ffmpeg _encoder;
    private readonly RegionChrome _chrome;
    private readonly TextBlock _time;
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private readonly DispatcherTimer _ticker;
    private readonly Thread _worker;
    private volatile bool _stop;
    private string? _workerError;

    /// <param name="rect">Physical virtual-screen pixels.</param>
    /// <param name="format">"gif" or "mp4".</param>
    public static void Start(Int32Rect rect, string format)
    {
        if (_current is not null || ScrollCaptureSession.IsActive) return;
        // H.264 in 4:2:0 needs even sizes; one pixel off the edge is never missed.
        rect = new Int32Rect(rect.X, rect.Y, rect.Width & ~1, rect.Height & ~1);
        if (rect.Width < 16 || rect.Height < 16) return;
        if (!Ffmpeg.Available)
        {
            NotifyPopup.Show(Loc.T("Recording needs FFmpeg on the PATH: winget install Gyan.FFmpeg"));
            return;
        }
        try { _current = new RecordingSession(rect, format == "mp4" ? "mp4" : "gif"); }
        catch (Exception ex)
        {
            _current = null;
            NotifyPopup.Show(Loc.T("Recording failed.") + $"\n{ex.Message}");
        }
    }

    private RecordingSession(Int32Rect rect, string format)
    {
        _gif = format == "gif";
        _fps = _gif ? GifFps : Mp4Fps;
        _output = OutputPath(format);
        _temp = Path.Combine(Path.GetTempPath(), "Sitch", $"rec-{Guid.NewGuid():N}.mp4");
        Directory.CreateDirectory(Path.GetDirectoryName(_temp)!);

        _grabber = new FrameGrabber(rect);
        _encoder = Ffmpeg.Encoder(rect.Width, rect.Height, _fps, _gif
            // Near-lossless and full-chroma: GIF conversion works from this.
            ? ["-c:v", "libx264", "-preset", "ultrafast", "-crf", "8", "-pix_fmt", "yuv444p", _temp]
            : ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p", "-movflags", "+faststart", _output]);

        var dot = RegionChrome.Label("●", new SolidColorBrush(Color.FromRgb(0xFF, 0x3B, 0x30)));
        dot.Margin = new Thickness(0, 0, 6, 0);
        _time = RegionChrome.Label("00:00", bold: true);
        var size = RegionChrome.Label($"{rect.Width}×{rect.Height} · {format.ToUpperInvariant()}", new SolidColorBrush(Color.FromRgb(0xB0, 0xB0, 0xB8)));
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(dot);
        row.Children.Add(_time);
        row.Children.Add(size);
        row.Children.Add(RegionChrome.BarButton(Loc.T("Stop"), primary: true, () => Stop(keep: true)));
        row.Children.Add(RegionChrome.BarButton(Loc.T("Cancel"), primary: false, () => Stop(keep: false)));
        _chrome = new RegionChrome(rect, row) { Frame = Brushes.Red };

        _ticker = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        _ticker.Tick += (_, _) =>
        {
            var t = _clock.Elapsed;
            _time.Text = $"{(int)t.TotalMinutes:00}:{t.Seconds:00}";
            if (_workerError is not null || t >= (_gif ? GifLimit : Mp4Limit)) Stop(keep: true);
        };
        _ticker.Start();

        _worker = new Thread(Record) { IsBackground = true, Name = "Sitch recorder" };
        _worker.Start();
    }

    private void Record()
    {
        var frame = new byte[_grabber.FrameBytes];
        long written = 0;
        bool pointer = App.Settings.RecordPointer;
        try
        {
            while (!_stop)
            {
                _grabber.Grab(frame, pointer);
                // Frames owed by now: a slow grab or encode repeats this one instead of shortening time.
                long due = (long)(_clock.Elapsed.TotalSeconds * _fps) + 1;
                do { _encoder.Input.Write(frame, 0, frame.Length); written++; } while (written < due);
                var next = TimeSpan.FromSeconds((double)written / _fps) - _clock.Elapsed;
                if (next > TimeSpan.Zero) Thread.Sleep(next);
            }
        }
        catch (Exception ex) { _workerError = ex.Message; } // FFmpeg quit early: Stop reports its own error
    }

    private async void Stop(bool keep)
    {
        if (_current != this) return;
        _current = null;
        _ticker.Stop();
        _stop = true;
        _chrome.Close();
        // Cancel kills FFmpeg first: a worker blocked writing to it then fails out instead of hanging Join.
        if (!keep) _encoder.Kill();
        _worker.Join();
        _grabber.Dispose();

        if (!keep)
        {
            _encoder.Dispose();
            TryDelete(_temp);
            TryDelete(_output);
            return;
        }

        NotifyPopup.Show(Loc.T(_gif ? "Making the GIF…" : "Saving the video…"));
        try
        {
            await _encoder.FinishAsync();
            if (_gif) await MakeGifAsync();
            CopyFileToClipboard(_output);
            NotifyPopup.Show(Loc.F("Saved {0} — the file is on the clipboard", Path.GetFileName(_output)));
        }
        catch (Exception ex)
        {
            NotifyPopup.Show(Loc.T("Recording failed.") + $"\n{ex.Message}");
            TryDelete(_output);
        }
        finally
        {
            _encoder.Dispose();
            TryDelete(_temp);
        }
    }

    private async Task MakeGifAsync()
    {
        var palette = Path.ChangeExtension(_temp, ".png");
        try
        {
            // diff mode: the palette favours what moves; rectangle: each frame only redraws what changed.
            await Ffmpeg.RunAsync(["-i", _temp, "-vf", "palettegen=stats_mode=diff", palette]);
            await Ffmpeg.RunAsync(["-i", _temp, "-i", palette, "-lavfi",
                "paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle", "-loop", "0", _output]);
        }
        finally { TryDelete(palette); }
    }

    private static string OutputPath(string ext)
    {
        var folder = App.Settings.DefaultSaveFolder;
        if (string.IsNullOrWhiteSpace(folder) || !Directory.Exists(folder))
            folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "Sitch");
        Directory.CreateDirectory(folder);
        var baseName = $"Sitch {DateTime.Now:yyyy-MM-dd 'at' HH.mm.ss}";
        var path = Path.Combine(folder, $"{baseName}.{ext}");
        for (int n = 2; File.Exists(path); n++) path = Path.Combine(folder, $"{baseName} ({n}).{ext}");
        return path;
    }

    private static void CopyFileToClipboard(string path)
    {
        try { Clipboard.SetFileDropList([path]); }
        catch { /* clipboard busy: the file is saved anyway */ }
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); } catch (Exception e) when (e is IOException or UnauthorizedAccessException or Win32Exception) { }
    }
}
