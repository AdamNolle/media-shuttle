using System.Security.Cryptography;

namespace MediaShuttle.Core;

public sealed class TransferService
{
    private const int BufferSize = 1024 * 1024;
    private const string PartialMarker = ".partial-";
    private readonly StateStore _stateStore;
    private readonly AppLogger _logger;

    public TransferService(StateStore stateStore, AppLogger logger)
    {
        _stateStore = stateStore;
        _logger = logger;
    }

    public async Task<TransferResult> TransferAsync(
        CardInfo card,
        string destinationRoot,
        bool groupByDate,
        IProgress<OperationProgress>? progress,
        CancellationToken cancellationToken)
    {
        destinationRoot = Path.GetFullPath(destinationRoot);
        Directory.CreateDirectory(destinationRoot);
        EnsureDestinationFolders(destinationRoot);
        CleanupPartials(destinationRoot);

        progress?.Report(new OperationProgress(OperationPhase.Scanning, "Scanning card", 0, 0, 0, 0));
        await _logger.WriteAsync($"Scanning {card.RootPath} for camera media", cancellationToken);
        IReadOnlyList<MediaItem> media = await Task.Run(
            () => MediaClassifier.Scan(card.RootPath),
            cancellationToken).ConfigureAwait(false);
        if (media.Count == 0)
        {
            throw new InvalidOperationException("No supported photos or videos were found on this card.");
        }

        long totalBytes = media.Sum(item => item.Size);
        EnsureFreeSpace(destinationRoot, totalBytes);

        var session = new TransferSession
        {
            StartedUtc = DateTimeOffset.UtcNow,
            SourceRoot = card.RootPath,
            SourceLabel = card.VolumeLabel,
            SourceVolumeSerial = card.VolumeSerial,
            DestinationRoot = destinationRoot,
            TotalFiles = media.Count,
            TotalBytes = totalBytes
        };

        long processedBytes = 0;
        int completedFiles = 0;
        foreach (MediaItem item in media)
        {
            cancellationToken.ThrowIfCancellationRequested();
            string folder = Path.Combine(destinationRoot, MediaClassifier.DestinationFolder(item.Kind));
            if (groupByDate)
            {
                folder = Path.Combine(folder, item.LastWriteTimeUtc.ToLocalTime().ToString("yyyy-MM-dd"));
            }
            Directory.CreateDirectory(folder);

            string destinationPath = Path.Combine(folder, item.FileName);
            string hash;
            bool skipped = false;
            if (File.Exists(destinationPath) && new FileInfo(destinationPath).Length == item.Size)
            {
                progress?.Report(new OperationProgress(
                    OperationPhase.CheckingDuplicate,
                    item.FileName,
                    completedFiles,
                    media.Count,
                    processedBytes,
                    totalBytes,
                    session.CopiedCount,
                    session.SkippedCount,
                    item.SourcePath,
                    MediaClassifier.DestinationFolder(item.Kind)));
                string sourceHash = await FileHasher.Sha256Async(item.SourcePath, cancellationToken).ConfigureAwait(false);
                string destinationHash = await FileHasher.Sha256Async(destinationPath, cancellationToken).ConfigureAwait(false);
                if (sourceHash.Equals(destinationHash, StringComparison.OrdinalIgnoreCase))
                {
                    hash = sourceHash;
                    skipped = true;
                    session.SkippedCount++;
                    processedBytes += item.Size;
                    await _logger.WriteAsync($"Verified existing {item.FileName}", cancellationToken);
                }
                else
                {
                    destinationPath = GetUniquePath(folder, item.FileName);
                    hash = await CopyAndVerifyAsync(
                        item,
                        destinationPath,
                        media.Count,
                        completedFiles,
                        totalBytes,
                        () => processedBytes,
                        value => processedBytes = value,
                        session,
                        progress,
                        cancellationToken).ConfigureAwait(false);
                }
            }
            else
            {
                if (File.Exists(destinationPath))
                {
                    destinationPath = GetUniquePath(folder, item.FileName);
                }
                hash = await CopyAndVerifyAsync(
                    item,
                    destinationPath,
                    media.Count,
                    completedFiles,
                    totalBytes,
                    () => processedBytes,
                    value => processedBytes = value,
                    session,
                    progress,
                    cancellationToken).ConfigureAwait(false);
            }

            if (!skipped)
            {
                session.CopiedCount++;
            }
            completedFiles++;
            progress?.Report(new OperationProgress(
                OperationPhase.Verifying,
                item.FileName,
                completedFiles,
                media.Count,
                processedBytes,
                totalBytes,
                session.CopiedCount,
                session.SkippedCount,
                item.SourcePath,
                MediaClassifier.DestinationFolder(item.Kind)));
            session.Files.Add(new TransferRecord
            {
                SourcePath = item.SourcePath,
                DestinationPath = destinationPath,
                Sha256 = hash,
                Size = item.Size,
                Kind = item.Kind
            });
        }

        session.Status = "Verified";
        session.CompletedUtc = DateTimeOffset.UtcNow;
        string sessionFilePath = await _stateStore.SaveSessionAsync(session, cancellationToken).ConfigureAwait(false);
        await _logger.WriteAsync(
            $"Transfer verified: {session.CopiedCount} copied, {session.SkippedCount} already safe",
            cancellationToken).ConfigureAwait(false);
        progress?.Report(new OperationProgress(
            OperationPhase.Complete,
            "Transfer verified",
            media.Count,
            media.Count,
            totalBytes,
            totalBytes,
            session.CopiedCount,
            session.SkippedCount));
        return new TransferResult(session, sessionFilePath);
    }

