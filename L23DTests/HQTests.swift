import Foundation
import Network
import Testing
@testable import L23D

/// Stands in for the Mac's photogrammetry: checks what arrived and returns the sample model.
final class FakeBuilder: HQBuilder, @unchecked Sendable {
    private let lock = NSLock()
    private var _received: [String] = []
    private var _job: HQJobStart?
    var received: [String] { lock.withLock { _received } }
    var job: HQJobStart? { lock.withLock { _job } }

    func build(job: HQJobStart, folder: ScanFolder, progress: @escaping @Sendable (HQProgress) -> Void) async throws -> URL {
        let files = HQPackage.files(in: folder).map(\.path)
        lock.withLock {
            _received = files
            _job = job
        }
        progress(HQProgress(fraction: 0.5, stage: "Building mesh"))
        try await Task.sleep(for: .milliseconds(1200)) // let a progress message go out
        try folder.create()
        let output = folder.modelDirectory.appending(path: "model-\(job.detail.rawValue).usdz")
        try SampleModel.write(to: output)
        progress(HQProgress(fraction: 1, stage: "Done"))
        return output
    }
}

@MainActor
struct HQLoopbackTests {
    private func makeScanFolder() throws -> ScanFolder {
        let base = FileManager.default.temporaryDirectory.appending(path: "hq-client-\(UUID().uuidString)")
        let folder = ScanStore.folder(for: UUID(), base: base)
        try folder.create()
        try Data(repeating: 7, count: 3 * HQ.chunkSize + 123).write(to: folder.images.appending(path: "0001.jpg")) // multi-chunk file
        try Data([1, 2, 3]).write(to: folder.images.appending(path: "0002.jpg"))
        try FileManager.default.createDirectory(at: folder.masks, withIntermediateDirectories: true)
        try Data([9]).write(to: folder.masks.appending(path: "0001.png"))
        try Data("{\"mode\":\"personHelper\",\"frames\":[]}".utf8).write(to: folder.personManifest)
        return folder
    }

    private func startServer(code: String, builder: FakeBuilder, jobs existing: URL? = nil) async throws -> (HQServer, UInt16, URL) {
        let jobs = existing ?? FileManager.default.temporaryDirectory.appending(path: "hq-server-\(UUID().uuidString)")
        let server = HQServer(pairingCode: code, jobsDirectory: jobs, builder: builder) { _ in }
        let port = try await server.start(serviceName: nil)
        return (server, port, jobs)
    }

    @Test func roundTripSendsPhotosAndReturnsModel() async throws {
        let builder = FakeBuilder()
        let (server, port, jobs) = try await startServer(code: "123456", builder: builder)
        defer { server.stop(); try? FileManager.default.removeItem(at: jobs) }
        let folder = try makeScanFolder()
        defer { try? FileManager.default.removeItem(at: folder.root.deletingLastPathComponent()) }

        let transfer = HQTransfer()
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        await transfer.run(
            folder: folder, scanName: "Test", mode: .personHelper, detail: .full,
            endpoint: endpoint, pairingCode: "123456", destination: folder.hqModelFile, deviceName: "Test iPhone"
        )

        #expect(transfer.phase == .done(folder.hqModelFile))
        #expect(folder.hasHQModel)
        #expect(folder.activeModelFile == folder.hqModelFile)
        #expect(builder.received == ["Images/0001.jpg", "Images/0002.jpg", "Masks/0001.png", "frames.json"])
        #expect(builder.job?.detail == .full)
        #expect(builder.job?.scanName == "Test")

        // The big file arrived intact.
        let serverCopy = jobs.appending(path: builder.job!.jobID.uuidString).appending(path: "Images/0001.jpg")
        #expect(try Data(contentsOf: serverCopy) == Data(repeating: 7, count: 3 * HQ.chunkSize + 123))
        // The model that came back loads.
        let stats = try await ModelInspector.stats(for: folder.hqModelFile)
        #expect(stats.triangleCount == 12)
    }

    @Test func wrongPairingCodeIsRefused() async throws {
        let builder = FakeBuilder()
        let (server, port, jobs) = try await startServer(code: "111111", builder: builder)
        defer { server.stop(); try? FileManager.default.removeItem(at: jobs) }
        let folder = try makeScanFolder()
        defer { try? FileManager.default.removeItem(at: folder.root.deletingLastPathComponent()) }

        let transfer = HQTransfer()
        await transfer.run(
            folder: folder, scanName: "Test", mode: .object, detail: .medium,
            endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
            pairingCode: "999999", destination: folder.hqModelFile, deviceName: "Intruder"
        )
        guard case .failed(let message) = transfer.phase else {
            Issue.record("expected failure, got \(transfer.phase)")
            return
        }
        #expect(message.contains("pairing code"))
        #expect(builder.job == nil)
        #expect(!folder.hasHQModel)
    }
}

