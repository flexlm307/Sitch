using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Sitch.Shelf.UI;

/// <summary>The line's windows wear Sitch's icon and name (it was Snapline's own brand before the merge).</summary>
public static class Brand
{
    private static BitmapFrame? _icon;

    /// <summary>The app icon, for window title bars.</summary>
    public static BitmapFrame? Icon
    {
        get
        {
            if (_icon is not null) return _icon;
            try
            {
                var info = Application.GetResourceStream(new Uri("pack://application:,,,/Assets/sitch.ico"));
                if (info is null) return null;
                var decoder = BitmapDecoder.Create(info.Stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
                _icon = decoder.Frames.OrderByDescending(f => f.PixelWidth).First();
            }
            catch { }
            return _icon;
        }
    }

    /// <summary>The icon beside the name, for the settings header.</summary>
    public static FrameworkElement Lockup(double nameSize, bool dark = false)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        if (Icon is { } icon)
            row.Children.Add(new Image { Source = icon, Width = nameSize * 1.1, Height = nameSize * 1.1, Margin = new Thickness(0, 0, nameSize * 0.3, 0), VerticalAlignment = VerticalAlignment.Center });
        row.Children.Add(new TextBlock
        {
            Text = Strings.AppName, FontWeight = FontWeights.Bold, FontSize = nameSize,
            Foreground = new SolidColorBrush(dark ? Colors.White : Color.FromRgb(0x1C, 0x1F, 0x2A)), VerticalAlignment = VerticalAlignment.Center,
        });
        return row;
    }
}
