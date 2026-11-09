import Foundation
import Network
#if os(macOS)
import RealityKit
#endif

/// HQ mode: the iPhone sends a scan's photos to the L23D HQ Mac app over Wi-Fi,
/// the Mac builds a high-detail model, and sends it back.
///
/// Wire format: every message is a 12-byte header (type: UInt32, length: UInt64, little-endian)
/// followed by `length` bytes. JSON messages carry small structs; file data is streamed.
///
///     iPhone                         Mac
///     hello(code) ─────────────────▶
///                 ◀───────────────── helloOK | error
///     jobStart ────────────────────▶
///     (fileHeader + fileData) × N ─▶
///     jobEnd ──────────────────────▶
///                 ◀───────────────── progress …
///                 ◀───────────────── resultHeader + resultData | error
enum HQ {
    static let serviceType = "_l23d-hq._tcp"
    static let protocolVersion = 2 // 2: Ultra detail + fetch a finished job again
    /// Chunk size for streaming files.
    static let chunkSize = 1 << 20
    /// Largest JSON/small message we accept in memory.
    static let maxInMemoryMessage: UInt64 = 16 << 20
}

enum HQDetail: String, Codable, CaseIterable, Identifiable, Sendable {
    case medium, full, raw, ultra

    var id: String { rawValue }

    var title: String {
        switch self {
        case .medium: "Medium"
        case .full: "Full"
        case .raw: "Raw"
        case .ultra: "Ultra"
        }
    }

    var help: String {
        switch self {
        case .medium: "A step up from the phone. Quick to build, small files."
        case .full: "High detail with 4K-class textures. Best for most games and renders."
        case .raw: "Every detail the photos hold. Huge files (millions of triangles) — for film, close-ups, or 3D printing."
        case .ultra: "Made for photoreal Blender renders: a dense mesh, 8K lossless textures, plus a displacement map for fine surface relief. Big files."
        }
    }

    #if os(macOS)
    var photogrammetryDetail: PhotogrammetrySession.Request.Detail {
        switch self {
        case .medium: .medium
        case .full: .full
        case .raw: .raw
        case .ultra: .custom
        }
    }

    /// Only used by `.ultra` (Apple's `.custom` detail).
    var customSpecification: PhotogrammetrySession.Configuration.CustomDetailSpecification? {
        guard self == .ultra else { return nil }
        var spec = PhotogrammetrySession.Configuration.CustomDetailSpecification()
        spec.maximumPolygonCount = 1_000_000
        spec.maximumTextureDimension = .eightK
        spec.outputTextureMaps = .all // color, normal, roughness, AO, displacement
        spec.textureFormat = .png // lossless (normal + displacement keep their full precision)
        return spec
    }
    #endif
}

enum HQMessageType: UInt32, Sendable {
    case hello = 1
    case helloOK
    case error
    case jobStart
    case fileHeader
    case fileData
    case jobEnd
    case progress
    case resultHeader
    case resultData
    /// iPhone → Mac: "send me the model for this job" (after a dropped connection).
    case fetch
}

struct HQFetch: Codable, Sendable {
    var jobID: UUID
}

struct HQHello: Codable, Sendable {
    var version: Int
    var pairingCode: String
    var deviceName: String
}

struct HQErrorMessage: Codable, Sendable, Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

struct HQJobStart: Codable, Sendable, Equatable {
    var jobID: UUID
    var scanName: String
    var mode: String
    var detail: HQDetail
    var fileCount: Int
    var totalBytes: Int64
}

struct HQFileHeader: Codable, Sendable {
    var path: String
    var size: Int64
}

struct HQProgress: Codable, Sendable, Equatable {
    var fraction: Double
    var stage: String
}

struct HQResultHeader: Codable, Sendable {
    var size: Int64
}

struct HQEmpty: Codable, Sendable {}

struct HQMessageHeader: Equatable, Sendable {
    static let size = 12
    var rawType: UInt32
    var length: UInt64

    var type: HQMessageType? { HQMessageType(rawValue: rawType) }

    init(type: HQMessageType, length: UInt64) {
        rawType = type.rawValue
        self.length = length
    }

    init?(_ data: Data) {
        guard data.count == Self.size else { return nil }
        let bytes = [UInt8](data)
        rawType = bytes[0..<4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
        length = bytes[4..<12].enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * $1.offset) }
    }

    var encoded: Data {
        var data = Data()
        data.appendLE(rawType)
        data.appendLE(length)
        return data
    }
}

enum HQTransferError: LocalizedError {
    case closed
    case unexpected(HQMessageType?, expected: HQMessageType)
    case tooLarge
    case badPath(String)
    case wrongVersion