extension HQLoopbackTests {
    private func local(_ port: UInt16) -> NWEndpoint {
        .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    }

    @Test func droppedConnectionCanFetchTheModelLater() async throws {
        let builder = FakeBuilder()
        let (server, port, jobs) = try await startServer(code: "123456", builder: builder)
        defer { server.stop(); try? FileManager.default.removeItem(at: jobs) }
        let folder = try makeScanFolder()
        defer { try? FileManager.default.removeItem(at: folder.root.deletingLastPathComponent()) }

        // Send, then drop the connection as soon as the photos are on the Mac.
        let transfer = HQTransfer()
        let run = Task {
            await transfer.run(
                folder: folder, scanName: "Test", mode: .object, detail: .ultra,
                endpoint: local(port), pairingCode: "123456", destination: folder.hqModelFile, deviceName: "Test iPhone"
            )
        }
        while transfer.sentJobID == nil { try await Task.sleep(for: .milliseconds(20)) }
        transfer.cancel()
        await run.value
        guard case .failed = transfer.phase else {
            Issue.record("expected the dropped run to fail, got \(transfer.phase)")
            return
        }
        #expect(!folder.hasHQModel)
        let jobID = try #require(transfer.sentJobID)

        // The Mac kept building; a new connection gets the model.
        let again = HQTransfer()
        await again.fetch(jobID: jobID, endpoint: local(port), pairingCode: "123456", destination: folder.hqModelFile, deviceName: "Test iPhone")
        #expect(again.phase == .done(folder.hqModelFile))
        #expect(builder.job?.detail == .ultra)
        #expect(try await ModelInspector.stats(for: folder.hqModelFile).triangleCount == 12)

        // After the Mac app restarts, the finished model is still found on disk.
        server.stop()
        let (restarted, newPort, _) = try await startServer(code: "123456", builder: FakeBuilder(), jobs: jobs)
        defer { restarted.stop() }
        try FileManager.default.removeItem(at: folder.hqModelFile)
        let third = HQTransfer()
        await third.fetch(jobID: jobID, endpoint: local(newPort), pairingCode: "123456", destination: folder.hqModelFile, deviceName: "Test iPhone")
        #expect(third.phase == .done(folder.hqModelFile))
    }

    @Test func fetchingAnUnknownJobExplains() async throws {
        let (server, port, jobs) = try await startServer(code: "123456", builder: FakeBuilder())
        defer { server.stop(); try? FileManager.default.removeItem(at: jobs) }
        let folder = try makeScanFolder()
        defer { try? FileManager.default.removeItem(at: folder.root.deletingLastPathComponent()) }

        let transfer = HQTransfer()
        await transfer.fetch(jobID: UUID(), endpoint: local(port), pairingCode: "123456", destination: folder.hqModelFile, deviceName: "Test iPhone")
        guard case .failed(let message) = transfer.phase else {
            Issue.record("expected failure, got \(transfer.phase)")
            return
        }
        #expect(message.contains("doesn't have that build"))
    }

    @Test func pendingJobIsRemembered() {
        let scanID = UUID()
        let job = HQPendingJob(jobID: UUID(), macName: "Studio", detail: .ultra)
        HQPendingJob.save(job, for: scanID)
        #expect(HQPendingJob.load(for: scanID) == job)
        HQPendingJob.save(nil, for: scanID)
        #expect(HQPendingJob.load(for: scanID) == nil)
    }
}

extension HQLoopbackTests {
    @Test func wrongCodesLockPairingEvenForTheRightCode() async throws {
        let jobs = FileManager.default.temporaryDirectory.appending(path: "hq-server-\(UUID().uuidString)")
        let server = HQServer(pairingCode: "123456", jobsDirectory: jobs, builder: FakeBuilder(), maxWrongCodes: 2, lockout: .seconds(600)) { _ in }
        let port = try await server.start(serviceName: nil)
        defer { server.stop(); try? FileManager.default.removeItem(at: jobs) }
        let folder = try makeScanFolder()
        defer { try? FileManager.default.removeItem(at: folder.root.deletingLastPathComponent()) }

        func attempt(_ code: String) async -> String {
            let transfer = HQTransfer()
            await transfer.run(
                folder: folder, scanName: "Test", mode: .object, detail: .medium,
                endpoint: local(port), pairingCode: code, destination: folder.hqModelFile, deviceName: "Guesser"
            )
            if case .failed(let message) = transfer.phase { return message }
            return "ok"
        }
        #expect(await attempt("000000").contains("Wrong pairing code"))
        #expect(await attempt("000001").contains("Wrong pairing code"))
        // Now locked: the right code is refused too.
        #expect(await attempt("123456").contains("Too many wrong pairing codes"))
        #expect(!folder.hasHQModel)
    }

