using System.Runtime.InteropServices;
using System.Text;

namespace MediaShuttle.Core;

public static class CardDetector
{
    public static IReadOnlyList<CardInfo> GetCandidates(string destinationRoot)
    {
        string destinationDrive = Path.GetPathRoot(Path.GetFullPath(destinationRoot)) ?? string.Empty;
        var candidates = new List<CardInfo>();

        foreach (DriveInfo drive in DriveInfo.GetDrives())
        {
            try
            {
                if (!drive.IsReady ||
                    drive.RootDirectory.FullName.Equals(destinationDrive, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                string root = drive.RootDirectory.FullName;
                bool hasCameraLayout = Directory.Exists(Path.Combine(root, "DCIM")) ||
                                       Directory.Exists(Path.Combine(root, "M4ROOT")) ||
                                       Directory.Exists(Path.Combine(root, "PRIVATE"));
                if (!hasCameraLayout)
                {
                    continue;
                }

                candidates.Add(new CardInfo(
                    root,
                    string.IsNullOrWhiteSpace(drive.VolumeLabel) ? "CAMERA MEDIA" : drive.VolumeLabel,
                    GetVolumeSerial(root),
                    drive.TotalSize,
                    drive.AvailableFreeSpace,
                    drive.DriveType.ToString()));
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }

        return candidates;
    }

    public static uint GetVolumeSerial(string rootPath)
    {
        var volumeName = new StringBuilder(261);
        var fileSystemName = new StringBuilder(261);
        return GetVolumeInformation(
            Path.GetPathRoot(Path.GetFullPath(rootPath))!,
            volumeName,
            volumeName.Capacity,
            out uint serial,
            out _,
            out _,
            fileSystemName,
            fileSystemName.Capacity)
            ? serial
            : 0;
    }

    [DllImport("kernel32.dll", EntryPoint = "GetVolumeInformationW", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetVolumeInformation(
        string rootPathName,
        StringBuilder volumeNameBuffer,
        int volumeNameSize,
        out uint volumeSerialNumber,
        out uint maximumComponentLength,
        out uint fileSystemFlags,
        StringBuilder fileSystemNameBuffer,
        int fileSystemNameSize);
}
