import Foundation
import Observation
import RealityKit
import SwiftData

/// Progress of one model build.
@MainActor
@Observable
final class ReconstructionJob {
    enum Phase: Equatable {
        case queued
        case running
        case finished
        case failed(String)
        case cancelled
    }

    let scanID: UUID
    var phase: Phase = .queued
    /// 0...1
    var fraction: Double = 0
    var stage: String?
    var remaining: TimeInterval?

    fileprivate var session: PhotogrammetrySession?
    fileprivate var cancelRequested = false

    init(scanID: UUID) {
        self.scanID = scanID
    }

    var isActive: Bool { phase == .queued || phase == .running }

    /// "About 3 min left"
    var remainingText: String? {
        guard let remaining, remaining > 0 else { return nil }
        let minutes = Int((remaining / 60).rounded(.up))
        return minutes <= 1 ? "Less than a minute left" : "About \(minutes) min left"
    }
}

/// Builds 3D models from photos, one at a time, on the phone.
///
/// Uses Apple's `PhotogrammetrySession`. On iPhone, Apple only allows the `.reduced`
/// detail level. Higher detail needs a Mac (planned HQ mode).
@MainActor
@Observable
final class ReconstructionCenter {
    private(set) var jobs: [UUID: ReconstructionJob] = [:]
    private var queue: [UUID] = []
    private var isRunning = false
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
        recoverInterruptedBuilds()
    }

    func job(for scanID: UUID) -> ReconstructionJob? {
        jobs[scanID]
    }

    /// Adds a scan to the build queue. Does nothing if it is already queued or running.
    func enqueue(_ scan: Scan) {
        if jobs[scan.id]?.isActive == true { return }
        let job = ReconstructionJob(scanID: scan.id)
        jobs[scan.id] = job
        queue.append(scan.id)
        scan.status = .processing
        scan.failureMessage = nil
        try? container.mainContext.save()
        runNextIfIdle()
    }

    func cancel(_ scanID: UUID) {
        guard let job = jobs[scanID] else { return }
        job.cancelRequested = true
        if let index = queue.firstIndex(of: scanID) {
            queue.remove(at: index)
            job.phase = .cancelled
            updateScan(scanID) { $0.status = .captured }
        }
        job.session?.cancel()
    }

    // MARK: - Running

    private func runNextIfIdle() {
        guard !isRunning, !queue.isEmpty else { return }
        let scanID = queue.removeFirst()
        guard let job = jobs[scanID] else {
            runNextIfIdle()
            return
        }
        isRunning = true
        Task {
            await run(job)
            isRunning = false
            runNextIfIdle()
        }
    }

    private func run(_ job: ReconstructionJob) async {
        let folder = ScanStore.folder(for: job.scanID)
        job.phase = .running
        job.fraction = 0
        job.stage = "Starting"

        // Keep building if the user switches apps. If iOS stops us, cancel cleanly;
        // the checkpoint lets the next build pick up where this one left off.
        let background = BackgroundBuildTask()
        var expired = false
        background.begin(scanName: scanName(job.scanID)) { [weak self] in
            expired = true
            self?.cancel(job.scanID)
        }

        do {
            try FileManager.default.createDirectory(at: folder.modelDirectory, withIntermediateDirectories: true)
            if folder.hasModel {
                try FileManager.default.removeItem(at: folder.modelFile)
            }

            let session = try ReconstructionSetup.makeSession(for: folder)
            job.session = session
            try session.process(requests: [.modelFile(url: folder.modelFile)])

            var requestError: (any Error)?
            var wasCancelled = false

            // The output stream doesn't end by itself; stop at completion or cancellation.
            outputLoop: for try await output in session.outputs {
                switch output {
                case .requestProgress(_, let fraction):
                    job.fraction = fraction
                    background.update(fraction: fraction, stage: job.stage)
                case .requestProgressInfo(_, let info):
                    job.remaining = info.estimatedRemainingTime
                    if let stage = info.processingStage {
                        job.stage = ReconstructionSetup.label(for: stage)
                    }
                case .requestError(_, let error):
                    requestError = error
                case .processingCancelled:
                    wasCancelled = true
                    break outputLoop
                case .processingComplete:
                    break outputLoop
                case .requestComplete, .inputComplete,
                     .invalidSample, .skippedSample, .automaticDownsampling, .stitchingIncomplete:
                    break
                @unknown default:
                    break
                }
            }
            job.session = nil

            if wasCancelled || job.cancelRequested {
                background.end(success: false)
                job.phase = .cancelled
                updateScan(job.scanID) { scan in
                    scan.status = .captured
                    if expired {
                        scan.failureMessage = "iOS paused the build in the background. Tap Build Model to continue."
                    }
                }
                return
            }
            if let requestError {
                throw requestError
            }
            guard folder.hasModel else {
                throw ReconstructionError.noModelProduced
            }

            job.stage = "Finishing up"
            let stats = try? await ModelInspector.stats(for: folder.modelFile)
            await ModelInspector.writeThumbnail(for: folder.modelFile, to: folder.thumbnail)

            updateScan(job.scanID) { scan in
                scan.status = .ready
                scan.failureMessage = nil
                if let stats {
                    scan.triangleCount = stats.triangleCount
                    scan.size = SIMD3(Double(stats.size.x), Double(stats.size.y), Double(stats.size.z))
                }
            }
            job.fraction = 1
            job.phase = .finished
            background.end(success: true)
        } catch {
            background.end(success: false)
            job.session = nil
            let message = Self.describe(error)
            job.phase = .failed(message)
            updateScan(job.scanID) { scan in
                scan.status = .failed
                scan.failureMessage = message
            }
        }
    }

    // MARK: - Helpers

    /// If the app was closed while building, mark those scans as "ready to build"
    /// so the user can tap Build again (the checkpoint lets it resume).
    private func recoverInterruptedBuilds() {
        let processing = ScanStatus.processing.rawValue
        let descriptor = FetchDescriptor<Scan>(predicate: #Predicate { $0.statusRaw == processing })
        guard let stuck = try? container.mainContext.fetch(descriptor), !stuck.isEmpty else { return }
        for scan in stuck {
            scan.status = .captured
            scan.failureMessage = "Building stopped when the app closed. Tap Build Model to continue."
        }
        try? container.mainContext.save()
    }

    private func scanName(_ scanID: UUID) -> String {
        let descriptor = FetchDescriptor<Scan>(predicate: #Predicate { $0.id == scanID })
        return (try? container.mainContext.fetch(descriptor).first?.name) ?? "Scan"
    }

    private func updateScan(_ scanID: UUID, _ change: (Scan) -> Void) {
        let context = container.mainContext
        let descriptor = FetchDescriptor<Scan>(predicate: #Predicate { $0.id == scanID })
        guard let scan = try? context.fetch(descriptor).first else { return }
        change(scan)
        try? context.save()
    }

    static func describe(_ error: any Error) -> String {
        if let sessionError = error as? PhotogrammetrySession.Error {
            switch sessionError {
            case .insufficientStorage:
                return "Not enough free storage to build the model. Free up some space and try again."
            case .invalidImages:
                return "The photos couldn't be used. Try scanning again with more light and slower moves."
            case .invalidOutput:
                return "Couldn't save the model file."
            @unknown default:
                return sessionError.localizedDescription
            }
        }
        if let reconstructionError = error as? ReconstructionError {
            return reconstructionError.message
        }
        return "Building failed: \(error.localizedDescription)"
    }
}

enum ReconstructionError: Error {
    case noModelProduced

    var message: String {
        switch self {
        case .noModelProduced:
            "No model was produced. The photos may not overlap enough — try scanning again with more laps."
        }
    }
}
