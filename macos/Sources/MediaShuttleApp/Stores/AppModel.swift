import AppKit
import Foundation
import MediaShuttleCore
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications

enum AppStatusTone: Sendable {
    case neutral
    case active
    case verified
    case warning
    case error
}

enum BannerTone: Sendable {
    case info
    case success
    case warning
    case error
}

struct BannerMessage: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let message: String
    let tone: BannerTone
}

struct ActivityEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let message: String
}

@MainActor
@Observable
final class AppModel {
    var settings = AppSettings()
    var destinationURL: URL
    var currentCard: CardInfo?
    var media: [MediaItem] = []
    var unverifiableFileCount = 0
    var verifiedSession: TransferSession?
    var reportURL: URL?
    var progress = OperationProgress(
        phase: .idle,
        currentItem: "Waiting for camera media",
        completedFiles: 0,
        totalFiles: 0,
        processedBytes: 0,
        totalBytes: 0
    )
    var activities: [ActivityEntry] = []
    var banner: BannerMessage?
    var isBusy = false
    var isDestinationAvailable = true
    var topStatus = "WAITING FOR MEDIA"
    var statusTone: AppStatusTone = .neutral
    var primaryActionTitle = "Scan for media"
    var operationStartedAt: Date?
    var operationEndedAt: Date?
    var isStarted = false
    var startupEnabled = SMAppService.mainApp.status == .enabled

    @ObservationIgnored private let stateStore: StateStore
    @ObservationIgnored private let logger: AppLogger
    @ObservationIgnored private let transferService: TransferService
    @ObservationIgnored private let wipeService: WipeService
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var presenceTracker = CardPresenceTracker()
    @ObservationIgnored private var lastScanSignature: String?

    init() {
        let applicationSupport = (try? StateStore.defaultRootURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Media Shuttle", isDirectory: true)
        do {
            let store = try StateStore(rootURL: applicationSupport)
            let appLogger = try AppLogger(stateRoot: applicationSupport)
            stateStore = store
            logger = appLogger
            transferService = TransferService(stateStore: store, logger: appLogger)
            wipeService = WipeService(stateStore: store, logger: appLogger)
        } catch {
            fatalError("Media Shuttle could not create its local state directory: \(error.localizedDescription)")
        }
        destinationURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent("Camera", isDirectory: true)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--screenshot") {
            configureScreenshotState()
        }
        #endif
    }

    deinit {
        scanTask?.cancel()
        operationTask?.cancel()
    }

    var appearance: ColorScheme? {
        switch settings.appearance {
        case "Light": .light
        case "Dark": .dark
        default: nil
        }
    }

    var canTransfer: Bool {
        !isBusy && isDestinationAvailable && currentCard != nil && !media.isEmpty
    }

    /// WipeService refuses a card holding content no transfer could have copied. Reflected here so
    /// erase reads as locked, rather than accepting the typed confirmation and only then refusing.
    var canWipe: Bool {
        !isBusy && currentCard != nil && verifiedSession?.files.isEmpty == false && unverifiableFileCount == 0
    }

    var mediaCounts: [MediaKind: Int] {
        Dictionary(grouping: media, by: \.kind).mapValues(\.count)
    }

    var totalMediaBytes: Int64 {
        media.reduce(Int64(0)) { $0 + $1.size }
    }

    /// Measured to the moment the operation finished, so the elapsed time and
    /// the throughput derived from it stop moving once a transfer is done.
    var elapsed: TimeInterval {
        guard let operationStartedAt else { return 0 }
        return (operationEndedAt ?? .now).timeIntervalSince(operationStartedAt)
    }

    var throughputBytesPerSecond: Double? {
        let elapsed = elapsed
        guard elapsed > 0, progress.processedBytes > 0 else { return nil }
        return Double(progress.processedBytes) / elapsed
    }

