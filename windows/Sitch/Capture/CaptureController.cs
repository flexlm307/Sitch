using System.Windows;
using System.Windows.Media.Imaging;
using Sitch.Core;

namespace Sitch.Capture;

public enum CaptureMode { Region, Window, FullScreen }

/// <param name="PhysicalRect">Region rect for recapture-last (regions only).</param>
/// <param name="SourceScreenRect">Where on screen the capture came from (all modes) — used to open the editor on that display.</param>
public sealed record CaptureResult(BitmapSource Bitmap, CaptureMode Kind,
    PixelRect? PhysicalRect, PixelRect? SourceScreenRect);

/// <summary>
/// Orchestrates interactive capture: freezes the desktop once, opens one overlay window per
/// monitor (each at that monitor's DPI), and completes with a crop of the frozen frame.
/// All selection state lives here, in physical virtual-screen coordinates, so a drag can
/// span monitors with different scale factors. In Region mode a plain click (no drag)
/// captures the hovered window — one hotkey covers region AND window, Skitch-style — or, with
/// <see cref="AppSettings.SnapToElements"/>, the hovered UI element (control, page, pane); the mouse
/// wheel steps out to its parents and back in. Arrow keys define/nudge a selection, Enter confirms.
/// </summary>
public sealed class CaptureController
{
    private readonly List<OverlayWindow> _overlays = new();
    private Action<CaptureResult>? _onDone;
    private BitmapSource? _frozen;
    private Int32Rect _frozenBounds;
    private CaptureMode _mode;
    private List<WindowEntry>? _windows;
    private ElementSnapper? _snapper;
    // Elements under the pointer, window first; _snapLevel indexes the highlighted one.
    private IReadOnlyList<SnapTarget> _snapChain = [];
    private int _snapLevel;
    private int _levelsUp; // wheel steps out from the innermost element, kept while the pointer stays inside
    public bool IsActive { get; private set; }

    // Selection state (physical px, virtual-screen space)
    public bool Dragging { get; private set; }
    public bool HasKeyboardSelection { get; private set; }
    public Point DragStart { get; private set; }
    public Point DragCurrent { get; private set; }
    public Point PointerPhysical { get; private set; }
    public WindowEntry? HoveredWindow { get; private set; }
    public CaptureMode Mode => _mode;

    /// <summary>The snapped element below window level, or null (then a click takes the whole window).</summary>
    public SnapTarget? HoveredElement => _snapLevel > 0 && _snapLevel < _snapChain.Count ? _snapChain[_snapLevel] : null;

    /// <summary>The highlighted thing's type name for the size readout ("button", "窗口"), or "".</summary>
    public string HoverKind => _snapLevel < _snapChain.Count ? _snapChain[_snapLevel].Kind : "";

    public bool HasSelection => Dragging || HasKeyboardSelection;

    public Int32Rect SelectionRect
    {
        get
        {
            int x1 = (int)Math.Round(Math.Min(DragStart.X, DragCurrent.X));
            int y1 = (int)Math.Round(Math.Min(DragStart.Y, DragCurrent.Y));
            int x2 = (int)Math.Round(Math.Max(DragStart.X, DragCurrent.X));
            int y2 = (int)Math.Round(Math.Max(DragStart.Y, DragCurrent.Y));
            return new Int32Rect(x1, y1, Math.Max(1, x2 - x1), Math.Max(1, y2 - y1));
        }
    }

    public void StartInteractive(CaptureMode mode, Action<CaptureResult> onDone)
    {
        if (IsActive) return;
        IsActive = true;
        _mode = mode;
        _onDone = onDone;
        Dragging = false;
        HasKeyboardSelection = false;
        HoveredWindow = null;
        ResetSnap();
        _snapper = mode == CaptureMode.Region && App.Settings.SnapToElements ? new ElementSnapper(OnSnapChain) : null;

        (_frozen, _frozenBounds) = ScreenFreezer.CaptureVirtualScreen();
        // Window list is used by Window mode AND by Region mode's click-to-capture-window.
        _windows = WindowEnumerator.GetTopWindows();

        Native.GetCursorPos(out var cursor);
        PointerPhysical = new Point(cursor.X, cursor.Y);
        UpdateHover(PointerPhysical);

        foreach (var monitor in MonitorInfoProvider.GetMonitors())
        {
            bool containsCursor =
                cursor.X >= monitor.Bounds.X && cursor.X < monitor.Bounds.X + monitor.Bounds.Width &&
                cursor.Y >= monitor.Bounds.Y && cursor.Y < monitor.Bounds.Y + monitor.Bounds.Height;
            var overlay = new OverlayWindow(this, monitor, _frozen, _frozenBounds, activate: containsCursor);
            _overlays.Add(overlay);
            overlay.Show();
        }
    }

    // ---- Overlay callbacks ------------------------------------------------------

