using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class Capture
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")] public static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool RestoreWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);

    // PW_RENDERFULLCONTENT (2) renders DirectComposition content, which is how WinUI 3 paints.
    public const uint PW_FLAGS = 2;

    public static IntPtr FindByTitle(string title)
    {
        IntPtr handle = FindWindow(null, title);
        if (handle == IntPtr.Zero) return IntPtr.Zero;
        if (IsIconic(handle)) RestoreWindow(handle);
        return handle;
    }

    public static Bitmap CaptureClient(IntPtr handle)
    {
        RECT client;
        if (!GetClientRect(handle, out client)) throw new Exception("GetClientRect failed");
        int w = client.Right - client.Left;
        int h = client.Bottom - client.Top;
        if (w <= 0 || h <= 0) throw new Exception("Client area is empty");

        Bitmap bitmap = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(bitmap))
        {
            IntPtr hdc = g.GetHdc();
            try
            {
                if (!PrintWindow(handle, hdc, PW_FLAGS))
                {
                    throw new Exception("PrintWindow failed");
                }
            }
            finally
            {
                g.ReleaseHdc(hdc);
            }
        }
        return bitmap;
    }
}
