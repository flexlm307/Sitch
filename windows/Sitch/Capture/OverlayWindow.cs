using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Sitch.Capture;

/// <summary>
/// One borderless topmost overlay per monitor showing that monitor's slice of the frozen
/// desktop. Draw + hit-test in DIPs locally; every coordinate handed to the controller is a
/// physical virtual-screen pixel, so cross-monitor drags with mixed scale factors stay exact.
/// NOTE: all painting happens in a child FrameworkElement — drawing in Window.OnRender is
/// invisible because the Window template paints its Background over it.
/// </summary>
public sealed class OverlayWindow : Window
{
    private readonly CaptureController _controller;
    private readonly MonitorData _monitor;
    private readonly OverlayVisual _visual;
    private double _scale; // physical px per DIP for this window
    private bool _closing;

    public OverlayWindow(CaptureController controller, MonitorData monitor,
        BitmapSource frozen, Int32Rect frozenBounds, bool activate)
    {
        _controller = controller;
        _monitor = monitor;
        _scale = monitor.Scale;

        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = activate;
        Focusable = true; // the activated overlay must catch Esc / arrows / Enter
        Topmost = true;
        Background = Brushes.Black;
        Cursor = controller.Mode == CaptureMode.Region ? Cursors.Cross : Cursors.Arrow;
        // Off-screen until SourceInitialized pins us to the monitor's physical bounds.
        Left = -32000; Top = -32000; Width = 10; Height = 10;

        _visual = new OverlayVisual(this, frozen, frozenBounds);
        Content = _visual;
        RenderOptions.SetBitmapScalingMode(_visual, BitmapScalingMode.NearestNeighbor);
        SnapsToDevicePixels = true;

        SourceInitialized += OnSourceInitialized;
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        // Physical placement — bypasses WPF's DIP layout entirely.
        Native.SetWindowPos(hwnd, Native.HWND_TOPMOST,
            _monitor.Bounds.X, _monitor.Bounds.Y, _monitor.Bounds.Width, _monitor.Bounds.Height,
            ShowActivated ? Native.SWP_SHOWWINDOW : Native.SWP_SHOWWINDOW | Native.SWP_NOACTIVATE);

        // Give the overlay under the cursor real keyboard focus so a plain Esc cancels the capture.
        if (ShowActivated)
        {
            Activate();
            Keyboard.Focus(this);
        }

        if (PresentationSource.FromVisual(this)?.CompositionTarget is { } ct)
            _scale = ct.TransformToDevice.M11;
        _visual.InvalidateVisual();
    }

    protected override void OnDpiChanged(DpiScale oldDpi, DpiScale newDpi)
    {
        base.OnDpiChanged(oldDpi, newDpi);
        _scale = newDpi.DpiScaleX;
        // Re-pin: DPI change can nudge WPF layout.
        var hwnd = new WindowInteropHelper(this).Handle;
        Native.SetWindowPos(hwnd, Native.HWND_TOPMOST,
            _monitor.Bounds.X, _monitor.Bounds.Y, _monitor.Bounds.Width, _monitor.Bounds.Height,
            Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
        _visual.InvalidateVisual();
    }

    public void RepaintOverlay() => _visual.InvalidateVisual();

    // ---- Coordinate mapping -----------------------------------------------------

    private Point ToPhysical(Point dip) =>
        new(_monitor.Bounds.X + dip.X * _scale, _monitor.Bounds.Y + dip.Y * _scale);

    private Point ToLocalDip(double physX, double physY) =>
        new((physX - _monitor.Bounds.X) / _scale, (physY - _monitor.Bounds.Y) / _scale);

    private Rect ToLocalDip(Int32Rect physical)
    {
        var tl = ToLocalDip(physical.X, physical.Y);
        return new Rect(tl, new Size(physical.Width / _scale, physical.Height / _scale));
    }

    // ---- Input ----------------------------------------------------------------

    protected override void OnMouseDown(MouseButtonEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.ChangedButton == MouseButton.Right) { _controller.Cancel(); return; }
        if (e.ChangedButton != MouseButton.Left) return;
        CaptureMouse();
        var phys = ToPhysical(e.GetPosition(this));
        if (_controller.Mode == CaptureMode.Region)
            _controller.BeginDrag(phys);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        _controller.UpdatePointer(ToPhysical(e.GetPosition(this)));
    }