    private async Task<string> CopyAndVerifyAsync(
        MediaItem item,
        string destinationPath,
        int totalFiles,
        int completedFiles,
        long totalBytes,
        Func<long> getProcessedBytes,
        Action<long> setProcessedBytes,
        TransferSession session,
        IProgress<OperationProgress>? progress,
        CancellationToken cancellationToken)
    {
        string temporaryPath = destinationPath + PartialMarker + Guid.NewGuid().ToString("N");
        try
        {
            await _logger.WriteAsync($"Copying {item.FileName}", cancellationToken);
            using IncrementalHash sourceHasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            await using (var source = new FileStream(
                             item.SourcePath,
                             FileMode.Open,
                             FileAccess.Read,
                             FileShare.Read,
                             BufferSize,
                             FileOptions.Asynchronous | FileOptions.SequentialScan))
            await using (var destination = new FileStream(
                             temporaryPath,
                             FileMode.CreateNew,
                             FileAccess.Write,
                             FileShare.None,
                             BufferSize,
                             FileOptions.Asynchronous | FileOptions.SequentialScan))
            {
                byte[] buffer = new byte[BufferSize];
                int read;
                while ((read = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) > 0)
                {
                    sourceHasher.AppendData(buffer, 0, read);
                    await destination.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
                    long next = getProcessedBytes() + read;
                    setProcessedBytes(next);
                    progress?.Report(new OperationProgress(
                        OperationPhase.Copying,
                        item.FileName,
                        completedFiles,
                        totalFiles,
                        next,
                        totalBytes,
                        session.CopiedCount,
                        session.SkippedCount,
                        item.SourcePath,
                        MediaClassifier.DestinationFolder(item.Kind)));
                }
                await destination.FlushAsync(cancellationToken).ConfigureAwait(false);
            }

            string sourceHash = Convert.ToHexString(sourceHasher.GetHashAndReset());
            File.SetLastWriteTimeUtc(temporaryPath, item.LastWriteTimeUtc);
            progress?.Report(new OperationProgress(
                OperationPhase.Verifying,
                item.FileName,
                completedFiles,
                totalFiles,
                getProcessedBytes(),
                totalBytes,
                session.CopiedCount,
                session.SkippedCount,
                item.SourcePath,
                MediaClassifier.DestinationFolder(item.Kind)));
            string destinationHash = await FileHasher.Sha256Async(temporaryPath, cancellationToken).ConfigureAwait(false);
            if (!sourceHash.Equals(destinationHash, StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException($"SHA-256 verification failed for {item.FileName}.");
            }
            File.Move(temporaryPath, destinationPath);
            await _logger.WriteAsync($"Verified {item.FileName}", cancellationToken);
            return sourceHash;
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.SetAttributes(temporaryPath, FileAttributes.Normal);
                File.Delete(temporaryPath);
            }
        }
    }

    private static string GetUniquePath(string directory, string fileName)
    {
        string stem = Path.GetFileNameWithoutExtension(fileName);
        string extension = Path.GetExtension(fileName);
        for (int number = 2; ; number++)
        {
            string candidate = Path.Combine(directory, $"{stem} ({number}){extension}");
            if (!File.Exists(candidate))
            {
                return candidate;
            }
        }
    }

    private static void EnsureDestinationFolders(string destinationRoot)
    {
        foreach (string path in new[]
                 {
                     Path.Combine(destinationRoot, "Photos", "JPEGs"),
                     Path.Combine(destinationRoot, "Photos", "RAWs"),
            Path.Combine(destinationRoot, "Photos", "Other"),
                     Path.Combine(destinationRoot, "Videos")
                 })
        {
            Directory.CreateDirectory(path);
        }
    }

    private static void CleanupPartials(string destinationRoot)
    {
        foreach (string partial in Directory.EnumerateFiles(
                     destinationRoot,
                     $"*{PartialMarker}*",
                     SearchOption.AllDirectories))
        {
            if (!IsOwnedPartial(partial))
            {
                continue;
            }

            try
            {
                File.SetAttributes(partial, FileAttributes.Normal);
                File.Delete(partial);
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }

    private static bool IsOwnedPartial(string path)
    {
        string fileName = Path.GetFileName(path);
        int markerIndex = fileName.LastIndexOf(PartialMarker, StringComparison.OrdinalIgnoreCase);
        if (markerIndex < 0)
        {
            return false;
        }

        ReadOnlySpan<char> identifier = fileName.AsSpan(markerIndex + PartialMarker.Length);
        if (identifier.Length != 32)
        {
            return false;
        }

        foreach (char character in identifier)
        {
            if (!Uri.IsHexDigit(character))
            {
                return false;
            }
        }

        return true;
    }

    private static void EnsureFreeSpace(string destinationRoot, long totalBytes)
    {
        string root = Path.GetPathRoot(destinationRoot) ?? throw new IOException("Destination drive was not found.");
        var drive = new DriveInfo(root);
        const long reserve = 1024L * 1024L * 1024L;
        if (drive.AvailableFreeSpace < totalBytes + reserve)
        {
            throw new IOException("Not enough free space. Keep at least the card size plus 1 GB available.");
        }
    }
}
