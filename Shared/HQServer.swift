import Foundation
import Network

/// Turns a received scan folder into a model file. The Mac app uses photogrammetry;
/// tests use a fake.
protocol HQBuilder: Sendable {
    func build(job: HQJobStart, folder: ScanFolder, progress: @escaping @Sendable (HQProgress) -> Void) async throws -> URL
}

/// What the server tells its UI.
enum HQServerEvent: Sendable {
    case listening(port: UInt16)
    case stopped(String?)
    case clientConnected(String)
    case rejected(String)
    case jobReceiving(HQJobStart, fraction: Double)
    case jobBuilding(HQJobStart, HQProgress)
    case jobFinished(HQJobStart, model: URL)
    case jobFailed(HQJobStart, String)
}

/// Listens on the local network (Bonjour), receives scans, builds them, sends models back.
final class HQServer: @unchecked Sendable {
    let pairingCode: String
    let jobsDirectory: URL
    private let builder: any HQBuilder
    private let onEvent: @Sendable (HQServerEvent) -> Void
    private let queue = DispatchQueue(label: "l23d.hq.server")
    private var listener: NWListener?

    init(pairingCode: String, jobsDirectory: URL, builder: any HQBuilder, onEvent: @escaping @Sendable (HQServerEvent) -> Void) {
        self.pairingCode = pairingCode
        self.jobsDirectory = jobsDirectory
        self.builder = builder
        self.onEvent = onEvent
    }

    /// Starts listening. Returns the port. `serviceName` nil = don't advertise (tests).
    @discardableResult
    func start(serviceName: String?, port: NWEndpoint.Port = .any) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let listener = try NWListener(using: parameters, on: port)
        if let serviceName {
            listener.service = NWListener.Service(name: serviceName, type: HQ.serviceType)
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.session(HQConnection(connection)) }
        }
        self.listener = listener
        let once = ResumeOnce()
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [onEvent] state in
                switch state {
                case .ready:
                    once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    once.run { continuation.resume(throwing: error) }
                    onEvent(.stopped(error.localizedDescription))
                case .cancelled:
                    once.run { continuation.resume(throwing: HQTransferError.closed) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        onEvent(.listening(port: port))
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
        onEvent(.stopped(nil))
    }

    // MARK: - One client

    private func session(_ connection: HQConnection) async {
        do {
            try await connection.start()
            let hello = try await connection.receiveJSON(.hello, as: HQHello.self)
            guard hello.version == HQ.protocolVersion else {
                try? await connection.send(.error, json: HQErrorMessage(message: HQTransferError.wrongVersion.errorDescription!))
                connection.cancel()
                return
            }
            guard hello.pairingCode == pairingCode else {
                onEvent(.rejected(hello.deviceName))
                try? await connection.send(.error, json: HQErrorMessage(message: "Wrong pairing code. Check the code shown in L23D HQ on your Mac."))
                connection.cancel()
                return
            }
            try await connection.send(.helloOK, json: HQEmpty())
            onEvent(.clientConnected(hello.deviceName))

            while true {
                let job: HQJobStart
                do {
                    job = try await connection.receiveJSON(.jobStart, as: HQJobStart.self)
                } catch {
                    break // client finished and closed
                }
                try await handle(job, on: connection)
            }
        } catch {
            // Connection-level failure; nothing more to tell the client.
        }
        connection.cancel()
    }

    private func handle(_ job: HQJobStart, on connection: HQConnection) async throws {
        let folder = ScanFolder(root: jobsDirectory.appending(path: job.jobID.uuidString, directoryHint: .isDirectory))
        do {
            try? FileManager.default.removeItem(at: folder.root)
            try folder.create()

            // 1. Receive files.
            var received: Int64 = 0
            for _ in 0..<job.fileCount {
                let header = try await connection.receiveJSON(.fileHeader, as: HQFileHeader.self)
                guard HQPackage.isSafe(header.path) else { throw HQTransferError.badPath(header.path) }
                let base = received
                let total = max(job.totalBytes, 1)
                try await connection.receiveFile(.fileData, to: folder.root.appending(path: header.path)) { [onEvent] bytes in
                    onEvent(.jobReceiving(job, fraction: Double(base + bytes) / Double(total)))
                }
                received += header.size
            }
            let end = try await connection.receiveMessage()
            guard end.type == .jobEnd else { throw HQTransferError.unexpected(end.type, expected: .jobEnd) }

            // 2. Build, sending progress about once a second.
            let latest = LatestProgress()
            let ticker = Task {
                var last: HQProgress?
                while !Task.isCancelled {
                    if let now = latest.value, now != last {
                        last = now
                        try? await connection.send(.progress, json: now)
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            let model: URL
            do {
                model = try await builder.build(job: job, folder: folder) { [onEvent] progress in
                    latest.value = progress
                    onEvent(.jobBuilding(job, progress))
                }
            } catch {
                ticker.cancel()
                _ = await ticker.result
                throw error
            }
            ticker.cancel()
            _ = await ticker.result

            // 3. Send the model.
            let size = (try? model.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
            try await connection.send(.resultHeader, json: HQResultHeader(size: Int64(size)))
            try await connection.sendFile(.resultData, url: model)
            onEvent(.jobFinished(job, model: model))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            onEvent(.jobFailed(job, message))
            try? await connection.send(.error, json: HQErrorMessage(message: message))
            throw error
        }
    }
}

/// Thread-safe "latest value" box.
final class LatestProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: HQProgress?

    var value: HQProgress? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
