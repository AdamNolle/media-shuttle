using System.Text.Json;
using System.Text.Json.Serialization;

namespace MediaShuttle.Core;

public sealed class StateStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter() }
    };

    public StateStore(string rootPath)
    {
        RootPath = Path.GetFullPath(rootPath);
        SessionsPath = Path.Combine(RootPath, "sessions");
        Directory.CreateDirectory(SessionsPath);
    }

    public string RootPath { get; }
    public string SessionsPath { get; }
    public string SettingsPath => Path.Combine(RootPath, "settings.json");

    public async Task<AppSettings> LoadSettingsAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(SettingsPath))
        {
            return new AppSettings();
        }

        try
        {
            await using FileStream stream = File.OpenRead(SettingsPath);
            return await JsonSerializer.DeserializeAsync<AppSettings>(stream, JsonOptions, cancellationToken)
                .ConfigureAwait(false) ?? new AppSettings();
        }
        catch (JsonException)
        {
            return new AppSettings();
        }
    }

    public Task SaveSettingsAsync(AppSettings settings, CancellationToken cancellationToken = default) =>
        SaveJsonAtomicAsync(SettingsPath, settings, cancellationToken);

    public async Task<string> SaveSessionAsync(TransferSession session, CancellationToken cancellationToken = default)
    {
        string path = Path.Combine(SessionsPath, $"{session.StartedUtc:yyyyMMdd-HHmmss}-{session.SessionId[..6]}.json");
        await SaveJsonAtomicAsync(path, session, cancellationToken).ConfigureAwait(false);
        return path;
    }

    public async Task<TransferSession?> LoadLatestVerifiedForCardAsync(
        CardInfo card,
        CancellationToken cancellationToken = default)
    {
        foreach (string path in Directory.EnumerateFiles(SessionsPath, "*.json")
                     .OrderByDescending(File.GetLastWriteTimeUtc))
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                await using FileStream stream = File.OpenRead(path);
                TransferSession? session = await JsonSerializer.DeserializeAsync<TransferSession>(
                    stream,
                    JsonOptions,
                    cancellationToken).ConfigureAwait(false);
                if (session is null ||
                    !SameRoot(session.SourceRoot, card.RootPath) ||
                    (session.SourceVolumeSerial != 0 &&
                     card.VolumeSerial != 0 &&
                     session.SourceVolumeSerial != card.VolumeSerial))
                {
                    continue;
                }

                return session.Status.Equals("Verified", StringComparison.OrdinalIgnoreCase) &&
                       session.Files.Count > 0
                    ? session
                    : null;
            }
            catch (JsonException)
            {
            }
            catch (IOException)
            {
            }
        }

        return null;
    }

    private static async Task SaveJsonAtomicAsync<T>(
        string path,
        T value,
        CancellationToken cancellationToken)
    {
        string directory = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(directory);
        string temporaryPath = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            await using (var stream = new FileStream(
                             temporaryPath,
                             FileMode.CreateNew,
                             FileAccess.Write,
                             FileShare.None,
                             64 * 1024,
                             FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await JsonSerializer.SerializeAsync(stream, value, JsonOptions, cancellationToken)
                    .ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
            }

            File.Move(temporaryPath, path, true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private static bool SameRoot(string first, string second) =>
        Path.GetFullPath(first).TrimEnd(Path.DirectorySeparatorChar)
            .Equals(
                Path.GetFullPath(second).TrimEnd(Path.DirectorySeparatorChar),
                StringComparison.OrdinalIgnoreCase);
}
