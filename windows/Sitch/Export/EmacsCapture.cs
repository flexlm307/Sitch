using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Media.Imaging;
using Sitch.Shell;

namespace Sitch.Export;

/// <summary>
/// Capture to Emacs (<c>--capture-to-emacs=&lt;folder&gt;</c>), the screenshot half of the AutoHotkey
/// one-key capture: with no text selected, AutoHotkey hands the capture to Sitch. The region is saved as
/// PNG into the bridge folder, read by OCR, and described in a UTF-8 request file that the Emacs side
/// (capture-bridge.el) turns into an Org entry. Only the request path goes on emacsclient's command line,
/// because emacsclient on Windows does not carry non-ASCII arguments intact. Windows only: the Mac app has
/// no AutoHotkey counterpart to pair with.
/// </summary>
public static class EmacsCapture
{
    /// <summary>Title of the foreground window, read before the overlay takes focus.</summary>
    public static string ForegroundTitle()
    {
        var hwnd = GetForegroundWindow();
        var title = new StringBuilder(512);
        return hwnd != IntPtr.Zero && GetWindowText(hwnd, title, title.Capacity) > 0 ? title.ToString() : "";
    }

    public static async Task SendAsync(BitmapSource bitmap, string folder, string source)
    {
        if (FindEmacsClient() is not { } client)
        {
            var saved = Exporters.QuickSave(bitmap);
            NotifyPopup.Show(Loc.F("Emacs was not found; saved {0} instead.", Path.GetFileName(saved)), bitmap);
            return;
        }
        try
        {
            Directory.CreateDirectory(folder);
            var stamp = $"{DateTime.Now:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}"[..24];
            var image = Path.Combine(folder, $"sitch-{stamp}.png");
            Exporters.Save(bitmap, image);

            string text = "";
            try { text = await Shelf.Core.Ocr.ReadAsync(bitmap) ?? ""; }
            catch (Exception e) { Shelf.Core.Log.Error($"Capture to Emacs: OCR failed: {e.Message}"); } // the image alone is still worth keeping

            var request = Path.Combine(folder, $"cap-{stamp}.txt");
            var header = $"Source: {source.ReplaceLineEndings(" ")}\nKind: screenshot\nImage: {image}\n\n";
            await File.WriteAllTextAsync(request, header + text, new UTF8Encoding(false));

            // emacsclient.exe with a hidden console: emacsclientw would show the eval result in a message box.
            var start = new ProcessStartInfo(client) { UseShellExecute = false, CreateNoWindow = true };
            start.ArgumentList.Add("-e");
            start.ArgumentList.Add($"(cxp/capture-from-file \"{request.Replace('\\', '/')}\")");
            using var process = Process.Start(start);
        }
        catch (Exception e)
        {
            Shelf.Core.Log.Error($"Capture to Emacs failed: {e.Message}");
            NotifyPopup.Show(Loc.F("Could not send the capture to Emacs: {0}", e.Message), bitmap);
        }
    }

    /// <summary>Newest emacsclient.exe under Program Files\Emacs, else the one on PATH.</summary>
    private static string? FindEmacsClient()
    {
        var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Emacs");
        if (Directory.Exists(root))
        {
            var found = Directory.GetDirectories(root)
                .Select(d => Path.Combine(d, "bin", "emacsclient.exe"))
                .Where(File.Exists)
                .OrderByDescending(p => p, StringComparer.OrdinalIgnoreCase)
                .FirstOrDefault();
            if (found is not null) return found;
        }
        return (Environment.GetEnvironmentVariable("PATH") ?? "")
            .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Select(d => Path.Combine(d.Trim(), "emacsclient.exe"))
            .FirstOrDefault(File.Exists);
    }

    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);
}
