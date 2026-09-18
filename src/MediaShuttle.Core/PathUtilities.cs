namespace MediaShuttle.Core;

public static class PathUtilities
{
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
