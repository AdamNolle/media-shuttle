using System;
using System.Runtime.InteropServices;

public static class Resize
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);

    public const uint SWP_NOZORDER = 0x0004;

    public static bool To(IntPtr handle, int x, int y, int w, int h)
    {
        bool ok = SetWindowPos(handle, IntPtr.Zero, x, y, w, h, SWP_NOZORDER);
        RECT r;
        GetWindowRect(handle, out r);
        Console.WriteLine("SetWindowPos returned " + ok + "; window now " + (r.Right - r.Left) + " x " + (r.Bottom - r.Top) + " at (" + r.Left + "," + r.Top + ")");
        return ok;
    }
}