    /// Talks to the server by hand, to send things the real app never would.
    private func rawUpload(port: UInt16, job: HQJobStart, path: String, announced: Int64, data: Data) async throws -> String {
        let connection = HQConnection(NWConnection(to: local(port), using: .tcp))
        defer { connection.cancel() }
        try await connection.start()
        try await connection.send(.hello, json: HQHello(version: HQ.protocolVersion, pairingCode: "123456", deviceName: "Raw"))
        _ = try await connection.receiveMessage()
        try await connection.send(.jobStart, json: job)
        try await connection.send(.fileHeader, json: HQFileHeader(path: path, size: announced))
        try await connection.send(.fileData, payload: data)
        do {
            _ = try await connection.receiveMessage()
            return "no error"
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    @Test func uploadsOutsideTheScanFoldersAreRefused() async throws {
        let (server, port, jobs) = try await startServer(code: "123456", builder: FakeBuilder())
        defer { server.stop(); try? FileManager.default.removeItem(at: jobs) }

        let job = HQJobStart(jobID: UUID(), scanName: "Evil", mode: "object", detail: .full, fileCount: 1, totalBytes: 3)
        let message = try await rawUpload(port: port, job: job, path: "Model/model-full.usdz", announced: 3, data: Data([1, 2, 3]))
        #expect(message.contains("unsafe file path"))
        // Nothing of the refused job stays on disk.
        #expect(!FileManager.default.fileExists(atPath: jobs.appending(path: job.jobID.uuidString).path(percentEncoded: false)))
    }

    @Test func filesLargerThanAnnouncedAreRefused() async throws {
        let (server, port, jobs) = try await startServer(code: "123456", builder: FakeBuilder())
        defer { server.stop(); try? FileManager.default.removeItem(at: jobs) }

        let job = HQJobStart(jobID: UUID(), scanName: "Big", mode: "object", detail: .full, fileCount: 1, totalBytes: 3)
        let lied = try await rawUpload(port: port, job: job, path: "Images/0001.jpg", announced: 3, data: Data(repeating: 1, count: 5000))
        #expect(lied.contains("not the size"))

        let huge = HQJobStart(jobID: UUID(), scanName: "Huge", mode: "object", detail: .full, fileCount: 1, totalBytes: HQ.maxJobSize + 1)
        let refused = try await rawUpload(port: port, job: huge, path: "Images/0001.jpg", announced: 1, data: Data([1]))
        #expect(refused.contains("larger than allowed"))
    }

    @Test func aJobIDCanOnlyBeUsedOnce() async throws {
        let builder = FakeBuilder()
        let (server, port, jobs) = try await startServer(code: "123456", builder: builder)
        defer { server.stop(); try? FileManager.default.removeItem(at: jobs) }
        let folder = try makeScanFolder()
        defer { try? FileManager.default.removeItem(at: folder.root.deletingLastPathComponent()) }

        let transfer = HQTransfer()
        await transfer.run(
            folder: folder, scanName: "Test", mode: .object, detail: .full,
            endpoint: local(port), pairingCode: "123456", destination: folder.hqModelFile, deviceName: "Test iPhone"
        )
        let jobID = try #require(transfer.sentJobID)
        let again = HQJobStart(jobID: jobID, scanName: "Again", mode: "object", detail: .full, fileCount: 1, totalBytes: 1)
        let message = try await rawUpload(port: port, job: again, path: "Images/0001.jpg", announced: 1, data: Data([1]))
        #expect(message.contains("already sent"))
        // The first job's photos are untouched.
        #expect(FileManager.default.fileExists(atPath: jobs.appending(path: jobID.uuidString).appending(path: "Images/0002.jpg").path(percentEncoded: false)))
    }
}

struct HQGuardTests {
    @Test func lockoutEndsAfterTheWait() async {
        let guardrail = HQPairingGuard(maxWrongCodes: 3, lockout: .seconds(60))
        let start = ContinuousClock.now
        #expect(await guardrail.check(code: "1", against: "9", now: start) == .wrong)
        #expect(await guardrail.check(code: "9", against: "9", now: start) == .accepted) // a right code resets the count
        for _ in 0..<3 { #expect(await guardrail.check(code: "1", against: "9", now: start) == .wrong) }
        #expect(await guardrail.check(code: "9", against: "9", now: start + .seconds(10)) == .lockedOut(seconds: 51))
        #expect(await guardrail.check(code: "9", against: "9", now: start + .seconds(61)) == .accepted)
    }

    @Test func onlyAFewUnpairedConnectionsAtOnce() async {
        let guardrail = HQPairingGuard()
        for _ in 0..<HQ.maxUnpairedConnections { #expect(await guardrail.beginUnpaired()) }
        #expect(await guardrail.beginUnpaired() == false)
        await guardrail.endUnpaired()
        #expect(await guardrail.beginUnpaired())
    }

    @Test func uploadsAreLimitedToScanFolders() {
        for path in ["Images/0001.jpg", "Masks/0001.png", "Depth/0001.bin", "Checkpoint/a/b.dat", "frames.json"] {
            #expect(HQPackage.isAllowedUpload(path))
        }
        for path in ["Model/model.usdz", "Blender/scene.blend", "thumbnail.jpg", "Images/../Model/x", "/etc/passwd", "Images"] {
            #expect(!HQPackage.isAllowedUpload(path))
        }
    }

    @Test func frameListCannotPointOutsideTheScan() throws {
        func manifest(image: String, mask: String? = nil, depth: String? = nil) -> PersonCaptureManifest {
            PersonCaptureManifest(mode: "personHelper", frames: [
                .init(index: 1, image: image, mask: mask, depth: depth, depthWidth: 0, depthHeight: 0, cameraTransform: nil, ring: 0, slice: 0),
            ])
        }
        try manifest(image: "Images/0001.jpg", mask: "Masks/0001.png", depth: "Depth/0001.bin").validatePaths()
        #expect(throws: PersonCaptureManifest.UnsafePath.self) { try manifest(image: "../../../Pictures/private.jpg").validatePaths() }
        #expect(throws: PersonCaptureManifest.UnsafePath.self) { try manifest(image: "/Users/me/private.jpg").validatePaths() }
        #expect(throws: PersonCaptureManifest.UnsafePath.self) { try manifest(image: "Model/model.usdz").validatePaths() }
        #expect(throws: PersonCaptureManifest.UnsafePath.self) { try manifest(image: "Images/1.jpg", mask: "Images/../../x.png").validatePaths() }
        #expect(throws: PersonCaptureManifest.UnsafePath.self) { try manifest(image: "Images/1.jpg", depth: "Masks/1.bin").validatePaths() }

        // Loading from disk checks too.
        let base = FileManager.default.temporaryDirectory.appending(path: "manifest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = ScanStore.folder(for: UUID(), base: base)
        try folder.create()
        try JSONEncoder().encode(manifest(image: "../../secret.jpg")).write(to: folder.personManifest)
        #expect(throws: PersonCaptureManifest.UnsafePath.self) { try PersonFrameStore.loadManifest(from: folder) }
    }

    @Test func damagedZipDoesNotCrash() {
        var writer = ZipWriter(alignment: 64)
        writer.add(name: "a.txt", data: Data("hello".utf8))
        writer.add(name: "b.txt", data: Data("world".utf8))
        let good = writer.finish()
        #expect(ZipReader.storedEntries(in: good).map(\.name) == ["a.txt", "b.txt"])

        // Flip every byte in turn to 0xFF, and cut the file at every length: must never crash.
        var bytes = [UInt8](good)
        for i in bytes.indices {
            let saved = bytes[i]
            bytes[i] = 0xFF
            _ = ZipReader.storedEntries(in: Data(bytes))
            bytes[i] = saved
        }
        for length in 0..<good.count {
            _ = ZipReader.storedEntries(in: good.prefix(length))
        }
    }
}

struct HQProtocolTests {
    @Test func headerRoundTrips() {
        let header = HQMessageHeader(type: .fileData, length: 5_000_000_123)
        let encoded = header.encoded
        #expect(encoded.count == HQMessageHeader.size)
        #expect(HQMessageHeader(encoded) == header)
        #expect(HQMessageHeader(encoded)?.type == .fileData)
        #expect(HQMessageHeader(Data([1, 2])) == nil)
    }

    @Test func onlySafeRelativePathsAreAccepted() {
        #expect(HQPackage.isSafe("Images/0001.jpg"))
        #expect(HQPackage.isSafe("frames.json"))
        #expect(!HQPackage.isSafe("../etc/passwd"))
        #expect(!HQPackage.isSafe("/tmp/x"))
        #expect(!HQPackage.isSafe("Images/../../x"))
        #expect(!HQPackage.isSafe("Images//x"))
        #expect(!HQPackage.isSafe(""))
    }

    @Test func detailLevelsAreDescribed() {
        #expect(HQDetail.allCases.map(\.title) == ["Medium", "Full", "Raw", "Ultra"])
        #expect(HQDetail.allCases.allSatisfy { !$0.help.isEmpty })
    }
}
