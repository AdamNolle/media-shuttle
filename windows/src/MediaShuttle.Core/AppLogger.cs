using System.Text;

namespace MediaShuttle.Core;

public sealed class AppLogger
{
    private readonly string _logPath;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public AppLogger(string stateRoot)
    {
        Directory.CreateDirectory(stateRoot);
        _logPath = Path.Combine(stateRoot, "app.log");
    }

    public async Task WriteAsync(string message, CancellationToken cancellationToken = default)
    {
        string line = $"{DateTimeOffset.Now:O}  {message}{Environment.NewLine}";
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await File.AppendAllTextAsync(_logPath, line, new UTF8Encoding(false), cancellationToken)
                .ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }
}
