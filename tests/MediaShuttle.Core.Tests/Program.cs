using MediaShuttle.Core;

namespace MediaShuttle.Core.Tests;

internal static class Program
{
    private static int _assertions;

    private static async Task<int> Main()
    {
        string testRoot = Path.Combine(Path.GetTempPath(), "MediaShuttle-Tests-" + Guid.NewGuid().ToString("N"));
        try
        {
            await RunAsync(testRoot);
            Console.WriteLine($"PASS: {_assertions} assertions covering classification, settings, verified copy, duplicates, collisions, safety blocking, read-only erase, and post-erase verification.");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine("FAIL: " + exception);
            return 1;
        }
        finally
        {
            if (Directory.Exists(testRoot))
            {
                ClearAttributes(testRoot);
                Directory.Delete(testRoot, true);
            }
        }
    }

    private static async Task RunAsync(string testRoot)
    {
        string cardRoot = Path.Combine(testRoot, "CARD");
        string destinationRoot = Path.Combine(testRoot, "Camera");
        string stateRoot = Path.Combine(testRoot, "State");
        Directory.CreateDirectory(Path.Combine(cardRoot, "DCIM", "100MSDCF"));
        Directory.CreateDirectory(Path.Combine(cardRoot, "PRIVATE", "M4ROOT", "CLIP"));
        Directory.CreateDirectory(destinationRoot);

        string jpeg = Path.Combine(cardRoot, "DCIM", "100MSDCF", "DSC00001.JPG");
        string raw = Path.Combine(cardRoot, "DCIM", "100MSDCF", "DSC00001.ARW");
        string appleDouble = Path.Combine(cardRoot, "DCIM", "100MSDCF", "._DSC00001.JPG");
        string video = Path.Combine(cardRoot, "PRIVATE", "M4ROOT", "CLIP", "C0001.MP4");
        await File.WriteAllTextAsync(jpeg, "jpeg-one");
        await File.WriteAllTextAsync(raw, "raw-one");
        await File.WriteAllTextAsync(appleDouble, "metadata-not-photo");
        await File.WriteAllTextAsync(video, "video-one");
        await File.WriteAllTextAsync(Path.Combine(cardRoot, "INDEX.XML"), "metadata");

        Assert(MediaClassifier.TryClassify(jpeg, out MediaKind jpegKind) && jpegKind == MediaKind.Jpeg, "JPEG classification");
        Assert(MediaClassifier.TryClassify(raw, out MediaKind rawKind) && rawKind == MediaKind.Raw, "RAW classification");
        Assert(MediaClassifier.TryClassify(video, out MediaKind videoKind) && videoKind == MediaKind.Video, "Video classification");
        Assert(!MediaClassifier.TryClassify(appleDouble, out _), "AppleDouble exclusion");

        var stateStore = new StateStore(stateRoot);
        var logger = new AppLogger(stateRoot);
        var transfer = new TransferService(stateStore, logger);
        var wipe = new WipeService(stateStore, logger);
        var card = new CardInfo(cardRoot, "TEST CARD", 0, 64L * 1024 * 1024, 48L * 1024 * 1024, "Removable");

        await stateStore.SaveSettingsAsync(new AppSettings
        {
            DestinationRoot = destinationRoot,
            Theme = "Dark"
        });
        AppSettings roundTripSettings = await stateStore.LoadSettingsAsync();
        Assert(roundTripSettings.DestinationRoot == destinationRoot, "Destination setting round trip");
        Assert(roundTripSettings.Theme == "Dark", "Theme setting round trip");

        TransferResult first = await transfer.TransferAsync(card, destinationRoot, false, null, CancellationToken.None);
        Assert(first.Session.Status == "Verified", "Transfer reaches verified state");
        Assert(first.Session.CopiedCount == 3, "Three genuine media files copied");
        Assert(first.Session.SkippedCount == 0, "No first-run duplicates");
        Assert(File.Exists(Path.Combine(destinationRoot, "Photos", "JPEGs", "DSC00001.JPG")), "JPEG destination");
        Assert(File.Exists(Path.Combine(destinationRoot, "Photos", "RAWs", "DSC00001.ARW")), "RAW destination");
        Assert(File.Exists(Path.Combine(destinationRoot, "Videos", "C0001.MP4")), "Video destination");

        TransferResult duplicate = await transfer.TransferAsync(card, destinationRoot, false, null, CancellationToken.None);
        Assert(duplicate.Session.CopiedCount == 0, "Duplicate rerun copies nothing");
        Assert(duplicate.Session.SkippedCount == 3, "Duplicate rerun verifies every file");

        await File.WriteAllTextAsync(jpeg, "jpeg-two");
        TransferResult collision = await transfer.TransferAsync(card, destinationRoot, false, null, CancellationToken.None);
        Assert(collision.Session.CopiedCount == 1, "Changed same-name file is copied");
        Assert(File.Exists(Path.Combine(destinationRoot, "Photos", "JPEGs", "DSC00001 (2).JPG")), "Collision uses numbered filename");

        string unverified = Path.Combine(cardRoot, "DCIM", "100MSDCF", "DSC99999.JPG");
        await File.WriteAllTextAsync(unverified, "not transferred");
        bool blocked = false;
        try
        {
            await wipe.WipeEverythingAsync(card, collision.Session, null, CancellationToken.None);
        }
        catch (InvalidOperationException exception) when (exception.Message.Contains("not part of the verified transfer"))
        {
            blocked = true;
        }
        Assert(blocked, "Erase blocks unverified media");
        File.Delete(unverified);

        File.SetAttributes(jpeg, File.GetAttributes(jpeg) | FileAttributes.ReadOnly);
        string readOnlyUnknown = Path.Combine(cardRoot, "CAMERA.DAT");
        await File.WriteAllTextAsync(readOnlyUnknown, "camera database");
        File.SetAttributes(readOnlyUnknown, FileAttributes.ReadOnly | FileAttributes.Hidden);
        string protectedDirectory = Path.Combine(cardRoot, "System Volume Information");
        Directory.CreateDirectory(protectedDirectory);

        WipeResult wipeResult = await wipe.WipeEverythingAsync(card, collision.Session, null, CancellationToken.None);
        Assert(wipeResult.DeletedFiles >= 5, "Erase deletes media and non-media files");
        string[] remaining = Directory.GetFileSystemEntries(cardRoot);
        Assert(remaining.Length == 1 && Path.GetFileName(remaining[0]) == "System Volume Information", "Only Windows-managed volume folder remains");
        Assert(MediaClassifier.Scan(cardRoot).Count == 0, "Post-erase media scan is empty");
    }

    private static void Assert(bool condition, string message)
    {
        _assertions++;
        if (!condition)
        {
            throw new InvalidOperationException("Assertion failed: " + message);
        }
    }

    private static void ClearAttributes(string root)
    {
        foreach (string path in Directory.EnumerateFileSystemEntries(root, "*", SearchOption.AllDirectories).Reverse())
        {
            try
            {
                File.SetAttributes(path, FileAttributes.Normal);
            }
            catch
            {
            }
        }
    }
}
