import CryptoKit
import Foundation

public enum FileHasher {
    private static let bufferSize = 1_048_576

    public static func sha256(at url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: bufferSize) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02X", $0) }.joined()
    }
}