    func start() async {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--screenshot") {
            return
        }
#endif
        guard !isStarted else { return }
        isStarted = true
        settings = await stateStore.loadSettings()
        if !settings.destinationPath.isEmpty {
            destinationURL = URL(fileURLWithPath: settings.destinationPath, isDirectory: true).standardizedFileURL
        }
        prepareDestination()
        addActivity("Watcher ready. Mounted-volume identity checks active.")
        await scanCards()

        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await self?.scanCards()
            }
        }
    }

    func scanNow() {
        Task { await scanCards(forceUpdate: true) }
    }

    func scanCards(forceUpdate: Bool = false) async {
        guard !isBusy else { return }
        let destination = destinationURL
        let cards = await Task.detached(priority: .utility) {
            CardDetector.candidates(destinationRoot: destination)
        }.value
        let selected = cards.first
        let isNew = presenceTracker.observe(
            selectedRoot: selected?.rootURL,
            activeRoots: cards.map(\.rootURL)
        )

        guard let card = selected else {
            if currentCard != nil || forceUpdate {
                currentCard = nil
                media = []
                unverifiableFileCount = 0
                lastScanSignature = nil
                verifiedSession = nil
                reportURL = nil
                updateDisconnectedState()
            }
            return
        }

        let previousCardID = currentCard?.id

        // This runs every two seconds for as long as a card stays connected. Walking the whole card
        // and re-reading every session report each time is minutes of pointless reader and disk
        // traffic on a full card, so skip it while the card looks untouched. Adding or removing
        // anything on a camera card moves the free-space figure, which is read fresh above.
        let signature = "\(card.rootURL.path)|\(card.volumeID)|\(card.freeBytes)"
        if !forceUpdate, !isNew, previousCardID == card.id, signature == lastScanSignature {
            return
        }
        lastScanSignature = signature

        let scan: CardScan
        do {
            scan = try await Task.detached(priority: .utility) {
                try MediaClassifier.scanCard(card.rootURL)
            }.value
        } catch {
            showError("Card scan failed", error.localizedDescription)
            return
        }
        let scanned = scan.media
        let storedSession = await stateStore.latestVerifiedSession(for: card)
        let session = storedSession.flatMap {
            $0.isEligibleForErase(card: card, media: scanned) ? $0 : nil
        }
        let sessionWasInvalidated = verifiedSession != nil && session == nil
        currentCard = card
        media = scanned
        unverifiableFileCount = scan.unverifiableFiles.count
        verifiedSession = session
        if let session {
            reportURL = await stateStore.sessionFileURL(for: session)
        } else {
            reportURL = nil
        }
        if session != nil {
            updateVerifiedState()
        } else if scanned.isEmpty {
            updateEmptyCardState()
        } else {
            updateDetectedState()
        }
        if sessionWasInvalidated {
            addActivity(
                "Card contents or destination copies changed. " +
                "Erase locked until the next verified transfer."
            )
        }

        if isNew || (forceUpdate && previousCardID != card.id) {
            addActivity("Detected \(card.volumeLabel) at \(card.rootURL.path)")
            if unverifiableFileCount > 0 {
                addActivity(
                    "\(unverifiableFileCount) unrecognised file(s) on this card cannot be verified — "
                    + "erase stays locked."
                )
            }
            if isNew, settings.autoTransfer, isDestinationAvailable, !scanned.isEmpty {
                startTransfer()
            }
        }
    }

    func startTransfer() {
        guard operationTask == nil else { return }
        guard isDestinationAvailable else {
            showError("Choose a destination", "Select an available destination folder before transferring.")
            return
        }
        guard let card = currentCard else {
            banner = BannerMessage(
                title: "No camera card found",
                message: "Connect a card containing DCIM, M4ROOT, or PRIVATE folders.",
                tone: .info
            )
            return
        }
        guard !media.isEmpty else {
            banner = BannerMessage(
                title: "No supported media found",
                message: "This card does not currently contain supported photos or videos.",
                tone: .info
            )
            return
        }

        isBusy = true
        operationStartedAt = .now
        operationEndedAt = nil
        banner = nil
        topStatus = "TRANSFER ACTIVE"
        statusTone = .active
        primaryActionTitle = "Transferring…"
        addActivity("Transfer started from \(card.rootURL.path)")
        let destination = destinationURL
        let groupByDate = settings.groupByDate

        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await transferService.transfer(
                    card: card,
                    destinationRoot: destination,
                    groupByDate: groupByDate,
                    progress: { [weak self] update in
                        await self?.apply(update)
                    }
                )
                verifiedSession = result.session
                reportURL = result.sessionFileURL
                updateVerifiedState()
                addActivity(
                    "Verified \(result.session.totalFiles) files — \(result.session.copiedCount) copied, " +
                    "\(result.session.skippedCount) already safe."
                )
                banner = BannerMessage(
                    title: "Transfer verified",
                    message: "\(result.session.totalFiles) files are safe at the destination and match by SHA-256.",
                    tone: .success
                )
                await sendNotification(
                    title: "Transfer verified",
                    body: "\(result.session.totalFiles) files match their destination copies."
                )
            } catch is CancellationError {
                progress = OperationProgress(
                    phase: .cancelled,
                    currentItem: "Transfer cancelled",
                    completedFiles: progress.completedFiles,
                    totalFiles: progress.totalFiles,
                    processedBytes: progress.processedBytes,
                    totalBytes: progress.totalBytes
                )
                topStatus = "TRANSFER CANCELLED"
                statusTone = .warning
                addActivity("Transfer cancelled.")
            } catch {
                progress = OperationProgress(
                    phase: .error,
                    currentItem: error.localizedDescription,
                    completedFiles: progress.completedFiles,
                    totalFiles: progress.totalFiles,
                    processedBytes: progress.processedBytes,
                    totalBytes: progress.totalBytes
                )
                showError("Transfer stopped", error.localizedDescription)
                topStatus = "NEEDS ATTENTION"
                statusTone = .error
                addActivity("Transfer stopped: \(error.localizedDescription)")
                await logger.write("Transfer failed: \(error.localizedDescription)")
            }
            operationEndedAt = .now
            isBusy = false
            operationTask = nil

            // Reading the card does not move its free space, so let the next tick re-derive state
            // rather than have the skip-unchanged check hold on to what was true before this ran.
            lastScanSignature = nil
            if verifiedSession == nil { primaryActionTitle = "Transfer and verify" }
        }
    }

    func cancelTransfer() {
        operationTask?.cancel()
    }

    /// The card and verified session the erase confirmation was opened against. The two-second scan
    /// keeps running while that sheet waits for input and can reassign both, so what is erased has
    /// to be checked against what was confirmed rather than against whatever is current on return.
    struct EraseTarget: Equatable, Sendable {
        let cardID: String
        let sessionID: String
    }

    var currentEraseTarget: EraseTarget? {
        guard canWipe, let card = currentCard, let session = verifiedSession else { return nil }
        return EraseTarget(cardID: card.id, sessionID: session.sessionID)
    }

    func wipeCard(expecting expected: EraseTarget) {
        guard operationTask == nil else {
            showError(
                "Operation in progress",
                "A transfer started while the confirmation was open. Wait for it to finish, then erase the card."
            )
            addActivity("Erase cancelled: a transfer started during confirmation.")
            return
        }
        guard let card = currentCard,
              let session = verifiedSession,
              card.id == expected.cardID,
              session.sessionID == expected.sessionID else {
            showError(
                "Card changed",
                "The connected card changed while the confirmation was open. Reconnect it and try erasing again."
            )
            addActivity("Erase cancelled: the connected card changed during confirmation.")
            return
        }

        isBusy = true
        operationStartedAt = .now
        operationEndedAt = nil
        banner = nil
        topStatus = "ERASE ACTIVE"
        statusTone = .active
        addActivity("Erase approved. Re-verifying card media before deletion.")

        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await wipeService.wipe(
                    card: card,
                    session: session,
                    progress: { [weak self] update in
                        await self?.apply(update)
                    }
                )
                verifiedSession = nil
                reportURL = nil
                media = []
                primaryActionTitle = "No media found"
                topStatus = "CARD EMPTY"
                statusTone = .verified
                addActivity("Erase complete. \(result.deletedFiles) files removed; post-erase scan empty.")
                banner = BannerMessage(
                    title: "Card contents erased",
                    message: "\(result.deletedFiles) files were removed successfully.",
                    tone: .success
                )
                await sendNotification(
                    title: "Card contents erased",
                    body: "\(result.deletedFiles) files removed successfully."
                )
            } catch {
                showError("Erase blocked", error.localizedDescription)
                topStatus = "ERASE BLOCKED"
                statusTone = .error
                addActivity("Erase blocked: \(error.localizedDescription)")
                await logger.write("Erase blocked: \(error.localizedDescription)")
            }
            operationEndedAt = .now
            isBusy = false
            operationTask = nil
            lastScanSignature = nil
        }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "Choose Media Destination"
        panel.message = "Photos and videos will be sorted into folders inside this location."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destinationURL
        guard panel.runModal() == .OK, let selected = panel.url else { return }

        let selectedURL = selected.standardizedFileURL
        if let card = currentCard,
           Self.isSameOrChild(
               selectedURL.resolvingSymlinksInPath(),
               of: card.rootURL.resolvingSymlinksInPath()
           ) {
            showError("Unsafe destination", "Choose a folder that is not on the connected camera card.")
            return
        }
        destinationURL = selectedURL
        prepareDestination()
        settings.destinationPath = selectedURL.path
        saveSettings()
        addActivity("Destination changed to \(selectedURL.path)")
        Task { await scanCards(forceUpdate: true) }
    }

    func openDestination() {
        NSWorkspace.shared.open(destinationURL)
    }

    func openReport() {
        guard let reportURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([reportURL])
    }

    func saveSettings() {
        let snapshot = settings
        Task {
            do {
                try await stateStore.saveSettings(snapshot)
            } catch {
                showError("Settings could not be saved", error.localizedDescription)
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            startupEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            startupEnabled = SMAppService.mainApp.status == .enabled
            showError(
                "Launch at Login could not be changed",
                "macOS may require the app to be moved to Applications before enabling this setting. " +
                    error.localizedDescription
            )
        }
    }

    func dismissBanner() {
        banner = nil
    }

    /// The root only, which is what proves the destination is reachable and writable. The category
    /// folders belong to a transfer, which creates the ones it has files for — scaffolding all four
    /// here left empty Photos/Other and Videos folders in a destination nothing had been copied to.
    private func prepareDestination() {
        do {
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            isDestinationAvailable = true
            settings.destinationPath = destinationURL.path
            Task { try? await stateStore.saveSettings(settings) }
        } catch {
            isDestinationAvailable = false
            showError(
                "Destination unavailable",
                "The saved destination could not be opened. Choose an available folder before transferring."
            )
            topStatus = "CHOOSE A DESTINATION"
            statusTone = .error
        }
    }

    private func apply(_ update: OperationProgress) {
        progress = update
    }

    private func updateDisconnectedState() {
        topStatus = "WAITING FOR MEDIA"
        statusTone = .neutral
        primaryActionTitle = "Scan for media"
        progress = OperationProgress(
            phase: .idle,
            currentItem: "Waiting for camera media",
            completedFiles: 0,
            totalFiles: 0,
            processedBytes: 0,
            totalBytes: 0
        )
    }

    private func updateDetectedState() {
        topStatus = "\(currentCard?.volumeLabel.uppercased() ?? "MEDIA") CONNECTED"
        statusTone = .active
        primaryActionTitle = "Transfer and verify"
    }

    private func updateVerifiedState() {
        guard let session = verifiedSession else { return }
        topStatus = "\(currentCard?.volumeLabel.uppercased() ?? "CARD") · TRANSFER VERIFIED"
        statusTone = .verified
        primaryActionTitle = "Transfer again"
        progress = OperationProgress(
            phase: .complete,
            currentItem: "Verified report ready",
            completedFiles: session.totalFiles,
            totalFiles: session.totalFiles,
            processedBytes: session.totalBytes,
            totalBytes: session.totalBytes,
            copiedFiles: session.copiedCount,
            skippedFiles: session.skippedCount
        )
    }

    private func updateEmptyCardState() {
        topStatus = "CARD EMPTY"
        statusTone = .verified
        primaryActionTitle = "No media found"
    }

    private func showError(_ title: String, _ message: String) {
        banner = BannerMessage(title: title, message: message, tone: .error)
    }

    private func addActivity(_ message: String) {
        activities.insert(ActivityEntry(date: .now, message: message), at: 0)
        if activities.count > 100 {
            activities.removeLast(activities.count - 100)
        }
    }

    private func sendNotification(title: String, body: String) async {
        guard settings.showNotifications, Bundle.isPackagedApp else { return }
        let center = UNUserNotificationCenter.current()
        let allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard allowed else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try? await center.add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        ))
    }

    private static func isSameOrChild(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path
            : root.standardizedFileURL.path + "/"
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == root.standardizedFileURL.path || candidatePath.hasPrefix(rootPath)
    }
}