    internal void BeginDrag(Point physical)
    {
        Dragging = true;
        HasKeyboardSelection = false;
        DragStart = DragCurrent = physical;
        Repaint();
    }

    internal void UpdatePointer(Point physical)
    {
        PointerPhysical = physical;
        if (!Dragging) UpdateHover(physical);
        else DragCurrent = physical;
        Repaint();
    }

    private void UpdateHover(Point physical)
    {
        var was = HoveredWindow;
        HoveredWindow = _windows?.FirstOrDefault(w => Contains(w.Bounds, physical));
        if (_snapper is null) return;
        if (HoveredWindow != was) ResetSnap();
        else if (_snapLevel < _snapChain.Count && !Contains(_snapChain[_snapLevel].Bounds, physical)) _levelsUp = 0;
        if (HoveredWindow is { } win) _snapper.Request(win, physical);
    }

    private static bool Contains(Int32Rect r, Point p) =>
        p.X >= r.X && p.X < r.X + r.Width && p.Y >= r.Y && p.Y < r.Y + r.Height;

    private void OnSnapChain(WindowEntry window, IReadOnlyList<SnapTarget> chain)
    {
        if (!IsActive || Dragging || window != HoveredWindow) return;
        _snapChain = chain;
        _snapLevel = Math.Max(0, chain.Count - 1 - _levelsUp);
        Repaint();
    }

    /// <summary>Mouse wheel: <paramref name="outward"/> steps toward the window, otherwise back in.</summary>
    internal void StepSnap(bool outward)
    {
        if (_snapper is null || Dragging || HasKeyboardSelection || _snapChain.Count == 0) return;
        int level = Math.Clamp(_snapLevel + (outward ? -1 : 1), 0, _snapChain.Count - 1);
        if (level == _snapLevel) return;
        _snapLevel = level;
        _levelsUp = _snapChain.Count - 1 - level;
        Repaint();
    }

    private void ResetSnap()
    {
        _snapChain = [];
        _snapLevel = 0;
        _levelsUp = 0;
    }

    internal void EndDrag(Point physical)
    {
        if (_mode == CaptureMode.Window)
        {
            if (HoveredWindow is { } win) CompleteWindow(win);
            else Cancel();
            return;
        }

        if (!Dragging) return; // drag was cancelled with Esc — the release must not close the overlay

        DragCurrent = physical;
        var rect = SelectionRect;
        if (rect.Width < 4 || rect.Height < 4)
        {
            Dragging = false;
            // A plain click captures the snapped element, else the window under the cursor (spec: one hotkey, all modes).
            if (HoveredElement is { } element) CompleteRegion(ClipToScreen(element.Bounds));
            else if (HoveredWindow is { } win) CompleteWindow(win);
            else Cancel();
            return;
        }
        CompleteRegion(rect);
    }

    /// <summary>Arrow-key capture: create/move (plain) or resize (Shift) the selection, 1px steps.</summary>
    internal void NudgeSelection(int dx, int dy, bool resize)
    {
        if (_mode != CaptureMode.Region || Dragging) return;
        if (!HasKeyboardSelection)
        {
            // Define a starter selection centered on the pointer.
            DragStart = new Point(PointerPhysical.X - 150, PointerPhysical.Y - 100);
            DragCurrent = new Point(PointerPhysical.X + 150, PointerPhysical.Y + 100);
            HasKeyboardSelection = true;
        }
        else if (resize)
        {
            DragCurrent = new Point(DragCurrent.X + dx, DragCurrent.Y + dy);
        }
        else
        {
            DragStart = new Point(DragStart.X + dx, DragStart.Y + dy);
            DragCurrent = new Point(DragCurrent.X + dx, DragCurrent.Y + dy);
        }
        Repaint();
    }

    internal void ConfirmSelection()
    {
        if (_mode != CaptureMode.Region) return;
        if (HasKeyboardSelection || Dragging)
        {
            var rect = SelectionRect;
            if (rect.Width >= 4 && rect.Height >= 4) CompleteRegion(rect);
        }
    }

    private Int32Rect ClipToScreen(Int32Rect r)
    {
        int x1 = Math.Max(r.X, _frozenBounds.X), y1 = Math.Max(r.Y, _frozenBounds.Y);
        int x2 = Math.Min(r.X + r.Width, _frozenBounds.X + _frozenBounds.Width);
        int y2 = Math.Min(r.Y + r.Height, _frozenBounds.Y + _frozenBounds.Height);
        return new Int32Rect(x1, y1, Math.Max(1, x2 - x1), Math.Max(1, y2 - y1));
    }

