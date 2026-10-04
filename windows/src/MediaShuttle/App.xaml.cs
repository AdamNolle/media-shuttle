using System.Threading;
using Microsoft.UI.Xaml;

namespace MediaShuttle;

public partial class App : Application
{
    private static Mutex? _instanceMutex;
    private Window? _window;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, eventArgs) => WriteStartupCrash(eventArgs.Exception);
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        string mutexName = MainWindow.IsVisualPreview
            ? "Local\\MediaShuttle.VisualPreview" : "Local\\MediaShuttle.WinUI3";
        _instanceMutex = new Mutex(true, mutexName, out bool createdNew);
        if (!createdNew)
        {
            NativeMethods.ActivateExistingWindow("Media Shuttle");
            Exit();
            return;
        }

        try
        {
            bool launchInBackground = Environment.GetCommandLineArgs()
                .Any(argument => argument.Equals("--background", StringComparison.OrdinalIgnoreCase));
            var mainWindow = new MainWindow(launchInBackground);
            _window = mainWindow;
            if (MainWindow.IsVisualPreview) mainWindow.ShowVisualPreview();
            else _window.Activate();
        }
        catch (Exception exception)
        {
            WriteStartupCrash(exception);
            Exit();
            return;
        }
        AppDomain.CurrentDomain.ProcessExit += (_, _) =>
        {
            try
            {
                _instanceMutex?.ReleaseMutex();
                _instanceMutex?.Dispose();
            }
            catch
            {
            }
        };
    }

    private static void WriteStartupCrash(Exception exception)
    {
        try
        {
            string directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Media Shuttle");
            if (MainWindow.IsVisualPreview) directory = Path.Combine(Path.GetTempPath(), "MediaShuttle-VisualPreview");
            Directory.CreateDirectory(directory);
            File.WriteAllText(
                Path.Combine(directory, "startup-crash.log"),
                $"{DateTimeOffset.Now:O}{Environment.NewLine}{exception}");
        }
        catch
        {
        }
    }
}
