import Foundation
import simd

/// Lowers a mesh's triangle count for games (LODs) with quadric error edge collapse
/// (Garland & Heckbert). Open edges are locked — on scanned meshes these are the
/// texture (UV) seams, so textures stay intact. Collapses that would flip a triangle are skipped.
enum MeshSimplifier {
    static func simplify(_ mesh: MeshData, targetTriangles: Int) -> MeshData {
        let faceCount = mesh.triangleCount
        guard targetTriangles < faceCount, faceCount > 4 else { return mesh }

        let vertexCount = mesh.vertexCount
        var positions = mesh.positions.map { SIMD3<Double>($0) }
        var normals = mesh.normals
        var uvs = mesh.uvs
        var corners = mesh.indices.map(Int.init) // 3 per face
        var alive = [Bool](repeating: true, count: faceCount)
        var vertexFaces = [[Int]](repeating: [], count: vertexCount)
        var quadrics = [Quadric](repeating: Quadric(), count: vertexCount)

        // Quadrics from each face's plane, weighted by area.
        for f in 0..<faceCount {
            let a = corners[3 * f], b = corners[3 * f + 1], c = corners[3 * f + 2]
            if a == b || b == c || a == c {
                alive[f] = false
                continue
            }
            let cross = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            let length = simd_length(cross)
            if length > 1e-18 {
                let normal = cross / length
                let q = Quadric(normal: normal, d: -simd_dot(normal, positions[a])) * (length / 2)
                quadrics[a] += q; quadrics[b] += q; quadrics[c] += q
            }
            vertexFaces[a].append(f); vertexFaces[b].append(f); vertexFaces[c].append(f)
        }

        // Lock vertices on open or non-manifold edges.
        var edgeUse: [UInt64: Int] = [:]
        edgeUse.reserveCapacity(faceCount * 3)
        for f in 0..<faceCount where alive[f] {
            for k in 0..<3 {
                edgeUse[edgeKey(corners[3 * f + k], corners[3 * f + (k + 1) % 3]), default: 0] += 1
            }
        }
        var locked = [Bool](repeating: false, count: vertexCount)
        for (key, uses) in edgeUse where uses != 2 {
            locked[Int(key >> 32)] = true
            locked[Int(key & 0xFFFF_FFFF)] = true
        }

        var version = [Int](repeating: 0, count: vertexCount)
        var removed = [Bool](repeating: false, count: vertexCount)
        var heap = MinHeap()

        func candidate(_ a: Int, _ b: Int) -> Candidate? {
            if locked[a] && locked[b] { return nil }
            let q = quadrics[a] + quadrics[b]
            var options: [(to: Int, from: Int, pos: SIMD3<Double>, mid: Bool)] = []
            if locked[a] {
                options = [(a, b, positions[a], false)]
            } else if locked[b] {
                options = [(b, a, positions[b], false)]
            } else {
                options = [(a, b, positions[a], false), (b, a, positions[b], false), (a, b, (positions[a] + positions[b]) / 2, true)]
            }
            let best = options.min { q.error($0.pos) < q.error($1.pos) }!
            return Candidate(
                cost: max(0, q.error(best.pos)), from: best.from, to: best.to, position: best.pos,
                isMidpoint: best.mid, fromVersion: version[best.from], toVersion: version[best.to]
            )
        }

        for key in edgeUse.keys {
            if let c = candidate(Int(key >> 32), Int(key & 0xFFFF_FFFF)) { heap.push(c) }
        }

        var liveFaces = alive.lazy.filter { $0 }.count

        func flips(_ c: Candidate) -> Bool {
            for f in vertexFaces[c.from] + vertexFaces[c.to] where alive[f] {
                let v = [corners[3 * f], corners[3 * f + 1], corners[3 * f + 2]]
                if v.contains(c.from) && v.contains(c.to) { continue } // this face disappears
                let old = v.map { positions[$0] }
                let new = v.map { ($0 == c.from || $0 == c.to) ? c.position : positions[$0] }
                let oldNormal = simd_cross(old[1] - old[0], old[2] - old[0])
                let newNormal = simd_cross(new[1] - new[0], new[2] - new[0])
                let newLength = simd_length(newNormal), oldLength = simd_length(oldNormal)
                if newLength < 1e-18 { return true }
                if oldLength > 1e-18, simd_dot(oldNormal / oldLength, newNormal / newLength) < 0.2 { return true }
            }
            return false
        }

        while liveFaces > targetTriangles, let c = heap.pop() {
            guard !removed[c.from], !removed[c.to],
                  version[c.from] == c.fromVersion, version[c.to] == c.toVersion,
                  !flips(c) else { continue }

            // Collapse `from` into `to`.
            for f in vertexFaces[c.from] where alive[f] {
                let range = (3 * f)..<(3 * f + 3)
                if corners[range].contains(c.to) {
                    alive[f] = false
                    liveFaces -= 1
                } else {
                    for i in range where corners[i] == c.from { corners[i] = c.to }
                    vertexFaces[c.to].append(f)
                }
            }
            if c.isMidpoint {
                if !uvs.isEmpty { uvs[c.to] = (uvs[c.to] + uvs[c.from]) / 2 }
                if !normals.isEmpty {
                    let sum = normals[c.to] + normals[c.from]
                    normals[c.to] = simd_length(sum) > 1e-6 ? simd_normalize(sum) : normals[c.to]
                }
            }
            positions[c.to] = c.position
            quadrics[c.to] += quadrics[c.from]
            removed[c.from] = true
            vertexFaces[c.from] = []
            vertexFaces[c.to] = vertexFaces[c.to].filter { alive[$0] }
            version[c.to] += 1

            var neighbors = Set<Int>()
            for f in vertexFaces[c.to] {
                for i in (3 * f)..<(3 * f + 3) where corners[i] != c.to { neighbors.insert(corners[i]) }
            }
            for n in neighbors {
                if let next = candidate(c.to, n) { heap.push(next) }
            }
        }

        // Keep only used vertices.
        var remap = [Int](repeating: -1, count: vertexCount)
        var out = MeshData(positions: [], normals: [], uvs: [], indices: [], material: mesh.material)
        for f in 0..<faceCount where alive[f] {
            for i in (3 * f)..<(3 * f + 3) {
                let v = corners[i]
                if remap[v] < 0 {
                    remap[v] = out.positions.count
                    out.positions.append(SIMD3<Float>(positions[v]))
                    if !normals.isEmpty { out.normals.append(normals[v]) }
                    if !uvs.isEmpty { out.uvs.append(uvs[v]) }
                }
                out.indices.append(UInt32(remap[v]))
            }
        }
        return out
    }

