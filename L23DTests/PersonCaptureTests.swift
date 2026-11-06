import CoreVideo
import Foundation
import simd
import Testing
@testable import L23D

struct CoverageTrackerTests {
    private let center = SIMD3<Float>(0, 1.2, 0)

    @Test func startPositionIsSliceZeroAtChestHeight() {
        let start = SIMD3<Float>(0, 1.2, 1.5)
        let tracker = CoverageTracker(center: center, startCamera: start)
        #expect(tracker.placement(of: start) == .cell(.init(ring: 1, slice: 0)))
    }

    @Test func walkingAroundVisitsEverySlice() {
        let tracker = CoverageTracker(center: center, startCamera: [0, 1.2, 1.5])
        var slices = Set<Int>()
        for step in 0..<360 {
            let angle = Float(step) * .pi / 180
            let position = SIMD3<Float>(1.5 * sin(angle), 1.2, 1.5 * cos(angle))
            if case .cell(let cell) = tracker.placement(of: position) { slices.insert(cell.slice) }
        }
        #expect(slices.count == CoverageTracker.slices)
    }

    @Test func heightPicksTheRing() {
        let tracker = CoverageTracker(center: center, startCamera: [0, 1.2, 1.5])
        #expect(tracker.placement(of: [0, 0.4, 1.5]) == .cell(.init(ring: 0, slice: 0)))  // crouched
        #expect(tracker.placement(of: [0, 2.2, 1.5]) == .cell(.init(ring: 2, slice: 0)))  // raised
    }

    @Test func distanceLimits() {
        let tracker = CoverageTracker(center: center, startCamera: [0, 1.2, 1.5])
        #expect(tracker.placement(of: [0, 1.2, 0.2]) == .tooClose)
        #expect(tracker.placement(of: [0, 1.2, 6]) == .tooFar)
    }

    @Test func fillAndUnfill() {
        var tracker = CoverageTracker(center: center, startCamera: [0, 1.2, 1.5])
        let cell = CoverageTracker.Cell(ring: 1, slice: 3)
        tracker.fill(cell)
        #expect(tracker.isFilled(cell))
        #expect(tracker.fraction(ring: 1) == 1.0 / Double(CoverageTracker.slices))
        tracker.unfill(cell)
        #expect(!tracker.isFilled(cell))
        #expect(tracker.cells.count == CoverageTracker.rings * CoverageTracker.slices)
    }
}

struct FrameQualityTests {
    private func sharpness(_ pixels: [UInt8], size: Int) -> Double {
        pixels.withUnsafeBufferPointer { FrameQuality.sharpness(gray: $0, width: size, height: size, bytesPerRow: size) }
    }

    @Test func sharpEdgesScoreHigherThanFlatGray() {
        let size = 200
        let flat = [UInt8](repeating: 128, count: size * size)
        var checker = [UInt8](repeating: 0, count: size * size)
        for y in 0..<size { for x in 0..<size { checker[y * size + x] = ((x / 6 + y / 6) % 2 == 0) ? 255 : 0 } }
        #expect(sharpness(flat, size: size) < 1)
        #expect(sharpness(checker, size: size) > FrameQuality.sharpnessThreshold)
    }

    @Test func steadinessCheck() {
        let a = matrix_identity_float4x4
        var slowMove = a
        slowMove.columns.3 = [0.01, 0, 0, 1]
        #expect(FrameQuality.isSteady(from: a, to: slowMove, dt: 1.0 / 30))  // 0.3 m/s
        var fastMove = a
        fastMove.columns.3 = [0.1, 0, 0, 1]
        #expect(!FrameQuality.isSteady(from: a, to: fastMove, dt: 1.0 / 30)) // 3 m/s
        let spin = simd_float4x4(simd_quatf(angle: 0.1, axis: [0, 1, 0]))
        #expect(!FrameQuality.isSteady(from: a, to: spin, dt: 1.0 / 30))     // 3 rad/s
    }
}

struct PersonMaskerTests {
    @Test func depthBandRemovesBackground() {
        // 4×1 cutout: Vision says all four pixels are "person".
        let segmentation: [UInt8] = [255, 255, 255, 255]
        // Depth: person at 1.5 m, wall at 4 m, unknown (0), slightly off (1.9 m).
        let depth = PersonMasker.DepthMap(values: [1.5, 4.0, 0, 1.9], width: 4, height: 1)
        let mask = PersonMasker.combine(segmentation: segmentation, width: 4, height: 1, depth: depth, subjectDistance: 1.5)
        #expect(mask.pixels == [255, 0, 255, 255])
    }

    @Test func lowConfidenceIsDropped() {
        let mask = PersonMasker.combine(segmentation: [10, 200], width: 2, height: 1, depth: nil, subjectDistance: nil)
        #expect(mask.pixels == [0, 255])
        #expect(mask.coverage == 0.5)
    }

    @Test func centerDepthIgnoresBadValues() {
        var values = [Float](repeating: 2.0, count: 9 * 9)
        values[40] = .nan
        values[41] = 0
        let depth = PersonMasker.DepthMap(values: values, width: 9, height: 9)
        #expect(PersonMasker.centerDepth(depth) == 2.0)
        #expect(PersonMasker.centerDepth(.init(values: [Float](repeating: 0, count: 4), width: 2, height: 2)) == nil)
    }
}

struct PersonFrameStoreTests {
    private func tempFolder() -> ScanFolder {
        ScanStore.folder(for: UUID(), base: FileManager.default.temporaryDirectory.appending(path: "person-\(UUID().uuidString)"))
    }

