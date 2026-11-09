import Foundation

/// Minimal ZIP writer that stores files without compression.
///
/// USDZ files are exactly this: an uncompressed zip whose file data starts on
/// 64-byte boundaries. The same writer packs OBJ exports for sharing.
struct ZipWriter {
    private var output = Data()
    private var centralDirectory = Data()
    private var entryCount: UInt16 = 0
    private let alignment: Int

    /// - Parameter alignment: byte boundary for each file's data (USDZ needs 64).
    init(alignment: Int = 64) {
        self.alignment = max(1, alignment)
    }

    /// - Parameter executable: mark the file runnable (e.g. a .command script) when unzipped on a Mac.
    mutating func add(name: String, data: Data, executable: Bool = false) {
        let nameBytes = Data(name.utf8)
        let crc = CRC32.checksum(data)
        let localHeaderOffset = UInt32(output.count)

        // Pad with an extra field so the file data lands on the alignment boundary.
        var extra = Data()
        let headerEnd = output.count + 30 + nameBytes.count
        if alignment > 1 {
            var padding = (alignment - (headerEnd + 4) % alignment) % alignment
            if padding < 0 { padding += alignment }
            extra.appendLE(UInt16(0x1986)) // private extra-field id (same one Pixar's USD uses)
            extra.appendLE(UInt16(padding))
            extra.append(Data(count: padding))
        }

        // Local file header
        output.appendLE(UInt32(0x0403_4B50))
        output.appendLE(UInt16(20))        // version needed
        output.appendLE(UInt16(0))         // flags
        output.appendLE(UInt16(0))         // compression: stored
        output.appendLE(UInt16(0))         // mod time
        output.appendLE(UInt16(0x0021))    // mod date (1980-01-01)
        output.appendLE(crc)
        output.appendLE(UInt32(data.count)) // compressed size
        output.appendLE(UInt32(data.count)) // uncompressed size
        output.appendLE(UInt16(nameBytes.count))
        output.appendLE(UInt16(extra.count))
        output.append(nameBytes)
        output.append(extra)
        output.append(data)

        // Central directory entry
        centralDirectory.appendLE(UInt32(0x0201_4B50))
        centralDirectory.appendLE(UInt16(0x0314)) // version made by: Unix, 2.0 (so permissions apply)
        centralDirectory.appendLE(UInt16(20))  // version needed
        centralDirectory.appendLE(UInt16(0))
        centralDirectory.appendLE(UInt16(0))
        centralDirectory.appendLE(UInt16(0))
        centralDirectory.appendLE(UInt16(0x0021))
        centralDirectory.appendLE(crc)
        centralDirectory.appendLE(UInt32(data.count))
        centralDirectory.appendLE(UInt32(data.count))
        centralDirectory.appendLE(UInt16(nameBytes.count))
        centralDirectory.appendLE(UInt16(0))  // extra length
        centralDirectory.appendLE(UInt16(0))  // comment length
        centralDirectory.appendLE(UInt16(0))  // disk number
        centralDirectory.appendLE(UInt16(0))  // internal attributes
        let mode: UInt32 = executable ? 0o100755 : 0o100644
        centralDirectory.appendLE(mode << 16)  // external attributes: Unix file mode
        centralDirectory.appendLE(localHeaderOffset)
        centralDirectory.append(nameBytes)

        entryCount += 1
    }

    /// Returns the finished archive.
    func finish() -> Data {
        var archive = output
        let directoryOffset = UInt32(archive.count)
        archive.append(centralDirectory)
        archive.appendLE(UInt32(0x0605_4B50))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(entryCount)
        archive.appendLE(entryCount)
        archive.appendLE(UInt32(centralDirectory.count))
        archive.appendLE(directoryOffset)
        archive.appendLE(UInt16(0))
        return archive
    }
}

/// Reads files stored without compression (enough for USDZ, which never compresses).
enum ZipReader {
    struct Entry {
        let name: String
        let data: Data
    }

    static func storedEntries(in archive: Data) -> [Entry] {
        let bytes = [UInt8](archive)
        guard bytes.count >= 22 else { return [] }
        // Find the end-of-central-directory record (search backwards).
        var eocd = -1
        var i = bytes.count - 22
        while i >= 0 {
            if bytes.readLE32(at: i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return [] }
        let count = Int(bytes.readLE16(at: eocd + 10))
        var cursor = Int(bytes.readLE32(at: eocd + 16))

        var entries: [Entry] = []
        for _ in 0..<count {
            guard cursor + 46 <= bytes.count, bytes.readLE32(at: cursor) == 0x0201_4B50 else { break }
            let method = bytes.readLE16(at: cursor + 10)
            let size = Int(bytes.readLE32(at: cursor + 20))
            let nameLength = Int(bytes.readLE16(at: cursor + 28))
            let extraLength = Int(bytes.readLE16(at: cursor + 30))
            let commentLength = Int(bytes.readLE16(at: cursor + 32))
            let localOffset = Int(bytes.readLE32(at: cursor + 42))
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            cursor += 46 + nameLength + extraLength + commentLength

            guard method == 0, localOffset + 30 <= bytes.count else { continue }
            let localName = Int(bytes.readLE16(at: localOffset + 26))
            let localExtra = Int(bytes.readLE16(at: localOffset + 28))
            let start = localOffset + 30 + localName + localExtra
            guard start + size <= bytes.count else { continue }
            entries.append(Entry(name: name, data: Data(bytes[start..<(start + size)])))
        }
        return entries
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

private extension [UInt8] {
    func readLE16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func readLE32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }
}
