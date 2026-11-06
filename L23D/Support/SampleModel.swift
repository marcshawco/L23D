#if DEBUG
import CoreGraphics
import Foundation
import ModelIO
import SwiftData

/// Debug-only test model so the library, viewer and export can be tried in the Simulator,
/// which has no camera. Makes a textured box (30 × 15 × 10 cm) and saves it as USDZ.
@MainActor
enum SampleModel {
    static func addSampleScan(to context: ModelContext) async throws -> Scan {
        let scan = Scan(name: "Sample Box", mode: .object)
        let folder = scan.folder
        try folder.create()
        try write(to: folder.modelFile)

        let stats = try await ModelInspector.stats(for: folder.modelFile)
        await ModelInspector.writeThumbnail(for: folder.modelFile, to: folder.thumbnail)

        scan.status = .ready
        scan.triangleCount = stats.triangleCount
        scan.size = SIMD3(Double(stats.size.x), Double(stats.size.y), Double(stats.size.z))
        context.insert(scan)
        try context.save()
        return scan
    }

    nonisolated static func meshData() throws -> MeshData {
        let box = MDLMesh(
            boxWithExtent: [0.30, 0.15, 0.10], segments: [1, 1, 1], inwardNormals: false,
            geometryType: .triangles, allocator: MDLMeshBufferDataAllocator()
        )
        var mesh = try MeshLoader.meshData(from: box)
        var material = MaterialData()
        material.baseColor = TextureData(image: checkerImage())
        material.roughnessFactor = 0.6
        mesh.material = material
        return mesh
    }

    nonisolated static func write(to url: URL) throws {
        try USDZWriter.write(meshData(), to: url, name: "SampleBox")
    }

    /// 512 × 512 colorful checkerboard so UV and orientation problems are easy to spot.
    nonisolated static func checkerImage(side: Int = 512, cells: Int = 8) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let cell = CGFloat(side) / CGFloat(cells)
        for row in 0..<cells {
            for col in 0..<cells {
                let hue = CGFloat(row * cells + col) / CGFloat(cells * cells)
                let dark = (row + col).isMultiple(of: 2)
                let (r, g, b) = hsbToRGB(hue: hue, saturation: 0.7, brightness: dark ? 0.55 : 0.95)
                context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
                context.fill(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
            }
        }
        return context.makeImage()!
    }

    nonisolated private static func hsbToRGB(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let h = hue * 6
        let i = floor(h)
        let f = h - i
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))
        switch Int(i) % 6 {
        case 0: return (brightness, t, p)
        case 1: return (q, brightness, p)
        case 2: return (p, brightness, t)
        case 3: return (p, q, brightness)
        case 4: return (t, p, brightness)
        default: return (brightness, p, q)
        }
    }
}
#endif
