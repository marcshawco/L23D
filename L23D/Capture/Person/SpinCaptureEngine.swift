import AVFoundation
import CoreMotion
import Foundation
import RealityKit

/// What the spin-chair screen shows.
@MainActor
@Observable
final class SpinCaptureModel {
    enum Phase: Equatable {
        case starting
        case setup
        case countdown(Int)
        case spinning(pass: Int)
        case betweenSpins
        case saving
        case done(Int)
        case failed(String)
    }

    var phase: Phase = .starting
    var shots = 0
    var progress = 0.0
    var plan = SpinPlan()
    var passesDone = 0

    static let minimumShots = 20
}

/// Runs the LiDAR camera (no ARKit — the phone stays still on a tripod) and takes a photo
/// with depth every `shotInterval` seconds while the person turns on a swivel chair.
final class SpinCaptureEngine: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let captureSession = AVCaptureSession()
    private let model: SpinCaptureModel
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "l23d.spin.session")
    private let workQueue = DispatchQueue(label: "l23d.spin.work", qos: .userInitiated)
    private let motion = CMMotionManager()

    // Shared between queues; guarded by `lock`.
    private let lock = NSLock()
    private var pendingPhotos: [Int64: CoverageTracker.Cell] = [:]
    private var pendingWork = 0
    private var isFinished = false

    // sessionQueue only
    private var device: AVCaptureDevice?
    private var timer: DispatchSourceTimer?
    private var passStart = Date()
    private var plan = SpinPlan()
    private var pass = 1

    // workQueue only
    private let store: PersonFrameStore

    /// Limits how many full-size photos wait in memory at once (each is ~48 MB).
    private static let maxBacklog = 2

    @MainActor
    init(folder: ScanFolder, model: SpinCaptureModel) throws {
        self.model = model
        store = try PersonFrameStore(folder: folder, mode: .personSpin)
        super.init()
    }

    // MARK: - Control (main actor)

    @MainActor
    func start() {
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates()
        sessionQueue.async { [self] in
            do {
                try configure()
                captureSession.startRunning()
                Task { @MainActor [model] in model.phase = .setup }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                Task { @MainActor [model] in model.phase = .failed(message) }
            }
        }
    }

    @MainActor
    func startShooting(pass: Int, plan: SpinPlan) {
        sessionQueue.async { [self] in
            self.pass = pass
            self.plan = plan
            if pass == 1 { lockCameraSettings() }
            passStart = Date()
            let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
            timer.schedule(deadline: .now(), repeating: plan.shotInterval)
            timer.setEventHandler { [weak self] in self?.shoot() }
            timer.resume()
            self.timer = timer
        }
    }

    @MainActor
    func stopShooting() {
        sessionQueue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    /// Ends the scan and writes the frame list. The model moves to `.done(count)`.
    @MainActor
    func finish() {
        model.phase = .saving
        stopShooting()
        // Let in-flight photos land, then close the list.
        sessionQueue.asyncAfter(deadline: .now() + 1.0) { [self] in
            lock.withLock { isFinished = true }
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

    @MainActor
    func stop() {
        motion.stopDeviceMotionUpdates()
        sessionQueue.async { [self] in
            timer?.cancel()
            timer = nil
            unlockCameraSettings()
            if captureSession.isRunning { captureSession.stopRunning() }
        }
    }

    // MARK: - Setup (sessionQueue)

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) else {
            throw SpinError.noLiDARCamera
        }
        self.device = device
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        captureSession.sessionPreset = .inputPriority

        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input), captureSession.canAddOutput(photoOutput) else { throw SpinError.cameraSetup }
        captureSession.addInput(input)
        captureSession.addOutput(photoOutput)

        // Biggest format that also delivers LiDAR depth.
        let depthFormats = device.formats.filter { !$0.supportedDepthDataFormats.isEmpty && !$0.isVideoBinned }
        if let best = depthFormats.max(by: { Self.area($0.formatDescription) < Self.area($1.formatDescription) }) {
            try device.lockForConfiguration()
            device.activeFormat = best
            let floatDepth = best.supportedDepthDataFormats.filter {
                let type = CMFormatDescriptionGetMediaSubType($0.formatDescription)
                return type == kCVPixelFormatType_DepthFloat32 || type == kCVPixelFormatType_DepthFloat16
            }
            if let depthFormat = floatDepth.max(by: { Self.area($0.formatDescription) < Self.area($1.formatDescription) }) {
                device.activeDepthDataFormat = depthFormat
            }
            device.unlockForConfiguration()
            if let dimensions = best.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
                photoOutput.maxPhotoDimensions = dimensions
            }
        }
        photoOutput.maxPhotoQualityPrioritization = .balanced
        photoOutput.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliverySupported
    }

    private static func area(_ description: CMFormatDescription) -> Int32 {
        let d = CMVideoFormatDescriptionGetDimensions(description)
        return d.width * d.height
    }

    // MARK: - Shooting (sessionQueue)

    private func shoot() {
        let busy = lock.withLock { isFinished || pendingWork + pendingPhotos.count >= Self.maxBacklog }
        guard !busy else { return } // skip this tick; the next one is 0.4 s away

        let elapsed = Date().timeIntervalSince(passStart)
        let cell = CoverageTracker.Cell(ring: pass == 1 ? 1 : 2, slice: plan.slice(at: elapsed))
        let settings = AVCapturePhotoSettings(format: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        settings.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliveryEnabled
        settings.isDepthDataFiltered = true
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        settings.photoQualityPrioritization = .speed
        lock.withLock { pendingPhotos[settings.uniqueID] = cell }
        photoOutput.capturePhoto(with: settings, delegate: self)

        let progress = plan.progress(at: elapsed)
        Task { @MainActor [model] in model.progress = progress }
    }

    // MARK: - AVCapturePhotoCaptureDelegate

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        let (cell, finished): (CoverageTracker.Cell?, Bool) = lock.withLock {
            let cell = pendingPhotos.removeValue(forKey: photo.resolvedSettings.uniqueID)
            if cell != nil, !isFinished, error == nil { pendingWork += 1 }
            return (cell, isFinished)
        }
        guard let cell, !finished, error == nil, let pixelBuffer = photo.pixelBuffer else { return }

        let image = Box(pixelBuffer)
        let depth = photo.depthData
            .map { $0.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32) }
            .flatMap { PersonMasker.readDepth($0.depthDataMap) }
        let deviceGravity = motion.deviceMotion.map { SIMD3($0.gravity.x, $0.gravity.y, $0.gravity.z) }

        workQueue.async { [self] in
            defer { lock.withLock { pendingWork -= 1 } }
            guard FrameQuality.sharpness(of: image.value) >= FrameQuality.sharpnessThreshold else { return }
            let distance = depth.flatMap { PersonMasker.centerDepth($0) }
            let mask = try? PersonMasker.mask(for: image.value, depth: depth, subjectDistance: distance)
            if let mask, mask.coverage < 0.01 { return } // nobody in the chair
            let gravity = deviceGravity.map(PersonFrameStore.cameraGravity(fromDevice:))
            if let count = try? store.add(
                image: image.value, mask: mask, depth: depth, cameraTransform: nil, gravity: gravity, cell: cell
            ) {
                Task { @MainActor [model] in model.shots = count }
            }
        }
    }

    // MARK: - Camera lock

    private func lockCameraSettings() {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
        if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
        if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
        device.unlockForConfiguration()
    }

    private func unlockCameraSettings() {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        device.unlockForConfiguration()
    }
}

enum SpinError: LocalizedError {
    case noLiDARCamera
    case cameraSetup

    var errorDescription: String? {
        switch self {
        case .noLiDARCamera: "This iPhone has no LiDAR camera, which spin-chair scans need."
        case .cameraSetup: "Couldn't start the camera. Close other camera apps and try again."
        }
    }
}
