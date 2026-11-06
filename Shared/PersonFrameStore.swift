import CoreImage
import CoreMotion
import CoreVideo
import Foundation
import ImageIO
import RealityKit
import UniformTypeIdentifiers
import simd

/// List of saved person-scan frames (`frames.json` in the scan folder).
struct PersonCaptureManifest: Codable, Sendable, Equatable {
    struct Frame: Codable, Sendable, Equatable {
        var index: Int
        var image: String          // Images/0001.jpg
        var mask: String?          // Masks/0001.png
        var depth: String?         // Depth/0001.bin (Float32, row-major)
        var depthWidth: Int
        var depthHeight: Int
        /// ARKit camera-to-world transform, 16 floats column-major (also useful for a later Mac HQ build).
        var cameraTransform: [Float]?
        /// Gravity in camera space (x right, y up, z back), in g. Used when there is no pose (tripod).
        var gravity: [Double]? = nil
        var ring: Int
        var slice: Int
    }

    var mode: String
    var frames: [Frame] = []
}

/// Writes frames to disk while capturing. Use from one queue only.
final class PersonFrameStore {
    let folder: ScanFolder
    private(set) var manifest: PersonCaptureManifest
    private let context = CIContext()

    init(folder: ScanFolder, mode: ScanMode) throws {
        self.folder = folder
        manifest = PersonCaptureManifest(mode: mode.rawValue)
        try folder.create()
        try folder.resetCapture()
    }

    var count: Int { manifest.frames.count }

    /// Saves one frame. Returns the new frame count.
    @discardableResult
    func add(
        image: CVPixelBuffer, mask: PersonMasker.Mask?, depth: PersonMasker.DepthMap?,
        cameraTransform: simd_float4x4?, gravity: SIMD3<Double>? = nil, cell: CoverageTracker.Cell
    ) throws -> Int {
        let index = manifest.frames.count + 1
        let stem = String(format: "%04d", index)

        let imageName = "Images/\(stem).jpg"
        guard let jpeg = context.jpegRepresentation(
            of: CIImage(cvPixelBuffer: image),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92]
        ) else { throw MeshError.unreadable("couldn't encode photo") }
        try jpeg.write(to: folder.root.appending(path: imageName))

        var maskName: String?
        if let mask, let png = Self.png(gray: mask.pixels, width: mask.width, height: mask.height) {
            maskName = "Masks/\(stem).png"
            try png.write(to: folder.root.appending(path: maskName!))
        }

        var depthName: String?
        if let depth {
            depthName = "Depth/\(stem).bin"
            let data = depth.values.withUnsafeBufferPointer { Data(buffer: $0) }
            try data.write(to: folder.root.appending(path: depthName!))
        }

        manifest.frames.append(.init(
            index: index, image: imageName, mask: maskName, depth: depthName,
            depthWidth: depth?.width ?? 0, depthHeight: depth?.height ?? 0,
            cameraTransform: cameraTransform.map(Self.flatten), gravity: gravity.map { [$0.x, $0.y, $0.z] },
            ring: cell.ring, slice: cell.slice
        ))
        return manifest.frames.count
    }

    func writeManifest() throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: folder.personManifest, options: .atomic)
    }

    static func flatten(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    static func matrix(_ values: [Float]) -> simd_float4x4? {
        guard values.count == 16 else { return nil }
        return simd_float4x4(
            SIMD4(values[0], values[1], values[2], values[3]), SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]), SIMD4(values[12], values[13], values[14], values[15])
        )
    }

    /// World "down" expressed in ARKit camera space (x = image right, y = image up, z = toward viewer), in g.
    /// Not yet verified against what PhotogrammetrySession expects on a real device (see roadmap).
    static func gravity(cameraTransform m: simd_float4x4) -> SIMD3<Double> {
        let down = SIMD3<Float>(0, -1, 0)
        let x = SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let y = SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let z = SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        return SIMD3(Double(simd_dot(x, down)), Double(simd_dot(y, down)), Double(simd_dot(z, down)))
    }

    /// Converts CoreMotion device gravity (portrait axes: x right, y top, z out of screen)
    /// to back-camera image space (landscape-right: x right, y up, z back), matching ARKit's camera axes.
    static func cameraGravity(fromDevice g: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(-g.y, g.x, g.z)
    }

    static func png(gray: [UInt8], width: Int, height: Int) -> Data? {
        guard let provider = CGDataProvider(data: Data(gray) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }
        return ImageCoding.png(image)
    }

    static func loadManifest(from folder: ScanFolder) throws -> PersonCaptureManifest {
        try JSONDecoder().decode(PersonCaptureManifest.self, from: Data(contentsOf: folder.personManifest))
    }
}

