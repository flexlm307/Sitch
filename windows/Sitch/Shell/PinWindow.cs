using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using Sitch.Core;
using Sitch.Export;

namespace Sitch.Shell;

/// <summary>Opens and tracks pins: captures floating above every window.</summary>
public static class Pins
{
    private static readonly List<PinWindow> Open = [];

    public static int Count => Open.Count;

    /// <param name="at">Physical virtual-screen rect the image came from: the pin lands exactly over it.
    /// Null centres it on the pointer.</param>
    public static void Pin(BitmapSource bitmap, PixelRect? at = null)
    {
        if (!bitmap.IsFrozen) bitmap.Freeze();
        if (at is null)
        {
            Capture.Native.GetCursorPos(out var p);
            at = new PixelRect(p.X - bitmap.PixelWidth / 2, p.Y - bitmap.PixelHeight / 2, bitmap.PixelWidth, bitmap.PixelHeight);
        }
        var pin = new PinWindow(bitmap, at.Value);
        Open.Add(pin);
        pin.Closed += (_, _) => Open.Remove(pin);
        pin.Show();
        pin.Activate();
    }

    public static void PinClipboard()
    {
        BitmapSource? image = null;
        try
        {
            if (Clipboard.ContainsImage()) image = Clipboard.GetImage();
            else if (Clipboard.ContainsFileDropList() && Clipboard.GetFileDropList() is { Count: > 0 } files)
                image = Load(files[0]!);
        }
        catch { /* clipboard held by another app */ }
        if (image is null) { NotifyPopup.Show(Loc.T("No image on the clipboard to pin.")); return; }
        Pin(image);
    }

    public static void PinFile(string path)
    {
        try { Pin(Load(path)); }
        catch (Exception ex) { NotifyPopup.Show(Loc.F("Couldn't open {0}", Path.GetFileName(path)) + $"\n{ex.Message}"); }
    }

    public static void CloseAll()
    {
        foreach (var pin in Open.ToList()) pin.Close();
    }

    private static BitmapSource Load(string path)
    {
        var bmp = new BitmapImage();
        bmp.BeginInit();
        bmp.CacheOption = BitmapCacheOption.OnLoad;
        bmp.UriSource = new Uri(Path.GetFullPath(path));
        bmp.EndInit();
        bmp.Freeze();
        return bmp;
    }
}

/// <summary>
/// One pin: a borderless, topmost window showing a capture at 1:1 physical pixels with a soft shadow,
/// so it sits exactly where it was taken. Drag to move, wheel to zoom, Ctrl+wheel for opacity,
/// double-click or Esc to close, right-click for the rest.
/// </summary>
public sealed class PinWindow : Window
{
    private const double ShadowMargin = 14; // DIP of transparent room around the image for the shadow
    private const double MinZoom = 0.1, MaxZoom = 5;

    private readonly BitmapSource _bitmap;
    private readonly PixelRect _place;
    private readonly Image _image;
    private readonly Border _frame;
    private double _zoom = 1;
    private double _scale = 1; // physical px per DIP on the pin's monitor

