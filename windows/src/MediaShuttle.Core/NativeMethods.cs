using System.Runtime.InteropServices;

namespace MediaShuttle.Core;

internal static class NativeMethods
{
    /// <summary>
    /// Free space for the volume holding <paramref name="directoryName"/>. Unlike DriveInfo this
    /// answers for UNC shares and directory mount points, and reports the quota available to the
    /// calling user rather than the raw volume figure.
    /// </summary>
    [DllImport("kernel32.dll", EntryPoint = "GetDiskFreeSpaceExW", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetDiskFreeSpaceEx(
        string directoryName,
        out ulong freeBytesAvailableToCaller,
        out ulong totalNumberOfBytes,
        out ulong totalNumberOfFreeBytes);
}
