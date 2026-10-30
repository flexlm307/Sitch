using System.Windows;
using System.Windows.Controls;
using Sitch.Shell;

namespace Sitch.Editor;

/// <summary>
/// The editor's "Extract text" result: the recognised lines in an editable box (OCR is rarely perfect,
/// so fix it here before copying), with Copy and Close. One per editor; a new run replaces its text.
/// </summary>
public sealed class OcrWindow : Window
{
    private readonly TextBox _text;

    public OcrWindow(Window owner)
    {
        Owner = owner;
        Title = Loc.T("Extracted text");
        Width = 460;
        Height = 380;
        MinWidth = 300;
        MinHeight = 200;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        SetResourceReference(BackgroundProperty, "Brush.Window");
        SetResourceReference(ForegroundProperty, "Brush.Text");
        Icon = Shelf.UI.Brand.Icon;

        var root = new DockPanel { Margin = new Thickness(16) };

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 12, 0, 0),
        };
        DockPanel.SetDock(buttons, Dock.Bottom);
        var close = new Button { Content = Loc.T("Close"), Margin = new Thickness(0, 0, 8, 0), IsCancel = true };
        close.SetResourceReference(StyleProperty, "GhostButton");
        close.Click += (_, _) => Close();
        var copy = new Button { Content = Loc.T("Copy"), IsDefault = true };
        copy.SetResourceReference(StyleProperty, "PrimaryButton");
        copy.Click += (_, _) => CopyText();
        buttons.Children.Add(close);
        buttons.Children.Add(copy);
        root.Children.Add(buttons);

        _text = new TextBox
        {
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            FontSize = 13,
            Padding = new Thickness(6),
        };
        _text.SetResourceReference(StyleProperty, "Field");
        _text.VerticalContentAlignment = VerticalAlignment.Top;
        root.Children.Add(_text);

        Content = root;
    }

    public void ShowText(string text)
    {
        _text.Text = text;
        if (!IsVisible) Show();
        Activate();
        _text.Focus();
        _text.SelectAll();
    }

    private void CopyText()
    {
        var text = _text.SelectionLength > 0 ? _text.SelectedText : _text.Text;
        try
        {
            Clipboard.SetText(text);
            NotifyPopup.Show(Loc.T("Text copied"));
        }
        catch { NotifyPopup.Show(Loc.T("Clipboard is busy — try again.")); }
    }
}
