import ARKit
import AVFoundation
import Foundation
import RealityKit
import simd

/// What the helper-capture screen shows. Updated from the engine on the main actor.
@MainActor
@Observable
final class HelperCaptureModel {
    enum Phase: Equatable {
        case starting
        case aiming
        case capturing
        case saving
        case done(Int)
        case failed(String)
    }

    var phase: Phase = .starting
    var cells = [Bool](repeating: false, count: CoverageTracker.rings * CoverageTracker.slices)
    var currentCell: Int?
    var shots = 0
    var hint: String?
    /// True once the camera sees something at a usable distance in the middle of the screen.
    var canStart = false
    var subjectDistance: Float?

    static let minimumShots = 20
}

/// Runs ARKit for the "helper walks around a still person" mode.
///
/// Each time the phone reaches a new spot on the coverage ring, steady and sharp,
/// it takes a full-resolution photo, cuts out the person (Vision + LiDAR depth),
/// and saves photo, mask, depth and camera pose.
final class HelperCaptureEngine: NSObject, ARSessionDelegate, @unchecked Sendable {
    let session: ARSession
    private let model: HelperCaptureModel
    private let frameQueue = DispatchQueue(label: "l23d.helper.frames", qos: .userInteractive)
    private let workQueue = DispatchQueue(label: "l23d.helper.work", qos: .userInitiated)

    // --- frameQueue state ---
    private var tracker: CoverageTracker?
    private var isCapturing = false
    private var isFinished = false
    private var captureInFlight = false
    private var lastTransform: simd_float4x4?
    private var lastTimestamp: TimeInterval = 0
    private var lastUIUpdate: TimeInterval = 0
    private var latestDepth: PersonMasker.DepthMap?
    private var latestCenterDepth: Float?
    private var frameCounter = 0
    private let maxShots = min(PhotogrammetrySession.limits.maximumNumberOfInputImages, CoverageTracker.rings * CoverageTracker.slices)

    // --- workQueue state ---
    private let store: PersonFrameStore

    @MainActor
    init(session: ARSession, folder: ScanFolder, model: HelperCaptureModel) throws {
        self.session = session
        self.model = model
        store = try PersonFrameStore(folder: folder, mode: .personHelper)
        super.init()
    }

    // MARK: - Control (call from the main actor)

