import Foundation

public enum MediaClassifier {
    // Anything a camera can write has to appear in one of these four sets. A format missing here is
    // not merely unsupported: the file is never copied, yet erase would still delete it. Erase is
    // guarded separately by isDisposableCameraArtifact, so the two lists must be read together.
    private static let rawExtensions: Set<String> = [
        "arw", "sr2", "srf",
        "dng", "raw",
        "cr2", "cr3", "crw",
        "nef", "nrw",
        "raf",
        "orf",
        "rw2", "rwl",
        "pef", "ptx",
        "srw",
        "x3f",
        "3fr", "fff",
        "iiq", "cap", "eip",
        "mef", "mos",
        "mrw",
        "erf",
        "dcr", "kdc", "k25",
        "gpr",
        "ari"
    ]

    private static let jpegExtensions: Set<String> = ["jpg", "jpeg", "jpe"]

    private static let otherPhotoExtensions: Set<String> = [
        "heif", "heic", "hif", "avif", "jxl",
        "tif", "tiff",
        "png", "bmp", "gif", "webp",
        "jp2", "j2k",
        "psd"
    ]

    private static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov",
        "mxf", "braw", "r3d",
        "mts", "m2ts", "m2t", "ts", "mod", "tod",
        "avi", "mkv", "webm",
        "wmv", "asf",
        "mpg", "mpeg", "m2v", "vob",
        "3gp", "3g2",
        "insv", "lrv",
        "dv"
    ]

    // Housekeeping a camera or an operating system writes for itself. Erase may remove these
    // without a verified destination copy; everything else on the card blocks erase instead.
    // Generic text, binary, database and settings extensions do not establish camera ownership.
    // They must block erase even when they are stored inside a camera directory.
    private static let disposableExtensions: Set<String> = [
        "thm", "ctg", "cpi", "mpl", "bdm", "bdmv", "clpi", "mpls",
        "inp", "ind", "int", "tdt", "tid", "modd", "moff", "bnp", "pmp",
        "xml", "xmp",
        "sec", "info", "mdt", "osd", "mtd", "pck", "fpr", "set", "sav",
        "idx", "map", "tmp", "bup", "ifo"
    ]

    private static let disposableFileNames: Set<String> = [
        ".ds_store", "thumbs.db", "desktop.ini", "icon\r", "autorun.inf"
    ]

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
        try scanCard(rootURL).media
    }

    /// Files on the card that are neither recognised camera media nor camera/OS housekeeping. These
    /// are never copied by a transfer, so erase has no verified copy to check them against and must
    /// refuse rather than delete them.
    public static func unverifiableFiles(at rootURL: URL) throws -> [URL] {
        try scanCard(rootURL).unverifiableFiles
    }

    public static func isDisposableCameraArtifact(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix("._") || disposableFileNames.contains(name.lowercased()) {
            return true
        }
        return disposableExtensions.contains(url.pathExtension.lowercased())
    }

    /// Walks the card once and splits what it finds into media to copy and content erase must never
    /// delete. Callers that need both should use this rather than two separate walks — a full card
    /// is tens of thousands of entries and the UI rescans every couple of seconds.
    public static func scanCard(_ rootURL: URL) throws -> CardScan {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey
        ]
        var traversalError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, error in
                traversalError = error
                return false
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var items: [MediaItem] = []
        var unverifiable: [URL] = []
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
                if url.deletingLastPathComponent().standardizedFileURL == rootURL.standardizedFileURL,
                   isSystemManagedRootEntry(url) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values.isRegularFile == true else { continue }
            guard let kind = classify(url) else {
                if !isDisposableCameraArtifact(url) {
                    unverifiable.append(url.standardizedFileURL)
                }
                continue
            }
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

        return CardScan(
            media: items.sorted {
                $0.sourceURL.path.localizedCaseInsensitiveCompare($1.sourceURL.path) == .orderedAscending
            },
            unverifiableFiles: unverifiable.sorted {
                $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
            }
        )
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
