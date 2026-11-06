import Foundation
import ModelIO
import simd
import Testing
@testable import L23D

struct MeshSimplifierTests {
    private func sphere(segments: UInt32 = 48) throws -> MeshData {
        let mdl = MDLMesh(
            sphereWithExtent: [0.4, 0.4, 0.4], segments: [segments, segments], inwardNormals: false,
            geometryType: .triangles, allocator: MDLMeshBufferDataAllocator()
        )
        return try MeshLoader.meshData(from: mdl)
    }

    /// Flat n×n grid of quads in the XZ plane, 1 m across, with UVs.
    private func grid(_ n: Int) -> MeshData {
        var positions: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
        for z in 0...n {
            for x in 0...n {
                positions.append([Float(x) / Float(n), 0, Float(z) / Float(n)])
                uvs.append([Float(x) / Float(n), Float(z) / Float(n)])
                normals.append([0, 1, 0])
            }
        }
        let row = n + 1
        for z in 0..<n {
            for x in 0..<n {
                let a = UInt32(z * row + x), b = a + 1, c = a + UInt32(row), d = c + 1
                indices += [a, c, b, b, c, d]
            }
        }
        return MeshData(positions: positions, normals: normals, uvs: uvs, indices: indices, material: MaterialData())
    }

    @Test func halvesASphere() throws {
        let mesh = try sphere()
        let target = mesh.triangleCount / 2
        let simple = MeshSimplifier.simplify(mesh, targetTriangles: target)
        try simple.validate()
        #expect(simple.triangleCount <= target + 2)
        #expect(simple.triangleCount > target / 2)
        #expect(simple.uvs.count == simple.vertexCount)
        // Shape stays the same size.
        let before = mesh.size, after = simple.size
        #expect(abs(after.x - before.x) / before.x < 0.05)
        #expect(abs(after.y - before.y) / before.y < 0.05)
    }

    @Test func handlesScanSizedMeshes() throws {
        let mesh = try sphere(segments: 140) // ~39k triangles, close to an on-phone scan
        let start = Date()
        let simple = MeshSimplifier.simplify(mesh, targetTriangles: mesh.triangleCount / 10)
        let seconds = Date().timeIntervalSince(start)
        try simple.validate()
        #expect(simple.triangleCount <= mesh.triangleCount / 10 + 2)
        print("SIMPLIFY \(mesh.triangleCount) -> \(simple.triangleCount) in \(seconds) s")
        #expect(seconds < 30)
    }

    @Test func flatGridCollapsesButKeepsItsEdges() throws {
        let mesh = grid(20) // 800 triangles
        let simple = MeshSimplifier.simplify(mesh, targetTriangles: 200)
        try simple.validate()
        #expect(simple.triangleCount <= 200)
        let b = simple.bounds
        #expect(b.min.x == 0 && b.max.x == 1 && b.min.z == 0 && b.max.z == 1, "border is locked")
        #expect(simple.positions.allSatisfy { $0.y == 0 }, "stays flat")
    }

    @Test func nothingToDoReturnsTheSameMesh() throws {
        let mesh = grid(4)
        #expect(MeshSimplifier.simplify(mesh, targetTriangles: 1000).triangleCount == mesh.triangleCount)
    }

    @Test func exportDetailOptionShrinksTheMesh() throws {
        let mesh = try sphere()
        var options = ExportOptions()
        options.detail = .medium
        let prepared = ExportService.prepare(mesh, realSize: nil, options: options)
        #expect(prepared.triangleCount <= Int(Double(mesh.triangleCount) * 0.25) + 2)
        #expect(!ExportOptions(format: .usdz, detail: .low, pivot: .original).isPassThrough)
    }

    @Test func quadricErrorIsZeroOnThePlane() {
        let q = MeshSimplifier.Quadric(normal: [0, 1, 0], d: -2) // plane y = 2
        #expect(q.error([5, 2, -3]) == 0)
        #expect(abs(q.error([0, 3, 0]) - 1) < 1e-12)
    }
}

struct SystemStatusTests {
    @Test func thermalWarnings() {
        #expect(SystemStatus.thermalWarning(for: .nominal) == nil)
        #expect(SystemStatus.thermalWarning(for: .fair) == nil)
        #expect(SystemStatus.thermalWarning(for: .serious) != nil)
        #expect(SystemStatus.thermalWarning(for: .critical)?.contains("too hot") == true)
    }

    @Test func storageWarnings() {
        #expect(SystemStatus.storageWarning(freeBytes: nil) == nil)
        #expect(SystemStatus.storageWarning(freeBytes: 50_000_000_000) == nil)
        #expect(SystemStatus.storageWarning(freeBytes: 500_000_000) != nil)
    }
}

struct DeletePhotosTests {
    @Test func keepsModelAndExports() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "del-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = ScanStore.folder(for: UUID(), base: base)
        try folder.create()
        try Data([1]).write(to: folder.images.appending(path: "0001.jpg"))
        try Data([1]).write(to: folder.modelFile)
        try Data([1]).write(to: folder.exports.appending(path: "a.glb"))
        try Data([1]).write(to: folder.personManifest)

        try folder.deleteCaptureData()
        #expect(folder.imageCount == 0)
        #expect(!folder.isPersonScan)
        #expect(folder.hasModel)
        #expect(FileManager.default.fileExists(atPath: folder.exports.appending(path: "a.glb").path(percentEncoded: false)))
    }
}
