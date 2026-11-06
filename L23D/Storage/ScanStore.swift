import Foundation

/// File layout for one scan:
/// ```
/// Scans/<uuid>/
///   Images/        photos taken during capture
///   Checkpoint/    photogrammetry checkpoint (lets a failed build resume)
///   Model/model.usdz
///   thumbnail.jpg
///   Exports/       GLB / OBJ / USDZ files made for sharing
/// ```
struct ScanFolder: Sendable, Hashable {
    let root: URL

    var images: URL { root.appending(path: "Images", directoryHint: .isDirectory) }
    var checkpoint: URL { root.appending(path: "Checkpoint", directoryHint: .isDirectory) }
    var modelDirectory: URL { root.appending(path: "Model", directoryHint: .isDirectory) }
    var modelFile: URL { modelDirectory.appending(path: "model.usdz") }
    var thumbnail: URL { root.appending(path: "thumbnail.jpg") }
    var exports: URL { root.appending(path: "Exports", directoryHint: .isDirectory) }

    var hasModel: Bool { FileManager.default.fileExists(atPath: modelFile.path(percentEncoded: false)) }
    var hasThumbnail: Bool { FileManager.default.fileExists(atPath: thumbnail.path(percentEncoded: false)) }

    /// Number of photos saved in `Images/`.
    var imageCount: Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: images, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["heic", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }.count
    }

    /// Creates every sub-folder. Safe to call more than once.
    func create() throws {
        let fm = FileManager.default
        for dir in [root, images, checkpoint, modelDirectory, exports] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Empties `Images/` and `Checkpoint/` so a new capture can start
    /// (Object Capture refuses a folder that already has files in it).
    func resetCapture() throws {
        let fm = FileManager.default
        for dir in [images, checkpoint] {
            if fm.fileExists(atPath: dir.path(percentEncoded: false)) {
                try fm.removeItem(at: dir)
            }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Total bytes on disk for this scan.
    var diskUsage: Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}

enum ScanStore {
    /// `Application Support/Scans`, excluded from iCloud backup (scans are large).
    static let baseURL: URL = {
        let support = URL.applicationSupportDirectory
        var url = support.appending(path: "Scans", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    static func folder(for id: UUID, base: URL = baseURL) -> ScanFolder {
        ScanFolder(root: base.appending(path: id.uuidString, directoryHint: .isDirectory))
    }

    /// Deletes everything on disk for a scan.
    static func deleteFiles(for id: UUID, base: URL = baseURL) {
        try? FileManager.default.removeItem(at: folder(for: id, base: base).root)
    }
}
