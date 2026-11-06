import Foundation
import SwiftData

/// One scan in the library. Big files (photos, model) live on disk in `ScanStore`;
/// this record only holds the small facts the UI needs.
@Model
final class Scan {
    @Attribute(.unique) var id: UUID
    var name: String
    var modeRaw: String
    var statusRaw: String
    var createdAt: Date
    var imageCount: Int
    var triangleCount: Int?
    /// Real-world size of the model in meters (width, height, depth).
    var sizeX: Double?
    var sizeY: Double?
    var sizeZ: Double?
    var failureMessage: String?
    /// Set when a high-detail model from the Mac is in use (HQDetail raw value).
    var hqDetailRaw: String?

    init(name: String, mode: ScanMode, id: UUID = UUID(), createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.modeRaw = mode.rawValue
        self.statusRaw = ScanStatus.capturing.rawValue
        self.createdAt = createdAt
        self.imageCount = 0
    }

    var mode: ScanMode {
        get { ScanMode(rawValue: modeRaw) ?? .object }
        set { modeRaw = newValue.rawValue }
    }

    var status: ScanStatus {
        get { ScanStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    var folder: ScanFolder { ScanStore.folder(for: id) }

    var hqDetail: HQDetail? {
        get { hqDetailRaw.flatMap(HQDetail.init(rawValue:)) }
        set { hqDetailRaw = newValue?.rawValue }
    }

    /// Size in meters, if known.
    var size: SIMD3<Double>? {
        get {
            guard let sizeX, let sizeY, let sizeZ else { return nil }
            return SIMD3(sizeX, sizeY, sizeZ)
        }
        set {
            sizeX = newValue?.x
            sizeY = newValue?.y
            sizeZ = newValue?.z
        }
    }

    static func defaultName(for mode: ScanMode, date: Date = .now) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        let kind = mode == .object ? "Object" : "Person"
        return "\(kind) \(date.formatted(style))"
    }
}
