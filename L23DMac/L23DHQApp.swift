import AppKit
import SwiftUI

@main
struct L23DHQApp: App {
    @State private var model = HQServerModel()

    init() {
        // Command-line mode: build from a photos folder and exit (no window).
        if let code = LocalBuild.runFromCommandLineIfRequested() {
            exit(code)
        }
    }

    var body: some Scene {
        WindowGroup("L23D HQ") {
            HQWindow()
                .environment(model)
                .frame(minWidth: 620, minHeight: 460)
                .task { await model.start() }
        }
        .windowResizability(.contentMinSize)
    }
}

/// One job as shown in the window.
struct HQJobRow: Identifiable, Equatable {
    enum Status: Equatable {
        case receiving(Double)
        case building(Double, String)
        case makingScene
        case done(model: URL, scene: BlenderSceneMaker.Result?, note: String?)
        case failed(String)
    }

    enum Source: Equatable {
        case iPhone
        case folder
    }

    let id: UUID
    let name: String
    let detail: HQDetail
    let source: Source
    let started: Date
    var status: Status
}

/// Runs the server, local builds and Blender scenes, and keeps the window's state.
@MainActor
@Observable
final class HQServerModel {
    private(set) var pairingCode: String
    private(set) var listeningPort: UInt16?
    private(set) var problem: String?
    private(set) var lastClient: String?
    private(set) var jobs: [HQJobRow] = []
    private(set) var blenderURL: URL? = BlenderSceneMaker.findBlender()
    @ObservationIgnored private var server: HQServer?

    nonisolated static let jobsDirectory: URL = {
        let url = URL.applicationSupportDirectory.appending(path: "L23D HQ/Jobs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init() {
        if let saved = UserDefaults.standard.string(forKey: "pairingCode"), saved.count == 6 {
            pairingCode = saved
        } else {
            pairingCode = Self.newCode()
            UserDefaults.standard.set(pairingCode, forKey: "pairingCode")
        }
    }

    var serviceName: String { Host.current().localizedName ?? "Mac" }

    func start() async {
        guard server == nil else { return }
        let server = HQServer(
            pairingCode: pairingCode, jobsDirectory: Self.jobsDirectory, builder: PhotogrammetryBuilder()
        ) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        self.server = server
        do {
            try await server.start(serviceName: serviceName)
        } catch {
            problem = "Couldn't start listening: \(error.localizedDescription)"
        }
    }

    /// Makes a new pairing code; iPhones will need to enter it again.
    func resetCode() async {
        server?.stop()
        server = nil
        listeningPort = nil
        pairingCode = Self.newCode()
        UserDefaults.standard.set(pairingCode, forKey: "pairingCode")
        await start()
    }

    /// Build from a folder of photos taken with any camera.
    func buildFromFolder(_ folder: URL, detail: HQDetail) {
        let id = UUID()
        jobs.insert(HQJobRow(id: id, name: folder.lastPathComponent, detail: detail, source: .folder, started: .now, status: .building(0, "Copying photos")), at: 0)
        Task {
            do {
                let output = try await LocalBuild.run(photos: folder, detail: detail, jobsDirectory: Self.jobsDirectory, blender: blenderURL) { progress in
                    Task { @MainActor in
                        let status: HQJobRow.Status = progress.stage == "Making Blender scene" ? .makingScene : .building(progress.fraction, progress.stage)
                        self.update(id, status: status)
                    }
                }
                update(id, status: .done(model: output.model, scene: output.scene, note: output.sceneError))
            } catch {
                update(id, status: .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
    }

    func refreshBlender() {
        blenderURL = BlenderSceneMaker.findBlender()
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openInBlender(_ blend: URL) {
        if let app = blenderURL?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() {
            NSWorkspace.shared.open([blend], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(blend)
        }
    }

    func revealJobsFolder() {
        NSWorkspace.shared.open(Self.jobsDirectory)
    }

    // MARK: - Events

    private func handle(_ event: HQServerEvent) {
        switch event {
        case .listening(let port):
            listeningPort = port
            problem = nil
        case .stopped(let message):
            listeningPort = nil
            if let message { problem = message }
        case .clientConnected(let name):
            lastClient = name
        case .rejected(let name):
            problem = "\(name) tried to connect with the wrong pairing code."
        case .jobReceiving(let job, let fraction):
            upsert(job, status: .receiving(fraction))
        case .jobBuilding(let job, let progress):
            upsert(job, status: .building(progress.fraction, progress.stage))
        case .jobFinished(let job, let model):
            makeScene(for: job.jobID, model: model)
        case .jobFailed(let job, let message):
            upsert(job, status: .failed(message))
        }
    }

    /// After the model went back to the iPhone, make the Blender scene on the Mac.
    private func makeScene(for id: UUID, model: URL) {
        refreshBlender()
        guard let blender = blenderURL, let script = BlenderSceneMaker.scriptURL else {
            update(id, status: .done(model: model, scene: nil, note: BlenderSceneMaker.Failure.noBlender.errorDescription))
            return
        }
        update(id, status: .makingScene)
        let directory = model.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Blender")
        Task {
            do {
                let scene = try await BlenderSceneMaker.make(model: model, in: directory, blender: blender, script: script)
                update(id, status: .done(model: model, scene: scene, note: nil))
            } catch {
                update(id, status: .done(model: model, scene: nil, note: error.localizedDescription))
            }
        }
    }

    private func upsert(_ job: HQJobStart, status: HQJobRow.Status) {
        if jobs.contains(where: { $0.id == job.jobID }) {
            update(job.jobID, status: status)
        } else {
            jobs.insert(HQJobRow(id: job.jobID, name: job.scanName, detail: job.detail, source: .iPhone, started: .now, status: status), at: 0)
        }
    }

    private func update(_ id: UUID, status: HQJobRow.Status) {
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            jobs[index].status = status
        }
    }

    private static func newCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
}
