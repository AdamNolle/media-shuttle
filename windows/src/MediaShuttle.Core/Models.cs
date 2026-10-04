namespace MediaShuttle.Core;

public enum MediaKind
{
    Jpeg,
    Raw,
    OtherPhoto,
    Video
}

public enum OperationPhase
{
    Idle,
    Scanning,
    CheckingDuplicate,
    Copying,
    Verifying,
    ReVerifying,
    Erasing,
    Complete,
    Cancelled,
    Error
}

public sealed record MediaItem(
    string SourcePath,
    string FileName,
    string Extension,
    long Size,
    DateTime LastWriteTimeUtc,
    MediaKind Kind);

public sealed record CardScan(
    IReadOnlyList<MediaItem> Media,
    IReadOnlyList<string> UnverifiableFiles);

public sealed record CardInfo(
    string RootPath,
    string VolumeLabel,
    uint VolumeSerial,
    long TotalBytes,
    long FreeBytes,
    string DriveType)
{
    public long UsedBytes => Math.Max(0, TotalBytes - FreeBytes);
}

public sealed class TransferRecord
{
    public string SourcePath { get; set; } = string.Empty;
    public string DestinationPath { get; set; } = string.Empty;
    public string Sha256 { get; set; } = string.Empty;
    public long Size { get; set; }
    public MediaKind Kind { get; set; }
}

public sealed class TransferSession
{
    public string SessionId { get; set; } = Guid.NewGuid().ToString("N");
    public DateTimeOffset StartedUtc { get; set; }
    public DateTimeOffset? CompletedUtc { get; set; }
    public DateTimeOffset? ErasedUtc { get; set; }
    public string Status { get; set; } = "In progress";
    public string SourceRoot { get; set; } = string.Empty;
    public string SourceLabel { get; set; } = string.Empty;
    public uint SourceVolumeSerial { get; set; }
    public string DestinationRoot { get; set; } = string.Empty;
    public int TotalFiles { get; set; }
    public long TotalBytes { get; set; }
    public int CopiedCount { get; set; }
    public int SkippedCount { get; set; }
    public int ErasedFileCount { get; set; }
    public List<TransferRecord> Files { get; set; } = [];

    public bool IsEligibleForErase(CardInfo card, IReadOnlyList<MediaItem> media)
    {
        try
        {
            if (!Status.Equals("Verified", StringComparison.OrdinalIgnoreCase) ||
                !Path.TrimEndingDirectorySeparator(Path.GetFullPath(SourceRoot)).Equals(
                    Path.TrimEndingDirectorySeparator(Path.GetFullPath(card.RootPath)), StringComparison.OrdinalIgnoreCase) ||
                SourceVolumeSerial != card.VolumeSerial || Files.Count == 0 || Files.Count != media.Count)
                return false;
            var records = new Dictionary<string, TransferRecord>(StringComparer.OrdinalIgnoreCase);
            foreach (TransferRecord record in Files)
                if (!records.TryAdd(Path.GetFullPath(record.SourcePath), record)) return false;
            foreach (MediaItem item in media)
            {
                if (!records.TryGetValue(Path.GetFullPath(item.SourcePath), out TransferRecord? record) ||
                    record.Size != item.Size || !File.Exists(record.DestinationPath) ||
                    new FileInfo(record.DestinationPath).Length != record.Size) return false;
                PathUtilities.EnsureDestinationOutsideSource(record.DestinationPath, card.RootPath);
            }
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException or InvalidOperationException)
        {
            return false;
        }
    }
}

public sealed record OperationProgress(
    OperationPhase Phase,
    string CurrentItem,
    int CompletedFiles,
    int TotalFiles,
    long ProcessedBytes,
    long TotalBytes,
    int CopiedFiles = 0,
    int SkippedFiles = 0,
    string CurrentSourcePath = "",
    string CurrentDestinationFolder = "")
{
    public double Percent => TotalBytes <= 0
        ? (TotalFiles <= 0 ? 0 : Math.Clamp((double)CompletedFiles / TotalFiles * 100, 0, 100))
        : Math.Clamp((double)ProcessedBytes / TotalBytes * 100, 0, 100);
}

public sealed record TransferResult(TransferSession Session, string SessionFilePath);

public sealed record WipeResult(int DeletedFiles, IReadOnlyList<string> ProtectedSystemEntries);

public sealed class AppSettings
{
    public bool AutoTransfer { get; set; }
    public bool GroupByDate { get; set; }
    public bool ShowNotifications { get; set; } = true;
    public bool ShowActivityLog { get; set; } = true;
    public string DestinationRoot { get; set; } = string.Empty;
    public string Theme { get; set; } = "System";
}
