using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Sitch.Capture;

namespace Sitch.Shell;

/// <summary>
/// The on-screen furniture of a live capture of one region (scrolling capture, recording): a
/// click-through frame just outside the region — so it never lands in a sample — and a no-activate
/// bar beside it holding the session's controls, so focus stays in the app being captured. Both are
/// placed in physical pixels and placed again after a DPI change (WPF rescales a window that moves to
/// a monitor with another scale).
/// </summary>
public sealed class RegionChrome
{
    private readonly Int32Rect _rect;
    private readonly int _pad;
    private readonly Window _frame;
    private readonly Window _bar;
    private readonly Border _frameBorder;

    /// <param name="rect">Physical virtual-screen pixels.</param>
    public RegionChrome(Int32Rect rect, UIElement barContent)
    {
        _rect = rect;
        _pad = (int)Math.Ceiling(3 * MonitorScale(rect.X + rect.Width / 2, rect.Y + rect.Height / 2));

        _frameBorder = new Border { BorderThickness = new Thickness(2), BorderBrush = FrameBrush };
        _frame = Chromeless();
        _frame.Content = _frameBorder;
        _frame.DpiChanged += (_, _) => _frame.Dispatcher.BeginInvoke(PlaceFrame, DispatcherPriority.Loaded);
        _frame.SourceInitialized += (_, _) =>
        {
            AddExStyle(new WindowInteropHelper(_frame).Handle, WS_EX_TRANSPARENT | WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE);
            PlaceFrame();
        };

        _bar = Chromeless();
        _bar.SizeToContent = SizeToContent.WidthAndHeight;
        _bar.Content = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0xF0, 0x1E, 0x1E, 0x22)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(14, 7, 8, 7),
            Child = barContent,
        };
        _bar.SourceInitialized += (_, _) => AddExStyle(new WindowInteropHelper(_bar).Handle, WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE);
        _bar.ContentRendered += (_, _) => PlaceBar();
        _bar.SizeChanged += (_, _) => PlaceBar(); // labels change width as they count
        _bar.DpiChanged += (_, _) => _bar.Dispatcher.BeginInvoke(PlaceBar, DispatcherPriority.Loaded);

        _frame.Show();
        _bar.Show();
    }

    public static readonly Brush FrameBrush = Frozen(Color.FromRgb(0xFF, 0x33, 0x66));

    /// <summary>The frame's colour, e.g. red while recording.</summary>
    public Brush Frame { set => _frameBorder.BorderBrush = value; }

    public void Close()
    {
        _frame.Close();
        _bar.Close();
    }

    /// <summary>A label and a button styled for the bar.</summary>
    public static TextBlock Label(string text = "", Brush? color = null, bool bold = false) => new()
    {
        Text = text,
        Foreground = color ?? Brushes.White,
        FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
        Margin = new Thickness(0, 0, 12, 0),
        VerticalAlignment = VerticalAlignment.Center,
    };

    public static Button BarButton(string text, bool primary, Action click)
    {
        var b = new Button { Content = text, Margin = new Thickness(0, 0, primary ? 8 : 0, 0) };
        b.SetResourceReference(FrameworkElement.StyleProperty, primary ? "PrimaryButton" : "GhostButton");
        b.Click += (_, _) => click();
        return b;
    }

    private static Window Chromeless() => new()
    {
        WindowStyle = WindowStyle.None,
        AllowsTransparency = true,
        Background = Brushes.Transparent,
        Topmost = true,
        ShowInTaskbar = false,
        ShowActivated = false,
        ResizeMode = ResizeMode.NoResize,
        Left = -32000, Top = -32000,
    };

    private void PlaceFrame() => SetWindowPos(new WindowInteropHelper(_frame).Handle, HWND_TOPMOST,
        _rect.X - _pad, _rect.Y - _pad, _rect.Width + 2 * _pad, _rect.Height + 2 * _pad, SWP_NOACTIVATE);

    /// <summary>Below the region, else above it, else inside its bottom edge; kept on the region's monitor.</summary>
    private void PlaceBar()
    {
        var hwnd = new WindowInteropHelper(_bar).Handle;
        if (hwnd == IntPtr.Zero) return;
        GetWindowRect(hwnd, out var r);
        int bw = r.Right - r.Left, bh = r.Bottom - r.Top;
        var mi = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        GetMonitorInfo(MonitorFromPoint(new Native.POINT { X = _rect.X + _rect.Width / 2, Y = _rect.Y + _rect.Height / 2 }, 2), ref mi);
        var work = mi.rcWork;
        int gap = _pad + 8;
        int x = Math.Clamp(_rect.X + (_rect.Width - bw) / 2, work.Left + 8, Math.Max(work.Left + 8, work.Right - bw - 8));
        int y = _rect.Y + _rect.Height + gap;
        if (y + bh > work.Bottom - 8) y = _rect.Y - gap - bh;
        if (y < work.Top + 8) y = _rect.Y + _rect.Height - bh - gap; // no room outside: sits over the bottom edge
        SetWindowPos(hwnd, HWND_TOPMOST, x, y, 0, 0, SWP_NOACTIVATE | SWP_NOSIZE);
    }

    private static Brush Frozen(Color c)
    {
        var b = new SolidColorBrush(c);
        b.Freeze();
        return b;
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
