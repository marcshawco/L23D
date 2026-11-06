import CoreGraphics
import Foundation
import ModelIO

/// Reads a USD/USDZ model (such as Object Capture output) into `MeshData`.
///
/// Geometry comes from ModelIO. Textures are taken as their original bytes from the
/// USDZ package when possible (no re-encoding), falling back to ModelIO's decoded images.
enum MeshLoader {
    static func load(url: URL) throws -> MeshData {
        let asset = MDLAsset(url: url)
        asset.loadTextures()
        let meshes = asset.childObjects(of: MDLMesh.self).compactMap { $0 as? MDLMesh }
        guard !meshes.isEmpty else { throw MeshError.unreadable("no meshes found") }

        var result = MeshData(positions: [], normals: [], uvs: [], indices: [], material: MaterialData())
        var firstMaterial: MDLMaterial?
        for mesh in meshes {
            let transform = MDLTransform.globalTransform(with: mesh, atTime: 0)
            let part = try meshData(from: mesh, transform: transform)
            append(part, to: &result)
            if firstMaterial == nil {
                firstMaterial = (mesh.submeshes as? [MDLSubmesh])?.compactMap(\.material).first
            }
        }

        let packageFiles = url.pathExtension.lowercased() == "usdz"
            ? ((try? Data(contentsOf: url)).map { ZipReader.storedEntries(in: $0) } ?? [])
            : []
        result.material = material(from: firstMaterial, packageFiles: packageFiles)
        try result.validate()
        return result
    }

    /// Converts one ModelIO mesh (all triangle submeshes) into `MeshData`.
    static func meshData(from mesh: MDLMesh, transform: simd_float4x4 = matrix_identity_float4x4) throws -> MeshData {
        if mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal) == nil {
            mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
        }
        let count = mesh.vertexCount
        guard count > 0,
              let positionData = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else {
            throw MeshError.unreadable("mesh has no positions")
        }