    protected override void OnMouseUp(MouseButtonEventArgs e)
    {
        base.OnMouseUp(e);
        if (e.ChangedButton != MouseButton.Left) return;
        ReleaseMouseCapture();
        _controller.EndDrag(ToPhysical(e.GetPosition(this)));
    }

    protected override void OnMouseWheel(MouseWheelEventArgs e)
    {
        base.OnMouseWheel(e);
        _controller.StepSnap(outward: e.Delta > 0);
        e.Handled = true;
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        bool shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
        int step = Keyboard.Modifiers.HasFlag(ModifierKeys.Control) ? 10 : 1;
        switch (e.Key)
        {
            case Key.Escape:
                // A single Escape always abandons the whole capture — nothing is captured.
                _controller.Cancel();
                e.Handled = true;
                break;
            case Key.Enter:
                _controller.ConfirmSelection();
                e.Handled = true;
                break;
            case Key.Left: _controller.NudgeSelection(-step, 0, shift); e.Handled = true; break;
            case Key.Right: _controller.NudgeSelection(step, 0, shift); e.Handled = true; break;
            case Key.Up: _controller.NudgeSelection(0, -step, shift); e.Handled = true; break;
            case Key.Down: _controller.NudgeSelection(0, step, shift); e.Handled = true; break;
            case Key.C when Keyboard.Modifiers is ModifierKeys.None or ModifierKeys.Shift:
                _controller.CopyColor(asRgb: shift);
                e.Handled = true;
                break;
        }
    }

    public void CloseOverlay()
    {
        if (_closing) return;
        _closing = true;
        Close();
    }

    // ---- Painting (child element — Window.OnRender would be painted over) ------------

    private sealed class OverlayVisual : FrameworkElement
    {
        private static readonly Brush DimBrush = new SolidColorBrush(Color.FromArgb(0x73, 0, 0, 0));
        private static readonly Pen SelectionPen = new(new SolidColorBrush(Color.FromRgb(0xFF, 0x33, 0x66)), 1.5);
        private static readonly Brush ReadoutBg = new SolidColorBrush(Color.FromArgb(0xD9, 0x1E, 0x1E, 0x20));
        private static readonly Pen GridPen = new(new SolidColorBrush(Color.FromArgb(0x24, 0xFF, 0xFF, 0xFF)), 1);
        private static readonly Brush DimText = new SolidColorBrush(Color.FromRgb(0xD2, 0xD2, 0xD2));

        // Magnifier: a 15x15 physical-pixel sample, 8 DIP per pixel.
        private const int Grid = 15, Cell = 8, Pad = 8;

        static OverlayVisual()
        {
            DimBrush.Freeze();
            SelectionPen.Freeze();
            ReadoutBg.Freeze();
            GridPen.Freeze();
            DimText.Freeze();
        }

        private readonly OverlayWindow _win;
        private readonly BitmapSource _frozen;
        private readonly Int32Rect _frozenBounds;

        public OverlayVisual(OverlayWindow win, BitmapSource frozen, Int32Rect frozenBounds)
        {
            _win = win;
            _frozen = frozen;
            _frozenBounds = frozenBounds;
            IsHitTestVisible = false; // input is handled by the window itself
        }

