import AppKit
import Foundation

/// Runs Blender in the background to turn a model into a ready-to-render, photoreal .blend
/// (plus a preview render), using the bundled `l23d_scene.py`.
enum BlenderSceneMaker {
    struct Result: Sendable, Equatable {
        var blend: URL
        var preview: URL?
        var triangles: Int?
        var device: String?
    }

    enum Failure: LocalizedError {
        case noBlender
        case noScript
        case blenderFailed(String)

        var errorDescription: String? {
            switch self {
            case .noBlender: "Blender isn't installed. Install it from blender.org to get ready-made .blend files."
            case .noScript: "The Blender scene script is missing from the app."
            case .blenderFailed(let detail): "Blender couldn't make the scene: \(detail)"
            }
        }
    }

    /// The Blender executable, if Blender is installed.
    static func findBlender() -> URL? {
        var candidates = [
            URL(fileURLWithPath: "/Applications/Blender.app"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/Blender.app"),
        ]
        if let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.blenderfoundation.blender") {
            candidates.insert(found, at: 0)
        }
        for app in candidates {
            let binary = app.appending(path: "Contents/MacOS/Blender")
            if FileManager.default.isExecutableFile(atPath: binary.path(percentEncoded: false)) {
                return binary
            }
        }
        return nil
    }

    static var scriptURL: URL? {
        Bundle.main.url(forResource: "l23d_scene", withExtension: "py")
    }

    /// Makes `scene.blend` and `preview.png` in `directory`.
    static func make(model: URL, in directory: URL, blender: URL, script: URL, previewSamples: Int = 64) async throws -> Result {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blend = directory.appending(path: "scene.blend")
        let preview = directory.appending(path: "preview.png")
        let arguments = [
            "-b", "--factory-startup", "--python", script.path(percentEncoded: false), "--",
            "--model", model.path(percentEncoded: false),
            "--out", blend.path(percentEncoded: false),
            "--render", preview.path(percentEncoded: false),
            "--preview-samples", String(previewSamples),
        ]
        let output = try await run(blender, arguments: arguments)
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("L23D_RESULT ") }),
              let json = try? JSONSerialization.jsonObject(with: Data(line.dropFirst("L23D_RESULT ".count).utf8)) as? [String: Any] else {
            let tail = output.split(separator: "\n").suffix(5).joined(separator: " ")
            throw Failure.blenderFailed(tail.isEmpty ? "no output" : tail)
        }
        return Result(
            blend: blend,
            preview: FileManager.default.fileExists(atPath: preview.path(percentEncoded: false)) ? preview : nil,
            triangles: json["triangles"] as? Int,
            device: json["device"] as? String
        )
    }

    /// Runs a process and returns its combined output.
    private static func run(_ executable: URL, arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collected = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            collected.append(handle.availableData)
        }
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
                let text = collected.text
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    let tail = text.split(separator: "\n").suffix(5).joined(separator: " ")
                    continuation.resume(throwing: Failure.blenderFailed("exit \(finished.terminationStatus): \(tail)"))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock { data.append(chunk) }
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}
