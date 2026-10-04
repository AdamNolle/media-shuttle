namespace MediaShuttle.Core;

public sealed class WipeService
{
    private readonly StateStore _stateStore;
    private readonly AppLogger _logger;

    public WipeService(StateStore stateStore, AppLogger logger)
    {
        _stateStore = stateStore;
        _logger = logger;
    }

    public async Task<WipeResult> WipeEverythingAsync(
        CardInfo card,
        TransferSession session,
        IProgress<OperationProgress>? progress,
        CancellationToken cancellationToken)
    {
        ValidateSession(card, session);
        if (card.DriveType == "Selected folder")
        {
            throw new InvalidOperationException("Erase is restricted to camera-card volumes, not selected folders.");
        }
        PathUtilities.EnsureNoLinks(card.RootPath);
        PathUtilities.EnsureDestinationOutsideSource(session.DestinationRoot, card.RootPath);
        string root = Path.GetFullPath(card.RootPath);
        if (!Directory.Exists(root))
        {
            throw new DirectoryNotFoundException("The verified card is no longer connected.");
        }

        // A transfer only copies files the classifier recognises as camera media, so any other user
        // content on the card has no destination copy to verify against. Deleting it anyway would
        // lose it permanently, so fail closed: the card must hold nothing but recognised media and
        // camera/OS housekeeping before erase will touch it.
        CardScan scan = await Task.Run(() => MediaClassifier.ScanCard(root), cancellationToken).ConfigureAwait(false);
        if (scan.UnverifiableFiles.Count > 0)
        {
            string names = string.Join(", ", scan.UnverifiableFiles.Select(Path.GetFileName).Take(5));
            throw new InvalidOperationException(
                $"Erase blocked: {scan.UnverifiableFiles.Count:N0} file(s) on this card are not recognised camera media, " +
                $"so no verified copy exists for them: {names}. " +
                "Copy them off the card yourself before erasing.");
        }

        IReadOnlyList<MediaItem> currentMedia = scan.Media;
        var records = session.Files.ToDictionary(
            record => Path.GetFullPath(record.SourcePath),
            StringComparer.OrdinalIgnoreCase);
        long totalBytes = currentMedia.Sum(item => item.Size);
        long processedBytes = 0;
        int verifiedFiles = 0;

        await _logger.WriteAsync("Re-verifying all remaining card media before erase", cancellationToken);
        foreach (MediaItem item in currentMedia)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!records.TryGetValue(Path.GetFullPath(item.SourcePath), out TransferRecord? record))
            {
                throw new InvalidOperationException(
                    $"Erase blocked: {item.FileName} was not part of the verified transfer. Transfer the card again first.");
            }
            // Each of these says what to do about it. "The destination copy changed size" on its own
            // leaves erase locked with nothing the card's owner can act on, and the answer is the
            // same every time: transfer again, which re-verifies the file and records it afresh.
            PathUtilities.EnsureDestinationOutsideSource(record.DestinationPath, card.RootPath);
            if (!File.Exists(record.DestinationPath))
            {
                throw new FileNotFoundException(
                    $"Erase blocked: the destination copy of {item.FileName} is missing. " +
                    "Transfer this card again to restore it, then erase.",
                    record.DestinationPath);
            }
            if (new FileInfo(record.DestinationPath).Length != record.Size)
            {
                throw new IOException(
                    $"Erase blocked: the destination copy of {item.FileName} is no longer the size it was verified at. " +
                    "Transfer this card again to re-verify it, then erase.");
            }

            string destinationFolder = PathUtilities.RelativeDestinationFolder(session.DestinationRoot, record.DestinationPath);
            progress?.Report(new OperationProgress(
                OperationPhase.ReVerifying,
                item.FileName,
                verifiedFiles,
                currentMedia.Count,
                processedBytes,
                totalBytes,
                CurrentSourcePath: item.SourcePath,
                CurrentDestinationFolder: destinationFolder));
            string sourceHash = await FileHasher.Sha256Async(item.SourcePath, cancellationToken).ConfigureAwait(false);
            string destinationHash = await FileHasher.Sha256Async(record.DestinationPath, cancellationToken).ConfigureAwait(false);
            if (!sourceHash.Equals(record.Sha256, StringComparison.OrdinalIgnoreCase) ||
                !destinationHash.Equals(record.Sha256, StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException(
                    $"Erase blocked: {item.FileName} no longer matches its verified copy. " +
                    "Transfer this card again to re-verify it, then erase.");
            }

            processedBytes += item.Size;
            verifiedFiles++;
        }

        if (!session.IsEligibleForErase(card, currentMedia))
        {
            throw new InvalidOperationException("Erase blocked: the card contents or destination copies changed. Transfer again first.");
        }
        string[] rootEntries = Directory.GetFileSystemEntries(root);
        int totalUserEntries = rootEntries.Count(entry => !MediaClassifier.IsWindowsManagedRootEntry(entry));
        int completedEntries = 0;
        int deletedFiles = 0;
        var failures = new List<string>();
        var protectedEntries = new List<string>();