    /// <summary>
    /// F3 in the overlay: what a click (or Enter) would capture is pinned in place instead — the keyboard
    /// selection, a drag still in progress, the snapped element or the hovered window.
    /// </summary>
    internal void PinTarget()
    {
        Int32Rect? rect = HasSelection ? SelectionRect
            : HoveredElement?.Bounds ?? (_mode != CaptureMode.FullScreen ? HoveredWindow?.Bounds : null);
        if (rect is not { Width: >= 4, Height: >= 4 } r || _frozen is null) return;
        r = ClipToScreen(r);
        var bmp = ScreenFreezer.Crop(_frozen, _frozenBounds, r);
        CloseOverlays();
        Cleanup();
        Shell.Pins.Pin(bmp, new PixelRect(r.X, r.Y, r.Width, r.Height));
    }

    /// <summary>The frozen frame's colour at a physical point, or null off-screen.</summary>
    internal System.Windows.Media.Color? PixelAt(Point physical)
    {
        if (_frozen is null) return null;
        int x = (int)Math.Floor(physical.X) - _frozenBounds.X, y = (int)Math.Floor(physical.Y) - _frozenBounds.Y;
        if (x < 0 || y < 0 || x >= _frozen.PixelWidth || y >= _frozen.PixelHeight) return null;
        // BitBlt frames are Bgr32; anything else is converted so the byte order below holds.
        var source = _frozen.Format == System.Windows.Media.PixelFormats.Bgr32 || _frozen.Format == System.Windows.Media.PixelFormats.Bgra32
            ? _frozen
            : new FormatConvertedBitmap(_frozen, System.Windows.Media.PixelFormats.Bgra32, null, 0);
        var px = new byte[4];
        source.CopyPixels(new Int32Rect(x, y, 1, 1), px, 4, 0);
        return System.Windows.Media.Color.FromRgb(px[2], px[1], px[0]);
    }

    /// <summary>C in the overlay: the colour under the pointer goes to the clipboard and the capture ends.</summary>
    internal void CopyColor(bool asRgb)
    {
        if (_mode != CaptureMode.Region || !App.Settings.ShowMagnifier || PixelAt(PointerPhysical) is not { } c) return;
        var text = asRgb ? $"{c.R}, {c.G}, {c.B}" : $"#{c.R:X2}{c.G:X2}{c.B:X2}";
        Cancel();
        try
        {
            Clipboard.SetText(text);
            Shell.NotifyPopup.Show(Shell.Loc.F("Copied {0}", text));
        }
        catch { Shell.NotifyPopup.Show(Shell.Loc.T("Clipboard is busy — try again.")); }
    }

    internal void Cancel()
    {
        CloseOverlays();
        Cleanup();
    }

    private void CompleteRegion(Int32Rect physicalRect)
    {
        var frozen = _frozen!;
        var bounds = _frozenBounds;
        var done = _onDone;
        CloseOverlays();
        var bmp = ScreenFreezer.Crop(frozen, bounds, physicalRect);
        Cleanup();
        var rect = new PixelRect(physicalRect.X, physicalRect.Y, physicalRect.Width, physicalRect.Height);
        done?.Invoke(new CaptureResult(bmp, CaptureMode.Region, rect, rect));
    }

    private void CompleteWindow(WindowEntry win)
    {
        var frozen = _frozen!;
        var bounds = _frozenBounds;
        var done = _onDone;
        CloseOverlays();

        // Prefer the window's own composited content (clean even when occluded);
        // fall back to cropping the frozen desktop.
        var bmp = WindowEnumerator.CaptureWindow(win)
                  ?? ScreenFreezer.Crop(frozen, bounds, win.Bounds);
        Cleanup();
        done?.Invoke(new CaptureResult(bmp, CaptureMode.Window, null,
            new PixelRect(win.Bounds.X, win.Bounds.Y, win.Bounds.Width, win.Bounds.Height)));
    }

    private void CloseOverlays()
    {
        foreach (var o in _overlays) o.CloseOverlay();
        _overlays.Clear();
    }

    private void Cleanup()
    {
        _frozen = null;
        _windows = null;
        _onDone = null;
        Dragging = false;
        HasKeyboardSelection = false;
        HoveredWindow = null;
        _snapper?.Cancel();
        _snapper = null;
        ResetSnap();
        IsActive = false;
    }

    private void Repaint()
    {
        foreach (var o in _overlays) o.RepaintOverlay();
    }

    // ---- Non-interactive captures ---------------------------------------------------

    public CaptureResult? CaptureMonitor(int index)
    {
        var monitors = MonitorInfoProvider.GetMonitors();
        if (index < 0 || index >= monitors.Count) return null;
        var b = monitors[index].Bounds;
        var bmp = ScreenFreezer.CapturePhysicalRect(b);
        return new CaptureResult(bmp, CaptureMode.FullScreen, null,
            new PixelRect(b.X, b.Y, b.Width, b.Height));
    }

    public CaptureResult? CaptureRegionRect(PixelRect r)
    {
        var bmp = ScreenFreezer.CapturePhysicalRect(new Int32Rect(r.X, r.Y, r.Width, r.Height));
        return new CaptureResult(bmp, CaptureMode.Region, r, r);
    }
}
