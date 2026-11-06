import CoreGraphics
import simd
import Foundation

/// Writes a `MeshData` as binary glTF 2.0 (`.glb`): one mesh, one PBR material,
/// textures embedded. Y-up, meters. Imports into Blender, Unity (glTFast), Godot and Unreal.
enum GLBWriter {
    static func data(for mesh: MeshData, name: String = "Model", generator: String = "L23D") throws -> Data {
        try mesh.validate()

        var binary = Data()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []

        /// Appends bytes as a new buffer view (4-byte aligned) and returns its index.
        func addView(_ bytes: Data, target: Int?) -> Int {
            while binary.count % 4 != 0 { binary.append(0) }
            var view: [String: Any] = ["buffer": 0, "byteOffset": binary.count, "byteLength": bytes.count]
            if let target { view["target"] = target }
            binary.append(bytes)
            bufferViews.append(view)
            return bufferViews.count - 1
        }

        func addAccessor(view: Int, componentType: Int, count: Int, type: String, min: [Float]? = nil, max: [Float]? = nil) -> Int {
            var accessor: [String: Any] = ["bufferView": view, "componentType": componentType, "count": count, "type": type]
            if let min { accessor["min"] = min }
            if let max { accessor["max"] = max }
            accessors.append(accessor)
            return accessors.count - 1
        }

        // Geometry
        let bounds = mesh.bounds
        var attributes: [String: Int] = [:]
        attributes["POSITION"] = addAccessor(
            view: addView(floats(mesh.positions.flatMap { [$0.x, $0.y, $0.z] }), target: arrayBuffer),
            componentType: float, count: mesh.vertexCount, type: "VEC3",
            min: [bounds.min.x, bounds.min.y, bounds.min.z], max: [bounds.max.x, bounds.max.y, bounds.max.z]
        )
        if !mesh.normals.isEmpty {
            let unit = mesh.normals.map { n -> SIMD3<Float> in
                let length = simd_length(n)
                return length > 1e-6 ? n / length : SIMD3(0, 1, 0)
            }
            attributes["NORMAL"] = addAccessor(
                view: addView(floats(unit.flatMap { [$0.x, $0.y, $0.z] }), target: arrayBuffer),
                componentType: float, count: mesh.vertexCount, type: "VEC3"
            )
        }
        if !mesh.uvs.isEmpty {
            // glTF puts the UV origin at the top-left; USD/OBJ at the bottom-left.
            attributes["TEXCOORD_0"] = addAccessor(
                view: addView(floats(mesh.uvs.flatMap { [$0.x, 1 - $0.y] }), target: arrayBuffer),
                componentType: float, count: mesh.vertexCount, type: "VEC2"
            )
        }
        let indexAccessor = addAccessor(
            view: addView(uint32s(mesh.indices), target: elementArrayBuffer),
            componentType: unsignedInt, count: mesh.indices.count, type: "SCALAR"
        )

        // Textures
        var images: [[String: Any]] = []
        var textures: [[String: Any]] = []
        func addTexture(_ texture: TextureData) -> Int {
            let view = addView(texture.data, target: nil)
            images.append(["bufferView": view, "mimeType": texture.mimeType])
            textures.append(["source": images.count - 1, "sampler": 0])
            return textures.count - 1
        }

        let material = mesh.material
        var pbr: [String: Any] = [
            "baseColorFactor": [material.baseColorFactor.x, material.baseColorFactor.y, material.baseColorFactor.z, material.baseColorFactor.w],
            "metallicFactor": material.metallicFactor,
            "roughnessFactor": material.roughnessFactor,
        ]
        if let baseColor = material.baseColor {
            pbr["baseColorTexture"] = ["index": addTexture(baseColor)]
        }
        if let packed = packMetallicRoughness(material) {
            pbr["metallicRoughnessTexture"] = ["index": addTexture(packed.texture)]
            pbr["roughnessFactor"] = 1
            pbr["metallicFactor"] = packed.metallicFactor
        }
        var materialJSON: [String: Any] = ["name": "Material", "pbrMetallicRoughness": pbr, "doubleSided": false]
        if let normal = material.normal {
            materialJSON["normalTexture"] = ["index": addTexture(normal)]
        }
        if let occlusion = material.occlusion {
            materialJSON["occlusionTexture"] = ["index": addTexture(occlusion)]
        }

        var json: [String: Any] = [
            "asset": ["version": "2.0", "generator": generator],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0, "name": name]],
            "meshes": [["name": name, "primitives": [[
                "attributes": attributes, "indices": indexAccessor, "material": 0, "mode": 4,
            ]]]],
            "materials": [materialJSON],
            "accessors": accessors,
            "bufferViews": bufferViews,
            "buffers": [["byteLength": paddedLength(binary.count)]],
        ]
        if !textures.isEmpty {
            json["textures"] = textures
            json["images"] = images
            // Linear filtering with mipmaps, repeat wrapping.
            json["samplers"] = [["magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497]]
        }

        var jsonData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
        while jsonData.count % 4 != 0 { jsonData.append(0x20) } // pad JSON with spaces
        while binary.count % 4 != 0 { binary.append(0) }        // pad BIN with zeros

        var glb = Data()
        glb.appendLE(UInt32(0x4654_6C67))                       // "glTF"
        glb.appendLE(UInt32(2))                                  // version
        glb.appendLE(UInt32(12 + 8 + jsonData.count + 8 + binary.count))
        glb.appendLE(UInt32(jsonData.count))
        glb.appendLE(UInt32(0x4E4F_534A))                       // "JSON"
        glb.append(jsonData)
        glb.appendLE(UInt32(binary.count))
        glb.appendLE(UInt32(0x004E_4942))                       // "BIN\0"
        glb.append(binary)
        return glb
    }

    static func write(_ mesh: MeshData, to url: URL, name: String = "Model", generator: String = "L23D") throws {
        try data(for: mesh, name: name, generator: generator).write(to: url, options: .atomic)
    }

    // MARK: - Metallic / roughness packing

    /// glTF wants one image with roughness in G and metallic in B.
    /// Returns nil when there is no roughness or metallic map to pack.
    static func packMetallicRoughness(_ material: MaterialData) -> (texture: TextureData, metallicFactor: Float)? {
        guard material.roughness != nil || material.metallic != nil else { return nil }
        let roughnessImage = material.roughness?.cgImage()
        let metallicImage = material.metallic?.cgImage()
        guard let reference = roughnessImage ?? metallicImage else { return nil }
        let width = reference.width
        let height = reference.height

        let roughness = roughnessImage.flatMap { grayPixels($0, width: width, height: height) }
        let metallic = metallicImage.flatMap { grayPixels($0, width: width, height: height) }
        let roughnessFallback = UInt8(clamping: Int((material.roughnessFactor * 255).rounded()))

        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            rgba[i * 4 + 0] = 255
            rgba[i * 4 + 1] = roughness?[i] ?? roughnessFallback
            rgba[i * 4 + 2] = metallic?[i] ?? 255
            rgba[i * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ),
              let texture = TextureData(image: image) else { return nil }
        // With no metallic map, B = 255 and the factor carries the real value.
        let factor = metallic == nil ? material.metallicFactor : 1
        return (texture, factor)
    }

    /// Draws an image into an 8-bit grayscale buffer of the given size.
    static func grayPixels(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? pixels : nil
    }

    // MARK: - Helpers

    private static let float = 5126
    private static let unsignedInt = 5125
    private static let arrayBuffer = 34962
    private static let elementArrayBuffer = 34963

    private static func floats(_ values: [Float]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func uint32s(_ values: [UInt32]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func paddedLength(_ count: Int) -> Int {
        (count + 3) / 4 * 4
    }
}
