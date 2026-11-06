import CoreGraphics
import Foundation
import simd
import Testing
@testable import L23D

/// Parsed pieces of a .glb for checking.
private struct ParsedGLB {
    let version: UInt32
    let totalLength: UInt32
    let json: [String: Any]
    let jsonChunkLength: Int
    let binChunkLength: Int
    let fileLength: Int

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        func u32(_ o: Int) -> UInt32 {
            UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
        }
        #expect(u32(0) == 0x4654_6C67, "magic must be glTF")
        version = u32(4)
        totalLength = u32(8)
        jsonChunkLength = Int(u32(12))
        #expect(u32(16) == 0x4E4F_534A, "first chunk must be JSON")
        let jsonBytes = Data(bytes[20..<(20 + jsonChunkLength)])
        json = try #require(try JSONSerialization.jsonObject(with: jsonBytes) as? [String: Any])
        let binHeader = 20 + jsonChunkLength
        binChunkLength = Int(u32(binHeader))
        #expect(u32(binHeader + 4) == 0x004E_4942, "second chunk must be BIN")
        fileLength = bytes.count
    }
}

struct GLBTests {
    @Test func headerAndChunksAreValid() throws {
        let mesh = try SampleModel.meshData()
        let glb = try GLBWriter.data(for: mesh, name: "Box")
        let parsed = try ParsedGLB(glb)

        #expect(parsed.version == 2)
        #expect(Int(parsed.totalLength) == parsed.fileLength)
        #expect(parsed.jsonChunkLength % 4 == 0)
        #expect(parsed.binChunkLength % 4 == 0)
        #expect(12 + 8 + parsed.jsonChunkLength + 8 + parsed.binChunkLength == parsed.fileLength)
    }

    @Test func accessorsMatchMesh() throws {
        let mesh = try SampleModel.meshData()
        let parsed = try ParsedGLB(GLBWriter.data(for: mesh))
        let accessors = try #require(parsed.json["accessors"] as? [[String: Any]])
        let primitive = try #require(
            ((parsed.json["meshes"] as? [[String: Any]])?.first?["primitives"] as? [[String: Any]])?.first
        )
        let attributes = try #require(primitive["attributes"] as? [String: Int])

        let position = accessors[try #require(attributes["POSITION"])]
        #expect(position["count"] as? Int == mesh.vertexCount)
        #expect(position["type"] as? String == "VEC3")
        #expect((position["min"] as? [Double])?.count == 3)
        #expect((position["max"] as? [Double])?.count == 3)

        #expect(accessors[try #require(attributes["NORMAL"])]["count"] as? Int == mesh.vertexCount)
        #expect(accessors[try #require(attributes["TEXCOORD_0"])]["count"] as? Int == mesh.vertexCount)
        let indices = accessors[try #require(primitive["indices"] as? Int)]
        #expect(indices["count"] as? Int == mesh.indices.count)
        #expect(indices["componentType"] as? Int == 5125)

        // Every buffer view fits in the buffer and starts 4-byte aligned.
        let buffer = try #require((parsed.json["buffers"] as? [[String: Any]])?.first?["byteLength"] as? Int)
        #expect(buffer == parsed.binChunkLength)
        for view in try #require(parsed.json["bufferViews"] as? [[String: Any]]) {
            let offset = try #require(view["byteOffset"] as? Int)
            let length = try #require(view["byteLength"] as? Int)
            #expect(offset % 4 == 0)
            #expect(offset + length <= buffer)
        }
    }

    @Test func embedsBaseColorTexture() throws {
        let mesh = try SampleModel.meshData()
        let parsed = try ParsedGLB(GLBWriter.data(for: mesh))
        let images = try #require(parsed.json["images"] as? [[String: Any]])
        #expect(images.count == 1)
        #expect(images.first?["mimeType"] as? String == "image/png")
        let material = try #require((parsed.json["materials"] as? [[String: Any]])?.first)
        let pbr = try #require(material["pbrMetallicRoughness"] as? [String: Any])
        #expect(pbr["baseColorTexture"] != nil)
    }

    @Test func packsRoughnessIntoGreenChannel() throws {
        var material = MaterialData()
        material.roughness = TextureData(image: solidGray(value: 200))
        let packed = try #require(GLBWriter.packMetallicRoughness(material))
        let image = try #require(packed.texture.cgImage())
        let pixel = rgba(of: image)
        #expect(abs(Int(pixel.g) - 200) <= 2, "roughness goes in green")
        #expect(pixel.b == 255, "no metallic map: blue is full and the factor carries the value")
        #expect(packed.metallicFactor == 0)
    }

