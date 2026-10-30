using System.IO;
using System.Windows;
using System.Windows.Media.Imaging;
using Sitch.Capture;
using Sitch.Core;
using Sitch.Editor;
using Sitch.Export;
using Sitch.Shell;

namespace Sitch;

public partial class App : Application
{
    public static AppSettings Settings { get; private set; } = new();
    public static new App Current => (App)Application.Current;

    public const int HkCapture = 1;
    public const int HkRecapture = 2;
    public const int HkQuickCopy = 3;
    public const int HkPin = 4;
    public const int HkScroll = 5;

    /// <summary>The global hotkeys in Settings/tray order; Name labels them in conflict messages.</summary>
    public static readonly (int Id, string Name, Func<AppSettings, string> Get)[] HotkeySlots =
    [
        (HkCapture, "Capture", s => s.CaptureHotkey),
        (HkRecapture, "Recapture last region", s => s.RecaptureHotkey),
        (HkQuickCopy, "Capture to clipboard", s => s.QuickCopyHotkey),
        (HkPin, "Pin clipboard image", s => s.PinHotkey),
        (HkScroll, "Scrolling capture", s => s.ScrollHotkey),
    ];

    private SingleInstance? _instance;
    private TrayController? _tray;
    private HotkeyManager? _hotkeys;
    private CaptureController? _capture;
    private ScreenshotWatcher? _watcher;

    /// <summary>The screenshot line (merged from Snapline); null while it is off or Snapline itself runs.</summary>
    public Shelf.ShelfController? Shelf { get; private set; }

    public CaptureController Capture => _capture!;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // Self-contained render+exit mode; never needs (or should touch) the singleton.
        foreach (var arg in e.Args)
        {
            if (arg.StartsWith("--shot-region=", StringComparison.Ordinal))
            {
                Settings = SettingsStore.Load();
                DemoMode.RenderRegionShot(arg["--shot-region=".Length..]);
                Shutdown();
                return;
            }
        }

        _instance = SingleInstance.TryAcquire(OnIpcMessage);
        if (_instance is null)
        {
            // Another Sitch is running: hand our args to it and bow out.
            SingleInstance.SendToPrimary(e.Args);
            Shutdown();
            return;
        }

        // The line ticks 30 times a second; one bad frame there is logged, not fatal to Sitch.
        DispatcherUnhandledException += (_, ex) =>
        {
            if (ex.Exception.StackTrace?.Contains("Sitch.Shelf.", StringComparison.Ordinal) != true) return;
            Sitch.Shelf.Core.Log.Error($"Unhandled in the line: {ex.Exception}");
            ex.Handled = true;
        };

        Settings = SettingsStore.Load();
        StartupManager.MigrateLegacy();
        StartupManager.RegisterAppPath();
        ThemeManager.Apply(Settings.Theme);

        _capture = new CaptureController();
        _hotkeys = new HotkeyManager();
        _hotkeys.Pressed += OnHotkey;
        RegisterHotkeys();

        _tray = new TrayController();
        UpdateScreenshotWatcher();
        UpdateShelf();

        HandleArgs(e.Args);

        // Fresh install launched with no task: without this, the only sign of life is a tray
        // icon that Windows 11 hides in the overflow flyout — i.e., nothing visible at all.
        if (SettingsStore.FirstRun && e.Args.Length == 0)
        {
            SettingsStore.Save(Settings); // materialize settings so the welcome shows once
            new WelcomeWindow().Show();
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _watcher?.Dispose();
        Shelf?.Dispose();
        _hotkeys?.Dispose();
        _tray?.Dispose();
        _instance?.Dispose();
        Sitch.Shelf.Core.RapidOcr.Stop();
        base.OnExit(e);
    }

    // ---- IPC from secondary instances --------------------------------------

