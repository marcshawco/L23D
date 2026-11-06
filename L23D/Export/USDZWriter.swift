import Foundation

/// Writes a `MeshData` as a USDZ: a text USD layer (`model.usda`) plus PNG/JPEG textures,
/// packed in an aligned, uncompressed zip. Uses `UsdPreviewSurface`, which AR Quick Look,
/// RealityKit and Blender all read.
enum USDZWriter {
    static func data(for mesh: MeshData, name: String = "Model") throws -> Data {
        try mesh.validate()
        var zip = ZipWriter(alignment: 64)
        // The first file in a USDZ must be the root USD layer.
        zip.add(name: "model.usda", data: Data(usda(for: mesh, name: name).utf8))
        for (slot, texture) in mesh.material.textures {
            zip.add(name: texturePath(slot, texture), data: texture.data)
        }
        return zip.finish()
    }

    static func write(_ mesh: MeshData, to url: URL, name: String = "Model") throws {
        try data(for: mesh, name: name).write(to: url, options: .atomic)
    }

    static func texturePath(_ slot: TextureSlot, _ texture: TextureData) -> String {
        "textures/\(slot.rawValue).\(texture.fileExtension)"
    }

    static func usda(for mesh: MeshData, name: String) -> String {
        let prim = sanitize(name)
        let materialPath = "/\(prim)/Materials/Material"
        let bounds = mesh.bounds
        let material = mesh.material

        var out = """
        #usda 1.0
        (
            defaultPrim = "\(prim)"
            metersPerUnit = 1
            upAxis = "Y"
        )

        def Xform "\(prim)" (
            kind = "component"
        )
        {
            def Mesh "Mesh" (
                prepend apiSchemas = ["MaterialBindingAPI"]
            )
            {
                float3[] extent = [\(vec(bounds.min)), \(vec(bounds.max))]
                int[] faceVertexCounts = [\(Array(repeating: "3", count: mesh.triangleCount).joined(separator: ", "))]
                int[] faceVertexIndices = [\(mesh.indices.map(String.init).joined(separator: ", "))]
                rel material:binding = <\(materialPath)>
                point3f[] points = [\(mesh.positions.map(vec).joined(separator: ", "))]
                uniform token subdivisionScheme = "none"

        """
        if !mesh.normals.isEmpty {
            out += """
                    normal3f[] normals = [\(mesh.normals.map(vec).joined(separator: ", "))] (
                        interpolation = "vertex"
                    )

            """
        }
        if !mesh.uvs.isEmpty {
            out += """
                    texCoord2f[] primvars:st = [\(mesh.uvs.map(vec).joined(separator: ", "))] (
                        interpolation = "vertex"
                    )

            """
        }
        out += """
            }

            def Scope "Materials"
            {
                def Material "Material"
                {
                    token outputs:surface.connect = <\(materialPath)/Surface.outputs:surface>

                    def Shader "Surface"
                    {
                        uniform token info:id = "UsdPreviewSurface"

        """
        let c = material.baseColorFactor
        out += material.baseColor != nil
            ? "                color3f inputs:diffuseColor.connect = <\(materialPath)/BaseColor.outputs:rgb>\n"
            : "                color3f inputs:diffuseColor = (\(num(c.x)), \(num(c.y)), \(num(c.z)))\n"
        out += material.roughness != nil
            ? "                float inputs:roughness.connect = <\(materialPath)/Roughness.outputs:r>\n"
            : "                float inputs:roughness = \(num(material.roughnessFactor))\n"
        out += material.metallic != nil
            ? "                float inputs:metallic.connect = <\(materialPath)/Metallic.outputs:r>\n"
            : "                float inputs:metallic = \(num(material.metallicFactor))\n"
        if material.normal != nil {
            out += "                normal3f inputs:normal.connect = <\(materialPath)/Normal.outputs:rgb>\n"
        }
        if material.occlusion != nil {
            out += "                float inputs:occlusion.connect = <\(materialPath)/Occlusion.outputs:r>\n"
        }
        out += """
                        token outputs:surface
                    }

                    def Shader "PrimvarST"
                    {
                        uniform token info:id = "UsdPrimvarReader_float2"
                        string inputs:varname = "st"
                        float2 outputs:result
                    }

        """
        for (slot, texture) in material.textures {
            out += textureShader(slot: slot, texture: texture, materialPath: materialPath)
        }
        out += """
                }
            }
        }

        """
        return out
    }

    private static func textureShader(slot: TextureSlot, texture: TextureData, materialPath: String) -> String {
        let shaderName: String = switch slot {
        case .baseColor: "BaseColor"
        case .normal: "Normal"
        case .occlusion: "Occlusion"
        case .roughness: "Roughness"
        case .metallic: "Metallic"
        }
        let output = (slot == .baseColor || slot == .normal) ? "float3 outputs:rgb" : "float outputs:r"
        var extras = ""
        if slot == .normal {
            // Normal maps store -1...1 as 0...1.
            extras = """
                            float4 inputs:scale = (2, 2, 2, 1)
                            float4 inputs:bias = (-1, -1, -1, 0)

            """
        }
        return """
                    def Shader "\(shaderName)"
                    {
                        uniform token info:id = "UsdUVTexture"
                        asset inputs:file = @\(texturePath(slot, texture))@
                        float2 inputs:st.connect = <\(materialPath)/PrimvarST.outputs:result>
                        token inputs:sourceColorSpace = "\(slot.isColor ? "sRGB" : "raw")"
                        token inputs:wrapS = "repeat"
                        token inputs:wrapT = "repeat"
        \(extras)                \(output)
                    }

        """
    }

    // MARK: - Formatting

    private static func num(_ value: Float) -> String {
        guard value.isFinite else { return "0" }
        // Shortest round-trip text; trims "1.0" to "1".
        var text = "\(value)"
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text
    }

    private static func vec(_ v: SIMD3<Float>) -> String {
        "(\(num(v.x)), \(num(v.y)), \(num(v.z)))"
    }

    private static func vec(_ v: SIMD2<Float>) -> String {
        "(\(num(v.x)), \(num(v.y)))"
    }

    /// USD prim names: letters, digits, underscore; can't start with a digit.
    static func sanitize(_ name: String) -> String {
        var result = String(name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "_" })
        if result.isEmpty { result = "Model" }
        if let first = result.first, first.isNumber { result = "_" + result }
        return result
    }
}
