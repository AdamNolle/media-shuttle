namespace MediaShuttle.Core;

public static class MediaClassifier
{
    // Anything a camera can write has to appear in one of these four sets. A format missing here is
    // not merely unsupported: the file is never copied, yet erase would still delete it. Erase is
    // guarded separately by IsDisposableCameraArtifact, so the two lists must be read together.
    private static readonly HashSet<string> RawExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".arw", ".sr2", ".srf",
        ".dng", ".raw",
        ".cr2", ".cr3", ".crw",
        ".nef", ".nrw",
        ".raf",
        ".orf",
        ".rw2", ".rwl",
        ".pef", ".ptx",
        ".srw",
        ".x3f",
        ".3fr", ".fff",
        ".iiq", ".cap", ".eip",
        ".mef", ".mos",
        ".mrw",
        ".erf",
        ".dcr", ".kdc", ".k25",
        ".gpr",
        ".ari"
    };

    private static readonly HashSet<string> JpegExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".jpg", ".jpeg", ".jpe"
    };

    private static readonly HashSet<string> OtherPhotoExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".heif", ".heic", ".hif", ".avif", ".jxl",
        ".tif", ".tiff",
        ".png", ".bmp", ".gif", ".webp",
        ".jp2", ".j2k",
        ".psd"
    };

    private static readonly HashSet<string> VideoExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".mp4", ".m4v", ".mov",
        ".mxf", ".braw", ".r3d",
        ".mts", ".m2ts", ".m2t", ".ts", ".mod", ".tod",
        ".avi", ".mkv", ".webm",
        ".wmv", ".asf",
        ".mpg", ".mpeg", ".m2v", ".vob",
        ".3gp", ".3g2",
        ".insv", ".lrv",
        ".dv"
    };

    // Housekeeping a camera or an operating system writes for itself. Erase may remove these
    // without a verified destination copy; everything else on the card blocks erase instead.
    private static readonly HashSet<string> DisposableExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".thm", ".ctg", ".cpi", ".mpl", ".bdm", ".bdmv", ".clpi", ".mpls",
        ".inp", ".ind", ".int", ".tdt", ".tid", ".modd", ".moff", ".bnp", ".pmp",
        ".xml", ".xmp", ".dat", ".bin", ".db", ".ini", ".inf", ".log", ".txt",
        ".sec", ".info", ".mdt", ".osd", ".mtd", ".pck", ".fpr", ".set", ".sav",
        ".idx", ".map", ".tmp", ".bup", ".ifo"
    };

    private static readonly HashSet<string> DisposableFileNames = new(StringComparer.OrdinalIgnoreCase)
    {
        ".DS_Store", "Thumbs.db", "desktop.ini", "Icon\r", "AUTORUN.INF"
    };

    private static readonly HashSet<string> ScanExcludedDirectories = new(StringComparer.OrdinalIgnoreCase)
    {
        "$RECYCLE.BIN", "System Volume Information", ".fseventsd", ".Spotlight-V100", ".Trashes"
    };

    public static bool TryClassify(string path, out MediaKind kind)
    {
        string fileName = Path.GetFileName(path);
        if (fileName.StartsWith("._", StringComparison.Ordinal))
        {
            kind = default;
            return false;
        }

        string extension = Path.GetExtension(fileName);
        if (RawExtensions.Contains(extension))
        {
            kind = MediaKind.Raw;
            return true;
        }
        if (JpegExtensions.Contains(extension))
        {
            kind = MediaKind.Jpeg;
            return true;
        }
        if (OtherPhotoExtensions.Contains(extension))
        {
            kind = MediaKind.OtherPhoto;
            return true;
        }
        if (VideoExtensions.Contains(extension))
        {
            kind = MediaKind.Video;
            return true;
        }

        kind = default;
        return false;
    }

    public static IReadOnlyList<MediaItem> Scan(string rootPath) => ScanCard(rootPath).Media;

    /// <summary>
    /// Files on the card that are neither recognised camera media nor camera/OS housekeeping. These
    /// are never copied by a transfer, so erase has no verified copy to check them against and must
    /// refuse rather than delete them.
    /// </summary>
    public static IReadOnlyList<string> FindUnverifiableFiles(string rootPath) =>
        ScanCard(rootPath).UnverifiableFiles;

    /// <summary>
    /// Walks the card once and splits what it finds into media to copy and content erase must never
    /// delete. Callers that need both should use this rather than two separate walks — a full card
    /// is tens of thousands of entries and the UI rescans every couple of seconds.
    /// </summary>
    public static CardScan ScanCard(string rootPath)
    {
        var media = new List<MediaItem>();
        var unverifiable = new List<string>();
        foreach (string filePath in EnumerateCardFiles(rootPath))
        {
            if (!TryClassify(filePath, out MediaKind kind))
            {
                if (!IsDisposableCameraArtifact(filePath))
                {
                    unverifiable.Add(filePath);
                }
                continue;
            }

            var file = new FileInfo(filePath);
            media.Add(new MediaItem(
                file.FullName,
                file.Name,
                file.Extension.ToLowerInvariant(),
                file.Length,
                file.LastWriteTimeUtc,
                kind));
        }

        media.Sort((left, right) => StringComparer.OrdinalIgnoreCase.Compare(left.SourcePath, right.SourcePath));
        unverifiable.Sort(StringComparer.OrdinalIgnoreCase);
        return new CardScan(media, unverifiable);
    }

    public static bool IsDisposableCameraArtifact(string path)
    {
        string fileName = Path.GetFileName(path);
        if (fileName.StartsWith("._", StringComparison.Ordinal) || DisposableFileNames.Contains(fileName))
        {
            return true;
        }

        return DisposableExtensions.Contains(Path.GetExtension(fileName));
    }

    private static IEnumerable<string> EnumerateCardFiles(string rootPath)
    {
        var pending = new Stack<string>();
        pending.Push(Path.GetFullPath(rootPath));

        while (pending.Count > 0)
        {
            string directory = pending.Pop();
            string[] files;
            string[] directories;
            try
            {
                files = Directory.GetFiles(directory);
                directories = Directory.GetDirectories(directory);
            }
            catch (UnauthorizedAccessException)
            {
                continue;
            }
            catch (IOException)
            {
                continue;
            }

            foreach (string filePath in files)
            {
                yield return filePath;
            }

            foreach (string child in directories)
            {
                if (ScanExcludedDirectories.Contains(Path.GetFileName(child)) || IsReparsePoint(child))
                {
                    continue;
                }
                pending.Push(child);
            }
        }
    }

    private static bool IsReparsePoint(string path)
    {
        try
        {
            return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
        }
        catch (IOException)
        {
            return true;
        }
        catch (UnauthorizedAccessException)
        {
            return true;
        }
    }

    public static string DestinationFolder(MediaKind kind) => kind switch
    {
        MediaKind.Jpeg => Path.Combine("Photos", "JPEGs"),
        MediaKind.Raw => Path.Combine("Photos", "RAWs"),
        MediaKind.OtherPhoto => Path.Combine("Photos", "Other"),
        MediaKind.Video => "Videos",
        _ => throw new ArgumentOutOfRangeException(nameof(kind))
    };

    public static bool IsWindowsManagedRootEntry(string path)
    {
        string name = Path.GetFileName(Path.TrimEndingDirectorySeparator(path));
        return name.Equals("$RECYCLE.BIN", StringComparison.OrdinalIgnoreCase) ||
               name.Equals("System Volume Information", StringComparison.OrdinalIgnoreCase);
    }
}
