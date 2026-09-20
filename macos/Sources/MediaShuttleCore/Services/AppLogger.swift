import Foundation

public actor AppLogger {
    // A transfer logs a line per file, and the app is meant to sit in the menu bar for months, so
    // the log has to be bounded. One rollover keeps the previous run's history available for
    // diagnosing a transfer without letting the folder grow without end.
    private static let maximumBytes: Int64 = 2 * 1024 * 1024

    // Fixed at init and never reassigned, so they are readable without hopping onto the actor.
    public nonisolated let logURL: URL
    public nonisolated let previousLogURL: URL

    public init(stateRoot: URL) throws {
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        logURL = stateRoot.appendingPathComponent("app.log")
        previousLogURL = stateRoot.appendingPathComponent("app.previous.log")
    }

    /// `date` is the moment the event happened rather than the moment this line reaches the file.
    /// Callers hand off logging without awaiting it, so two events can arrive here out of order;
    /// stamping at the call site keeps the times in the file true to the events they describe.
    public func write(_ message: String, at date: Date = .now) {
        rollOverIfOversized()
        let line = "\(date.ISO8601Format())  \(message)\n"
        let data = Data(line.utf8)
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                return
            }
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    private func rollOverIfOversized() {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: logURL.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size >= Self.maximumBytes else { return }
        // Logging must never take down the operation it is describing, so a rollover that cannot
        // happen is dropped rather than raised: the next write simply appends to the oversized log.
        try? manager.removeItem(at: previousLogURL)
        try? manager.moveItem(at: logURL, to: previousLogURL)
    }
}
