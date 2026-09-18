import Foundation
import XCTest
@testable import MediaShuttleCore

final class MediaShuttleCoreTests: XCTestCase {
    private var testRoot: URL!
    private var cardRoot: URL!
    private var destinationRoot: URL!
    private var stateRoot: URL!

    override func setUpWithError() throws {
        testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaShuttleTests-\(UUID().uuidString)", isDirectory: true)
        cardRoot = testRoot.appendingPathComponent("CARD", isDirectory: true)
        destinationRoot = testRoot.appendingPathComponent("Camera", isDirectory: true)
        stateRoot = testRoot.appendingPathComponent("State", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cardRoot.appendingPathComponent("DCIM/100MSDCF", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: cardRoot.appendingPathComponent("PRIVATE/M4ROOT/CLIP", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let testRoot, FileManager.default.fileExists(atPath: testRoot.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: testRoot.path)
            try FileManager.default.removeItem(at: testRoot)
        }
    }

    func testClassificationAndScanIgnoreAppleDoubleFiles() throws {
        let jpeg = cardRoot.appendingPathComponent("DCIM/100MSDCF/DSC00001.JPG")
        let raw = cardRoot.appendingPathComponent("DCIM/100MSDCF/DSC00001.ARW")
        let video = cardRoot.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4")
        let sidecar = cardRoot.appendingPathComponent("DCIM/100MSDCF/._DSC00001.JPG")
        try write("jpeg", to: jpeg)
        try write("raw", to: raw)
        try write("video", to: video)
        try write("metadata", to: sidecar)

        XCTAssertEqual(MediaClassifier.classify(jpeg), .jpeg)
        XCTAssertEqual(MediaClassifier.classify(raw), .raw)
        XCTAssertEqual(MediaClassifier.classify(video), .video)
        XCTAssertNil(MediaClassifier.classify(sidecar))

        let items = try MediaClassifier.scan(cardRoot)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(Set(items.map(\.kind)), Set([.jpeg, .raw, .video]))
    }

    func testSettingsRoundTripAndCardPresenceBaseline() async throws {
        let store = try StateStore(rootURL: stateRoot)
        var settings = AppSettings()
        settings.autoTransfer = true
        settings.groupByDate = true
        settings.showActivityLog = false
        settings.appearance = "Dark"
        settings.destinationPath = destinationRoot.path
        try await store.saveSettings(settings)
        let loaded = await store.loadSettings()
        XCTAssertEqual(loaded, settings)

        var tracker = CardPresenceTracker()
        XCTAssertFalse(tracker.observe(selectedRoot: cardRoot, activeRoots: [cardRoot]))
        XCTAssertFalse(tracker.observe(selectedRoot: cardRoot, activeRoots: [cardRoot]))
        XCTAssertFalse(tracker.observe(selectedRoot: nil, activeRoots: []))
        XCTAssertTrue(tracker.observe(selectedRoot: cardRoot, activeRoots: [cardRoot]))
    }

    func testVerifiedTransferDuplicatesCollisionsAndSafeErase() async throws {
        let jpeg = cardRoot.appendingPathComponent("DCIM/100MSDCF/DSC00001.JPG")
        let raw = cardRoot.appendingPathComponent("DCIM/100MSDCF/DSC00001.ARW")
        let video = cardRoot.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4")
        let appleDouble = cardRoot.appendingPathComponent("DCIM/100MSDCF/._DSC00001.JPG")
        try write("jpeg-one", to: jpeg)
        try write("raw-one", to: raw)
        try write("video-one", to: video)
        try write("metadata", to: appleDouble)
        try write("camera database", to: cardRoot.appendingPathComponent("INDEX.XML"))

        let ownedPartial = destinationRoot.appendingPathComponent(
            "orphan.JPG.partial-0123456789abcdef0123456789abcdef"
        )
        let unrelatedPartial = destinationRoot.appendingPathComponent("keep.partial-draft")
        try write("stale", to: ownedPartial)
        try write("keep", to: unrelatedPartial)

        let store = try StateStore(rootURL: stateRoot)
        let logger = try AppLogger(stateRoot: stateRoot)
        let transfer = TransferService(stateStore: store, logger: logger)
        let wipe = WipeService(stateStore: store, logger: logger)
        let card = CardInfo(
            rootURL: cardRoot,
            volumeLabel: "TEST CARD",
            volumeID: "test-volume",
            totalBytes: 64 * 1_024 * 1_024,
            freeBytes: 32 * 1_024 * 1_024,
            driveType: "Removable media"
        )

        let first = try await transfer.transfer(
            card: card,
            destinationRoot: destinationRoot,
            groupByDate: false
        )
        XCTAssertEqual(first.session.status, "Verified")
        XCTAssertEqual(first.session.copiedCount, 3)
        XCTAssertEqual(first.session.skippedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationRoot.appendingPathComponent("Photos/JPEGs/DSC00001.JPG").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationRoot.appendingPathComponent("Photos/RAWs/DSC00001.ARW").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationRoot.appendingPathComponent("Videos/C0001.MP4").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedPartial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedPartial.path))

        let duplicate = try await transfer.transfer(
            card: card,
            destinationRoot: destinationRoot,
            groupByDate: false
        )
        XCTAssertEqual(duplicate.session.copiedCount, 0)
        XCTAssertEqual(duplicate.session.skippedCount, 3)

        try write("jpeg-two", to: jpeg)
        let collision = try await transfer.transfer(
            card: card,
            destinationRoot: destinationRoot,
            groupByDate: false
        )
        XCTAssertEqual(collision.session.copiedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationRoot.appendingPathComponent("Photos/JPEGs/DSC00001 (2).JPG").path
        ))

        let unverified = cardRoot.appendingPathComponent("DCIM/100MSDCF/DSC99999.JPG")
        try write("new file", to: unverified)
        do {
            _ = try await wipe.wipe(card: card, session: collision.session)
            XCTFail("Erase should be blocked by media added after transfer")
        } catch let error as MediaShuttleError {
            guard case .eraseBlocked = error else {
                return XCTFail("Unexpected safety error: \(error)")
            }
        }

        let finalTransfer = try await transfer.transfer(
            card: card,
            destinationRoot: destinationRoot,
            groupByDate: false
        )
        let nestedDatabase = cardRoot.appendingPathComponent("PRIVATE/CAMERA_DB/NESTED/INDEX.BDM")
        try write("database", to: nestedDatabase)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: nestedDatabase.path)

