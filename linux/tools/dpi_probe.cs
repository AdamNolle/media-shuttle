using System;
using System.Runtime.InteropServices;

public static class Dpi
{
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwarenessContext(IntPtr context);
    public static readonly IntPtr PER_MONITOR_AWARE_V2 = new IntPtr(-4);

    public static void MakePerMonitorAware()
    {
        int result = SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2);
        Console.WriteLine("SetProcessDpiAwarenessContext returned " + result);
    }
}
