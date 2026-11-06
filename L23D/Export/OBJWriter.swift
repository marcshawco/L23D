import Foundation

/// Writes a `MeshData` as Wavefront OBJ + MTL + texture files, packed in a .zip.
/// OBJ has no units; the numbers are written as-is (see `ExportOptions.Units`).
enum OBJWriter {
    struct Files {
        var obj: String
        var mtl: String
        var textures: [(path: String, data: Data)]
    }

    static func files(for mesh: MeshData, name: String = "Model") throws -> Files {
        try mesh.validate()
        let base = "model"
        var obj = "# Exported by L23D\n# \(mesh.vertexCount) vertices, \(mesh.triangleCount) triangles\n"
        obj += "mtllib \(base).mtl\n"
        obj.reserveCapacity(mesh.vertexCount * 90 + mesh.triangleCount * 40)
        obj += "o \(sanitizeName(name))\n"

        for p in mesh.positions {
            obj += "v \(num(p.x)) \(num(p.y)) \(num(p.z))\n"
        }
        let hasUV = !mesh.uvs.isEmpty
        let hasNormal = !mesh.normals.isEmpty
        for uv in mesh.uvs {
            obj += "vt \(num(uv.x)) \(num(uv.y))\n"
        }
        for n in mesh.normals {
            obj += "vn \(num(n.x)) \(num(n.y)) \(num(n.z))\n"
        }
        obj += "usemtl Material\ns 1\n"
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.indices[t] + 1, b = mesh.indices[t + 1] + 1, c = mesh.indices[t + 2] + 1
            switch (hasUV, hasNormal) {
            case (true, true): obj += "f \(a)/\(a)/\(a) \(b)/\(b)/\(b) \(c)/\(c)/\(c)\n"
            case (true, false): obj += "f \(a)/\(a) \(b)/\(b) \(c)/\(c)\n"
            case (false, true): obj += "f \(a)//\(a) \(b)//\(b) \(c)//\(c)\n"
            case (false, false): obj += "f \(a) \(b) \(c)\n"
            }
        }

        let material = mesh.material
        var textures: [(path: String, data: Data)] = []
        func add(_ slot: TextureSlot, _ texture: TextureData?) -> String? {
            guard let texture else { return nil }
            let path = "textures/\(slot.rawValue).\(texture.fileExtension)"
            textures.append((path, texture.data))
            return path
        }

        let c = material.baseColorFactor
        var mtl = "# Exported by L23D\nnewmtl Material\n"
        mtl += "Ka 1 1 1\nKd \(num(c.x)) \(num(c.y)) \(num(c.z))\nKs 0 0 0\nd 1\nillum 2\n"
        mtl += "Pr \(num(material.roughnessFactor))\nPm \(num(material.metallicFactor))\n"
        if let path = add(.baseColor, material.baseColor) { mtl += "map_Kd \(path)\n" }
        if let path = add(.normal, material.normal) { mtl += "norm \(path)\nmap_Bump \(path)\n" }
        if let path = add(.roughness, material.roughness) { mtl += "map_Pr \(path)\n" }
        if let path = add(.metallic, material.metallic) { mtl += "map_Pm \(path)\n" }
        if let path = add(.occlusion, material.occlusion) { mtl += "# ambient occlusion: \(path)\n" }

        return Files(obj: obj, mtl: mtl, textures: textures)
    }

    /// A .zip with `model.obj`, `model.mtl` and `textures/…`.
    static func zipData(for mesh: MeshData, name: String = "Model") throws -> Data {
        let files = try files(for: mesh, name: name)
        var zip = ZipWriter(alignment: 4)
        zip.add(name: "model.obj", data: Data(files.obj.utf8))
        zip.add(name: "model.mtl", data: Data(files.mtl.utf8))
        for texture in files.textures {
            zip.add(name: texture.path, data: texture.data)
        }
        return zip.finish()
    }

    private static func num(_ value: Float) -> String {
        guard value.isFinite else { return "0" }
        var text = "\(value)"
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text
    }

    private static func sanitizeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Model" : cleaned
    }
}
