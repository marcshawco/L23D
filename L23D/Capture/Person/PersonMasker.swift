import CoreVideo
import Foundation
import Vision

/// Makes a black-and-white mask of "the person" for each photo, so the model build
/// ignores the room and anyone else in view.
///
/// Mask = Vision's person cutout AND "LiDAR depth is near the subject's distance".
enum PersonMasker {
    /// How far (meters) a pixel's depth may be from the subject distance and still count.
    static let depthBand: Float = 0.8

    struct Mask: Sendable {
        var pixels: [UInt8] // 0 or 255
        var width: Int
        var height: Int

        var coverage: Double {
            guard !pixels.isEmpty else { return 0 }
            return Double(pixels.lazy.filter { $0 > 127 }.count) / Double(pixels.count)
        }
    }

    struct DepthMap: Sendable {
        var values: [Float] // meters, row-major
        var width: Int
        var height: Int
    }

    /// Combines a person cutout with depth. Pure function so it can be tested.
    /// - Parameters:
    ///   - segmentation: 0...255 person confidence, `width` × `height`.
    ///   - depth: optional LiDAR depth in the same image orientation (any size).
    ///   - subjectDistance: distance from camera to the person, meters.
    static func combine(
        segmentation: [UInt8], width: Int, height: Int,
        depth: DepthMap?, subjectDistance: Float?, band: Float = depthBand
    ) -> Mask {
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                guard segmentation[i] >= 128 else { continue }
                if let depth, let subjectDistance, depth.width > 0, depth.height > 0 {
                    let dx = min(depth.width - 1, x * depth.width / width)
                    let dy = min(depth.height - 1, y * depth.height / height)
                    let d = depth.values[dy * depth.width + dx]
                    // Unknown depth (0 / NaN) keeps Vision's answer.
                    if d.isFinite, d > 0, abs(d - subjectDistance) > band { continue }
                }
                out[i] = 255
            }
        }
        return Mask(pixels: out, width: width, height: height)
    }

    /// Runs Vision person segmentation (accurate) on a camera frame.
    static func segment(_ pixelBuffer: CVPixelBuffer) throws -> (pixels: [UInt8], width: Int, height: Int)? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
        guard let result = request.results?.first?.pixelBuffer else { return nil }
        return readGray(result)
    }

    /// Full mask for one frame.
    static func mask(for image: CVPixelBuffer, depth: DepthMap?, subjectDistance: Float?) throws -> Mask? {
        guard let segmentation = try segment(image) else { return nil }
        return combine(
            segmentation: segmentation.pixels, width: segmentation.width, height: segmentation.height,
            depth: depth, subjectDistance: subjectDistance
        )
    }

    static func readGray(_ buffer: CVPixelBuffer) -> (pixels: [UInt8], width: Int, height: Int)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var pixels = [UInt8](repeating: 0, count: width * height)
        let source = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = source[y * rowBytes + x]
            }
        }
        return (pixels, width, height)
    }

    /// Copies a Float32 depth buffer (ARKit sceneDepth) into a `DepthMap`.
    static func readDepth(_ buffer: CVPixelBuffer) -> DepthMap? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = (base + y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in 0..<width {
                values[y * width + x] = row[x]
            }
        }
        return DepthMap(values: values, width: width, height: height)
    }

    /// Median depth of a small patch around the image center (meters), ignoring bad values.
    static func centerDepth(_ depth: DepthMap, radius: Int = 3) -> Float? {
        let cx = depth.width / 2, cy = depth.height / 2
        var samples: [Float] = []
        for y in max(0, cy - radius)...min(depth.height - 1, cy + radius) {
            for x in max(0, cx - radius)...min(depth.width - 1, cx + radius) {
                let d = depth.values[y * depth.width + x]
                if d.isFinite, d > 0 { samples.append(d) }
            }
        }
        guard !samples.isEmpty else { return nil }
        samples.sort()
        return samples[samples.count / 2]
    }
}