        protected override void OnRender(DrawingContext dc)
        {
            base.OnRender(dc);
            var c = _win._controller;
            double scale = _win._scale;
            var mon = _win._monitor.Bounds;

            double w = mon.Width / scale;
            double h = mon.Height / scale;
            var full = new Rect(0, 0, w, h);

            // Frozen desktop: draw the whole virtual-screen bitmap offset so our slice lines up 1:1.
            var imgRect = new Rect(
                (_frozenBounds.X - mon.X) / scale,
                (_frozenBounds.Y - mon.Y) / scale,
                _frozenBounds.Width / scale,
                _frozenBounds.Height / scale);
            dc.DrawImage(_frozen, imgRect);

            // Region mode: drag/keyboard selection wins; otherwise a plain click captures the
            // hovered window, so show that highlight. Window mode: hover only.
            bool hasSelection = c.Mode switch
            {
                CaptureMode.Region => c.HasSelection || c.HoveredWindow is not null,
                CaptureMode.Window => c.HoveredWindow is not null,
                _ => false,
            };

            Int32Rect selPhys = c.Mode == CaptureMode.Region && c.HasSelection
                ? c.SelectionRect
                : c.HoveredElement?.Bounds ?? c.HoveredWindow?.Bounds ?? default;
            bool hovering = !(c.Mode == CaptureMode.Region && c.HasSelection);

            if (hasSelection)
            {
                var sel = _win.ToLocalDip(selPhys);
                var dimGeo = new CombinedGeometry(GeometryCombineMode.Exclude,
                    new RectangleGeometry(full), new RectangleGeometry(sel));
                dc.DrawGeometry(DimBrush, null, dimGeo);
                dc.DrawRectangle(null, SelectionPen, sel);
                // Only annotate the readout on overlays the selection actually touches.
                if (sel.IntersectsWith(full))
                    DrawReadout(dc, full, sel, hovering && c.HoverKind.Length > 0
                        ? $"{c.HoverKind}  {selPhys.Width} × {selPhys.Height}"
                        : $"{selPhys.Width} × {selPhys.Height}");
                if (c.Mode == CaptureMode.Region && !c.HasSelection)
                    DrawCrosshair(dc, full);
            }
            else
            {
                dc.DrawRectangle(DimBrush, null, full);
                if (c.Mode == CaptureMode.Region)
                    DrawCrosshair(dc, full);
            }

            if (c.Mode == CaptureMode.Region && App.Settings.ShowMagnifier)
                DrawMagnifier(dc, full);
        }

        /// <summary>
        /// Zoomed view of the frozen frame around the pointer plus that pixel's colour (C copies HEX,
        /// Shift+C RGB). Samples physical pixels, so the centre cell is exactly the pixel under the
        /// pointer at any scale factor. Only the monitor holding the pointer draws it.
        /// </summary>
        private void DrawMagnifier(DrawingContext dc, Rect full)
        {
            var c = _win._controller;
            var p = c.PointerPhysical;
            var local = _win.ToLocalDip(p.X, p.Y);
            if (!full.Contains(local) || c.PixelAt(p) is not { } color) return;

            // Clamp the sample inside the frame; the centre cell then follows the pointer to the edge.
            int px = (int)Math.Floor(p.X) - _frozenBounds.X, py = (int)Math.Floor(p.Y) - _frozenBounds.Y;
            int sx = Math.Clamp(px - Grid / 2, 0, Math.Max(0, _frozen.PixelWidth - Grid));
            int sy = Math.Clamp(py - Grid / 2, 0, Math.Max(0, _frozen.PixelHeight - Grid));
            var sample = new CroppedBitmap(_frozen, new Int32Rect(sx, sy,
                Math.Min(Grid, _frozen.PixelWidth - sx), Math.Min(Grid, _frozen.PixelHeight - sy)));

            const double zoom = Grid * Cell;
            double dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
            string[] lines =
            [
                $"({(int)Math.Floor(p.X)}, {(int)Math.Floor(p.Y)})",
                $"RGB {color.R}, {color.G}, {color.B}",
                $"#{color.R:X2}{color.G:X2}{color.B:X2}",
                Shell.Loc.T("C: copy HEX · Shift+C: RGB"),
            ];
            var texts = lines.Select((l, i) => new FormattedText(l, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
                new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, i == 2 ? FontWeights.SemiBold : FontWeights.Normal, FontStretches.Normal),
                i == 3 ? 10.5 : 12, i == 2 ? Brushes.White : DimText, dpi)).ToArray();
            double width = Math.Max(zoom, texts.Max(t => t.Width) + 17) + Pad * 2;
            double height = Pad + zoom + 6 + texts.Sum(t => t.Height + 1) + Pad;