    public PinWindow(BitmapSource bitmap, PixelRect place)
    {
        _bitmap = bitmap;
        _place = place;

        Title = Loc.T("Pinned capture");
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        Topmost = true;
        ShowInTaskbar = false;
        Icon = Shelf.UI.Brand.Icon;
        // Off-screen until SourceInitialized places it in physical pixels.
        Left = -32000; Top = -32000;

        _image = new Image { Source = bitmap, Stretch = Stretch.Fill };
        RenderOptions.SetBitmapScalingMode(_image, BitmapScalingMode.HighQuality);
        _frame = new Border
        {
            Child = _image,
            BorderThickness = new Thickness(1),
            BorderBrush = IdleBorder,
            Margin = new Thickness(ShadowMargin),
            Effect = new DropShadowEffect { BlurRadius = 18, ShadowDepth = 3, Direction = 270, Opacity = 0.45, Color = Colors.Black },
        };
        Content = _frame;

        _scale = MonitorScale(place.X + place.Width / 2, place.Y + place.Height / 2);
        ApplySize();

        SourceInitialized += (_, _) =>
        {
            // The image (inside its 1px border and the shadow margin) lands on the rect it came from.
            int inset = (int)Math.Round((ShadowMargin + 1) * _scale);
            NativeMethods.SetWindowPos(new WindowInteropHelper(this).Handle, NativeMethods.HWND_TOPMOST,
                _place.X - inset, _place.Y - inset, 0, 0, NativeMethods.SWP_NOSIZE | NativeMethods.SWP_NOACTIVATE);
        };

        MouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount == 2) { Close(); return; }
            try { DragMove(); } catch (InvalidOperationException) { }
        };
        MouseWheel += (_, e) =>
        {
            if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control))
                Opacity = Math.Clamp(Opacity + (e.Delta > 0 ? 0.1 : -0.1), 0.2, 1);
            else
                SetZoom(_zoom * (e.Delta > 0 ? 1.1 : 1 / 1.1));
            e.Handled = true;
        };
        KeyDown += (_, e) =>
        {
            bool ctrl = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
            if (e.Key == Key.Escape) Close();
            else if (ctrl && e.Key == Key.C) CopyImage();
            else if (ctrl && e.Key == Key.S) SaveAs();
            else if (e.Key is Key.D0 or Key.NumPad0 && ctrl) SetZoom(1);
            else return;
            e.Handled = true;
        };
        MouseEnter += (_, _) => _frame.BorderBrush = HoverBorder;
        MouseLeave += (_, _) => _frame.BorderBrush = IdleBorder;
        MouseRightButtonUp += (_, e) => { BuildMenu().IsOpen = true; e.Handled = true; };
    }

    private static readonly Brush IdleBorder = Frozen(Color.FromArgb(0x66, 0x80, 0x80, 0x80));
    private static readonly Brush HoverBorder = Frozen(Color.FromRgb(0xFF, 0x33, 0x66));

    private static Brush Frozen(Color c)
    {
        var b = new SolidColorBrush(c);
        b.Freeze();
        return b;
    }

    protected override void OnDpiChanged(DpiScale oldDpi, DpiScale newDpi)
    {
        base.OnDpiChanged(oldDpi, newDpi);
        // Dragged onto a monitor with another scale: keep the image at the same physical size.
        _scale = newDpi.DpiScaleX;
        ApplySize();
    }

    private void SetZoom(double zoom)
    {
        _zoom = Math.Clamp(zoom, MinZoom, MaxZoom);
        ApplySize();
        NotifyPopup.Show($"{Math.Round(_zoom * 100)}%");
    }

    private void ApplySize()
    {
        _image.Width = _bitmap.PixelWidth * _zoom / _scale;
        _image.Height = _bitmap.PixelHeight * _zoom / _scale;
    }

    private ContextMenu BuildMenu()
    {
        var menu = new ContextMenu { PlacementTarget = this };
        menu.Items.Add(Item(Loc.T("Copy") + "\tCtrl+C", CopyImage));
        menu.Items.Add(Item(Loc.T("Save As…") + "\tCtrl+S", SaveAs));
        menu.Items.Add(Item(Loc.T("Open in editor"), () => { App.Current.OpenEditor(_bitmap, Loc.T("Untitled")); Close(); }));
        menu.Items.Add(Item(Loc.T("Extract text"), ExtractText));
        if (MinerU.Configured) menu.Items.Add(Item(Loc.T("Restore as Markdown (MinerU)"), () => MinerU.Restore(_bitmap)));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item(Loc.T("Actual size") + "\tCtrl+0", () => SetZoom(1)));
        var opacity = new MenuItem { Header = Loc.T("Opacity") };
        foreach (var pct in new[] { 100, 80, 60, 40 })
        {
            var item = Item($"{pct}%", () => Opacity = pct / 100.0);
            item.IsChecked = Math.Abs(Opacity * 100 - pct) < 5;
            opacity.Items.Add(item);
        }
        menu.Items.Add(opacity);
        menu.Items.Add(new Separator());
        menu.Items.Add(Item(Loc.T("Close") + "\tEsc", Close));
        if (Pins.Count > 1) menu.Items.Add(Item(Loc.T("Close all pins"), Pins.CloseAll));
        return menu;
    }

    private static MenuItem Item(string header, Action action)
    {
        var mi = new MenuItem { Header = header };
        mi.Click += (_, _) => action();
        return mi;
    }

    private void CopyImage() =>
        NotifyPopup.Show(ClipboardHelper.CopyImage(_bitmap) ? Loc.T("Copied to clipboard.") : Loc.T("Clipboard is busy — try again."));

    private void SaveAs()
    {
        var dlg = new Microsoft.Win32.SaveFileDialog
        {
            FileName = $"Sitch {DateTime.Now:yyyy-MM-dd 'at' HH.mm.ss}",
            DefaultExt = ".png",
            Filter = "PNG|*.png|JPEG|*.jpg|PDF|*.pdf|TIFF|*.tiff",
            InitialDirectory = Directory.Exists(App.Settings.DefaultSaveFolder) ? App.Settings.DefaultSaveFolder : null,
        };
        if (dlg.ShowDialog(this) != true) return;
        try
        {
            Exporters.Save(_bitmap, dlg.FileName);
            NotifyPopup.Show(Loc.F("Saved {0}", Path.GetFileName(dlg.FileName)));
            MediaMini.CompressLater(dlg.FileName);
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, Loc.T("Save failed.") + $"\n{ex.Message}", "Sitch", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private async void ExtractText()
    {
        NotifyPopup.Show(Loc.T("Reading text…"));
        string? text;
        try { text = await Shelf.Core.Ocr.ReadAsync(_bitmap); }
        catch (Exception ex) { NotifyPopup.Show(Loc.T("Could not read text.") + $"\n{ex.Message}"); return; }
        if (string.IsNullOrWhiteSpace(text)) { NotifyPopup.Show(Loc.T("No text found.")); return; }
        new Editor.OcrWindow(this).ShowText(text);
    }

    /// <summary>DPI of the monitor holding a physical point, as physical px per DIP.</summary>
    private static double MonitorScale(int x, int y)
    {
        var mon = NativeMethods.MonitorFromPoint(new Capture.Native.POINT { X = x, Y = y }, NativeMethods.MONITOR_DEFAULTTONEAREST);
        return Capture.Native.GetDpiForMonitor(mon, 0, out uint dpi, out _) == 0 && dpi > 0 ? dpi / 96.0 : 1;
    }

    private static class NativeMethods
    {
        public static readonly IntPtr HWND_TOPMOST = new(-1);
        public const uint SWP_NOSIZE = 0x0001, SWP_NOACTIVATE = 0x0010;
        public const uint MONITOR_DEFAULTTONEAREST = 2;

        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

        [DllImport("user32.dll")]
        public static extern IntPtr MonitorFromPoint(Capture.Native.POINT pt, uint flags);
    }
}