    var errorDescription: String? {
        switch self {
        case .closed: "The connection closed."
        case .unexpected(let got, let expected): "Unexpected message \(got.map { "\($0)" } ?? "unknown") (wanted \(expected))."
        case .tooLarge: "A message was too large."
        case .badPath(let path): "Refused an unsafe file path: \(path)"
        case .wrongVersion: "The iPhone and Mac apps are different versions. Update both."
        }
    }
}

/// Async wrapper around `NWConnection` that sends and receives framed messages.
final class HQConnection: @unchecked Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "l23d.hq.connection")

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    /// Starts the connection and waits until it is ready.
    func start() async throws {
        let once = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    once.run { continuation.resume(throwing: error) }
                case .cancelled:
                    once.run { continuation.resume(throwing: HQTransferError.closed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func cancel() {
        connection.cancel()
    }

    // MARK: Sending

    func send(_ type: HQMessageType, payload: Data = Data()) async throws {
        var message = HQMessageHeader(type: type, length: UInt64(payload.count)).encoded
        message.append(payload)
        try await sendRaw(message)
    }

    func send<T: Encodable>(_ type: HQMessageType, json: T) async throws {
        try await send(type, payload: JSONEncoder().encode(json))
    }

    /// Sends a file as one message, streamed in chunks.
    func sendFile(_ type: HQMessageType, url: URL, progress: (@Sendable (Int64) -> Void)? = nil) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        try await sendRaw(HQMessageHeader(type: type, length: size).encoded)
        var sent: Int64 = 0
        while let chunk = try handle.read(upToCount: HQ.chunkSize), !chunk.isEmpty {
            try await sendRaw(chunk)
            sent += Int64(chunk.count)
            progress?(sent)
        }
    }

    private func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    // MARK: Receiving

    func receiveHeader() async throws -> HQMessageHeader {
        guard let header = HQMessageHeader(try await receiveExactly(HQMessageHeader.size)) else { throw HQTransferError.closed }
        return header
    }

    /// Receives one small message. Error messages from the other side are thrown.
    func receiveMessage() async throws -> (type: HQMessageType?, payload: Data) {
        let header = try await receiveHeader()
        guard header.length <= HQ.maxInMemoryMessage else { throw HQTransferError.tooLarge }
        let payload = header.length == 0 ? Data() : try await receiveExactly(Int(header.length))
        if header.type == .error, let error = try? JSONDecoder().decode(HQErrorMessage.self, from: payload) {
            throw error
        }
        return (header.type, payload)
    }

    func receiveJSON<T: Decodable>(_ type: HQMessageType, as: T.Type) async throws -> T {
        let message = try await receiveMessage()
        guard message.type == type else { throw HQTransferError.unexpected(message.type, expected: type) }
        return try JSONDecoder().decode(T.self, from: message.payload)
    }

    /// Receives the next message, which must be `type`, streaming its bytes into `url`.
    func receiveFile(_ type: HQMessageType, to url: URL, progress: (@Sendable (Int64) -> Void)? = nil) async throws {
        let header = try await receiveHeader()
        if header.type == .error {
            let payload = try await receiveExactly(Int(min(header.length, HQ.maxInMemoryMessage)))
            throw (try? JSONDecoder().decode(HQErrorMessage.self, from: payload)) ?? HQTransferError.closed
        }
        guard header.type == type else { throw HQTransferError.unexpected(header.type, expected: type) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var remaining = header.length
        var received: Int64 = 0
        while remaining > 0 {
            let chunk = try await receiveExactly(Int(min(remaining, UInt64(HQ.chunkSize))))
            try handle.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
            received += Int64(chunk.count)
            progress?(received)
        }
    }

    private func receiveExactly(_ count: Int) async throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            let needed = count - buffer.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: needed) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: HQTransferError.closed)
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
            buffer.append(chunk)
        }
        return buffer
    }
}

/// Runs a closure at most once, from any thread.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

/// Which files of a scan folder go to the Mac.
enum HQPackage {
    struct File: Sendable, Equatable {
        var path: String   // relative to the scan folder, e.g. "Images/0001.jpg"
        var url: URL
        var size: Int64
    }

    static func files(in folder: ScanFolder) -> [File] {
        var files: [File] = []
        let fm = FileManager.default
        for directory in [folder.images, folder.masks, folder.depth, folder.checkpoint] {
            guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { continue }
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }
                let relative = String(url.standardizedFileURL.path(percentEncoded: false)
                    .dropFirst(folder.root.standardizedFileURL.path(percentEncoded: false).count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                files.append(File(path: relative, url: url, size: Int64(values?.fileSize ?? 0)))
            }
        }
        if fm.fileExists(atPath: folder.personManifest.path(percentEncoded: false)) {
            let size = (try? folder.personManifest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            files.append(File(path: "frames.json", url: folder.personManifest, size: Int64(size)))
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Only plain relative paths inside the scan folder are allowed.
    static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains { $0.isEmpty || $0 == ".." || $0 == "." }
    }
}
