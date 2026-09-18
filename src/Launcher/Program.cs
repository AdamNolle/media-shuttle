using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;

[assembly: AssemblyTitle("Media Shuttle")]
[assembly: AssemblyDescription("Verified Sony camera-card ingest for Windows")]
[assembly: AssemblyCompany("Media Shuttle")]
[assembly: AssemblyProduct("Media Shuttle")]
[assembly: AssemblyCopyright("Copyright 2026")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace MediaShuttle.Launcher
{
    internal static class Program
    {
        private const int SwShow = 5;
        private const int SwRestore = 9;

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr FindWindow(string className, string windowName);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr windowHandle, int command);

        [DllImport("user32.dll")]
        private static extern bool IsIconic(IntPtr windowHandle);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr windowHandle);

        [STAThread]
        private static int Main(string[] args)
        {
            bool background = args.Any(arg => string.Equals(arg, "--background", StringComparison.OrdinalIgnoreCase));
            bool selfTest = args.Any(arg => string.Equals(arg, "--self-test", StringComparison.OrdinalIgnoreCase));

            if (!background && !selfTest)
            {
                IntPtr existingWindow = FindWindow(null, "Sony Media Shuttle");
                if (existingWindow != IntPtr.Zero)
                {
                    ShowWindow(existingWindow, IsIconic(existingWindow) ? SwRestore : SwShow);
                    SetForegroundWindow(existingWindow);
                    return 0;
                }
            }

            string appDirectory = AppDomain.CurrentDomain.BaseDirectory;
            string scriptPath = Path.Combine(appDirectory, "Sony Media Shuttle.ps1");
            if (!File.Exists(scriptPath))
            {
                MessageBox.Show(
                    "The Media Shuttle application script is missing. Rebuild or reinstall the app.",
                    "Media Shuttle",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return 2;
            }

            string windowsDirectory = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string powerShellPath = Path.Combine(
                windowsDirectory,
                "System32",
                "WindowsPowerShell",
                "v1.0",
                "powershell.exe");

            string powerShellArguments =
                "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File \"" +
                scriptPath.Replace("\"", "\\\"") +
                "\"";
            if (background)
            {
                powerShellArguments += " -Background";
            }
            if (selfTest)
            {
                powerShellArguments += " -SelfTest";
            }

            ProcessStartInfo startInfo = new ProcessStartInfo
            {
                FileName = powerShellPath,
                Arguments = powerShellArguments,
                WorkingDirectory = appDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };

            try
            {
                Process child = Process.Start(startInfo);
                if (selfTest && child != null)
                {
                    child.WaitForExit();
                    return child.ExitCode;
                }
                return child == null ? 3 : 0;
            }
            catch (Exception exception)
            {
                MessageBox.Show(
                    "Media Shuttle could not start.\r\n\r\n" + exception.Message,
                    "Media Shuttle",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return 4;
            }
        }
    }
}