    private void OnIpcMessage(string message)
    {
        Dispatcher.Invoke(() =>
        {
            if (message.StartsWith("OPEN ", StringComparison.Ordinal))
                OpenImageFile(message[5..]);
            else if (message.StartsWith("EDIT ", StringComparison.Ordinal))
                OpenImageFile(message[5..], saveBack: true);
            else if (message == "CAPTURE")
                CaptureRegion();
            else if (message == "SETTINGS")
                ShowSettings();
            else if (message == "FOCUS")
                FocusAnyEditor();
        });
    }

    private void HandleArgs(string[] args)
    {
        foreach (var arg in args)
        {
            switch (arg)
            {
                case "--demo": DemoMode.OpenEditorDemo(); break;
                case "--demo-crop": DemoMode.OpenEditorDemo(cropMode: true); break;
                case "--demo-light": DemoMode.OpenEditorDemo(lightTheme: true); break;
                case "--settings": ShowSettings(); break;
                case "--capture": CaptureRegion(); break;
                case var edit when edit.StartsWith("--edit=", StringComparison.Ordinal):
                    if (File.Exists(edit[7..])) OpenImageFile(edit[7..], saveBack: true);
                    break;
                default:
                    if (File.Exists(arg)) OpenImageFile(arg);
                    break;
            }
        }
    }

    // ---- Hotkeys ------------------------------------------------------------

    public void RegisterHotkeys()
    {
        if (_hotkeys is null) return;
        _hotkeys.UnregisterAll();
        var taken = new Dictionary<HotkeyChord, string>();
        foreach (var (id, name, get) in HotkeySlots)
        {
            if (!HotkeyChord.TryParse(get(Settings), out var chord)) continue;
            // A settings file from before the recorder refused duplicates: first slot wins.
            if (taken.TryGetValue(chord, out var owner))
                NotifyPopup.Show(Loc.F("{0} hotkey {1} is already used by {2}.", Loc.T(name), chord, Loc.T(owner)));
            else if (_hotkeys.Register(id, chord))
                taken[chord] = name;
            else
                NotifyPopup.Show(Loc.F("{0} hotkey {1} is in use by another app.", Loc.T(name), chord));
        }
    }

    /// <summary>The Settings recorder listens for chords that are currently registered.</summary>
    public void UnregisterHotkeys() => _hotkeys?.UnregisterAll();

    /// <summary>Name of the other Sitch action already bound to <paramref name="chord"/>, if any.</summary>
    public static string? HotkeyOwner(HotkeyChord chord, int exceptId) =>
        HotkeySlots.FirstOrDefault(s => s.Id != exceptId &&
            HotkeyChord.TryParse(s.Get(Settings), out var c) && c == chord).Name;

    private void OnHotkey(int id)
    {
        switch (id)
        {
            case HkCapture: CaptureRegion(); break;
            case HkRecapture: RecaptureLast(); break;
            case HkQuickCopy: QuickCapture(toClipboard: true); break;
            case HkPin: Pins.PinClipboard(); break;
            case HkScroll: ScrollCapture(); break;
        }
    }

    // ---- Capture entry points ------------------------------------------------

    public void CaptureRegion() => StartCapture(CaptureMode.Region);
    public void CaptureWindow() => StartCapture(CaptureMode.Window);

    /// <summary>Region capture whose result lands as a new tab inside an existing editor window.</summary>
    public void CaptureRegionInto(EditorWindow editor)
    {
        RunWithTimer(() => _capture!.StartInteractive(CaptureMode.Region, r => RouteCapture(r, editor)));
    }

    public void CaptureFullScreen(int monitorIndex)
    {
        RunWithTimer(() =>
        {
            var result = _capture!.CaptureMonitor(monitorIndex);
            if (result is not null) RouteCapture(result);
        });
    }

    public void RecaptureLast()
    {
        if (Settings.LastRegion is { Width: > 0, Height: > 0 } r)
        {
            RunWithTimer(() =>
            {
                var result = _capture!.CaptureRegionRect(r);
                if (result is not null) RouteCapture(result);
            });
        }
        else CaptureRegion();
    }