        foreach (string entry in rootEntries)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (MediaClassifier.IsWindowsManagedRootEntry(entry))
            {
                protectedEntries.Add(Path.GetFileName(Path.TrimEndingDirectorySeparator(entry)));
                continue;
            }

            // Deletion has no byte total to measure against, so progress is counted in entries and
            // the byte figures are left at zero. Reporting the entry count as a byte count made the
            // processed and throughput readouts show "12 B" and "0 MB/s avg" during an erase.
            progress?.Report(new OperationProgress(
                OperationPhase.Erasing,
                Path.GetFileName(Path.TrimEndingDirectorySeparator(entry)),
                completedEntries,
                Math.Max(1, totalUserEntries),
                0,
                0));
            try
            {
                deletedFiles += DeleteEntry(entry, root, cancellationToken);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                failures.Add($"{Path.GetFileName(entry)}: {exception.Message}");
            }
            completedEntries++;
        }

        string[] remainingUserEntries = Directory.GetFileSystemEntries(root)
            .Where(entry => !MediaClassifier.IsWindowsManagedRootEntry(entry))
            .ToArray();
        IReadOnlyList<MediaItem> remainingMedia = MediaClassifier.Scan(root);
        if (failures.Count > 0 || remainingUserEntries.Length > 0 || remainingMedia.Count > 0)
        {
            string detail = failures.Count > 0
                ? string.Join("; ", failures.Take(5))
                : string.Join(", ", remainingUserEntries.Select(Path.GetFileName).Take(5));
            throw new IOException(
                $"The card could not be completely erased. Remaining content: {detail}. " +
                "Check the card's write-protect switch and close apps using the card, then try again.");
        }

        session.Status = "Erased";
        session.ErasedUtc = DateTimeOffset.UtcNow;
        session.ErasedFileCount = deletedFiles;
        await _stateStore.SaveSessionAsync(session, cancellationToken).ConfigureAwait(false);
        await _logger.WriteAsync(
            $"Card erase complete: {deletedFiles} files removed; only Windows-managed volume folders may remain",
            cancellationToken).ConfigureAwait(false);
        progress?.Report(new OperationProgress(
            OperationPhase.Complete,
            "Card contents erased",
            Math.Max(1, totalUserEntries),
            Math.Max(1, totalUserEntries),
            0,
            0));
        return new WipeResult(deletedFiles, protectedEntries);
    }

    private static int DeleteEntry(string path, string root, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        EnsureSafeChild(path, root);
        FileAttributes attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.Directory) == 0)
        {
            DeleteFileWithRetry(path);
            return 1;
        }

        if ((attributes & FileAttributes.ReparsePoint) != 0)
        {
            File.SetAttributes(path, FileAttributes.Normal);
            Directory.Delete(path);
            return 0;
        }

        int deletedFiles = 0;
        foreach (string child in Directory.GetFileSystemEntries(path))
        {
            deletedFiles += DeleteEntry(child, root, cancellationToken);
        }

        File.SetAttributes(path, FileAttributes.Normal);
        Directory.Delete(path);
        return deletedFiles;
    }

    private static void DeleteFileWithRetry(string path)
    {
        Exception? lastError = null;
        for (int attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                File.SetAttributes(path, FileAttributes.Normal);
                File.Delete(path);
                if (!File.Exists(path))
                {
                    return;
                }
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                lastError = exception;
                Thread.Sleep(100 * (attempt + 1));
            }
        }

        throw new IOException($"Could not delete {Path.GetFileName(path)} after clearing its attributes.", lastError);
    }

    private static void EnsureSafeChild(string candidate, string root)
    {
        string normalizedRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        string normalizedCandidate = Path.GetFullPath(candidate);
        if (!normalizedCandidate.StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("Safety check rejected a path outside the selected card.");
        }
    }

    private static void ValidateSession(CardInfo card, TransferSession session)
    {
        if (session.Files.Count == 0)
        {
            throw new InvalidOperationException("Erase requires a verified transfer containing media files.");
        }
        if (!session.Status.Equals("Verified", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("Erase is available only after a completed verified transfer.");
        }
        if (!Path.GetFullPath(session.SourceRoot).TrimEnd(Path.DirectorySeparatorChar)
                .Equals(
                    Path.GetFullPath(card.RootPath).TrimEnd(Path.DirectorySeparatorChar),
                    StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("The connected card does not match the verified transfer.");
        }
        if (session.SourceVolumeSerial != 0 && card.VolumeSerial != 0 &&
            session.SourceVolumeSerial != card.VolumeSerial)
        {
            throw new InvalidOperationException("The card volume ID does not match the verified transfer.");
        }
    }
}
