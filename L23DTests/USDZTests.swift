import CoreGraphics
import Foundation
import RealityKit
import Testing
@testable import L23D

struct ZipTests {
    @Test func roundTripsStoredFiles() {
        var zip = ZipWriter(alignment: 64)
        let a = Data("hello usd".utf8)
        let b = Data((0..<1000).map { UInt8($0 % 251) })
        zip.add(name: "model.usda", data: a)
        zip.add(name: "textures/b.png", data: b)
        let archive = zip.finish()

        let entries = ZipReader.storedEntries(in: archive)
        #expect(entries.map(\.name) == ["model.usda", "textures/b.png"])
        #expect(entries.first?.data == a)
        #expect(entries.last?.data == b)
    }

    @Test func fileDataIsSixtyFourByteAligned() {
        var zip = ZipWriter(alignment: 64)
        zip.add(name: "a.usda", data: Data(repeating: 1, count: 37))
        zip.add(name: "textures/odd-name-length.png", data: Data(repeating: 2, count: 5))
        let bytes = [UInt8](zip.finish())

        // Walk local headers and check where each file's data begins.
        var offset = 0
        var checked = 0
        while offset + 30 < bytes.count,
              bytes[offset] == 0x50, bytes[offset + 1] == 0x4B, bytes[offset + 2] == 0x03, bytes[offset + 3] == 0x04 {
            let size = Int(bytes[offset + 18]) | Int(bytes[offset + 19]) << 8
            let nameLength = Int(bytes[offset + 26]) | Int(bytes[offset + 27]) << 8
            let extraLength = Int(bytes[offset + 28]) | Int(bytes[offset + 29]) << 8
            let dataStart = offset + 30 + nameLength + extraLength
            #expect(dataStart % 64 == 0)
            offset = dataStart + size
            checked += 1
        }
        #expect(checked == 2)
    }

    @Test func crc32MatchesKnownValue() {
        // Standard check value for "123456789".
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}

struct USDZRoundTripTests {
    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(name)")
    }

    @Test func sampleMeshIsValid() throws {
        let mesh = try SampleModel.meshData()
        try mesh.validate()
        #expect(mesh.triangleCount == 12)
        #expect(mesh.uvs.count == mesh.vertexCount)
        #expect(mesh.normals.count == mesh.vertexCount)
        #expect(mesh.material.baseColor != nil)
        let size = mesh.size
        #expect(abs(size.x - 0.30) < 0.001 && abs(size.y - 0.15) < 0.001 && abs(size.z - 0.10) < 0.001)
    }

    @Test func usdzRoundTripsThroughModelIO() throws {
        let url = tempURL("sample.usdz")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try SampleModel.meshData()
        try USDZWriter.write(original, to: url, name: "SampleBox")

        let entries = ZipReader.storedEntries(in: try Data(contentsOf: url))
        #expect(entries.first?.name == "model.usda")
        #expect(entries.contains { $0.name == "textures/baseColor.png" })

        let loaded = try MeshLoader.load(url: url)
        #expect(loaded.triangleCount == original.triangleCount)
        #expect(loaded.uvs.count == loaded.vertexCount)
        #expect(loaded.material.baseColor != nil)
        let size = loaded.size
        #expect(abs(size.x - 0.30) < 0.001 && abs(size.y - 0.15) < 0.001 && abs(size.z - 0.10) < 0.001)
    }

    @MainActor
    @Test func usdzLoadsInRealityKit() async throws {
        let url = tempURL("sample.usdz")
        defer { try? FileManager.default.removeItem(at: url) }
        try SampleModel.write(to: url)

        let stats = try await ModelInspector.stats(for: url)
        #expect(stats.triangleCount == 12)
        #expect(abs(stats.size.x - 0.30) < 0.001)
        #expect(abs(stats.size.y - 0.15) < 0.001)
        #expect(abs(stats.size.z - 0.10) < 0.001)
    }

    @MainActor
    @Test func thumbnailShowsTheModel() async throws {
        let url = tempURL("sample.usdz")
        defer { try? FileManager.default.removeItem(at: url) }
        try SampleModel.write(to: url)

        let image = try await ModelInspector.renderThumbnail(for: url, side: 128)
        #expect(image.width == 128 && image.height == 128)

        // Count pixels that differ from the plain gray background: the box must cover some of the frame.
        let context = CGContext(
            data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 128 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 128))
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: 128 * 128 * 4)
        let background = (Int(pixels[0]), Int(pixels[1]), Int(pixels[2]))
        var different = 0
        for i in stride(from: 0, to: 128 * 128 * 4, by: 4) {
            let dr = abs(Int(pixels[i]) - background.0)
            let dg = abs(Int(pixels[i + 1]) - background.1)
            let db = abs(Int(pixels[i + 2]) - background.2)
            if dr + dg + db > 30 { different += 1 }
        }
        #expect(different > 128 * 128 / 20, "model should cover at least 5% of the thumbnail, got \(different) px")
    }

    @Test func primNamesAreSanitized() {
        #expect(USDZWriter.sanitize("My Scan #1") == "My_Scan__1")
        #expect(USDZWriter.sanitize("3D") == "_3D")
        #expect(USDZWriter.sanitize("") == "Model")
    }

    @Test func textureSlotGuessing() {
        #expect(MeshLoader.guessSlot(for: "0/baseColor_0.png") == .baseColor)
        #expect(MeshLoader.guessSlot(for: "textures/normal.png") == .normal)
        #expect(MeshLoader.guessSlot(for: "0/roughness0.png") == .roughness)
        #expect(MeshLoader.guessSlot(for: "0/ao0.png") == .occlusion)
        #expect(MeshLoader.guessSlot(for: "model.usdc") == nil)
    }
}
