using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Sitch.Capture;
using Sitch.Core;

namespace Sitch.Shell;

/// <summary>
/// Scrolling capture: the user scrolls a chosen region (wheel, keys, scrollbar — anything) while it is
/// sampled every 80 ms and joined by <see cref="ScrollStitcher"/>. <see cref="RegionChrome"/> marks the
/// region and holds the height with Done / Cancel. Done routes the long image like any capture.
/// </summary>
public sealed class ScrollCaptureSession
{
    private static ScrollCaptureSession? _current;

    private readonly Int32Rect _rect;
    private readonly ScrollStitcher _stitcher;
    private readonly DispatcherTimer _timer;
    private readonly RegionChrome _chrome;
    private readonly TextBlock _status;
    private readonly TextBlock _height;
    private DateTime _warnUntil;

    public static bool IsActive => _current is not null;

    /// <param name="rect">Physical virtual-screen pixels.</param>
    public static void Start(Int32Rect rect)
    {
        if (_current is not null || RecordingSession.IsActive) return;
        if (rect.Width < 60 || rect.Height < 80)
        {
            NotifyPopup.Show(Loc.T("Choose a larger area to scroll."));
            return;
        }
        _current = new ScrollCaptureSession(rect);
    }

    private ScrollCaptureSession(Int32Rect rect)
    {
        _rect = rect;
        var (first, w, h) = Grab();
        _stitcher = new ScrollStitcher(first, w, h);

        _status = RegionChrome.Label(Loc.T("Scroll the area slowly…"));
        _height = RegionChrome.Label(color: new SolidColorBrush(Color.FromRgb(0xFF, 0x8F, 0xAB)), bold: true);
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(_status);
        row.Children.Add(_height);
        row.Children.Add(RegionChrome.BarButton(Loc.T("Done"), primary: true, () => Finish(keep: true)));
        row.Children.Add(RegionChrome.BarButton(Loc.T("Cancel"), primary: false, () => Finish(keep: false)));
        UpdateLabels();
        _chrome = new RegionChrome(rect, row);

        _timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(80) };
        _timer.Tick += (_, _) => Sample();
        _timer.Start();
    }

    private void Sample()
    {
        var (frame, _, _) = Grab();
        switch (_stitcher.Add(frame))
        {
            case StitchStep.NoMatch:
                _warnUntil = DateTime.Now.AddSeconds(1.5);
                _status.Text = Loc.T("Lost track — scroll back a little, then slower");
                break;
            case StitchStep.Full:
                _status.Text = Loc.T("Maximum height reached");
                break;
            default:
                if (DateTime.Now > _warnUntil) _status.Text = Loc.T("Scroll the area slowly…");
                break;
        }
        UpdateLabels();
    }

    private void UpdateLabels() => _height.Text = Loc.F("{0} px · {1} frames", _stitcher.Height, _stitcher.Frames);

    private void Finish(bool keep)
    {
        _timer.Stop();
        _chrome.Close();
        _current = null;
        if (!keep) return;
        if (_stitcher.Frames < 2)
        {
            NotifyPopup.Show(Loc.T("Nothing scrolled — keeping a normal capture."));
        }
        App.Current.FinishScrollCapture(_stitcher.ToBitmap(), new PixelRect(_rect.X, _rect.Y, _rect.Width, _rect.Height));
    }

    private (byte[] Pixels, int Width, int Height) Grab()
    {
        BitmapSource shot = ScreenFreezer.CapturePhysicalRect(_rect);
        if (shot.Format != PixelFormats.Bgr32) shot = new FormatConvertedBitmap(shot, PixelFormats.Bgr32, null, 0);
        var pixels = new byte[shot.PixelWidth * 4 * shot.PixelHeight];
        shot.CopyPixels(pixels, shot.PixelWidth * 4, 0);
        return (pixels, shot.PixelWidth, shot.PixelHeight);
    }
}
