using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Sitch.Capture;
using Sitch.Core;

namespace Sitch.Shell;

/// <summary>
/// Scrolling capture: the user scrolls a chosen region (wheel, keys, scrollbar — anything) while it is
/// sampled every 80 ms and joined by <see cref="ScrollStitcher"/>. A click-through frame marks the region
/// just outside it (so it never lands in a sample) and a no-activate bar beside it shows the height with
/// Done / Cancel; focus stays in the app being scrolled. Done routes the long image like any capture.
/// </summary>
public sealed class ScrollCaptureSession
{
    private static ScrollCaptureSession? _current;

    private readonly Int32Rect _rect;
    private readonly ScrollStitcher _stitcher;
    private readonly DispatcherTimer _timer;
    private readonly Window _frame;
    private readonly Window _bar;
    private readonly TextBlock _status;
    private readonly TextBlock _height;
    private DateTime _warnUntil;

    public static bool IsActive => _current is not null;

    /// <param name="rect">Physical virtual-screen pixels.</param>
    public static void Start(Int32Rect rect)
    {
        if (_current is not null) return;
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

        double scale = MonitorScale(rect.X + rect.Width / 2, rect.Y + rect.Height / 2);
        int pad = (int)Math.Ceiling(3 * scale);
        _frame = new Window
        {
            WindowStyle = WindowStyle.None,
            AllowsTransparency = true,
            Background = Brushes.Transparent,
            Topmost = true,
            ShowInTaskbar = false,
            ShowActivated = false,
            ResizeMode = ResizeMode.NoResize,
            Content = new Border { BorderThickness = new Thickness(2), BorderBrush = new SolidColorBrush(Color.FromRgb(0xFF, 0x33, 0x66)) },
        };
        void PlaceFrame() => SetWindowPos(new WindowInteropHelper(_frame).Handle, HWND_TOPMOST,
            rect.X - pad, rect.Y - pad, rect.Width + 2 * pad, rect.Height + 2 * pad, SWP_NOACTIVATE);
        // Moving onto a monitor with another scale makes WPF rescale the window to the DPI change's
        // suggested rect (a 100% → 150% move grew the frame by half); set the physical rect again after.
        _frame.DpiChanged += (_, _) => _frame.Dispatcher.BeginInvoke(PlaceFrame, DispatcherPriority.Loaded);
        _frame.SourceInitialized += (_, _) =>
        {
            AddExStyle(new WindowInteropHelper(_frame).Handle, WS_EX_TRANSPARENT | WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE);
            PlaceFrame();
        };

        _status = new TextBlock { Text = Loc.T("Scroll the area slowly…"), Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center };
        _height = new TextBlock
        {
            Foreground = new SolidColorBrush(Color.FromRgb(0xFF, 0x8F, 0xAB)),
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(12, 0, 14, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var done = new Button { Content = Loc.T("Done"), Margin = new Thickness(0, 0, 8, 0) };
        done.SetResourceReference(FrameworkElement.StyleProperty, "PrimaryButton");
        done.Click += (_, _) => Finish(keep: true);
        var cancel = new Button { Content = Loc.T("Cancel") };
        cancel.SetResourceReference(FrameworkElement.StyleProperty, "GhostButton");
        cancel.Click += (_, _) => Finish(keep: false);
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(_status);
        row.Children.Add(_height);
        row.Children.Add(done);
        row.Children.Add(cancel);

        _bar = new Window
        {
            WindowStyle = WindowStyle.None,
            AllowsTransparency = true,
            Background = Brushes.Transparent,
            Topmost = true,
            ShowInTaskbar = false,
            ShowActivated = false,
            ResizeMode = ResizeMode.NoResize,
            SizeToContent = SizeToContent.WidthAndHeight,
            Left = -32000, Top = -32000,
            Content = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(0xF0, 0x1E, 0x1E, 0x22)),
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF)),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(10),
                Padding = new Thickness(14, 7, 8, 7),
                Child = row,
            },
        };
        _bar.SourceInitialized += (_, _) => AddExStyle(new WindowInteropHelper(_bar).Handle, WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE);
        _bar.ContentRendered += (_, _) => PlaceBar(pad);
        _bar.DpiChanged += (_, _) => _bar.Dispatcher.BeginInvoke(() => PlaceBar(pad), DispatcherPriority.Loaded);

        UpdateLabels();
        _frame.Show();
        _bar.Show();

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
        _frame.Close();
        _bar.Close();
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

    /// <summary>Below the region, else above it, else inside its bottom edge; kept on the region's monitor.</summary>
    private void PlaceBar(int pad)
    {
        var hwnd = new WindowInteropHelper(_bar).Handle;
        GetWindowRect(hwnd, out var r);
        int bw = r.Right - r.Left, bh = r.Bottom - r.Top;
        var mi = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        GetMonitorInfo(MonitorFromPoint(new Native.POINT { X = _rect.X + _rect.Width / 2, Y = _rect.Y + _rect.Height / 2 }, 2), ref mi);
        var work = mi.rcWork;
        int gap = pad + 8;
        int x = Math.Clamp(_rect.X + (_rect.Width - bw) / 2, work.Left + 8, Math.Max(work.Left + 8, work.Right - bw - 8));
        int y = _rect.Y + _rect.Height + gap;
        if (y + bh > work.Bottom - 8) y = _rect.Y - gap - bh;
        if (y < work.Top + 8) y = _rect.Y + _rect.Height - bh - gap; // no room outside: sits over the bottom edge
        SetWindowPos(hwnd, HWND_TOPMOST, x, y, 0, 0, SWP_NOACTIVATE | SWP_NOSIZE);
    }

    private static double MonitorScale(int x, int y)
    {
        var mon = MonitorFromPoint(new Native.POINT { X = x, Y = y }, 2);
        return Native.GetDpiForMonitor(mon, 0, out uint dpi, out _) == 0 && dpi > 0 ? dpi / 96.0 : 1;
    }

    private static void AddExStyle(IntPtr hwnd, long add)
    {
        long ex = GetWindowLongPtr(hwnd, GWL_EXSTYLE).ToInt64();
        SetWindowLongPtr(hwnd, GWL_EXSTYLE, new IntPtr(ex | add));
    }

    private const int GWL_EXSTYLE = -20;
    private const long WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_LAYERED = 0x80000, WS_EX_NOACTIVATE = 0x8000000;
    private static readonly IntPtr HWND_TOPMOST = new(-1);
    private const uint SWP_NOSIZE = 0x1, SWP_NOACTIVATE = 0x10;

    [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public uint dwFlags; }

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromPoint(Native.POINT pt, uint flags);
    [DllImport("user32.dll")] private static extern bool GetMonitorInfo(IntPtr mon, ref MONITORINFO mi);
}
