import CoreVideo
import Foundation
import simd

/// Cheap checks that keep blurry or shaky photos out of a person scan.
enum FrameQuality {
    /// Below this, a frame is treated as blurry (variance of the Laplacian on 0–255 gray).
    static let sharpnessThreshold: Double = 35
    /// Max camera speed while shooting.
    static let maxAngularSpeed: Float = 0.8 // radians / second
    static let maxLinearSpeed: Float = 0.6  // meters / second

    /// Variance of the Laplacian over the middle of the image, sampling every `step` pixels.
    /// Higher = sharper.
    static func sharpness(gray: UnsafeBufferPointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, step: Int = 4) -> Double {
        guard width > 4 * step, height > 4 * step else { return 0 }
        // Middle 60% of the frame, where the person is.
        let x0 = width / 5, x1 = width - width / 5
        let y0 = height / 5, y1 = height - height / 5
        var sum = 0.0, sumSquares = 0.0, count = 0.0
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                let c = Int(gray[y * bytesPerRow + x])
                let l = Int(gray[y * bytesPerRow + x - step])
                let r = Int(gray[y * bytesPerRow + x + step])
                let u = Int(gray[(y - step) * bytesPerRow + x])
                let d = Int(gray[(y + step) * bytesPerRow + x])
                let laplacian = Double(l + r + u + d - 4 * c)
                sum += laplacian
                sumSquares += laplacian * laplacian
                count += 1
                x += step
            }
            y += step
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        return sumSquares / count - mean * mean
    }

    /// Sharpness of the luma (Y) plane of a camera frame (bi-planar YUV from ARKit).
    static func sharpness(of pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(pixelBuffer)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) : CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return 0
        }
        let width = planar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : CVPixelBufferGetWidth(pixelBuffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) : CVPixelBufferGetBytesPerRow(pixelBuffer)
        let buffer = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: rowBytes * height)
        return sharpness(gray: buffer, width: width, height: height, bytesPerRow: rowBytes)
    }

    /// Angle (radians) between two camera orientations.
    static func rotationAngle(from a: simd_float4x4, to b: simd_float4x4) -> Float {
        let qa = simd_quatf(a)
        let qb = simd_quatf(b)
        let delta = qb * qa.inverse
        return abs(delta.angle > .pi ? 2 * .pi - delta.angle : delta.angle)
    }

    /// True if the camera moved slowly enough between two frames `dt` seconds apart.
    static func isSteady(from a: simd_float4x4, to b: simd_float4x4, dt: TimeInterval) -> Bool {
        guard dt > 0 else { return true }
        let angular = rotationAngle(from: a, to: b) / Float(dt)
        let pa = SIMD3(a.columns.3.x, a.columns.3.y, a.columns.3.z)
        let pb = SIMD3(b.columns.3.x, b.columns.3.y, b.columns.3.z)
        let linear = simd_length(pb - pa) / Float(dt)
        return angular <= maxAngularSpeed && linear <= maxLinearSpeed
    }
}
