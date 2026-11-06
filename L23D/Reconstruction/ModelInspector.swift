import Metal
import QuickLookThumbnailing
import RealityKit
import UIKit

/// Basic facts about a finished model.
struct ModelStats: Sendable, Equatable {
    var triangleCount: Int
    /// Width, height, depth in meters.
    var size: SIMD3<Float>
}

@MainActor
enum ModelInspector {
    /// Loads the model with RealityKit (which applies the file's units, so sizes are in meters)
    /// and counts its triangles.
    static func stats(for url: URL) async throws -> ModelStats {
        let entity = try await Entity(contentsOf: url)
        let bounds = entity.visualBounds(relativeTo: nil)
        return ModelStats(triangleCount: triangleCount(in: entity), size: bounds.extents)
    }

    static func triangleCount(in entity: Entity) -> Int {
        var total = 0
        if let model = entity.components[ModelComponent.self] {
            for meshModel in model.mesh.contents.models {
                for part in meshModel.parts {
                    total += (part.triangleIndices?.count ?? 0) / 3
                }
            }
        }
        for child in entity.children {
            total += triangleCount(in: child)
        }
        return total
    }

    /// Saves a square JPEG preview of the model. Renders with RealityKit off-screen;
    /// falls back to the system thumbnailer if that fails.
    static func writeThumbnail(for modelURL: URL, to destination: URL, side: CGFloat = 512) async {
        if let image = try? await renderThumbnail(for: modelURL, side: Int(side)),
           let data = ImageCoding.jpeg(image, quality: 0.85) {
            try? data.write(to: destination, options: .atomic)
            return
        }
        await writeSystemThumbnail(for: modelURL, to: destination, side: side)
    }

    /// Three-quarter view of the model on a light gray background.
    static func renderThumbnail(for modelURL: URL, side: Int) async throws -> CGImage {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { throw ThumbnailError.noGPU }

        let renderer = try RealityRenderer()
        let model = try await Entity(contentsOf: modelURL)
        let root = ModelViewer.framed(model) // centered, ~0.5 m across
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 35
        camera.look(at: .zero, from: [0.55, 0.40, 0.85], relativeTo: nil)
        renderer.entities.append(contentsOf: [root, ModelViewer.lights(), camera])
        renderer.activeCamera = camera
        renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0.92, alpha: 1))

        // Render into a GPU-only texture, then copy it into a CPU-readable buffer
        // (shared textures aren't allowed as render targets in the Simulator).
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: side, height: side, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw ThumbnailError.noGPU }
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            do {
                try renderer.updateAndRender(deltaTime: 1 / 30, cameraOutput: output, onComplete: { _ in
                    continuation.resume()
                })
            } catch {
                continuation.resume(throwing: error)
            }
        }

        let bytesPerRow = side * 4
        guard let buffer = device.makeBuffer(length: bytesPerRow * side, options: .storageModeShared),
              let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { throw ThumbnailError.noGPU }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: side, height: side, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * side
        )
        blit.endEncoding()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            commands.addCompletedHandler { _ in continuation.resume() }
            commands.commit()
        }

        let data = Data(bytes: buffer.contents(), count: bytesPerRow * side)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { throw ThumbnailError.readbackFailed }
        return image
    }

    enum ThumbnailError: Error {
        case noGPU
        case readbackFailed
    }

    /// System USDZ thumbnailer (works on device; not always in the Simulator).
    private static func writeSystemThumbnail(for modelURL: URL, to destination: URL, side: CGFloat) async {
        let request = QLThumbnailGenerator.Request(
            fileAt: modelURL,
            size: CGSize(width: side, height: side),
            scale: 1,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return
        }
        let image = representation.uiImage
        // Put the (transparent) render on a soft background so it reads well in the grid.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let flattened = renderer.image { context in
            UIColor(white: 0.92, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let scale = min(side / image.size.width, side / image.size.height)
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let origin = CGPoint(x: (side - drawSize.width) / 2, y: (side - drawSize.height) / 2)
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
        try? flattened.jpegData(compressionQuality: 0.85)?.write(to: destination, options: .atomic)
    }
}

enum Format {
    /// "30.0 × 15.0 × 10.0 cm" from meters.
    static func sizeInCentimeters(_ size: SIMD3<Double>) -> String {
        let cm = size * 100
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
        return "\(cm.x.formatted(style)) × \(cm.y.formatted(style)) × \(cm.z.formatted(style)) cm"
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