    static func edgeKey(_ a: Int, _ b: Int) -> UInt64 {
        let lo = UInt64(min(a, b)), hi = UInt64(max(a, b))
        return lo << 32 | hi
    }

    // MARK: - Types

    struct Candidate {
        var cost: Double
        var from: Int
        var to: Int
        var position: SIMD3<Double>
        var isMidpoint: Bool
        var fromVersion: Int
        var toVersion: Int
    }

    /// Symmetric 4×4 error quadric, stored as its 10 unique values.
    struct Quadric {
        var a = [Double](repeating: 0, count: 10)

        init() {}

        init(normal n: SIMD3<Double>, d: Double) {
            a = [n.x * n.x, n.x * n.y, n.x * n.z, n.x * d,
                 n.y * n.y, n.y * n.z, n.y * d,
                 n.z * n.z, n.z * d,
                 d * d]
        }

        static func + (l: Quadric, r: Quadric) -> Quadric {
            var q = Quadric()
            for i in 0..<10 { q.a[i] = l.a[i] + r.a[i] }
            return q
        }

        static func += (l: inout Quadric, r: Quadric) { l = l + r }

        static func * (l: Quadric, s: Double) -> Quadric {
            var q = l
            for i in 0..<10 { q.a[i] *= s }
            return q
        }

        /// Squared distance-to-planes error for a point.
        func error(_ p: SIMD3<Double>) -> Double {
            let x = p.x, y = p.y, z = p.z
            return a[0] * x * x + 2 * a[1] * x * y + 2 * a[2] * x * z + 2 * a[3] * x
                + a[4] * y * y + 2 * a[5] * y * z + 2 * a[6] * y
                + a[7] * z * z + 2 * a[8] * z
                + a[9]
        }
    }

    struct MinHeap {
        private var items: [Candidate] = []

        mutating func push(_ item: Candidate) {
            items.append(item)
            var i = items.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                guard items[i].cost < items[parent].cost else { break }
                items.swapAt(i, parent)
                i = parent
            }
        }

        mutating func pop() -> Candidate? {
            guard !items.isEmpty else { return nil }
            items.swapAt(0, items.count - 1)
            let top = items.removeLast()
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var smallest = i
                if l < items.count, items[l].cost < items[smallest].cost { smallest = l }
                if r < items.count, items[r].cost < items[smallest].cost { smallest = r }
                if smallest == i { break }
                items.swapAt(i, smallest)
                i = smallest
            }
            return top
        }
    }
}
