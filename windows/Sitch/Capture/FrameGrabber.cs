using System.Runtime.InteropServices;
using System.Windows;

namespace Sitch.Capture;

/// <summary>
/// Repeated grabs of one physical screen rect into a reused top-down 32-bit DIB, with the pointer drawn
/// in (BitBlt leaves it out). For recording: a grab is one BitBlt and one copy, cheap enough at 30 fps,
/// and safe on a worker thread.
/// </summary>
public sealed class FrameGrabber : IDisposable
{
    private readonly Int32Rect _rect;
    private readonly IntPtr _screenDc, _memDc, _bitmap, _old, _bits;

    public int Width => _rect.Width;
    public int Height => _rect.Height;
    public int FrameBytes => _rect.Width * _rect.Height * 4;

    public FrameGrabber(Int32Rect rect)
    {
        _rect = rect;
        _screenDc = Native.GetDC(IntPtr.Zero);
        _memDc = Native.CreateCompatibleDC(_screenDc);
        var bmi = new BITMAPINFOHEADER
        {
            biSize = Marshal.SizeOf<BITMAPINFOHEADER>(),
            biWidth = rect.Width,
            biHeight = -rect.Height, // top-down rows, as raw video expects
            biPlanes = 1,
            biBitCount = 32,
        };
        _bitmap = CreateDIBSection(_memDc, ref bmi, 0, out _bits, IntPtr.Zero, 0);
        if (_bitmap == IntPtr.Zero) throw new InvalidOperationException("CreateDIBSection failed");
        _old = Native.SelectObject(_memDc, _bitmap);
    }

    /// <summary>Fills <paramref name="into"/> (BGRA, top-down) with the rect as it is now.</summary>
    public void Grab(byte[] into, bool withPointer)
    {
        Native.BitBlt(_memDc, 0, 0, _rect.Width, _rect.Height, _screenDc, _rect.X, _rect.Y, Native.SRCCOPY | Native.CAPTUREBLT);
        if (withPointer) DrawPointer();
        GdiFlush();
        Marshal.Copy(_bits, into, 0, FrameBytes);
    }

    private void DrawPointer()
    {
        var ci = new CURSORINFO { cbSize = Marshal.SizeOf<CURSORINFO>() };
        if (!GetCursorInfo(ref ci) || (ci.flags & CURSOR_SHOWING) == 0 || ci.hCursor == IntPtr.Zero) return;
        int hx = 0, hy = 0;
        if (GetIconInfo(ci.hCursor, out var ii))
        {
            hx = ii.xHotspot;
            hy = ii.yHotspot;
            if (ii.hbmMask != IntPtr.Zero) Native.DeleteObject(ii.hbmMask);
            if (ii.hbmColor != IntPtr.Zero) Native.DeleteObject(ii.hbmColor);
        }
        DrawIconEx(_memDc, ci.ptScreenPos.X - hx - _rect.X, ci.ptScreenPos.Y - hy - _rect.Y, ci.hCursor, 0, 0, 0, IntPtr.Zero, DI_NORMAL);
    }

    public void Dispose()
    {
        Native.SelectObject(_memDc, _old);
        Native.DeleteObject(_bitmap);
        Native.DeleteDC(_memDc);
        Native.ReleaseDC(IntPtr.Zero, _screenDc);
    }

    private const int CURSOR_SHOWING = 1, DI_NORMAL = 3;

    [StructLayout(LayoutKind.Sequential)]
    private struct BITMAPINFOHEADER
    {
        public int biSize, biWidth, biHeight;
        public short biPlanes, biBitCount;
        public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct CURSORINFO { public int cbSize, flags; public IntPtr hCursor; public Native.POINT ptScreenPos; }

    [StructLayout(LayoutKind.Sequential)]
    private struct ICONINFO { public bool fIcon; public int xHotspot, yHotspot; public IntPtr hbmMask, hbmColor; }

    [DllImport("gdi32.dll")] private static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFOHEADER bmi, uint usage, out IntPtr bits, IntPtr section, uint offset);
    [DllImport("gdi32.dll")] private static extern bool GdiFlush();
    [DllImport("user32.dll")] private static extern bool GetCursorInfo(ref CURSORINFO ci);
    [DllImport("user32.dll")] private static extern bool GetIconInfo(IntPtr icon, out ICONINFO ii);
    [DllImport("user32.dll")] private static extern bool DrawIconEx(IntPtr hdc, int x, int y, IntPtr icon, int cx, int cy, int step, IntPtr brush, int flags);
}
