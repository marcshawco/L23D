import AppKit
import SwiftUI

@main
struct L23DHQApp: App {
    @State private var model = HQServerModel()

    var body: some Scene {
        WindowGroup("L23D HQ") {
            HQWindow()
                .environment(model)
                .frame(minWidth: 520, minHeight: 420)
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
        case done(URL)
        case failed(String)
    }

    let id: UUID
    let name: String
    let detail: HQDetail
    let started: Date
    var status: Status
}

/// Runs the server and keeps the window's state.
@MainActor
@Observable
final class HQServerModel {
    private(set) var pairingCode: String
    private(set) var listeningPort: UInt16?
    private(set) var problem: String?
    private(set) var lastClient: String?
    private(set) var jobs: [HQJobRow] = []
    @ObservationIgnored private var server: HQServer?

    static let jobsDirectory: URL = {
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

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealJobsFolder() {
        NSWorkspace.shared.open(Self.jobsDirectory)
    }

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
            upsert(job, status: .done(model))
        case .jobFailed(let job, let message):
            upsert(job, status: .failed(message))
        }
    }

    private func upsert(_ job: HQJobStart, status: HQJobRow.Status) {
        if let index = jobs.firstIndex(where: { $0.id == job.jobID }) {
            jobs[index].status = status
        } else {
            jobs.insert(HQJobRow(id: job.jobID, name: job.scanName, detail: job.detail, started: .now, status: status), at: 0)
        }
    }

    private static func newCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
}
