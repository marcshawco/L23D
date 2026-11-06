import CoreGraphics
import Foundation

/// What the user picked on the export screen.
struct ExportOptions: Sendable, Equatable {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case glb, obj, usdz
        var id: String { rawValue }
        var title: String { rawValue.uppercased() }
        var fileExtension: String { self == .obj ? "zip" : rawValue }
        var help: String {
            switch self {
            case .glb: "Best for Unity, Godot, Unreal, Blender and the web. One file with the textures inside."
            case .obj: "Works almost everywhere. Comes as a .zip with the model, its material, and textures."
            case .usdz: "Apple's format. Best for AR Quick Look, Reality Composer, and Blender 4+."
            }
        }
    }

    enum Pivot: String, CaseIterable, Identifiable, Sendable {
        case bottomCenter, center, original
        var id: String { rawValue }
        var title: String {
            switch self {
            case .bottomCenter: "Bottom center"
            case .center: "Center"
            case .original: "As scanned"
            }
        }
        var help: String {
            switch self {
            case .bottomCenter: "The model sits on the ground at 0,0,0. Best for game objects and characters."
            case .center: "The middle of the model is at 0,0,0. Good for spinning props."
            case .original: "Keeps the position from the scan."
            }
        }
    }

    enum Units: String, CaseIterable, Identifiable, Sendable {
        case meters, centimeters
        var id: String { rawValue }
        var title: String { self == .meters ? "Meters" : "Centimeters" }
        var scale: Float { self == .meters ? 1 : 100 }
    }

    enum TextureSize: Int, CaseIterable, Identifiable, Sendable {
        case original = 0, size4096 = 4096, size2048 = 2048, size1024 = 1024, size512 = 512
        var id: Int { rawValue }
        var title: String { self == .original ? "Original" : "\(rawValue) px" }
    }

    var format: Format = .glb
    var pivot: Pivot = .bottomCenter
    /// Only used for OBJ, which has no unit of its own. GLB and USDZ are always meters.
    var units: Units = .meters
    var maxTextureSize: TextureSize = .original
    var fileName: String = "Model"

    /// True when the original USDZ can be shared untouched.
    var isPassThrough: Bool {
        format == .usdz && pivot == .original && maxTextureSize == .original
    }
}

/// Turns a scan's `model.usdz` into a GLB, OBJ (.zip) or re-written USDZ.
enum ExportService {
    /// Runs the export off the main thread. Returns the file URL to share.
    static func export(
        modelURL: URL, realSize: SIMD3<Float>?, options: ExportOptions, to directory: URL, generator: String = "L23D"
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try exportNow(modelURL: modelURL, realSize: realSize, options: options, to: directory, generator: generator)
        }.value
    }

    static func exportNow(
        modelURL: URL, realSize: SIMD3<Float>?, options: ExportOptions, to directory: URL, generator: String = "L23D"
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = safeFileName(options.fileName)
        let destination = directory.appending(path: "\(name).\(options.format.fileExtension)")
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: destination)
        }

        if options.isPassThrough {
            try FileManager.default.copyItem(at: modelURL, to: destination)
            return destination
        }

        let mesh = try prepare(MeshLoader.load(url: modelURL), realSize: realSize, options: options)
        let data: Data = switch options.format {
        case .glb: try GLBWriter.data(for: mesh, name: name, generator: generator)
        case .obj: try OBJWriter.zipData(for: mesh, name: name)
        case .usdz: try USDZWriter.data(for: mesh, name: name)
        }
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// Applies unit fix-up, pivot, export units and texture size.
    static func prepare(_ source: MeshData, realSize: SIMD3<Float>?, options: ExportOptions) -> MeshData {
        var mesh = source
        // 1. Make sure the mesh is in meters (some USD files use centimeters).
        if let realSize {
            let unitScale = unitCorrection(meshSize: mesh.size, realSize: realSize)
            if unitScale != 1 {
                mesh = mesh.transformed(offset: .zero, scale: unitScale)
            }
        }
        // 2. Move the pivot, then 3. convert units (OBJ only).
        let offset = pivotOffset(for: mesh, pivot: options.pivot)
        let scale = options.format == .obj ? options.units.scale : 1
        if offset != .zero || scale != 1 {
            mesh = mesh.transformed(offset: offset, scale: scale)
        }
        // 4. Shrink textures if asked.
        if options.maxTextureSize != .original {
            mesh.material = resized(mesh.material, maxSide: options.maxTextureSize.rawValue)
        }
        return mesh
    }

    static func pivotOffset(for mesh: MeshData, pivot: ExportOptions.Pivot) -> SIMD3<Float> {
        let b = mesh.bounds
        let center = (b.min + b.max) / 2
        switch pivot {
        case .original: return .zero
        case .center: return -center
        case .bottomCenter: return -SIMD3(center.x, b.min.y, center.z)
        }
    }

    /// Scale that turns the mesh's raw numbers into meters, by comparing with the
    /// real size RealityKit measured. Snaps to a power of ten when close (cm, mm…).
    static func unitCorrection(meshSize: SIMD3<Float>, realSize: SIMD3<Float>) -> Float {
        let meshLargest = max(meshSize.x, meshSize.y, meshSize.z)
        let realLargest = max(realSize.x, realSize.y, realSize.z)
        guard meshLargest > 0, realLargest > 0 else { return 1 }
        let ratio = realLargest / meshLargest
        if abs(ratio - 1) < 0.02 { return 1 }
        let power = (log10(ratio)).rounded()
        let snapped = pow(10, power)
        return abs(ratio / snapped - 1) < 0.05 ? snapped : ratio
    }

    static func resized(_ material: MaterialData, maxSide: Int) -> MaterialData {
        var copy = material
        copy.baseColor = material.baseColor.map { downscaled($0, maxSide: maxSide) }
        copy.normal = material.normal.map { downscaled($0, maxSide: maxSide) }
        copy.occlusion = material.occlusion.map { downscaled($0, maxSide: maxSide) }
        copy.roughness = material.roughness.map { downscaled($0, maxSide: maxSide) }
        copy.metallic = material.metallic.map { downscaled($0, maxSide: maxSide) }
        return copy
    }

    /// Shrinks a texture so its longest side is at most `maxSide`. Never enlarges.
    static func downscaled(_ texture: TextureData, maxSide: Int) -> TextureData {
        let longest = max(texture.width, texture.height)
        guard longest > maxSide, let image = texture.cgImage() else { return texture }
        let scale = Double(maxSide) / Double(longest)
        let width = max(1, Int((Double(texture.width) * scale).rounded()))
        let height = max(1, Int((Double(texture.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return texture }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return texture }
        let data = texture.isJPEG ? ImageCoding.jpeg(small) : ImageCoding.png(small)
        guard let data else { return texture }
        return TextureData(data: data, width: width, height: height, isJPEG: texture.isJPEG)
    }

    /// Letters, digits, spaces, dashes and underscores only.
    static func safeFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(name.unicodeScalars.filter { allowed.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Model" : String(cleaned.prefix(80))
    }
}
