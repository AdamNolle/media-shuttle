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
        _instanceMutex = new Mutex(true, "Local\\MediaShuttle.WinUI3", out bool createdNew);
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
            _window = new MainWindow(launchInBackground);
            _window.Activate();
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
