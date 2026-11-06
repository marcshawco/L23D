import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A single triangle mesh with one PBR material, in meters, Y-up.
///
/// This is the app's neutral format: Object Capture USDZ files are read into it,
/// and every exporter (GLB, OBJ, USDZ) writes from it.
struct MeshData: Sendable {
    var positions: [SIMD3<Float>]
    /// Same count as `positions`, or empty.
    var normals: [SIMD3<Float>]
    /// Same count as `positions`, or empty. Origin at the bottom-left (USD / OBJ convention).
    var uvs: [SIMD2<Float>]
    /// Three per triangle, counter-clockwise front faces.
    var indices: [UInt32]
    var material: MaterialData

    var vertexCount: Int { positions.count }
    var triangleCount: Int { indices.count / 3 }

    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard var lo = positions.first else { return (.zero, .zero) }
        var hi = lo
        for p in positions {
            lo = pointwiseMin(lo, p)
            hi = pointwiseMax(hi, p)
        }
        return (lo, hi)
    }

    var size: SIMD3<Float> {
        let b = bounds
        return b.max - b.min
    }

    /// Moves and scales every vertex: `p' = (p + offset) * scale`. Normals are unchanged
    /// (uniform scale keeps their direction).
    func transformed(offset: SIMD3<Float>, scale: Float) -> MeshData {
        var copy = self
        copy.positions = positions.map { ($0 + offset) * scale }
        return copy
    }

    /// Checks that counts line up. Exporters call this before writing.
    func validate() throws {
        guard !positions.isEmpty, !indices.isEmpty else { throw MeshError.empty }
        guard indices.count % 3 == 0 else { throw MeshError.badIndices }
        guard normals.isEmpty || normals.count == positions.count,
              uvs.isEmpty || uvs.count == positions.count else { throw MeshError.attributeMismatch }
        let count = UInt32(positions.count)
        guard indices.allSatisfy({ $0 < count }) else { throw MeshError.badIndices }
    }
}

/// PBR material. Texture images are stored as encoded PNG/JPEG bytes so the
/// data is `Sendable` and can be copied straight into export files.
struct MaterialData: Sendable {
    var baseColor: TextureData?
    var normal: TextureData?
    var occlusion: TextureData?
    var roughness: TextureData?
    var metallic: TextureData?

    var baseColorFactor: SIMD4<Float> = [1, 1, 1, 1]
    var roughnessFactor: Float = 1
    var metallicFactor: Float = 0

    var textures: [(TextureSlot, TextureData)] {
        var list: [(TextureSlot, TextureData)] = []
        if let baseColor { list.append((.baseColor, baseColor)) }
        if let normal { list.append((.normal, normal)) }
        if let occlusion { list.append((.occlusion, occlusion)) }
        if let roughness { list.append((.roughness, roughness)) }
        if let metallic { list.append((.metallic, metallic)) }
        return list
    }
}

enum TextureSlot: String, Sendable, CaseIterable {
    case baseColor, normal, occlusion, roughness, metallic

    /// Color textures are sRGB; the rest hold raw data.
    var isColor: Bool { self == .baseColor }
}

/// An encoded image (PNG or JPEG) plus its pixel size.
struct TextureData: Sendable, Equatable {
    var data: Data
    var width: Int
    var height: Int
    var isJPEG: Bool

    var fileExtension: String { isJPEG ? "jpg" : "png" }
    var mimeType: String { isJPEG ? "image/jpeg" : "image/png" }

    init(data: Data, width: Int, height: Int, isJPEG: Bool) {
        self.data = data
        self.width = width
        self.height = height
        self.isJPEG = isJPEG
    }

    /// Reads size and type from encoded bytes.
    init?(encoded data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let type = CGImageSourceGetType(source) as String?
        self.init(data: data, width: width, height: height, isJPEG: type == UTType.jpeg.identifier)
    }

    /// Encodes a CGImage as PNG.
    init?(image: CGImage) {
        guard let data = ImageCoding.png(image) else { return nil }
        self.init(data: data, width: image.width, height: image.height, isJPEG: false)
    }

    func cgImage() -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

enum ImageCoding {
    static func png(_ image: CGImage) -> Data? {
        encode(image, type: .png, options: [:])
    }

    static func jpeg(_ image: CGImage, quality: Double = 0.9) -> Data? {
        encode(image, type: .jpeg, options: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    private static func encode(_ image: CGImage, type: UTType, options: [CFString: Any]) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

enum MeshError: LocalizedError {
    case empty
    case badIndices
    case attributeMismatch
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .empty: "The model has no geometry."
        case .badIndices: "The model's triangle list is broken."
        case .attributeMismatch: "The model's vertex data doesn't line up."
        case .unreadable(let detail): "Couldn't read the model: \(detail)"
        }
    }
}
