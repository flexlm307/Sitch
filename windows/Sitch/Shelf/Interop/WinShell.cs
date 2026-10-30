using System.Diagnostics;
using System.IO;
using Sitch.Shelf.Core;
using Microsoft.Win32;
using static Sitch.Shelf.Interop.Native;

namespace Sitch.Shelf.Interop;

/// <summary>Files, folders and apps, the way Explorer would do it.</summary>
public static class WinShell
{
    /// <summary>Moves a file to the Recycle Bin, silently.</summary>
    public static bool Recycle(string path)
    {
        var op = new SHFILEOPSTRUCT
        {
            wFunc = FO_DELETE,
            pFrom = path + "\0\0",
            fFlags = (ushort)(FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI),
        };
        return SHFileOperation(ref op) == 0 && !op.fAnyOperationsAborted;
    }

    /// <summary>Opens a file with its default app, like a double click in Explorer.</summary>
    public static bool Open(string path) => Execute(path, "open");

    /// <summary>Opens a file in its editor: Paint for images, unless the user chose another.</summary>
    public static bool Edit(string path)
    {
        if (Execute(path, "edit")) return true;
        try { Process.Start(new ProcessStartInfo("mspaint.exe", $"\"{path}\"") { UseShellExecute = true }); return true; }
        catch { return false; }
    }

    public static void ShowInExplorer(string path)
    {
        try { Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true }); }
        catch { }
    }

    /// <summary>Starts a new screen snip, the same as Win+Shift+S.</summary>
    public static void Snip()
    {
        try { Process.Start(new ProcessStartInfo("explorer.exe", "ms-screenclip:") { UseShellExecute = true }); }
        catch (Exception e) { Log.Error($"Could not start a snip: {e.Message}"); }
    }

    public static void OpenFolder(string path)
    {
        try { Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true }); }
        catch { }
    }

    private static bool Execute(string file, string verb)
    {
        var info = new SHELLEXECUTEINFO
        {
            cbSize = System.Runtime.InteropServices.Marshal.SizeOf<SHELLEXECUTEINFO>(),
            fMask = SEE_MASK_FLAG_NO_UI,
            lpVerb = verb,
            lpFile = file,
            nShow = 1,
        };
        return ShellExecuteEx(ref info);
    }

    /// <summary>Where Windows saves screenshots: Pictures\Screenshots, OneDrive aware.</summary>
    public static string ScreenshotsFolder()
    {
        var known = KnownFolder(FOLDERID_Screenshots);
        if (!string.IsNullOrEmpty(known)) return known;
        var pictures = KnownFolder(FOLDERID_Pictures)
            ?? Environment.GetFolderPath(Environment.SpecialFolder.MyPictures);
        return Path.Combine(pictures, "Screenshots");
    }

    public static string Desktop()
        => KnownFolder(FOLDERID_Desktop) ?? Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
}