            // Down-right of the pointer, flipped to whichever side has room.
            double x = local.X + 20, y = local.Y + 20;
            if (x + width > full.Width) x = local.X - 20 - width;
            if (y + height > full.Height) y = local.Y - 20 - height;

            dc.DrawRoundedRectangle(ReadoutBg, null, new Rect(x, y, width, height), 6, 6);
            var zoomRect = new Rect(x + Pad, y + Pad, sample.PixelWidth * Cell, sample.PixelHeight * Cell);
            dc.DrawImage(sample, zoomRect);
            for (int i = 0; i <= sample.PixelWidth; i++)
                dc.DrawLine(GridPen, new Point(zoomRect.X + i * Cell, zoomRect.Y), new Point(zoomRect.X + i * Cell, zoomRect.Bottom));
            for (int i = 0; i <= sample.PixelHeight; i++)
                dc.DrawLine(GridPen, new Point(zoomRect.X, zoomRect.Y + i * Cell), new Point(zoomRect.Right, zoomRect.Y + i * Cell));

            // Centre cell outlined in a colour that contrasts with the pixel itself.
            bool light = color.R * 0.299 + color.G * 0.587 + color.B * 0.114 > 128;
            dc.DrawRectangle(null, new Pen(light ? Brushes.Black : Brushes.White, 2),
                new Rect(zoomRect.X + (px - sx) * Cell, zoomRect.Y + (py - sy) * Cell, Cell, Cell));

            double ty = y + Pad + zoom + 6;
            for (int i = 0; i < texts.Length; i++)
            {
                double tx = x + Pad;
                if (i == 2)
                {
                    dc.DrawRectangle(new SolidColorBrush(color), new Pen(Brushes.White, 1), new Rect(tx, ty + 3, 11, 11));
                    tx += 17;
                }
                dc.DrawText(texts[i], new Point(tx, ty));
                ty += texts[i].Height + 1;
            }
        }

        private void DrawCrosshair(DrawingContext dc, Rect full)
        {
            // Shared controller pointer: only the monitor actually containing it draws a crosshair.
            var p = _win._controller.PointerPhysical;
            var local = _win.ToLocalDip(p.X, p.Y);
            if (!full.Contains(local)) return;
            var pen = new Pen(new SolidColorBrush(Color.FromArgb(0x80, 0xFF, 0xFF, 0xFF)), 1);
            dc.DrawLine(pen, new Point(local.X, 0), new Point(local.X, full.Height));
            dc.DrawLine(pen, new Point(0, local.Y), new Point(full.Width, local.Y));
        }

        private void DrawReadout(DrawingContext dc, Rect full, Rect sel, string text)
        {
            var ft = new FormattedText(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal),
                13, Brushes.White, VisualTreeHelper.GetDpi(this).PixelsPerDip);
            double pad = 5;
            double x = Math.Min(sel.Right + 8, full.Width - ft.Width - pad * 2 - 4);
            double y = Math.Min(sel.Bottom + 8, full.Height - ft.Height - pad * 2 - 4);
            if (x < 4) x = 4;
            if (y < 4) y = 4;
            var bg = new Rect(x, y, ft.Width + pad * 2, ft.Height + pad * 2);
            dc.DrawRoundedRectangle(ReadoutBg, null, bg, 5, 5);
            dc.DrawText(ft, new Point(x + pad, y + pad));
        }
    }
}