    /// <summary>Interactive region capture that skips the editor entirely (v1.3 quick capture).</summary>
    public void QuickCapture(bool toClipboard)
    {
        _capture!.StartInteractive(CaptureMode.Region, result =>
        {
            RememberRegion(result);
            if (toClipboard)
            {
                if (ClipboardHelper.CopyImage(result.Bitmap))
                {
                    NotifyPopup.Show(Loc.T("Copied to clipboard."), result.Bitmap);
                }
                else
                {
                    // Clipboard held by another app — don't lose the frame.
                    var fallback = Exporters.QuickSave(result.Bitmap);
                    NotifyPopup.Show(Loc.F("Clipboard busy — saved {0} instead.", Path.GetFileName(fallback)), result.Bitmap);
                }
            }
            else
            {
                var path = Exporters.QuickSave(result.Bitmap);
                NotifyPopup.Show(Loc.F("Saved {0}", Path.GetFileName(path)), result.Bitmap);
            }
            if (Settings.AfterHang) Shelf?.HangBitmap(result.Bitmap, result.SourceScreenRect);
        });
    }

    /// <summary>Pick the region (drag, or click a snapped element / window), then scroll it.</summary>
    public void ScrollCapture()
    {
        if (ScrollCaptureSession.IsActive) return;
        _capture!.StartInteractive(CaptureMode.Region, result =>
        {
            if (result.SourceScreenRect is { } r) ScrollCaptureSession.Start(new Int32Rect(r.X, r.Y, r.Width, r.Height));
        });
    }

    /// <summary>A finished scrolling capture goes where any capture goes (clipboard, editor, line).</summary>
    public void FinishScrollCapture(BitmapSource image, PixelRect source) =>
        RouteCapture(new CaptureResult(image, CaptureMode.Region, null, source));

    private void StartCapture(CaptureMode mode)
    {
        RunWithTimer(() => _capture!.StartInteractive(mode, result => RouteCapture(result)));
    }

    private void RunWithTimer(Action action)
    {
        int secs = Settings.TimerSeconds;
        if (secs is 3 or 5 or 10)
            CountdownPopup.Run(secs, action);
        else
            action();
    }

    /// <summary>
    /// Applies the configured after-capture actions (show / copy / save, any combo).
    /// When <paramref name="into"/> is set (the editor's own New Capture button), the frame always
    /// opens as a new tab in that window instead of spawning a separate one.
    /// </summary>
    private void RouteCapture(CaptureResult result, EditorWindow? into = null)
    {
        RememberRegion(result);
        bool any = false;
        if (Settings.AfterCopy)
        {
            if (ClipboardHelper.CopyImage(result.Bitmap))
            {
                NotifyPopup.Show(Loc.T("Copied to clipboard."), result.Bitmap);
                any = true; // a failed copy must NOT count — the editor fallback keeps the frame
            }
            else
            {
                NotifyPopup.Show(Loc.T("Clipboard is busy — opening the editor instead."));
            }
        }
        if (Settings.AfterSave)
        {
            var path = Exporters.QuickSave(result.Bitmap);
            NotifyPopup.Show(Loc.F("Saved {0}", Path.GetFileName(path)), result.Bitmap);
            any = true;
        }
        if (Settings.AfterHang && Shelf is not null)
        {
            Shelf.HangBitmap(result.Bitmap, result.SourceScreenRect);
            any = true;
        }
        if (into is not null)
            into.AddCaptureTab(result.Bitmap, Loc.T("Untitled"));
        else if (Settings.AfterShowEditor || !any)
            OpenEditor(result.Bitmap, Loc.T("Untitled"), result.SourceScreenRect);
    }

