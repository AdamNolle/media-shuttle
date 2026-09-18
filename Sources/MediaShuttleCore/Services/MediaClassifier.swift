import Foundation

public enum MediaClassifier {
    private static let rawExtensions: Set<String> = ["arw", "dng"]
    private static let jpegExtensions: Set<String> = ["jpg", "jpeg"]
    private static let otherPhotoExtensions: Set<String> = ["heif", "heic", "hif", "tif", "tiff", "png"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "mxf", "mts", "m2ts", "avi"]

    public static let systemManagedRootNames: Set<String> = [
        ".fseventsd", ".spotlight-v100", ".trashes", ".temporaryitems",
        ".documentrevisions-v100", "$recycle.bin", "system volume information"
    ]

    public static func classify(_ url: URL) -> MediaKind? {
        guard !url.lastPathComponent.hasPrefix("._") else { return nil }
        let fileExtension = url.pathExtension.lowercased()
        if rawExtensions.contains(fileExtension) { return .raw }
        if jpegExtensions.contains(fileExtension) { return .jpeg }
        if otherPhotoExtensions.contains(fileExtension) { return .otherPhoto }
        if videoExtensions.contains(fileExtension) { return .video }
        return nil
    }

    public static func scan(_ rootURL: URL) throws -> [MediaItem] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey
        ]
        var traversalError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, error in
                traversalError = error
                return false
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var items: [MediaItem] = []
        while let url = enumerator.nextObject() as? URL {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(keys))
            } catch {
                throw error
            }

            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            if values.isDirectory == true {
                if systemManagedRootNames.contains(url.lastPathComponent.lowercased()) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values.isRegularFile == true, let kind = classify(url) else { continue }
            items.append(MediaItem(
                sourceURL: url.standardizedFileURL,
                fileName: url.lastPathComponent,
                fileExtension: url.pathExtension.lowercased(),
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? .distantPast,
                kind: kind
            ))
        }

        if let traversalError {
            throw traversalError
        }

        return items.sorted {
            $0.sourceURL.path.localizedCaseInsensitiveCompare($1.sourceURL.path) == .orderedAscending
        }
    }

    public static func destinationFolder(for kind: MediaKind, under root: URL) -> URL {
        kind.destinationComponents.reduce(root) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
    }

    public static func isSystemManagedRootEntry(_ url: URL) -> Bool {
        systemManagedRootNames.contains(url.lastPathComponent.lowercased())
    }
}
