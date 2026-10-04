using System.Runtime.InteropServices;
using System.Text;

namespace MediaShuttle.Core;

public static class CardDetector
{
    public static CardInfo GetSelectedSource(string path)
    {
        string root = Path.GetFullPath(path);
        PathUtilities.EnsureNoLinks(root);
        if (!Directory.Exists(root))
        {
            throw new DirectoryNotFoundException("The selected source folder is unavailable.");
        }
        string volumeRoot = Path.GetPathRoot(root)!;
        bool isVolumeRoot = Path.TrimEndingDirectorySeparator(root).Equals(
            Path.TrimEndingDirectorySeparator(volumeRoot), StringComparison.OrdinalIgnoreCase);
        if (isVolumeRoot && volumeRoot.Equals(
                Path.GetPathRoot(Environment.SystemDirectory), StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("Choose a media folder or a camera card, rather than the system drive.");
        }
        if (!NativeMethods.GetDiskFreeSpaceEx(root, out ulong available, out ulong total, out _))
        {
            throw new IOException("The selected source volume is unavailable.");
        }
        var drive = new DriveInfo(volumeRoot);
        return new CardInfo(root,
            isVolumeRoot ? (string.IsNullOrWhiteSpace(drive.VolumeLabel) ? "CAMERA MEDIA" : drive.VolumeLabel)
                : Path.GetFileName(Path.TrimEndingDirectorySeparator(root)),
            GetVolumeSerial(root), (long)total, (long)available,
            isVolumeRoot ? "Selected volume" : "Selected folder");
    }

    public static bool IsCameraCardVolume(string path)
    {
        string root = Path.GetFullPath(path);
        string volumeRoot = Path.GetPathRoot(root)!;
        return Path.TrimEndingDirectorySeparator(root).Equals(
                Path.TrimEndingDirectorySeparator(volumeRoot), StringComparison.OrdinalIgnoreCase) &&
            !volumeRoot.Equals(Path.GetPathRoot(Environment.SystemDirectory), StringComparison.OrdinalIgnoreCase) &&
            new DriveInfo(volumeRoot).DriveType is DriveType.Removable or DriveType.Fixed &&
            (Directory.Exists(Path.Combine(root, "DCIM")) ||
             Directory.Exists(Path.Combine(root, "M4ROOT")) ||
             Directory.Exists(Path.Combine(root, "PRIVATE")));
    }

    public static IReadOnlyList<CardInfo> GetCandidates(string destinationRoot)
    {
        string destinationDrive = Path.GetPathRoot(Path.GetFullPath(destinationRoot)) ?? string.Empty;
        string systemDrive = Path.GetPathRoot(Environment.SystemDirectory) ?? string.Empty;
        var candidates = new List<CardInfo>();

        foreach (DriveInfo drive in DriveInfo.GetDrives())
        {
            try
            {
                // Many USB card readers — including this app's own reference hardware — report
                // DriveType.Fixed rather than Removable, so both are treated as candidates. The
                // DCIM/M4ROOT/PRIVATE-at-root check below is what actually gates candidacy; it
                // keeps ordinary fixed drives (including the system drive, excluded outright) out.
                if (!drive.IsReady ||
                    drive.DriveType is not (DriveType.Removable or DriveType.Fixed) ||
                    drive.RootDirectory.FullName.Equals(destinationDrive, StringComparison.OrdinalIgnoreCase) ||
                    drive.RootDirectory.FullName.Equals(systemDrive, StringComparison.OrdinalIgnoreCase))
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

        return candidates.OrderBy(card => card.VolumeLabel, StringComparer.OrdinalIgnoreCase).ToArray();
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

public sealed class CardPresenceTracker
{
    private readonly HashSet<string> _seenRoots = new(StringComparer.OrdinalIgnoreCase);
    private bool _baselineEstablished;

    public bool Observe(string? selectedRoot, IEnumerable<string> activeRoots)
    {
        var active = activeRoots.ToHashSet(StringComparer.OrdinalIgnoreCase);
        _seenRoots.RemoveWhere(root => !active.Contains(root));

        if (!_baselineEstablished)
        {
            _seenRoots.UnionWith(active);
            _baselineEstablished = true;
            return false;
        }

        return selectedRoot is not null && _seenRoots.Add(selectedRoot);
    }
}