    private void RememberRegion(CaptureResult result)
    {
        if (result.Kind == CaptureMode.Region && result.PhysicalRect is { } r)
        {
            Settings.LastRegion = r;
            SettingsStore.Save(Settings);
        }
    }

    // ---- Windows -------------------------------------------------------------

    public void OpenEditor(BitmapSource bitmap, string title, PixelRect? sourceRect = null, string? saveBackPath = null)
    {
        var win = new EditorWindow(bitmap, title, sourceRect, saveBackPath);
        win.Show();
        win.Activate();
    }

    /// <summary>
    /// <paramref name="saveBack"/>: <c>--edit</c> from another app (Snapline's "Edit in Sitch") —
    /// Save writes into this file, so the caller sees the marks. Only for formats Sitch encodes.
    /// </summary>
    public void OpenImageFile(string path, bool saveBack = false)
    {
        try
        {
            var bmp = new BitmapImage();
            bmp.BeginInit();
            bmp.CacheOption = BitmapCacheOption.OnLoad;
            bmp.UriSource = new Uri(Path.GetFullPath(path));
            bmp.EndInit();
            bmp.Freeze();
            var full = Path.GetFullPath(path);
            var ext = Path.GetExtension(full).TrimStart('.').ToLowerInvariant();
            bool canWrite = ext is "png" or "jpg" or "jpeg" or "tif" or "tiff";
            OpenEditor(bmp, Path.GetFileNameWithoutExtension(path), saveBackPath: saveBack && canWrite ? full : null);
        }
        catch (Exception ex)
        {
            MessageBox.Show(Loc.F("Couldn't open {0}", path) + $"\n\n{ex.Message}", "Sitch",
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private SettingsWindow? _settingsWindow;

    public void ShowSettings()
    {
        if (_settingsWindow is { IsLoaded: true })
        {
            _settingsWindow.Activate();
            return;
        }
        _settingsWindow = new SettingsWindow();
        _settingsWindow.Show();
    }

    private void FocusAnyEditor()
    {
        foreach (Window w in Windows)
            if (w is EditorWindow) { w.Activate(); return; }
        // Someone launched the exe again with nothing to show — say so instead of doing
        // nothing (the classic "I double-clicked it and nothing happened").
        NotifyPopup.Show(Loc.F("Sitch is already running in the system tray.\nPress {0} to capture.", Settings.CaptureHotkey));
    }

    public void UpdateScreenshotWatcher()
    {
        _watcher?.Dispose();
        _watcher = Settings.WatchSystemScreenshots ? new ScreenshotWatcher(path => OpenImageFile(path)) : null;
    }

    /// <summary>The standalone Snapline app is running: two lines would fight over the top edge.</summary>
    public static bool SnaplineRunning
    {
        get
        {
            if (!Mutex.TryOpenExisting(@"Local\Snapline.SingleInstance", out var m)) return false;
            m.Dispose();
            return true;
        }
    }

    /// <summary>Starts or stops the screenshot line to match <see cref="AppSettings.LineEnabled"/>.</summary>
    public void UpdateShelf()
    {
        bool want = Settings.LineEnabled && !SnaplineRunning;
        if (want == Shelf is not null) return;
        if (!want)
        {
            Shelf!.Dispose();
            Shelf = null;
            return;
        }
        try { Shelf = new Shelf.ShelfController(); }
        catch (Exception ex)
        {
            // The line is an extra: Sitch keeps capturing and editing without it.
            Sitch.Shelf.Core.Log.Error($"Could not start the line: {ex}");
            Shelf = null;
        }
    }

    public void QuitRequested()
    {
        // Give every dirty editor a chance to veto — and close without re-prompting.
        foreach (Window w in Windows.Cast<Window>().ToList())
        {
            if (w is EditorWindow ed)
            {
                if (!ed.ConfirmCloseWindow()) return;
                ed.CloseWithoutPrompt();
            }
            else
            {
                w.Close();
            }
        }
        Shutdown();
    }
}
