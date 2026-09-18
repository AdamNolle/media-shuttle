namespace MediaShuttle.Core;

public static class MediaClassifier
{
    private static readonly HashSet<string> RawExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".arw", ".dng"
    };

    private static readonly HashSet<string> JpegExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".jpg", ".jpeg"
    };

    private static readonly HashSet<string> OtherPhotoExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".heif", ".heic", ".hif", ".tif", ".tiff", ".png"
    };

    private static readonly HashSet<string> VideoExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".mp4", ".mov", ".mxf", ".mts", ".m2ts", ".avi"
    };

    private static readonly HashSet<string> ScanExcludedDirectories = new(StringComparer.OrdinalIgnoreCase)
    {
        "$RECYCLE.BIN", "System Volume Information", ".fseventsd"
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

    public static IReadOnlyList<MediaItem> Scan(string rootPath)
    {
        string root = Path.GetFullPath(rootPath);
        var results = new List<MediaItem>();
        var pending = new Stack<string>();
        pending.Push(root);

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
                if (!TryClassify(filePath, out MediaKind kind))
                {
                    continue;
                }

                var file = new FileInfo(filePath);
                results.Add(new MediaItem(
                    file.FullName,
                    file.Name,
                    file.Extension.ToLowerInvariant(),
                    file.Length,
                    file.LastWriteTimeUtc,
                    kind));
            }

            foreach (string child in directories)
            {
                if (ScanExcludedDirectories.Contains(Path.GetFileName(child)))
                {
                    continue;
                }
                pending.Push(child);
            }
        }

        return results.OrderBy(item => item.SourcePath, StringComparer.OrdinalIgnoreCase).ToArray();
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
