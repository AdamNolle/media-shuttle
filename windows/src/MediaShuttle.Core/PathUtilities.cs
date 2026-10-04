namespace MediaShuttle.Core;

public static class PathUtilities
{
    public static bool IsSameOrChild(string candidate, string parent)
    {
        string root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(parent));
        string path = Path.TrimEndingDirectorySeparator(Path.GetFullPath(candidate));
        return path.Equals(root, StringComparison.OrdinalIgnoreCase) ||
            path.StartsWith(root.EndsWith(Path.DirectorySeparatorChar) ? root : root + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase);
    }

    // Check every existing ancestor: a category folder can be a junction back to the card.
    public static void EnsureNoLinks(string path)
    {
        for (string? current = Path.GetFullPath(path); current is not null;
             current = Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(current)))
        {
            if ((Directory.Exists(current) || File.Exists(current)) &&
                (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
            {
                throw new InvalidOperationException("Choose a path without symbolic links or junctions.");
            }
        }
    }

    public static void EnsureDestinationOutsideSource(string destination, string source)
    {
        if (IsSameOrChild(destination, source))
        {
            throw new InvalidOperationException("The destination cannot be inside the selected source.");
        }
        EnsureNoLinks(source);
        EnsureNoLinks(destination);
    }

    /// <summary>
    /// The destination subfolder (relative to <paramref name="destinationRoot"/>) that contains
    /// <paramref name="destinationPath"/>, e.g. "Photos\RAWs". Shared by the wipe re-verify
    /// progress reporting and the UI's session-footer display so both agree on the same format.
    /// </summary>
    public static string RelativeDestinationFolder(string destinationRoot, string destinationPath)
    {
        string directory = Path.GetDirectoryName(destinationPath) ?? destinationRoot;
        return Path.GetRelativePath(destinationRoot, directory);
    }
}
