using System.Windows;
using System.Windows.Media;
using Sitch.Shelf.Core;
using Microsoft.Win32;

namespace Sitch.Shelf.UI;

/// <summary>Light or dark, following Windows (or the line's Appearance setting). The glass and the menus adapt.</summary>
public static class Theme
{
    public static bool AppsDark { get; private set; }
    public static bool SystemDark { get; private set; }
    public static event Action? Changed;

    static Theme() { Read(); }

    private static bool? _override;

    public static void Override(bool dark) { _override = dark; AppsDark = SystemDark = dark; Apply(); }

    /// <summary>Follows the Appearance setting: auto, light or dark.</summary>
    public static void ApplySetting()
    {
        _override = Settings.Current.Appearance switch { "light" => false, "dark" => true, _ => null };
        Refresh();
    }

    public static void Read()
    {
        if (_override is { } o) { AppsDark = SystemDark = o; return; }
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            AppsDark = key?.GetValue("AppsUseLightTheme") is int apps && apps == 0;
            SystemDark = key?.GetValue("SystemUsesLightTheme") is int sys && sys == 0;
        }
        catch { AppsDark = SystemDark = false; }
    }

    public static void Refresh()
    {
        bool a = AppsDark, s = SystemDark;
        Read();
        Apply();
        if (a != AppsDark || s != SystemDark) Changed?.Invoke();
    }

    public static Color Rgba(double r, double g, double b, double a) =>
        Color.FromArgb((byte)Math.Round(a * 255), (byte)Math.Round(r * 255), (byte)Math.Round(g * 255), (byte)Math.Round(b * 255));
    public static Color Gray(double white, double alpha = 1) => Rgba(white, white, white, alpha);

    // The glass frame around each photo: the system's blurred material cannot be
    // cut into a card shape on Windows, so it is a crisp translucent sheet with a
    // specular edge lit from above.
    public static Color GlassFill => AppsDark ? Gray(0.16, 0.74) : Gray(0.97, 0.72);
    public static Color GlassEdgeTop => AppsDark ? Gray(1, 0.32) : Gray(1, 0.55);
    public static Color GlassEdgeBottom => AppsDark ? Gray(1, 0.08) : Gray(1, 0.12);
    public static Color GlassOutline => Gray(0, AppsDark ? 0.28 : 0.10);
    public static Color PhotoEdge => Gray(1, 0.18);
    public static Color Primary => AppsDark ? Gray(0.96) : Gray(0.10);
    public static Color Secondary => AppsDark ? Gray(0.75) : Gray(0.38);
    public static Color HintFill => AppsDark ? Gray(0.16, 0.86) : Gray(0.98, 0.86);

    public static Brush Freeze(Brush b) { b.Freeze(); return b; }

    private static ResourceDictionary? _resources;

    /// <summary>
    /// The line's menu, tooltip and colour resources. Scoped to the line's own menus and windows
    /// (<see cref="Scope"/>) rather than merged into the app, so Sitch's other menus keep their look.
    /// </summary>
    public static ResourceDictionary Resources => _resources ??= new ResourceDictionary
    {
        Source = new Uri("pack://application:,,,/Shelf/UI/Theme.xaml"),
    };

    public static Brush Brush(string key) => (Brush)Resources[key];

    /// <summary>Gives a menu, tooltip or window the line's look.</summary>
    public static T Scope<T>(T element) where T : FrameworkElement
    {
        element.Resources.MergedDictionaries.Add(Resources);
        if (Resources[typeof(T)] is Style style) element.Style = style;
        return element;
    }

    /// <summary>Pushes the menu colours into the line's resources.</summary>
    public static void Apply()
    {
        if (Application.Current is null) return;
        var res = Resources;
        bool dark = AppsDark;
        res["MenuBg"] = Freeze(new SolidColorBrush(dark ? Color.FromRgb(0x2B, 0x2B, 0x2B) : Color.FromRgb(0xF9, 0xF9, 0xF9)));
        res["MenuBorder"] = Freeze(new SolidColorBrush(dark ? Gray(1, 0.09) : Gray(0, 0.10)));
        res["MenuFg"] = Freeze(new SolidColorBrush(dark ? Gray(0.96) : Gray(0.11)));
        res["MenuFgSecondary"] = Freeze(new SolidColorBrush(dark ? Gray(0.68) : Gray(0.45)));
        res["MenuHover"] = Freeze(new SolidColorBrush(dark ? Gray(1, 0.07) : Gray(0, 0.05)));
        res["MenuSeparator"] = Freeze(new SolidColorBrush(dark ? Gray(1, 0.09) : Gray(0, 0.08)));
    }
}