    @MainActor
    func start() {
        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            configuration.videoFormat = format
        }
        configuration.isAutoFocusEnabled = true
        session.delegateQueue = frameQueue
        session.delegate = self
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        model.phase = .aiming
    }

    /// Fixes the person's position (from the middle of the screen) and starts auto-capture.
    @MainActor
    func beginCapture() {
        frameQueue.async { [self] in
            guard let transform = lastTransform, let depth = latestCenterDepth else { return }
            let position = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            let forward = -SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            // The screen center hits the front of the body; the middle is a bit further in.
            let center = position + simd_normalize(forward) * (depth + 0.12)
            tracker = CoverageTracker(center: center, startCamera: position)
            isCapturing = true
            Self.lockCameraSettings()
            Task { @MainActor [model] in model.phase = .capturing }
        }
    }

    /// Stops capturing and writes the frame list. The model moves to `.done(count)`.
    @MainActor
    func finish() {
        model.phase = .saving
        frameQueue.async { [self] in
            isCapturing = false
            // Give an in-flight photo a moment to arrive, then close the list.
            frameQueue.asyncAfter(deadline: .now() + 0.6) { [self] in
                isFinished = true
                workQueue.async { [self] in
                    do {
                        try store.writeManifest()
                        let count = store.count
                        Task { @MainActor [model] in model.phase = .done(count) }
                    } catch {
                        let message = "Couldn't save the photos: \(error.localizedDescription)"
                        Task { @MainActor [model] in model.phase = .failed(message) }
                    }
                }
            }
        }
    }

    @MainActor
    func stop() {
        session.pause()
        Self.unlockCameraSettings()
    }

    // MARK: - ARSessionDelegate (frameQueue)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameCounter += 1
        let transform = frame.camera.transform
        let timestamp = frame.timestamp
        defer {
            lastTransform = transform
            lastTimestamp = timestamp
        }

        // Depth: copy a few times a second (copying every frame is wasteful).
        if frameCounter % 3 == 0, let depthBuffer = frame.sceneDepth?.depthMap,
           let depth = PersonMasker.readDepth(depthBuffer) {
            latestDepth = depth
            latestCenterDepth = PersonMasker.centerDepth(depth)
        }

        let trackingOK: Bool = if case .normal = frame.camera.trackingState { true } else { false }

        guard isCapturing, !isFinished, var tracker else {
            updateAimingUI(timestamp: timestamp, trackingOK: trackingOK)
            return
        }

        let position = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        var hint: String?
        var current: Int?

        switch tracker.placement(of: position) {
        case .tooClose:
            hint = "Step back a little"
        case .tooFar:
            hint = "Move closer"
        case .cell(let cell):
            current = cell.index
            if !trackingOK {
                hint = "Move slowly — tracking"
            } else if let last = lastTransform, !FrameQuality.isSteady(from: last, to: transform, dt: timestamp - lastTimestamp) {
                hint = "Slow down"
            } else if !tracker.isFilled(cell), !captureInFlight, tracker.filled.count < maxShots {
                if FrameQuality.sharpness(of: frame.capturedImage) >= FrameQuality.sharpnessThreshold {
                    tracker.fill(cell)
                    self.tracker = tracker
                    capture(cell: cell, transform: transform, center: tracker.center)
                } else {
                    hint = "Hold steady"
                }
            } else if tracker.isFilled(cell) {
                hint = nextHint(tracker)
            }
        }

        if timestamp - lastUIUpdate > 0.1 || hint != nil {
            lastUIUpdate = timestamp
            let cells = tracker.cells
            Task { @MainActor [model] in
                model.cells = cells
                model.currentCell = current
                model.hint = hint
            }
        }
        if tracker.filled.count >= maxShots {
            Task { @MainActor [self] in finish() }
            isCapturing = false
        }
    }

    func session(_ session: ARSession, didFailWithError error: any Error) {
        let message = "The camera stopped: \(error.localizedDescription)"
        Task { @MainActor [model] in model.phase = .failed(message) }
    }

    // MARK: - Capture

    private func capture(cell: CoverageTracker.Cell, transform: simd_float4x4, center: SIMD3<Float>) {
        captureInFlight = true
        let position = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let subjectDistance = simd_length(center - position)
        let fallbackDepth = latestDepth

        session.captureHighResolutionFrame { [self] frame, _ in
            // Runs on frameQueue.
            captureInFlight = false
            guard let frame, !isFinished else {
                tracker?.unfill(cell) // try this spot again
                return
            }
            let image = Box(frame.capturedImage)
            let depth = frame.sceneDepth.flatMap { PersonMasker.readDepth($0.depthMap) } ?? fallbackDepth
            let pose = frame.camera.transform
            workQueue.async { [self] in
                let mask = try? PersonMasker.mask(for: image.value, depth: depth, subjectDistance: subjectDistance)
                // Skip photos where the person cutout is nearly empty (they walked out of frame).
                if let mask, mask.coverage < 0.01 { return }
                if let count = try? store.add(image: image.value, mask: mask, depth: depth, cameraTransform: pose, cell: cell) {
                    Task { @MainActor [model] in
                        model.shots = count
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func updateAimingUI(timestamp: TimeInterval, trackingOK: Bool) {
        guard !isCapturing, timestamp - lastUIUpdate > 0.15 else { return }
        lastUIUpdate = timestamp
        let distance = latestCenterDepth
        let canStart = trackingOK && distance.map { $0 > 0.4 && $0 < 3.5 } == true
        let hint: String? = if !trackingOK {
            "Move the phone slowly to start tracking"
        } else if let distance, distance <= 0.4 {
            "Step back from the person"
        } else if let distance, distance >= 3.5 {
            "Move closer to the person"
        } else if distance == nil {
            "Point the circle at the person's chest"
        } else {
            nil
        }
        Task { @MainActor [model] in
            model.canStart = canStart
            model.subjectDistance = distance
            model.hint = hint
        }
    }

    private func nextHint(_ tracker: CoverageTracker) -> String? {
        if tracker.fraction(ring: 1) < 0.9 { return "Keep walking around at chest height" }
        if tracker.fraction(ring: 0) < 0.6 { return "Now crouch and go around low" }
        if tracker.fraction(ring: 2) < 0.6 { return "Now raise the phone and go around high" }
        return "Looking good — tap Finish when ready"
    }

    /// Locks exposure, white balance and focus so every photo matches.
    private static func lockCameraSettings() {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera,
              (try? device.lockForConfiguration()) != nil else { return }
        if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
        if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
        if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
        device.unlockForConfiguration()
    }

    private static func unlockCameraSettings() {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera,
              (try? device.lockForConfiguration()) != nil else { return }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        device.unlockForConfiguration()
    }
}

/// Carries a non-Sendable value across queues when we know only one queue uses it at a time.
struct Box<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
