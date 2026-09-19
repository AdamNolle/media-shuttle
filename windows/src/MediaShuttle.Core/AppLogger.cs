using System.Text;

namespace MediaShuttle.Core;

public sealed class AppLogger
{
    // A transfer logs a line per file, and the app is meant to sit in the tray for months, so the
    // log has to be bounded. One rollover keeps the previous run's history available for diagnosing
    // a transfer without letting the folder grow without end.
    private const long MaximumBytes = 2L * 1024 * 1024;
    private readonly string _logPath;
    private readonly string _previousLogPath;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public AppLogger(string stateRoot)
    {
        Directory.CreateDirectory(stateRoot);
        _logPath = Path.Combine(stateRoot, "app.log");
        _previousLogPath = Path.Combine(stateRoot, "app.previous.log");
    }

    public async Task WriteAsync(string message, CancellationToken cancellationToken = default)
    {
        string line = $"{DateTimeOffset.Now:O}  {message}{Environment.NewLine}";
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            RollOverIfOversized();
            await File.AppendAllTextAsync(_logPath, line, new UTF8Encoding(false), cancellationToken)
                .ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    private void RollOverIfOversized()
    {
        try
        {
            var log = new FileInfo(_logPath);
            if (log.Exists && log.Length >= MaximumBytes)
            {
                File.Move(_logPath, _previousLogPath, true);
            }
        }
        catch (IOException)
        {
            // Logging must never take down the operation it is describing.
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}
