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
    var heroTitle = "Ready for your next card."
    var heroSubtitle = "JPEGs, RAWs, and video are sorted automatically. " +
        "Every file is SHA-256 verified before erase is available."
    var primaryActionTitle = "Scan for media"
    var operationStartedAt: Date?
    var isStarted = false
    var startupEnabled = SMAppService.mainApp.status == .enabled

    @ObservationIgnored private let stateStore: StateStore
    @ObservationIgnored private let logger: AppLogger
    @ObservationIgnored private let transferService: TransferService
    @ObservationIgnored private let wipeService: WipeService
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var presenceTracker = CardPresenceTracker()

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

    var canWipe: Bool {
        !isBusy && currentCard != nil && verifiedSession?.files.isEmpty == false
    }

    var mediaCounts: [MediaKind: Int] {
        Dictionary(grouping: media, by: \.kind).mapValues(\.count)
    }

    var totalMediaBytes: Int64 {
        media.reduce(Int64(0)) { $0 + $1.size }
    }

    var elapsed: TimeInterval {
        guard let operationStartedAt else { return 0 }
        return Date.now.timeIntervalSince(operationStartedAt)
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
                verifiedSession = nil
                reportURL = nil
                updateDisconnectedState()
            }
            return
        }

        let previousCardID = currentCard?.id
        let scanned: [MediaItem]
        do {
            scanned = try await Task.detached(priority: .utility) {
                try MediaClassifier.scan(card.rootURL)
            }.value
        } catch {
            showError("Card scan failed", error.localizedDescription)
            return
        }
        let storedSession = await stateStore.latestVerifiedSession(for: card)
        let session = storedSession.flatMap {
            $0.isEligibleForErase(card: card, media: scanned) ? $0 : nil
        }
        let sessionWasInvalidated = verifiedSession != nil && session == nil
        currentCard = card
        media = scanned
        verifiedSession = session
        if let session {
            reportURL = await stateStore.sessionFileURL(for: session)
        } else {
            reportURL = nil
        }
        if session != nil {
            updateVerifiedState(justCompleted: false)
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
        banner = nil
        heroTitle = "Copying and verifying your media."
        heroSubtitle = "Each file is written safely, checked with SHA-256, then made visible at the destination."
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
                updateVerifiedState(justCompleted: true)
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
                heroTitle = "Transfer cancelled."
                heroSubtitle = "No partial file was left behind. You can safely start again."
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
                heroTitle = "Transfer needs attention."
                heroSubtitle = "The card was not erased and any incomplete copy was removed."
                addActivity("Transfer stopped: \(error.localizedDescription)")
                await logger.write("Transfer failed: \(error.localizedDescription)")
            }
            isBusy = false
            operationTask = nil
            if verifiedSession == nil { primaryActionTitle = "Transfer and verify" }
        }
    }

    func cancelTransfer() {
        operationTask?.cancel()
    }

    func wipeCard() {
        guard operationTask == nil, let card = currentCard, let session = verifiedSession else { return }
        isBusy = true
        operationStartedAt = .now
        banner = nil
        heroTitle = "Re-verifying before erase."
        heroSubtitle = "Deletion starts only after every remaining media file matches its destination copy."
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
                heroTitle = "Card contents erased."
                heroSubtitle = "The post-erase scan found no remaining media or user content. " +
                    "The card is ready for your camera."
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
                heroTitle = "Nothing was erased."
                heroSubtitle = "The safety check stopped before completion. " +
                    "Review the message and transfer again if needed."
                topStatus = "ERASE BLOCKED"
                statusTone = .error
                addActivity("Erase blocked: \(error.localizedDescription)")
                await logger.write("Erase blocked: \(error.localizedDescription)")
            }
            isBusy = false
            operationTask = nil
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

    private func prepareDestination() {
        do {
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            for kind in MediaKind.allCases {
                try FileManager.default.createDirectory(
                    at: MediaClassifier.destinationFolder(for: kind, under: destinationURL),
                    withIntermediateDirectories: true
                )
            }
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
        heroTitle = "Ready for your next card."
        heroSubtitle = "JPEGs, RAWs, and video are sorted automatically. " +
            "Every file is SHA-256 verified before erase is available."
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
        heroTitle = "Media ready to transfer."
        heroSubtitle = "\(media.count) supported files will be sorted and independently verified at the destination."
        primaryActionTitle = "Transfer and verify"
    }

    private func updateVerifiedState(justCompleted: Bool) {
        guard let session = verifiedSession else { return }
        topStatus = "\(currentCard?.volumeLabel.uppercased() ?? "CARD") · TRANSFER VERIFIED"
        statusTone = .verified
        heroTitle = justCompleted ? "Every original. Safely home." : "Transfer still verified."
        heroSubtitle = justCompleted
            ? "\(session.totalFiles) photos and videos match their destination copies, byte for byte. " +
                "This card is safe to erase."
            : "\(session.totalFiles) media files still match the verified inventory. " +
                "You can transfer again or erase the card."
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
        heroTitle = "No supported media found."
        heroSubtitle = "The connected card has no supported photos or videos."
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
        guard settings.showNotifications else { return }
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
