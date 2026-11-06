import Foundation
import simd

/// Splits the space around the person into 3 height rings × N slices and remembers
/// which ones already have a photo. Slice 0 is wherever the helper started.
struct CoverageTracker: Sendable, Equatable {
    static let rings = 3
    static let slices = 30 // one photo every 12°

    /// Middle of the person (world space, meters).
    let center: SIMD3<Float>
    /// Angle of the starting camera position, so slice 0 is "where you began".
    let startAzimuth: Float
    private(set) var filled: Set<Int> = []

    /// Closest and farthest the helper may stand (horizontal distance, meters).
    static let minDistance: Float = 0.5
    static let maxDistance: Float = 4.0

    init(center: SIMD3<Float>, startCamera: SIMD3<Float>) {
        self.center = center
        let offset = startCamera - center
        startAzimuth = atan2(offset.x, offset.z)
    }

    struct Cell: Hashable, Sendable {
        let ring: Int
        let slice: Int
        var index: Int { ring * CoverageTracker.slices + slice }
    }

    enum Placement: Equatable, Sendable {
        case cell(Cell)
        case tooClose
        case tooFar
    }

    /// Where a camera at `position` falls on the ring.
    func placement(of position: SIMD3<Float>) -> Placement {
        let offset = position - center
        let horizontal = simd_length(SIMD2(offset.x, offset.z))
        if horizontal < Self.minDistance { return .tooClose }
        if horizontal > Self.maxDistance { return .tooFar }

        var angle = atan2(offset.x, offset.z) - startAzimuth
        while angle < 0 { angle += 2 * .pi }
        while angle >= 2 * .pi { angle -= 2 * .pi }
        let slice = min(Self.slices - 1, Int(angle / (2 * .pi) * Float(Self.slices)))

        let elevation = atan2(offset.y, horizontal) * 180 / .pi
        let ring: Int = elevation < -12 ? 0 : (elevation <= 15 ? 1 : 2)
        return .cell(Cell(ring: ring, slice: slice))
    }

    func isFilled(_ cell: Cell) -> Bool { filled.contains(cell.index) }

    mutating func fill(_ cell: Cell) { filled.insert(cell.index) }

    /// Frees a cell again (e.g. when its photo failed).
    mutating func unfill(_ cell: Cell) { filled.remove(cell.index) }

    /// 0...1 of all cells.
    var fraction: Double { Double(filled.count) / Double(Self.rings * Self.slices) }

    /// 0...1 of one ring.
    func fraction(ring: Int) -> Double {
        let count = filled.filter { $0 / Self.slices == ring }.count
        return Double(count) / Double(Self.slices)
    }

    /// Flat list (ring-major) for drawing.
    var cells: [Bool] {
        (0..<(Self.rings * Self.slices)).map { filled.contains($0) }
    }
}
