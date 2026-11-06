import Foundation
import Testing
@testable import L23D

struct ScanStoreTests {
    private func tempBase() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "L23DTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func folderLayoutMatchesSpec() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID()
        let folder = ScanStore.folder(for: id, base: base)

        #expect(folder.root.lastPathComponent == id.uuidString)
        #expect(folder.images.lastPathComponent == "Images")
        #expect(folder.checkpoint.lastPathComponent == "Checkpoint")
        #expect(folder.modelFile.lastPathComponent == "model.usdz")
        #expect(folder.modelFile.deletingLastPathComponent().lastPathComponent == "Model")
        #expect(folder.exports.lastPathComponent == "Exports")

        try folder.create()
        var isDir: ObjCBool = false
        for dir in [folder.images, folder.checkpoint, folder.modelDirectory, folder.exports] {
            #expect(FileManager.default.fileExists(atPath: dir.path(percentEncoded: false), isDirectory: &isDir))
            #expect(isDir.boolValue)
        }
        #expect(folder.hasModel == false)
    }

    @Test func resetCaptureEmptiesImages() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = ScanStore.folder(for: UUID(), base: base)
        try folder.create()
        try Data([1, 2, 3]).write(to: folder.images.appending(path: "a.heic"))
        #expect(folder.imageCount == 1)

        try folder.resetCapture()
        #expect(folder.imageCount == 0)
    }

    @Test func deleteRemovesEverything() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID()
        let folder = ScanStore.folder(for: id, base: base)
        try folder.create()
        ScanStore.deleteFiles(for: id, base: base)
        #expect(!FileManager.default.fileExists(atPath: folder.root.path(percentEncoded: false)))
    }

    @Test func scanModeFlags() {
        #expect(ScanMode.object.isAvailable)
        #expect(ScanMode(rawValue: "personSpin") == .personSpin)
    }
}