    private func bgraBuffer(width: Int, height: Int) -> CVPixelBuffer {
        let buffer = PersonSampleSequence.pixelBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA)!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height { for x in 0..<width * 4 { base[y * rowBytes + x] = UInt8((x + y) % 256) } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    @Test func savesAndReloadsFramesAsSamples() throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder.root.deletingLastPathComponent()) }
        let store = try PersonFrameStore(folder: folder, mode: .personHelper)

        let mask = PersonMasker.Mask(pixels: [UInt8](repeating: 255, count: 16 * 12), width: 16, height: 12)
        let depth = PersonMasker.DepthMap(values: [Float](repeating: 1.5, count: 8 * 6), width: 8, height: 6)
        for slice in 0..<3 {
            try store.add(
                image: bgraBuffer(width: 64, height: 48), mask: mask, depth: depth,
                cameraTransform: matrix_identity_float4x4, cell: .init(ring: 1, slice: slice)
            )
        }
        try store.writeManifest()

        #expect(folder.isPersonScan)
        #expect(folder.imageCount == 3)
        let manifest = try PersonFrameStore.loadManifest(from: folder)
        #expect(manifest.frames.count == 3)
        #expect(manifest.mode == "personHelper")

        let samples = Array(PersonSampleSequence(folder: folder, manifest: manifest))
        #expect(samples.count == 3)
        let first = try #require(samples.first)
        #expect(CVPixelBufferGetWidth(first.image) == 64)
        let objectMask = try #require(first.objectMask)
        #expect(CVPixelBufferGetWidth(objectMask) == 64, "mask is stretched to the photo size")
        #expect(CVPixelBufferGetHeight(objectMask) == 48)
        let depthMap = try #require(first.depthDataMap)
        #expect(CVPixelBufferGetWidth(depthMap) == 8)
        #expect(CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32)
        let gravity = try #require(first.gravity)
        #expect(abs(gravity.y + 1) < 1e-6, "level camera: gravity points down the image's y axis")
    }

    @Test func sampleLimitKeepsAnEvenSpread() {
        let frames = (1...100).map {
            PersonCaptureManifest.Frame(index: $0, image: "Images/\($0).jpg", mask: nil, depth: nil,
                                        depthWidth: 0, depthHeight: 0, cameraTransform: nil, ring: 1, slice: 0)
        }
        let sequence = PersonSampleSequence(folder: tempFolder(), manifest: .init(mode: "personHelper", frames: frames), limit: 25)
        #expect(sequence.frames.count == 25)
        #expect(sequence.frames.first?.index == 1)
        #expect(sequence.frames.last!.index > 90)
    }

    @Test func resetClearsPersonData() throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder.root.deletingLastPathComponent()) }
        let store = try PersonFrameStore(folder: folder, mode: .personHelper)
        try store.add(image: bgraBuffer(width: 8, height: 8), mask: nil, depth: nil, cameraTransform: nil, cell: .init(ring: 0, slice: 0))
        try store.writeManifest()
        try folder.resetCapture()
        #expect(!folder.isPersonScan)
        #expect(folder.imageCount == 0)
    }
}

struct SpinPlanTests {
    @Test func cuesRunFromStartToStop() {
        let plan = SpinPlan(spinDuration: 30)
        #expect(plan.cues.first?.time == 0)
        #expect(plan.cues.last?.time == 30)
        #expect(plan.cues.last?.text == "Stop.")
        #expect(plan.cues.map(\.time) == plan.cues.map(\.time).sorted())
    }

    @Test func slicesCoverTheWholeTurn() {
        let plan = SpinPlan(spinDuration: 30)
        #expect(plan.slice(at: 0) == 0)
        #expect(plan.slice(at: 15) == CoverageTracker.slices / 2)
        #expect(plan.slice(at: 30) == CoverageTracker.slices - 1)
        #expect(plan.slice(at: 99) == CoverageTracker.slices - 1)
        #expect(plan.slice(at: -1) == 0)
        #expect(plan.expectedShots == 75)
        #expect(plan.progress(at: 45) == 1)
    }
}

struct SpinGravityTests {
    @Test func uprightPhoneMatchesARKitConvention() {
        // Phone held upright in portrait: CoreMotion gravity points to the bottom of the phone.
        let fromMotion = PersonFrameStore.cameraGravity(fromDevice: [0, -1, 0])
        // ARKit camera for the same pose: camera x axis points down in the world.
        var pose = matrix_identity_float4x4
        pose.columns.0 = [0, -1, 0, 0] // camera x = world down
        pose.columns.1 = [1, 0, 0, 0]  // camera y = world right
        pose.columns.2 = [0, 0, 1, 0]
        let fromPose = PersonFrameStore.gravity(cameraTransform: pose)
        #expect(simd_distance(fromMotion, fromPose) < 1e-9)
        #expect(fromMotion == [1, 0, 0])
    }
}

struct BGRASharpnessTests {
    @Test func colorPhotosAreScored() {
        let size = 200
        let buffer = PersonSampleSequence.pixelBuffer(width: size, height: size, format: kCVPixelFormatType_32BGRA)!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<size {
            for x in 0..<size {
                let v: UInt8 = ((x / 6 + y / 6) % 2 == 0) ? 255 : 0
                for c in 0..<4 { base[y * rowBytes + x * 4 + c] = v }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        #expect(FrameQuality.sharpness(of: buffer) > FrameQuality.sharpnessThreshold)
    }
}