        let result = try await wipe.wipe(card: card, session: finalTransfer.session)
        XCTAssertGreaterThanOrEqual(result.deletedFiles, 6)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cardRoot.path), [])
        let latestSession = await store.latestVerifiedSession(for: card)
        XCTAssertNil(latestSession)
    }

    func testEraseEligibilityLocksWhenSourceOrDestinationChanges() async throws {
        let jpeg = cardRoot.appendingPathComponent("DCIM/100MSDCF/DSC00001.JPG")
        try write("jpeg", to: jpeg)
        let database = cardRoot.appendingPathComponent("INDEX.XML")
        try write("camera database", to: database)

        let store = try StateStore(rootURL: stateRoot)
        let logger = try AppLogger(stateRoot: stateRoot)
        let transfer = TransferService(stateStore: store, logger: logger)
        let wipe = WipeService(stateStore: store, logger: logger)
        let card = CardInfo(
            rootURL: cardRoot,
            volumeLabel: "TEST CARD",
            volumeID: "test-volume",
            totalBytes: 64 * 1_024 * 1_024,
            freeBytes: 32 * 1_024 * 1_024,
            driveType: "Removable media"
        )

        let result = try await transfer.transfer(
            card: card,
            destinationRoot: destinationRoot,
            groupByDate: false
        )
        let scanned = try MediaClassifier.scan(cardRoot)
        XCTAssertTrue(result.session.isEligibleForErase(card: card, media: scanned))

        let destination = try XCTUnwrap(result.session.files.first?.destinationURL)
        try FileManager.default.removeItem(at: destination)
        XCTAssertFalse(result.session.isEligibleForErase(card: card, media: scanned))

        try write("jpeg", to: destination)
        XCTAssertTrue(result.session.isEligibleForErase(card: card, media: scanned))

        try FileManager.default.removeItem(at: jpeg)
        XCTAssertFalse(
            result.session.isEligibleForErase(card: card, media: try MediaClassifier.scan(cardRoot))
        )
        do {
            _ = try await wipe.wipe(card: card, session: result.session)
            XCTFail("Erase should be blocked when a transferred source file disappears")
        } catch let error as MediaShuttleError {
            guard case .eraseBlocked = error else {
                return XCTFail("Unexpected safety error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))
    }

    func testTransferRejectsDestinationInsideCard() async throws {
        try write("jpeg", to: cardRoot.appendingPathComponent("DCIM/100MSDCF/DSC00001.JPG"))
        let store = try StateStore(rootURL: stateRoot)
        let logger = try AppLogger(stateRoot: stateRoot)
        let transfer = TransferService(stateStore: store, logger: logger)
        let card = CardInfo(
            rootURL: cardRoot,
            volumeLabel: "TEST CARD",
            volumeID: "test-volume",
            totalBytes: 64 * 1_024 * 1_024,
            freeBytes: 32 * 1_024 * 1_024,
            driveType: "Removable media"
        )
        let unsafeDestination = cardRoot.appendingPathComponent("Backup", isDirectory: true)

        do {
            _ = try await transfer.transfer(
                card: card,
                destinationRoot: unsafeDestination,
                groupByDate: false
            )
            XCTFail("Transfer should reject a destination inside the source card")
        } catch let error as MediaShuttleError {
            XCTAssertEqual(error, .unsafePath)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: unsafeDestination.path))

        let photos = destinationRoot.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: photos.appendingPathComponent("JPEGs", isDirectory: true),
            withDestinationURL: cardRoot.appendingPathComponent("DCIM", isDirectory: true)
        )
        do {
            _ = try await transfer.transfer(
                card: card,
                destinationRoot: destinationRoot,
                groupByDate: false
            )
            XCTFail("Transfer should reject a category folder that resolves outside the destination")
        } catch let error as MediaShuttleError {
            XCTAssertEqual(error, .unsafePath)
        }
    }

    private func write(_ string: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(string.utf8).write(to: url)
    }
}
