using System.Runtime.InteropServices;

namespace MediaShuttle;

internal static class NativeMethods
{
    private const int SwShow = 5;
    private const int SwRestore = 9;

    public static void ActivateExistingWindow(string title)
    {
        IntPtr window = FindWindow(null, title);
        if (window == IntPtr.Zero)
        {
            return;
        }

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
