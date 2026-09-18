import Foundation

public actor AppLogger {
    public let logURL: URL

    public init(stateRoot: URL) throws {
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        logURL = stateRoot.appendingPathComponent("app.log")
    }

    public func write(_ message: String) {
        let line = "\(Date.now.ISO8601Format())  \(message)\n"
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
}
