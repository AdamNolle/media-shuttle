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
            Console.WriteLine($"PASS: {_assertions} assertions covering classification, settings, card-arrival startup safety, verified copy, duplicates, collisions, safety blocking, read-only erase, post-erase verification.");
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
        string stalePartial = Path.Combine(
            destinationRoot,
            "orphan.JPG.partial-0123456789abcdef0123456789abcdef");
        string unrelatedPartial = Path.Combine(destinationRoot, "keep.partial-draft");
        await File.WriteAllTextAsync(stalePartial, "stale interrupted transfer");
        await File.WriteAllTextAsync(unrelatedPartial, "user file");

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
        foreach (string rawName in new[] { "IMG.CR3", "IMG.CR2", "DSC.NEF", "DSCF.RAF", "P.ORF", "P.RW2", "X.PEF", "X.X3F" })
        {
            Assert(
                MediaClassifier.TryClassify(rawName, out MediaKind kind) && kind == MediaKind.Raw,
                $"{Path.GetExtension(rawName)} is recognised as RAW");
        }
        Assert(
            MediaClassifier.TryClassify("A001.BRAW", out MediaKind brawKind) && brawKind == MediaKind.Video,
            ".braw is recognised as video");
        Assert(MediaClassifier.IsDisposableCameraArtifact("INDEX.XML"), "Camera metadata is disposable");
        Assert(MediaClassifier.IsDisposableCameraArtifact("GOPR0001.THM"), "Camera thumbnails are disposable");
        Assert(!MediaClassifier.IsDisposableCameraArtifact("NOTES.PDF"), "Unknown user content is not disposable");

        var stateStore = new StateStore(stateRoot);
        var logger = new AppLogger(stateRoot);
        var transfer = new TransferService(stateStore, logger);
        var wipe = new WipeService(stateStore, logger);
        var card = new CardInfo(cardRoot, "TEST CARD", 0, 64L * 1024 * 1024, 48L * 1024 * 1024, "Removable");

        AppSettings newInstallSettings = await stateStore.LoadSettingsAsync();
        Assert(!newInstallSettings.AutoTransfer, "New installations leave automatic transfer off");
        Assert(newInstallSettings.ShowActivityLog, "New installations show the activity log by default");

        var mountedAtStartup = new CardPresenceTracker();
        Assert(
            !mountedAtStartup.Observe(cardRoot, [cardRoot]),
            "A card already mounted during the initial scan is baseline, not a new insertion");
        Assert(
            !mountedAtStartup.Observe(cardRoot, [cardRoot]),
            "A continuously mounted card is not reported as a new insertion");
        Assert(!mountedAtStartup.Observe(null, []), "Removing a card does not report an insertion");
        Assert(
            mountedAtStartup.Observe(cardRoot, [cardRoot]),
            "Reinserting a card after the initial scan is reported as a new insertion");

        string secondCardRoot = Path.Combine(testRoot, "SECOND-CARD");
        var multipleMountedAtStartup = new CardPresenceTracker();
        Assert(
            !multipleMountedAtStartup.Observe(cardRoot, [cardRoot, secondCardRoot]),
            "Every card present during the initial scan is added to the startup baseline");
        Assert(
            !multipleMountedAtStartup.Observe(secondCardRoot, [secondCardRoot]),
            "A second startup-mounted card is not reported as new when it becomes selected");

        var emptyAtStartup = new CardPresenceTracker();
        Assert(!emptyAtStartup.Observe(null, []), "An empty initial scan establishes the card baseline");
        Assert(
            emptyAtStartup.Observe(cardRoot, [cardRoot]),
            "A card first seen after an empty initial scan is reported as a new insertion");

        await stateStore.SaveSettingsAsync(new AppSettings
        {
            DestinationRoot = destinationRoot,
            AutoTransfer = true,
            Theme = "Dark",
            ShowActivityLog = false
        });
        AppSettings roundTripSettings = await stateStore.LoadSettingsAsync();
        Assert(roundTripSettings.DestinationRoot == destinationRoot, "Destination setting round trip");
        Assert(roundTripSettings.Theme == "Dark", "Theme setting round trip");
        Assert(roundTripSettings.AutoTransfer, "Automatic transfer opt-in round trip");
        Assert(!roundTripSettings.ShowActivityLog, "Activity log opt-out round trip");

        TransferResult first = await transfer.TransferAsync(card, destinationRoot, false, null, CancellationToken.None);
        Assert(first.Session.Status == "Verified", "Transfer reaches verified state");
        Assert(
            first.SessionFilePath == stateStore.SessionFilePath(first.Session),
            "Saved session path matches the deterministic report path");
        Assert(File.Exists(first.SessionFilePath), "Session report file exists after a verified transfer");
        Assert(first.Session.CopiedCount == 3, "Three genuine media files copied");
        Assert(first.Session.SkippedCount == 0, "No first-run duplicates");
        Assert(File.Exists(Path.Combine(destinationRoot, "Photos", "JPEGs", "DSC00001.JPG")), "JPEG destination");
        Assert(File.Exists(Path.Combine(destinationRoot, "Photos", "RAWs", "DSC00001.ARW")), "RAW destination");
        Assert(File.Exists(Path.Combine(destinationRoot, "Videos", "C0001.MP4")), "Video destination");
        Assert(Directory.Exists(Path.Combine(destinationRoot, "Photos", "Other")), "Other-photo destination exists");
        Assert(!File.Exists(stalePartial), "Stale Media Shuttle partial is cleaned up");
        Assert(File.Exists(unrelatedPartial), "Unrelated partial-like filename is preserved");

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

        // A format the classifier does not know is never copied, so erase has nothing to verify it
        // against and must refuse the whole card rather than delete it.
        string unknownFormat = Path.Combine(cardRoot, "DCIM", "100MSDCF", "CLIP0001.XYZ");
        await File.WriteAllTextAsync(unknownFormat, "an unrecognised camera format");
        Assert(
            MediaClassifier.FindUnverifiableFiles(cardRoot).Count == 1,
            "Unrecognised user content is reported as unverifiable");
        bool blockedUnknown = false;
        try
        {
            await wipe.WipeEverythingAsync(card, collision.Session, null, CancellationToken.None);
        }
        catch (InvalidOperationException exception) when (exception.Message.Contains("not recognised camera media"))
        {
            blockedUnknown = true;
        }
        Assert(blockedUnknown, "Erase blocks files it could never have copied");
        Assert(File.Exists(unknownFormat), "A blocked erase leaves unrecognised content untouched");
        File.Delete(unknownFormat);
        Assert(
            MediaClassifier.FindUnverifiableFiles(cardRoot).Count == 0,
            "Camera housekeeping alone does not block erase");

        File.SetAttributes(jpeg, File.GetAttributes(jpeg) | FileAttributes.ReadOnly);
        string readOnlyUnknown = Path.Combine(cardRoot, "CAMERA.DAT");
        await File.WriteAllTextAsync(readOnlyUnknown, "camera database");
        File.SetAttributes(readOnlyUnknown, FileAttributes.ReadOnly | FileAttributes.Hidden);

        string protectedCameraFolder = Path.Combine(cardRoot, "PRIVATE", "CAMERA_DB", "NESTED");
        Directory.CreateDirectory(protectedCameraFolder);
        string protectedCameraFile = Path.Combine(protectedCameraFolder, "INDEX.BDM");
        await File.WriteAllTextAsync(protectedCameraFile, "nested camera database");
        File.SetAttributes(protectedCameraFile, FileAttributes.ReadOnly | FileAttributes.Hidden);
        File.SetAttributes(Path.GetDirectoryName(protectedCameraFolder)!, FileAttributes.ReadOnly | FileAttributes.Hidden);
        string protectedDirectory = Path.Combine(cardRoot, "System Volume Information");
        Directory.CreateDirectory(protectedDirectory);

        WipeResult wipeResult = await wipe.WipeEverythingAsync(card, collision.Session, null, CancellationToken.None);
        Assert(wipeResult.DeletedFiles >= 5, "Erase deletes media and non-media files");
        string[] remaining = Directory.GetFileSystemEntries(cardRoot);
        Assert(remaining.Length == 1 && Path.GetFileName(remaining[0]) == "System Volume Information", "Only Windows-managed volume folder remains");
        Assert(MediaClassifier.Scan(cardRoot).Count == 0, "Post-erase media scan is empty");
        Assert(await stateStore.LoadLatestVerifiedForCardAsync(card) is null, "Erased session keeps older transfers locked");
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
