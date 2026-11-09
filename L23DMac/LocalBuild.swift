import Foundation
import UniformTypeIdentifiers

/// Builds from a folder of photos on the Mac itself (any camera — DSLR photos give the
/// most photoreal results), then makes the Blender scene. Used by the window and by
/// the command line:
///
///     L23DHQ.app/Contents/MacOS/L23DHQ --build <photos-folder> [--detail full] [--out <folder>]
enum LocalBuild {
    static let photoExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"]

    struct Output: Sendable {
        var folder: ScanFolder
        var model: URL
        var scene: BlenderSceneMaker.Result?
        var sceneError: String?
    }

    /// Copies the photos into a new scan folder under `jobsDirectory`.
    static func prepare(photos source: URL, jobsDirectory: URL, jobID: UUID = UUID()) throws -> (ScanFolder, Int) {
        let folder = ScanFolder(root: jobsDirectory.appending(path: jobID.uuidString, directoryHint: .isDirectory))
        try folder.create()
        let items = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .filter { photoExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for item in items {
            try FileManager.default.copyItem(at: item, to: folder.images.appending(path: item.lastPathComponent))
        }
        return (folder, items.count)
    }

    static func run(
        photos source: URL, detail: HQDetail, jobsDirectory: URL, name: String? = nil, blender: URL?,
        progress: @escaping @Sendable (HQProgress) -> Void
    ) async throws -> Output {
        let jobID = UUID()
        let (folder, count) = try prepare(photos: source, jobsDirectory: jobsDirectory, jobID: jobID)
        guard count >= 10 else {
            throw HQErrorMessage(message: "Found \(count) photos in that folder. Use at least 20 (50–200 is best), all around the subject.")
        }
        let job = HQJobStart(
            jobID: jobID, scanName: name ?? source.lastPathComponent, mode: ScanMode.object.rawValue,
            detail: detail, fileCount: count, totalBytes: 0
        )
        let model = try await PhotogrammetryBuilder().build(job: job, folder: folder, progress: progress)
        var output = Output(folder: folder, model: model)
        if let blender, let script = BlenderSceneMaker.scriptURL {
            progress(HQProgress(fraction: 1, stage: "Making Blender scene"))
            do {
                output.scene = try await BlenderSceneMaker.make(
                    model: model, in: folder.root.appending(path: "Blender"), blender: blender, script: script
                )
            } catch {
                output.sceneError = error.localizedDescription
            }
        } else {
            output.sceneError = BlenderSceneMaker.Failure.noBlender.errorDescription
        }
        return output
    }

    // MARK: - Command line

    /// Returns an exit code if the app was started with `--build`, else nil (normal app launch).
    static func runFromCommandLineIfRequested() -> Int32? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--build"), index + 1 < args.count else { return nil }
        let source = URL(fileURLWithPath: args[index + 1])
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let detail = value("--detail").flatMap(HQDetail.init(rawValue:)) ?? .full
        let jobs = value("--out").map { URL(fileURLWithPath: $0) } ?? HQServerModel.jobsDirectory

        // Look Blender up now, on the main thread: the lookup needs the main thread,
        // which is about to block while the build runs.
        let blender = BlenderSceneMaker.findBlender()
        let done = DispatchSemaphore(value: 0)
        let code = ExitCode()
        Task.detached {
            do {
                let output = try await run(photos: source, detail: detail, jobsDirectory: jobs, blender: blender) { progress in
                    print(String(format: "progress %3.0f%% %@", progress.fraction * 100, progress.stage))
                    fflush(stdout)
                }
                var result: [String: Any] = ["model": output.model.path(percentEncoded: false)]
                if let scene = output.scene {
                    result["blend"] = scene.blend.path(percentEncoded: false)
                    result["preview"] = scene.preview?.path(percentEncoded: false) ?? NSNull()
                    result["triangles"] = scene.triangles ?? NSNull()
                    result["device"] = scene.device ?? NSNull()
                }
                if let error = output.sceneError { result["blenderError"] = error }
                let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                print("L23DHQ_RESULT " + String(decoding: json, as: UTF8.self))
            } catch {
                print("L23DHQ_ERROR " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
                code.value = 1
            }
            done.signal()
        }
        done.wait()
        return code.value
    }
}

private final class ExitCode: @unchecked Sendable {
    var value: Int32 = 0
}