/// Feeds saved person frames to `PhotogrammetrySession` one at a time,
/// so only one full-size photo is in memory at once.
struct PersonSampleSequence: Sequence {
    let folder: ScanFolder
    let frames: [PersonCaptureManifest.Frame]

    init(folder: ScanFolder, manifest: PersonCaptureManifest, limit: Int? = nil) {
        self.folder = folder
        var frames = manifest.frames
        if let limit, frames.count > limit {
            // Keep an even spread around the person.
            let step = Double(frames.count) / Double(limit)
            frames = (0..<limit).map { frames[Int(Double($0) * step)] }
        }
        self.frames = frames
    }

    func makeIterator() -> Iterator {
        Iterator(folder: folder, frames: frames)
    }

    struct Iterator: IteratorProtocol {
        let folder: ScanFolder
        let frames: [PersonCaptureManifest.Frame]
        var position = 0
        let context = CIContext()

        mutating func next() -> PhotogrammetrySample? {
            while position < frames.count {
                let frame = frames[position]
                position += 1
                if let sample = PersonSampleSequence.sample(for: frame, id: position, folder: folder, context: context) {
                    return sample
                }
            }
            return nil
        }
    }

    static func sample(
        for frame: PersonCaptureManifest.Frame, id: Int, folder: ScanFolder, context: CIContext
    ) -> PhotogrammetrySample? {
        guard let ciImage = CIImage(contentsOf: folder.root.appending(path: frame.image)) else { return nil }
        let width = Int(ciImage.extent.width), height = Int(ciImage.extent.height)
        guard let image = pixelBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA) else { return nil }
        context.render(ciImage, to: image)

        var sample = PhotogrammetrySample(id: id, image: image)

        if let maskName = frame.mask,
           let maskImage = CIImage(contentsOf: folder.root.appending(path: maskName)),
           let mask = pixelBuffer(width: width, height: height, format: kCVPixelFormatType_OneComponent8) {
            // Masks are saved small; stretch to the photo's size.
            let scaled = maskImage.transformed(by: CGAffineTransform(
                scaleX: CGFloat(width) / maskImage.extent.width, y: CGFloat(height) / maskImage.extent.height
            ))
            context.render(scaled, to: mask)
            sample.objectMask = mask
        }

        if let depthName = frame.depth, frame.depthWidth > 0, frame.depthHeight > 0,
           let data = try? Data(contentsOf: folder.root.appending(path: depthName)),
           data.count == frame.depthWidth * frame.depthHeight * MemoryLayout<Float>.size,
           let depth = pixelBuffer(width: frame.depthWidth, height: frame.depthHeight, format: kCVPixelFormatType_DepthFloat32) {
            CVPixelBufferLockBaseAddress(depth, [])
            if let base = CVPixelBufferGetBaseAddress(depth) {
                let rowBytes = CVPixelBufferGetBytesPerRow(depth)
                data.withUnsafeBytes { raw in
                    for y in 0..<frame.depthHeight {
                        memcpy(base + y * rowBytes, raw.baseAddress! + y * frame.depthWidth * 4, frame.depthWidth * 4)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(depth, [])
            sample.depthDataMap = depth
        }

        if let g = frame.gravity, g.count == 3 {
            sample.gravity = CMAcceleration(x: g[0], y: g[1], z: g[2])
        } else if let values = frame.cameraTransform, let transform = PersonFrameStore.matrix(values) {
            let g = PersonFrameStore.gravity(cameraTransform: transform)
            sample.gravity = CMAcceleration(x: g.x, y: g.y, z: g.z)
        }
        return sample
    }

    static func pixelBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &buffer)
        return buffer
    }
}
