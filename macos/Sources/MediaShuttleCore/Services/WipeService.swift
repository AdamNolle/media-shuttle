import Foundation

public actor WipeService {
    public typealias ProgressHandler = @Sendable (OperationProgress) async -> Void

    private let stateStore: StateStore
    private let logger: AppLogger

    public init(stateStore: StateStore, logger: AppLogger) {
        self.stateStore = stateStore
        self.logger = logger
    }

    public func wipe(
        card: CardInfo,
        session: TransferSession,
        progress: ProgressHandler? = nil
    ) async throws -> WipeResult {
        try validate(card: card, session: session)
        let root = card.rootURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw MediaShuttleError.cardChanged
        }

        let currentMedia = try MediaClassifier.scan(root)
        guard session.isEligibleForErase(card: card, media: currentMedia) else {
            throw MediaShuttleError.eraseBlocked(
                "the card contents or destination copies changed after the verified transfer. Transfer again first."
            )
        }
        let records = Dictionary(uniqueKeysWithValues: session.files.map {
            ($0.sourceURL.standardizedFileURL.path, $0)
        })
        let totalBytes = currentMedia.reduce(Int64(0)) { $0 + $1.size }
        var processedBytes: Int64 = 0
        var verifiedFiles = 0

        await logger.write("Re-verifying all remaining card media before erase")
        for item in currentMedia {
            try Task.checkCancellation()
            guard let record = records[item.sourceURL.standardizedFileURL.path] else {
                throw MediaShuttleError.eraseBlocked(
                    "\(item.fileName) was not part of the verified transfer. Transfer the card again first."
                )
            }
            guard FileManager.default.fileExists(atPath: record.destinationURL.path) else {
                throw MediaShuttleError.eraseBlocked("the destination copy of \(item.fileName) is missing.")
            }
            guard fileSize(at: record.destinationURL) == record.size else {
                throw MediaShuttleError.eraseBlocked("the destination copy of \(item.fileName) changed size.")
            }

            let folder = relativeDestinationFolder(for: record, session: session)
            await progress?(OperationProgress(
                phase: .reVerifying,
                currentItem: item.fileName,
                completedFiles: verifiedFiles,
                totalFiles: currentMedia.count,
                processedBytes: processedBytes,
                totalBytes: totalBytes,
                currentSourceURL: item.sourceURL,
                currentDestinationFolder: folder
            ))

            let sourceHash = try await FileHasher.sha256(at: item.sourceURL)
            let destinationHash = try await FileHasher.sha256(at: record.destinationURL)
            guard sourceHash.caseInsensitiveCompare(record.sha256) == .orderedSame,
                  destinationHash.caseInsensitiveCompare(record.sha256) == .orderedSame else {
                throw MediaShuttleError.eraseBlocked("\(item.fileName) no longer matches its verified copy.")
            }
            verifiedFiles += 1
            processedBytes += item.size
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        let protected = entries.filter(MediaClassifier.isSystemManagedRootEntry)
        let userEntries = entries.filter { !MediaClassifier.isSystemManagedRootEntry($0) }
        var deletedFiles = 0
        var failures: [String] = []

        for (index, entry) in userEntries.enumerated() {
            await progress?(OperationProgress(
                phase: .erasing,
                currentItem: entry.lastPathComponent,
                completedFiles: index,
                totalFiles: max(1, userEntries.count),
                processedBytes: Int64(index),
                totalBytes: Int64(max(1, userEntries.count))
            ))
            do {
                deletedFiles += try deleteEntry(entry, within: root)
            } catch {
                failures.append("\(entry.lastPathComponent): \(error.localizedDescription)")
            }
        }

        let remaining = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ))?.filter { !MediaClassifier.isSystemManagedRootEntry($0) } ?? []
        let remainingMedia = try MediaClassifier.scan(root)
        if !failures.isEmpty || !remaining.isEmpty || !remainingMedia.isEmpty {
            let details = (failures + remaining.map(\.lastPathComponent)).prefix(5).joined(separator: ", ")
            throw MediaShuttleError.eraseBlocked(
                "some card content could not be removed (\(details)). Check the card's write-protect switch and try again."
            )
        }

        var erasedSession = session
        erasedSession.status = "Erased"
        erasedSession.erasedAt = .now
        erasedSession.erasedFileCount = deletedFiles
        _ = try await stateStore.saveSession(erasedSession)
        await logger.write("Card erase complete: \(deletedFiles) files removed")
        await progress?(OperationProgress(
            phase: .complete,
            currentItem: "Card contents erased",
            completedFiles: userEntries.count,
            totalFiles: max(1, userEntries.count),
            processedBytes: Int64(max(1, userEntries.count)),
            totalBytes: Int64(max(1, userEntries.count))
        ))
        return WipeResult(
            deletedFiles: deletedFiles,
            protectedSystemEntries: protected.map(\.lastPathComponent)
        )
    }

    private func validate(card: CardInfo, session: TransferSession) throws {
        guard session.status.caseInsensitiveCompare("Verified") == .orderedSame else {
            throw MediaShuttleError.eraseLocked
        }
        guard session.sourceRoot.standardizedFileURL.path == card.rootURL.standardizedFileURL.path,
              session.sourceVolumeID == card.volumeID else {
            throw MediaShuttleError.cardChanged
        }
    }

    private func deleteEntry(_ url: URL, within root: URL) throws -> Int {
        try Task.checkCancellation()
        try ensureSafeChild(url, root: root)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true || values.isDirectory != true {
            try removeWithRetry(url)
            return 1
        }

        var count = 0
        for child in try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) {
            try Task.checkCancellation()
            count += try deleteEntry(child, within: root)
        }
        try removeWithRetry(url)
        return count
    }

    private func removeWithRetry(_ url: URL) throws {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: url.path
                )
                try FileManager.default.removeItem(at: url)
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.1 * Double(attempt))
            }
        }
        throw lastError ?? CocoaError(.fileWriteUnknown)
    }

    private func ensureSafeChild(_ candidate: URL, root: URL) throws {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path
            : root.standardizedFileURL.path + "/"
        guard candidate.standardizedFileURL.path.hasPrefix(rootPath) else {
            throw MediaShuttleError.unsafePath
        }
    }

    private func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    }

    private func relativeDestinationFolder(for record: TransferRecord, session: TransferSession) -> String {
        let root = session.destinationRoot.standardizedFileURL.path.hasSuffix("/")
            ? session.destinationRoot.standardizedFileURL.path
            : session.destinationRoot.standardizedFileURL.path + "/"
        let directory = record.destinationURL.deletingLastPathComponent().standardizedFileURL.path
        return directory.hasPrefix(root) ? String(directory.dropFirst(root.count)) : directory
    }
}
