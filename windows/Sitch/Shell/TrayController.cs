using System.Windows;
using System.Windows.Controls;
using H.NotifyIcon;
using Sitch.Capture;

namespace Sitch.Shell;

/// <summary>System-tray presence: icon + context menu, the app's home base.</summary>
public sealed class TrayController : IDisposable
{
    private readonly TaskbarIcon _icon;

    public TrayController()
    {
        _icon = new TaskbarIcon
        {
            ToolTipText = Loc.T("Sitch — Capture. Annotate. Share."),
            IconSource = new System.Windows.Media.Imaging.BitmapImage(
                new Uri("pack://application:,,,/Assets/sitch.ico")),
            ContextMenu = BuildMenu(),
        };
        _icon.TrayLeftMouseUp += (_, _) => App.Current.CaptureRegion();
        _icon.ForceCreate();
    }

    private ContextMenu BuildMenu()
    {
        var menu = new ContextMenu();

        var captureItem = Item($"{Loc.T("Capture Region")}\t{App.Settings.CaptureHotkey}", () => App.Current.CaptureRegion());
        menu.Items.Add(captureItem);
        menu.Items.Add(Item(Loc.T("Capture Window"), () => App.Current.CaptureWindow()));

        var full = new MenuItem { Header = Loc.T("Capture Full Screen") };
        full.SubmenuOpened += (_, _) =>
        {
            full.Items.Clear();
            var monitors = MonitorInfoProvider.GetMonitors();
            for (int i = 0; i < monitors.Count; i++)
            {
                int idx = i;
                var m = monitors[i];
                full.Items.Add(Item(Loc.F("Display {0} ({1}×{2})", i + 1, m.Bounds.Width, m.Bounds.Height) + (m.IsPrimary ? Loc.T(" — primary") : ""),
                    () => App.Current.CaptureFullScreen(idx)));
            }
        };
        full.Items.Add(new MenuItem { Header = "…" }); // placeholder so the submenu arrow shows
        menu.Items.Add(full);

        var recaptureItem = Item($"{Loc.T("Recapture Last Region")}\t{App.Settings.RecaptureHotkey}", () => App.Current.RecaptureLast());
        menu.Items.Add(recaptureItem);
        var quickCopyItem = Item($"{Loc.T("Quick Capture → Clipboard")}\t{App.Settings.QuickCopyHotkey}", () => App.Current.QuickCapture(toClipboard: true));
        // Hotkeys are rebindable in Settings — refresh the labels every time the menu opens.
        menu.Opened += (_, _) =>
        {
            captureItem.Header = $"{Loc.T("Capture Region")}\t{App.Settings.CaptureHotkey}";
            recaptureItem.Header = $"{Loc.T("Recapture Last Region")}\t{App.Settings.RecaptureHotkey}";
            quickCopyItem.Header = $"{Loc.T("Quick Capture → Clipboard")}\t{App.Settings.QuickCopyHotkey}";
        };
        menu.Items.Add(new Separator());
        menu.Items.Add(quickCopyItem);
        menu.Items.Add(Item(Loc.T("Quick Capture → File"), () => App.Current.QuickCapture(toClipboard: false)));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item(Loc.T("Open Image…"), OpenImageDialog));
        var pinItem = Item($"{Loc.T("Pin Clipboard Image")}\t{App.Settings.PinHotkey}", Pins.PinClipboard);
        var unpinAll = Item(Loc.T("Close All Pins"), Pins.CloseAll);
        menu.Items.Add(pinItem);
        menu.Items.Add(unpinAll);
        menu.Opened += (_, _) =>
        {
            pinItem.Header = $"{Loc.T("Pin Clipboard Image")}\t{App.Settings.PinHotkey}";
            unpinAll.Visibility = Pins.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        };
        menu.Items.Add(new Separator());

        // The screenshot line (merged from Snapline): present only while it runs.
        var lineItem = new MenuItem();
        lineItem.Click += (_, _) => App.Current.Shelf?.Toggle();
        var noteHost = new MenuItem { Header = Loc.T("New Note") };
        var lineSettings = Item(Loc.T("Line Settings…"), () => App.Current.Shelf?.ShowSettings());
        var lineSeparator = new Separator();
        menu.Items.Add(lineItem);
        menu.Items.Add(noteHost);
        menu.Items.Add(lineSettings);
        menu.Items.Add(lineSeparator);
        menu.Opened += (_, _) =>
        {
            var shelf = App.Current.Shelf;
            var vis = shelf is null ? Visibility.Collapsed : Visibility.Visible;
            lineItem.Visibility = noteHost.Visibility = lineSettings.Visibility = lineSeparator.Visibility = vis;
            if (shelf is null) return;
            lineItem.Header = $"{Loc.T(shelf.IsRevealed ? "Hide Screenshot Line" : "Show Screenshot Line")}\t{shelf.HotKeyText}";
            noteHost.Items.Clear();
            foreach (var color in Sitch.Shelf.Core.Notes.Colors)
            {
                var c = color;
                noteHost.Items.Add(Item(Sitch.Shelf.UI.Strings.NoteName(c), () => App.Current.Shelf?.NewNote(c)));
            }
        };
        menu.Items.Add(Item(Loc.T("Settings…"), () => App.Current.ShowSettings()));
        menu.Items.Add(Item(Loc.T("About Sitch"), ShowAbout));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item(Loc.T("Quit Sitch"), () => App.Current.QuitRequested()));
        return menu;
    }

    private static MenuItem Item(string header, Action action)
    {
        var mi = new MenuItem { Header = header };
        mi.Click += (_, _) => action();
        return mi;
    }

    private static void OpenImageDialog()
    {
        var dlg = new Microsoft.Win32.OpenFileDialog
        {
            Filter = $"{Loc.T("Images")}|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff;*.webp|{Loc.T("All files")}|*.*",
        };
        if (dlg.ShowDialog() == true)
            App.Current.OpenImageFile(dlg.FileName);
    }

    private static void ShowAbout()
    {
        MessageBox.Show(
            "Sitch 0.2.0\n\n" + Loc.T("Skitch-style screenshot annotation for Windows.\nCapture. Annotate. Share.") + "\n\n" +
            "MIT License — © 2026 Josh Auriemma\ngithub.com/phalladar/sitch",
            Loc.T("About Sitch"), MessageBoxButton.OK, MessageBoxImage.Information);
    }

    public void Dispose() => _icon.Dispose();
}
