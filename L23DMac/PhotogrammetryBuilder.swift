import Foundation
import RealityKit

/// Builds received scans on the Mac with Apple's photogrammetry at Medium / Full / Raw detail.
/// One job at a time — each build already uses the whole GPU.
final class PhotogrammetryBuilder: HQBuilder {
    private let gate = SerialGate()

    func build(job: HQJobStart, folder: ScanFolder, progress: @escaping @Sendable (HQProgress) -> Void) async throws -> URL {
        progress(HQProgress(fraction: 0, stage: "Waiting for the Mac to be free"))
        await gate.enter()
        do {
            let url = try await run(job: job, folder: folder, progress: progress)
            await gate.leave()
            return url
        } catch {
            await gate.leave()
            throw error
        }
    }

    private func run(job: HQJobStart, folder: ScanFolder, progress: @escaping @Sendable (HQProgress) -> Void) async throws -> URL {
        guard PhotogrammetrySession.isSupported else {
            throw HQErrorMessage(message: "This Mac can't run Apple's photogrammetry (it needs Apple silicon or a strong GPU).")
        }
        try FileManager.default.createDirectory(at: folder.modelDirectory, withIntermediateDirectories: true)
        let output = folder.modelDirectory.appending(path: "model-\(job.detail.rawValue).usdz")
        try? FileManager.default.removeItem(at: output)

        let session = try ReconstructionSetup.makeSession(for: folder)
        try session.process(requests: [.modelFile(url: output, detail: job.detail.photogrammetryDetail)])

        var fraction = 0.0
        var stage = "Starting"
        var requestError: (any Error)?
        for try await item in session.outputs {
            switch item {
            case .requestProgress(_, let value):
                fraction = value
                progress(HQProgress(fraction: fraction, stage: stage))
            case .requestProgressInfo(_, let info):
                if let s = info.processingStage {
                    stage = ReconstructionSetup.label(for: s)
                    progress(HQProgress(fraction: fraction, stage: stage))
                }
            case .requestError(_, let error):
                requestError = error
            case .processingCancelled:
                throw HQErrorMessage(message: "The build was cancelled on the Mac.")
            default:
                break
            }
        }
        if let requestError { throw requestError }
        guard FileManager.default.fileExists(atPath: output.path(percentEncoded: false)) else {
            throw HQErrorMessage(message: "The Mac didn't produce a model. The photos may not overlap enough.")
        }
        progress(HQProgress(fraction: 1, stage: "Done"))
        return output
    }
}

/// Lets one task in at a time (FIFO).
actor SerialGate {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
