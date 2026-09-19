using System.Runtime.InteropServices;

namespace MediaShuttle;

internal static class NativeMethods
{
    private const int SwShow = 5;
    private const int SwRestore = 9;

    // Matching on the title alone finds any window called "Media Shuttle" — including a File Explorer
    // window open on a folder of that name, which is titled exactly that. Pinning the class to the one
    // WinUI 3 gives its desktop windows keeps this looking only at our own window.
    private const string WindowClass = "WinUIDesktopWin32WindowClass";

    public static void ActivateExistingWindow(string title)
    {
        IntPtr window = FindWindow(WindowClass, title);
        if (window != IntPtr.Zero)
        {
            ActivateWindow(window);
        }
    }

    public static void ActivateWindow(IntPtr window)
    {
        ShowWindow(window, IsIconic(window) ? SwRestore : SwShow);
        SetForegroundWindow(window);
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr FindWindow(string? className, string windowName);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindow(IntPtr window, int command);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsIconic(IntPtr window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    internal static extern uint GetDpiForWindow(IntPtr window);
}
