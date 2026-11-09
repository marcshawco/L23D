import CoreGraphics
import Foundation

/// What the user picked on the export screen.
struct ExportOptions: Sendable, Equatable {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case blender, glb, obj, usdz
        var id: String { rawValue }
        var title: String { self == .blender ? "Blender" : rawValue.uppercased() }
        var fileExtension: String { (self == .obj || self == .blender) ? "zip" : rawValue }
        var help: String {
            switch self {
            case .blender: "Photoreal Blender kit (.zip): the model plus a script that sets up Cycles lighting, a shadow floor and a camera. On a Mac, double-click “Open in Blender”."
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

    enum Detail: String, CaseIterable, Identifiable, Sendable {
        case full, high, medium, low
        var id: String { rawValue }
        /// Share of the original triangles to keep.
        var ratio: Double {
            switch self {
            case .full: 1
            case .high: 0.5
            case .medium: 0.25
            case .low: 0.1
            }
        }
        var title: String {
            switch self {
            case .full: "Full"
            case .high: "High (50%)"
            case .medium: "Low (25%)"
            case .low: "Very low (10%)"
            }
        }
    }

    var format: Format = .blender
    var detail: Detail = .full
    var pivot: Pivot = .bottomCenter
    /// Only used for OBJ, which has no unit of its own. GLB and USDZ are always meters.
    var units: Units = .meters
    var maxTextureSize: TextureSize = .original
    var fileName: String = "Model"

    /// True when the original USDZ can be shared untouched.
    var isPassThrough: Bool {
        format == .usdz && pivot == .original && maxTextureSize == .original && detail == .full
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
        case .blender: try BlenderKit.zipData(glb: GLBWriter.data(for: mesh, name: name, generator: generator), name: name)
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
        // 0. Fewer triangles if asked (game LODs).
        if options.detail != .full {
            let target = max(100, Int(Double(mesh.triangleCount) * options.detail.ratio))
            mesh = MeshSimplifier.simplify(mesh, targetTriangles: target)
        }
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

/// "Blender kit": model.glb + the photoreal scene script + a double-click launcher for Mac.
enum BlenderKit {
    static func zipData(glb: Data, name: String) throws -> Data {
        guard let scriptURL = Bundle.main.url(forResource: "l23d_scene", withExtension: "py") else {
            throw MeshError.unreadable("the Blender script is missing from the app")
        }
        var zip = ZipWriter(alignment: 4)
        zip.add(name: "model.glb", data: glb)
        zip.add(name: "l23d_scene.py", data: try Data(contentsOf: scriptURL))
        zip.add(name: "Open in Blender.command", data: Data(launcher.utf8), executable: true)
        zip.add(name: "README.txt", data: Data(readme(name: name).utf8))
        return zip.finish()
    }

    static let launcher = """
    #!/bin/bash
    # Builds a photoreal Blender scene from model.glb, then opens it.
    cd "$(dirname "$0")"
    BLENDER="/Applications/Blender.app/Contents/MacOS/Blender"
    [ -x "$BLENDER" ] || BLENDER="$HOME/Applications/Blender.app/Contents/MacOS/Blender"
    if [ ! -x "$BLENDER" ]; then
      echo "Blender isn't installed. Get it free from https://www.blender.org/download/"
      read -n 1 -p "Press any key to close."
      exit 1
    fi
    echo "Setting up the scene in Blender (about a minute)…"
    "$BLENDER" -b --factory-startup --python l23d_scene.py -- --model model.glb --out scene.blend --render preview.png || { read -n 1 -p "Something went wrong. Press any key."; exit 1; }
    open -a "${BLENDER%/Contents/MacOS/Blender}" scene.blend

    """

    static func readme(name: String) -> String {
        """
        \(name) — exported by L23D

        On a Mac with Blender installed:
          Double-click "Open in Blender.command". It makes scene.blend (photoreal Cycles setup:
          HDRI lighting, soft key light, shadow floor, framed camera) and opens it.
          If macOS blocks it, right-click it, choose Open, then Open again.

        Any computer, by hand:
          blender -b --factory-startup --python l23d_scene.py -- --model model.glb --out scene.blend
          or in Blender: File > Import > glTF 2.0 > model.glb

        Model: meters, Y-up glTF (Blender imports it Z-up), PBR textures inside the .glb.
        """
    }
}
