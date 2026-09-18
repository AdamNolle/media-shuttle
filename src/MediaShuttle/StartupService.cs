namespace MediaShuttle;

internal static class StartupService
{
    private const string ShortcutName = "Media Shuttle.lnk";
    private const string LegacyShortcutName = "Sony Media Shuttle.lnk";

    public static string ShortcutPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.Startup),
        ShortcutName);

    public static bool IsEnabled => File.Exists(ShortcutPath);

    public static void SetEnabled(bool enabled)
    {
        string legacyPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Startup),
            LegacyShortcutName);
        if (File.Exists(legacyPath))
        {
            File.Delete(legacyPath);
        }

        if (!enabled)
        {
            if (File.Exists(ShortcutPath))
            {
                File.Delete(ShortcutPath);
            }
            return;
        }

        string executable = Environment.ProcessPath ?? throw new InvalidOperationException("Application path is unavailable.");
        Type shellType = Type.GetTypeFromProgID("WScript.Shell") ??
                         throw new InvalidOperationException("Windows shortcut service is unavailable.");
        dynamic shell = Activator.CreateInstance(shellType)!;
        dynamic shortcut = shell.CreateShortcut(ShortcutPath);
        shortcut.TargetPath = executable;
        shortcut.Arguments = "--background";
        shortcut.WorkingDirectory = AppContext.BaseDirectory;
        shortcut.Description = "Watch for camera cards with Media Shuttle";
        shortcut.IconLocation = executable;
        shortcut.Save();
    }
}
