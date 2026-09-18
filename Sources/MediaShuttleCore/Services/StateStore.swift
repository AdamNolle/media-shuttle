import Foundation

public actor StateStore {
    public let rootURL: URL
    public let sessionsURL: URL
    public let settingsURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootURL: URL) throws {
        self.rootURL = rootURL
        sessionsURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
        settingsURL = rootURL.appendingPathComponent("settings.json")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
    }

    public static func defaultRootURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("Media Shuttle", isDirectory: true)
    }

    public func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? decoder.decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    public func saveSettings(_ settings: AppSettings) throws {
        let data = try encoder.encode(settings)
        try data.write(to: settingsURL, options: .atomic)
    }

    public func sessionFileURL(for session: TransferSession) -> URL {
        let stamp = Int(session.startedAt.timeIntervalSince1970)
        let prefix = String(session.sessionID.prefix(6))
        return sessionsURL.appendingPathComponent("\(stamp)-\(prefix).json")
    }

    @discardableResult
    public func saveSession(_ session: TransferSession) throws -> URL {
        let url = sessionFileURL(for: session)
        let data = try encoder.encode(session)
        try data.write(to: url, options: .atomic)
        return url
    }

    public func latestVerifiedSession(for card: CardInfo) -> TransferSession? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: sessionsURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        let sorted = files
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                return left > right
            }

        for file in sorted {
            guard let data = try? Data(contentsOf: file),
                  let session = try? decoder.decode(TransferSession.self, from: data),
                  Self.sameRoot(session.sourceRoot, card.rootURL),
                  session.sourceVolumeID == card.volumeID else {
                continue
            }
            return session.status.caseInsensitiveCompare("Verified") == .orderedSame && !session.files.isEmpty
                ? session
                : nil
        }
        return nil
    }

    private static func sameRoot(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }
}