        var positions = read(SIMD3<Float>.self, from: positionData, count: count) { pointer in
            SIMD3(pointer[0], pointer[1], pointer[2])
        }
        var normals: [SIMD3<Float>] = []
        if let normalData = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal, as: .float3) {
            normals = read(SIMD3<Float>.self, from: normalData, count: count) { SIMD3($0[0], $0[1], $0[2]) }
        }
        var uvs: [SIMD2<Float>] = []
        if let uvData = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeTextureCoordinate, as: .float2) {
            uvs = read(SIMD2<Float>.self, from: uvData, count: count) { SIMD2($0[0], $0[1]) }
        }

        if transform != matrix_identity_float4x4 {
            positions = positions.map { p in
                let t = transform * SIMD4(p, 1)
                return SIMD3(t.x, t.y, t.z) / (t.w == 0 ? 1 : t.w)
            }
            let upper = simd_float3x3(
                SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            )
            let normalMatrix = upper.inverse.transpose
            normals = normals.map { simd_normalize(normalMatrix * $0) }
        }

        var indices: [UInt32] = []
        for case let submesh as MDLSubmesh in mesh.submeshes ?? [] where submesh.geometryType == .triangles {
            let buffer = submesh.indexBuffer(asIndexType: .uInt32)
            let map = buffer.map()
            let pointer = map.bytes.bindMemory(to: UInt32.self, capacity: submesh.indexCount)
            indices.append(contentsOf: UnsafeBufferPointer(start: pointer, count: submesh.indexCount))
        }

        return MeshData(positions: positions, normals: normals, uvs: uvs, indices: indices, material: MaterialData())
    }

    // MARK: - Private

    private static func read<T>(
        _: T.Type, from attribute: MDLVertexAttributeData, count: Int, make: (UnsafePointer<Float>) -> T
    ) -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        let base = attribute.dataStart
        for i in 0..<count {
            let pointer = (base + i * attribute.stride).assumingMemoryBound(to: Float.self)
            values.append(make(pointer))
        }
        return values
    }

    private static func append(_ part: MeshData, to result: inout MeshData) {
        let offset = UInt32(result.positions.count)
        // Keep attributes aligned when one part lacks normals/UVs.
        if result.normals.count == result.positions.count, part.normals.count == part.positions.count {
            result.normals += part.normals
        } else {
            result.normals = []
        }
        if result.uvs.count == result.positions.count, part.uvs.count == part.positions.count {
            result.uvs += part.uvs
        } else {
            result.uvs = []
        }
        result.positions += part.positions
        result.indices += part.indices.map { $0 + offset }
    }

    static func material(from mdl: MDLMaterial?, packageFiles: [ZipReader.Entry]) -> MaterialData {
        var material = MaterialData()
        var usedNames = Set<String>()

        func texture(_ semantic: MDLMaterialSemantic, slot: TextureSlot) -> TextureData? {
            if let property = mdl?.property(with: semantic),
               let found = textureData(from: property, packageFiles: packageFiles, used: &usedNames) {
                return found
            }
            // ModelIO didn't give us this map; look for it by file name in the package.
            if let entry = packageFiles.first(where: { !usedNames.contains($0.name) && guessSlot(for: $0.name) == slot }),
               let data = TextureData(encoded: entry.data) {
                usedNames.insert(entry.name)
                return data
            }
            return nil
        }

        material.normal = texture(.tangentSpaceNormal, slot: .normal)
        material.roughness = texture(.roughness, slot: .roughness)
        material.metallic = texture(.metallic, slot: .metallic)
        material.occlusion = texture(.ambientOcclusion, slot: .occlusion)
        material.baseColor = texture(.baseColor, slot: .baseColor)

        if let property = mdl?.property(with: .baseColor) {
            switch property.type {
            case .float3: material.baseColorFactor = SIMD4(property.float3Value, 1)
            case .float4: material.baseColorFactor = property.float4Value
            case .color:
                if let components = property.color?.components, components.count >= 3 {
                    material.baseColorFactor = SIMD4(Float(components[0]), Float(components[1]), Float(components[2]), 1)
                }
            default: break
            }
        }
        if let property = mdl?.property(with: .roughness), property.type == .float {
            material.roughnessFactor = property.floatValue
        }
        if let property = mdl?.property(with: .metallic), property.type == .float {
            material.metallicFactor = property.floatValue
        }
        return material
    }

    private static func textureData(
        from property: MDLMaterialProperty, packageFiles: [ZipReader.Entry], used: inout Set<String>
    ) -> TextureData? {
        // 1. Find the original file in the package by name (keeps the original bytes).
        var candidateNames: [String] = []
        if let url = property.urlValue { candidateNames.append(url.lastPathComponent) }
        if let string = property.stringValue { candidateNames.append((string as NSString).lastPathComponent) }
        if let name = property.textureSamplerValue?.texture?.name { candidateNames.append((name as NSString).lastPathComponent) }
        for name in candidateNames where !name.isEmpty {
            if let entry = packageFiles.first(where: { ($0.name as NSString).lastPathComponent == name }),
               let data = TextureData(encoded: entry.data) {
                used.insert(entry.name)
                return data
            }
        }
        // 2. A file on disk.
        if let url = property.urlValue, let bytes = try? Data(contentsOf: url), let data = TextureData(encoded: bytes) {
            return data
        }
        // 3. ModelIO's decoded image.
        if property.type == .texture,
           let image = property.textureSamplerValue?.texture?.imageFromTexture()?.takeUnretainedValue() {
            return TextureData(image: image)
        }
        return nil
    }

    /// Guesses which material map an image file is from its name.
    static func guessSlot(for path: String) -> TextureSlot? {
        let name = (path as NSString).lastPathComponent.lowercased()
        guard ["png", "jpg", "jpeg", "exr"].contains((name as NSString).pathExtension) else { return nil }
        if name.contains("normal") { return .normal }
        if name.contains("rough") { return .roughness }
        if name.contains("metal") { return .metallic }
        if name.contains("occlusion") || name.hasPrefix("ao") || name.contains("_ao") || name.contains("ao.") { return .occlusion }
        if name.contains("basecolor") || name.contains("diffuse") || name.contains("albedo") || name.contains("color") {
            return .baseColor
        }
        return nil
    }
}
