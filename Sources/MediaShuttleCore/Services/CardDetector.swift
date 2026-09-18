import Foundation

public enum CardDetector {
    private static let cameraFolders = ["DCIM", "M4ROOT", "PRIVATE"]

    public static func candidates(destinationRoot: URL) -> [CardInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeUUIDStringKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeIsRemovableKey, .volumeIsInternalKey
        ]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return volumes.compactMap { volume in
            let root = volume.standardizedFileURL
            guard root.path != "/", !contains(destinationRoot.standardizedFileURL, in: root) else { return nil }
            guard cameraFolders.contains(where: {
                FileManager.default.fileExists(atPath: root.appendingPathComponent($0, isDirectory: true).path)
            }) else { return nil }

            guard let values = try? root.resourceValues(forKeys: Set(keys)) else { return nil }
            let identifier = values.volumeUUIDString ?? root.path
            let label = values.volumeName.flatMap { $0.isEmpty ? nil : $0 } ?? "CAMERA MEDIA"
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let free = Int64(values.volumeAvailableCapacity ?? 0)
            let type: String
            if values.volumeIsRemovable == true {
                type = "Removable media"
            } else if values.volumeIsInternal == true {
                type = "Mounted volume"
            } else {
                type = "External media"
            }
            return CardInfo(
                rootURL: root,
                volumeLabel: label,
                volumeID: identifier,
                totalBytes: total,
                freeBytes: free,
                driveType: type
            )
        }
        .sorted { $0.volumeLabel.localizedCaseInsensitiveCompare($1.volumeLabel) == .orderedAscending }
    }

    private static func contains(_ child: URL, in parent: URL) -> Bool {
        let parentPath = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        return child.path == parent.path || child.path.hasPrefix(parentPath)
    }
}

public struct CardPresenceTracker: Sendable {
    private var seenRoots: Set<String> = []
    private var baselineEstablished = false

    public init() {}

    public mutating func observe(selectedRoot: URL?, activeRoots: [URL]) -> Bool {
        let active = Set(activeRoots.map { $0.standardizedFileURL.path })
        defer {
            seenRoots.formIntersection(active)
            seenRoots.formUnion(active)
            baselineEstablished = true
        }
        guard baselineEstablished, let selectedRoot else { return false }
        return !seenRoots.contains(selectedRoot.standardizedFileURL.path)
    }
}
