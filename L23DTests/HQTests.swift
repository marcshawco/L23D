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

    private func startServer(code: String, builder: FakeBuilder) async throws -> (HQServer, UInt16, URL) {
        let jobs = FileManager.default.temporaryDirectory.appending(path: "hq-server-\(UUID().uuidString)")
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
        #expect(HQDetail.allCases.map(\.title) == ["Medium", "Full", "Raw"])
        #expect(HQDetail.allCases.allSatisfy { !$0.help.isEmpty })
    }
}