    private func solidGray(value: UInt8) -> CGImage {
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(gray: CGFloat(value) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context.makeImage()!
    }

    private func rgba(of image: CGImage) -> (r: UInt8, g: UInt8, b: UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (pixel[0], pixel[1], pixel[2])
    }
}

struct OBJTests {
    @Test func countsMatchMesh() throws {
        let mesh = try SampleModel.meshData()
        let files = try OBJWriter.files(for: mesh, name: "Box")
        let lines = files.obj.split(separator: "\n")
        #expect(lines.filter { $0.hasPrefix("v ") }.count == mesh.vertexCount)
        #expect(lines.filter { $0.hasPrefix("vt ") }.count == mesh.vertexCount)
        #expect(lines.filter { $0.hasPrefix("vn ") }.count == mesh.vertexCount)
        #expect(lines.filter { $0.hasPrefix("f ") }.count == mesh.triangleCount)
        #expect(files.obj.contains("mtllib model.mtl"))
        #expect(files.mtl.contains("map_Kd textures/baseColor.png"))
        #expect(files.textures.map(\.path) == ["textures/baseColor.png"])
    }

    @Test func faceIndicesAreOneBased() throws {
        let mesh = try SampleModel.meshData()
        let files = try OBJWriter.files(for: mesh)
        let faceIndices = files.obj.split(separator: "\n")
            .filter { $0.hasPrefix("f ") }
            .flatMap { $0.dropFirst(2).split(separator: " ").compactMap { Int($0.split(separator: "/").first!) } }
        #expect(faceIndices.min() == 1)
        #expect(faceIndices.max() == mesh.vertexCount)
    }

    @Test func zipHasAllFiles() throws {
        let mesh = try SampleModel.meshData()
        let entries = ZipReader.storedEntries(in: try OBJWriter.zipData(for: mesh))
        #expect(entries.map(\.name) == ["model.obj", "model.mtl", "textures/baseColor.png"])
    }
}

struct ExportOptionTests {
    @Test func bottomCenterPivotPutsModelOnTheGround() throws {
        let mesh = try SampleModel.meshData().transformed(offset: [1, 2, 3], scale: 1)
        var options = ExportOptions()
        options.pivot = .bottomCenter
        let prepared = ExportService.prepare(mesh, realSize: nil, options: options)
        let b = prepared.bounds
        #expect(abs(b.min.y) < 1e-5)
        #expect(abs((b.min.x + b.max.x) / 2) < 1e-5)
        #expect(abs((b.min.z + b.max.z) / 2) < 1e-5)
    }

    @Test func centerPivot() throws {
        let mesh = try SampleModel.meshData().transformed(offset: [1, 2, 3], scale: 1)
        var options = ExportOptions()
        options.pivot = .center
        let b = ExportService.prepare(mesh, realSize: nil, options: options).bounds
        let center = (b.min + b.max) / 2
        #expect(simd_length(center) < 1e-5)
    }

    @Test func centimetersOnlyApplyToOBJ() throws {
        let mesh = try SampleModel.meshData()
        var options = ExportOptions()
        options.pivot = .original
        options.units = .centimeters

        options.format = .obj
        #expect(abs(ExportService.prepare(mesh, realSize: nil, options: options).size.x - 30) < 1e-3)
        options.format = .glb
        #expect(abs(ExportService.prepare(mesh, realSize: nil, options: options).size.x - 0.30) < 1e-5)
    }

    @Test func unitCorrectionSnapsToPowersOfTen() {
        #expect(ExportService.unitCorrection(meshSize: [30, 15, 10], realSize: [0.3, 0.15, 0.1]) == 0.01)
        #expect(ExportService.unitCorrection(meshSize: [0.3, 0.15, 0.1], realSize: [0.3, 0.15, 0.1]) == 1)
        #expect(ExportService.unitCorrection(meshSize: [0.3, 0.15, 0.1], realSize: [0.301, 0.15, 0.1]) == 1)
        #expect(ExportService.unitCorrection(meshSize: .zero, realSize: [1, 1, 1]) == 1)
    }

    @Test func texturesShrinkButNeverGrow() throws {
        let big = try #require(TextureData(image: SampleModel.checkerImage(side: 512)))
        let small = ExportService.downscaled(big, maxSide: 128)
        #expect(small.width == 128 && small.height == 128)
        #expect(TextureData(encoded: small.data)?.width == 128)
        let same = ExportService.downscaled(big, maxSide: 1024)
        #expect(same == big)
    }

    @Test func fileNamesAreSafe() {
        #expect(ExportService.safeFileName("My Mug / v2:final") == "My Mug  v2final")
        #expect(ExportService.safeFileName("   ") == "Model")
    }

    @Test func endToEndExportWritesAllFormats() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = directory.appending(path: "model.usdz")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SampleModel.write(to: model)

        for format in ExportOptions.Format.allCases {
            var options = ExportOptions()
            options.format = format
            options.fileName = "Sample Box"
            let url = try ExportService.exportNow(
                modelURL: model, realSize: [0.3, 0.15, 0.1], options: options, to: directory.appending(path: "Exports")
            )
            #expect(url.lastPathComponent == "Sample Box.\(format.fileExtension)")
            let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int)
            #expect(size > 1000)
        }
    }
}
