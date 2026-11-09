import Foundation
import Network
import Observation
import UIKit

/// A Mac running L23D HQ, found on the local network.
struct HQMac: Identifiable, Hashable, Sendable {
    let name: String
    let endpoint: NWEndpoint
    var id: String { name }
}

/// Finds L23D HQ Macs on the same Wi-Fi (Bonjour).
@MainActor
@Observable
final class HQBrowser {
    private(set) var macs: [HQMac] = []
    private(set) var problem: String?
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: HQ.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> HQMac? in
                if case .service(let name, _, _, _) = result.endpoint {
                    return HQMac(name: name, endpoint: result.endpoint)
                }
                return nil
            }.sorted { $0.name < $1.name }
            Task { @MainActor in self?.macs = found }
        }
        browser.stateUpdateHandler = { [weak self] state in
            let message: String? = switch state {
            case .failed(let error), .waiting(let error):
                "Can't search the network: \(error.localizedDescription). Check Local Network access in Settings → Privacy."
            default:
                nil
            }
            Task { @MainActor in self?.problem = message }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

/// Remembers the pairing code for each Mac.
enum HQPairing {
    static func code(for mac: String) -> String? {
        UserDefaults.standard.string(forKey: "hq.pairing.\(mac)")
    }

    static func save(_ code: String, for mac: String) {
        UserDefaults.standard.set(code, forKey: "hq.pairing.\(mac)")
    }

    static func forget(_ mac: String) {
        UserDefaults.standard.removeObject(forKey: "hq.pairing.\(mac)")
    }
}

/// A build sent to a Mac whose model never made it back (Wi-Fi dropped, app closed).
struct HQPendingJob: Codable, Equatable, Sendable {
    var jobID: UUID
    var macName: String
    var detail: HQDetail

    private static func key(_ scanID: UUID) -> String { "hq.pending.\(scanID.uuidString)" }

    static func load(for scanID: UUID) -> HQPendingJob? {
        UserDefaults.standard.data(forKey: key(scanID)).flatMap { try? JSONDecoder().decode(HQPendingJob.self, from: $0) }
    }

    static func save(_ job: HQPendingJob?, for scanID: UUID) {
        if let job, let data = try? JSONEncoder().encode(job) {
            UserDefaults.standard.set(data, forKey: key(scanID))
        } else {
            UserDefaults.standard.removeObject(forKey: key(scanID))
        }
    }
}

/// Sends one scan to a Mac, waits for the build, and saves the model.
@MainActor
@Observable
final class HQTransfer {
    enum Phase: Equatable {
        case idle
        case connecting
        case uploading(Double)
        case building(Double, String)
        case downloading(Double)
        case done(URL)
        case failed(String)

        var isActive: Bool {
            switch self {
            case .connecting, .uploading, .building, .downloading: true
            default: false
            }
        }
    }

    private(set) var phase: Phase = .idle
    /// Set once every photo reached the Mac. The Mac keeps building even if the
    /// connection drops, so this ID can fetch the model later.
    private(set) var sentJobID: UUID?
    @ObservationIgnored private var connection: HQConnection?

    /// Runs the whole round trip. On success the model is at `destination`.
    func run(
        folder: ScanFolder, scanName: String, mode: ScanMode, detail: HQDetail,
        endpoint: NWEndpoint, pairingCode: String, destination: URL, deviceName: String = UIDevice.current.name
    ) async {
        sentJobID = nil
        await session(endpoint: endpoint, pairingCode: pairingCode, deviceName: deviceName) { connection in
            // Upload.
            let files = HQPackage.files(in: folder)
            guard !files.isEmpty else { throw HQErrorMessage(message: "This scan has no photos to send.") }
            let total = files.reduce(Int64(0)) { $0 + $1.size }
            let job = HQJobStart(jobID: UUID(), scanName: scanName, mode: mode.rawValue, detail: detail, fileCount: files.count, totalBytes: total)
            try await connection.send(.jobStart, json: job)
            var sent: Int64 = 0
            self.phase = .uploading(0)
            for file in files {
                try await connection.send(.fileHeader, json: HQFileHeader(path: file.path, size: file.size))
                let base = sent
                try await connection.sendFile(.fileData, url: file.url) { [weak self] bytes in
                    let fraction = Double(base + bytes) / Double(max(total, 1))
                    Task { @MainActor in self?.phase = .uploading(fraction) }
                }
                sent += file.size
            }
            try await connection.send(.jobEnd)
            self.sentJobID = job.jobID
            self.phase = .building(0, "Waiting for the Mac")
            try await self.receiveResult(on: connection, destination: destination)
        }
    }

    /// Picks up a job sent earlier whose connection dropped: waits for the build if it is
    /// still running, then downloads the model.
    func fetch(
        jobID: UUID, endpoint: NWEndpoint, pairingCode: String, destination: URL,
        deviceName: String = UIDevice.current.name
    ) async {
        sentJobID = jobID
        await session(endpoint: endpoint, pairingCode: pairingCode, deviceName: deviceName) { connection in
            try await connection.send(.fetch, json: HQFetch(jobID: jobID))
            self.phase = .building(0, "Checking on the Mac")
            try await self.receiveResult(on: connection, destination: destination)
        }
    }

    /// Connects, says hello with the pairing code, runs `body`, and turns errors into `.failed`.
    private func session(
        endpoint: NWEndpoint, pairingCode: String, deviceName: String,
        _ body: (HQConnection) async throws -> Void
    ) async {
        phase = .connecting
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = HQConnection(NWConnection(to: endpoint, using: parameters))
        self.connection = connection
        defer {
            connection.cancel()
            self.connection = nil
        }
        do {
            try await connection.start()
            try await connection.send(.hello, json: HQHello(version: HQ.protocolVersion, pairingCode: pairingCode, deviceName: deviceName))
            let reply = try await connection.receiveMessage()
            guard reply.type == .helloOK else { throw HQTransferError.unexpected(reply.type, expected: .helloOK) }
            try await body(connection)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .failed(message)
        }
    }

    /// Progress until the model arrives, then saves it to `destination`.
    private func receiveResult(on connection: HQConnection, destination: URL) async throws {
        while true {
            let message = try await connection.receiveMessage()
            switch message.type {
            case .progress:
                let progress = try JSONDecoder().decode(HQProgress.self, from: message.payload)
                phase = .building(progress.fraction, progress.stage)
            case .resultHeader:
                let header = try JSONDecoder().decode(HQResultHeader.self, from: message.payload)
                phase = .downloading(0)
                let temporary = destination.deletingLastPathComponent().appending(path: "incoming-hq.usdz")
                try await connection.receiveFile(.resultData, to: temporary) { [weak self] bytes in
                    let fraction = Double(bytes) / Double(max(header.size, 1))
                    Task { @MainActor in self?.phase = .downloading(fraction) }
                }
                if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporary, to: destination)
                phase = .done(destination)
                return
            default:
                throw HQTransferError.unexpected(message.type, expected: .resultHeader)
            }
        }
    }

    func cancel() {
        connection?.cancel()
    }
}
