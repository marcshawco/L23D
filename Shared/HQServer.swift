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
    private let registry = HQJobRegistry()

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
                let message: (type: HQMessageType?, payload: Data)
                do {
                    message = try await connection.receiveMessage()
                } catch {
                    break // client finished and closed
                }
                switch message.type {
                case .jobStart:
                    try await handle(try JSONDecoder().decode(HQJobStart.self, from: message.payload), on: connection)
                case .fetch:
                    try await handleFetch(try JSONDecoder().decode(HQFetch.self, from: message.payload).jobID, on: connection)
                default:
                    throw HQTransferError.unexpected(message.type, expected: .jobStart)
                }
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
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            onEvent(.jobFailed(job, message))
            try? await connection.send(.error, json: HQErrorMessage(message: message))
            throw error
        }

        // 2. Build in its own task, so it finishes (and the Mac keeps the model)
        //    even if the iPhone drops off the Wi-Fi. The iPhone can fetch it later.
        let latest = LatestProgress()
        let build = Task { [builder, onEvent] () throws -> URL in
            do {
                let model = try await builder.build(job: job, folder: folder) { progress in
                    latest.value = progress
                    onEvent(.jobBuilding(job, progress))
                }
                onEvent(.jobFinished(job, model: model))
                return model
            } catch {
                onEvent(.jobFailed(job, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
                throw error
            }
        }
        await registry.add(job.jobID, HQJobRegistry.Entry(build: build, progress: latest))

        // 3. Send progress, then the model.
        try await deliver(build: build, progress: latest, on: connection)
    }

    /// The iPhone asks again for a job it sent before (its connection dropped).
    private func handleFetch(_ jobID: UUID, on connection: HQConnection) async throws {
        if let entry = await registry.entry(jobID) {
            try await deliver(build: entry.build, progress: entry.progress, on: connection)
            return
        }
        // Built before the Mac app restarted: the model is still on disk.
        let folder = ScanFolder(root: jobsDirectory.appending(path: jobID.uuidString, directoryHint: .isDirectory))
        if let model = Self.finishedModel(in: folder) {
            try await sendResult(model, on: connection)
        } else {
            try await connection.send(.error, json: HQErrorMessage(
                message: "This Mac doesn't have that build anymore (it may have been stopped). Send the photos again."
            ))
        }
    }

    /// Newest built model in a job folder, if any.
    static func finishedModel(in folder: ScanFolder) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder.modelDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return items
            .filter { $0.lastPathComponent.hasPrefix("model-") && $0.pathExtension.lowercased() == "usdz" }
            .max {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a < b
            }
    }

    private func deliver(build: Task<URL, any Error>, progress latest: LatestProgress, on connection: HQConnection) async throws {
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
            model = try await build.value
        } catch {
            ticker.cancel()
            _ = await ticker.result
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            try? await connection.send(.error, json: HQErrorMessage(message: message))
            throw error
        }
        ticker.cancel()
        _ = await ticker.result
        try await sendResult(model, on: connection)
    }

    private func sendResult(_ model: URL, on connection: HQConnection) async throws {
        let size = (try? model.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        try await connection.send(.resultHeader, json: HQResultHeader(size: Int64(size)))
        try await connection.sendFile(.resultData, url: model)
    }
}

/// Builds the server knows about (running or finished) since it started.
actor HQJobRegistry {
    struct Entry: Sendable {
        var build: Task<URL, any Error>
        var progress: LatestProgress
    }

    private var entries: [UUID: Entry] = [:]

    func add(_ id: UUID, _ entry: Entry) { entries[id] = entry }
    func entry(_ id: UUID) -> Entry? { entries[id] }
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
