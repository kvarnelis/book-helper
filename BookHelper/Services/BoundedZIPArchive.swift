import Foundation
import zlib

/// A read-only ZIP reader. Nothing is extracted to disk. Only stored/deflated,
/// single-volume ZIPs are accepted; every allocation and inflate has a hard cap.
struct BoundedZIPArchive {
    static let maxArchiveBytes = 128 * 1024 * 1024
    private let data: Data
    private let entries: [String: Entry]
    private var bytesRead = 0

    private struct Entry {
        let method: UInt16
        let crc: UInt32
        let size: Int
        let compressedRange: Range<Int>
    }

    init(url: URL) throws {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw EPUBError.invalid
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: Self.maxArchiveBytes + 1) ?? Data()
        guard data.count <= Self.maxArchiveBytes else { throw EPUBError.tooLarge }
        guard data.count >= 22 else { throw EPUBError.invalid }

        // The end record must finish at EOF, including its optional ZIP comment.
        let end = stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1).first {
            data.u32($0) == 0x06054b50 && $0 + 22 + Int(data.u16($0 + 20)) == data.count
        }
        guard let end else { throw EPUBError.invalid }
        let count = Int(data.u16(end + 10))
        let directorySize = Int(data.u32(end + 12))
        let directoryStart = Int(data.u32(end + 16))
        guard data.u16(end + 4) == 0, data.u16(end + 6) == 0,
              Int(data.u16(end + 8)) == count, count != 65_535,
              directorySize != Int(UInt32.max), directoryStart != Int(UInt32.max) else {
            throw EPUBError.unsupported
        }
        guard count <= 10_000 else { throw EPUBError.tooLarge }
        guard directoryStart + directorySize == end else { throw EPUBError.invalid }

        var entries: [String: Entry] = [:]
        var position = directoryStart
        var expandedSize = 0
        var ranges: [Range<Int>] = []
        for _ in 0..<count {
            guard position + 46 <= end, data.u32(position) == 0x02014b50 else { throw EPUBError.invalid }
            let flags = data.u16(position + 8)
            let method = data.u16(position + 10)
            let crc = data.u32(position + 16)
            let compressedSize = Int(data.u32(position + 20))
            let size = Int(data.u32(position + 24))
            let nameSize = Int(data.u16(position + 28))
            let extraSize = Int(data.u16(position + 30))
            let commentSize = Int(data.u16(position + 32))
            let local = Int(data.u32(position + 42))
            let next = position + 46 + nameSize + extraSize + commentSize
            guard next <= end, nameSize > 0, data.u16(position + 34) == 0 else { throw EPUBError.invalid }
            guard flags & 0x0041 == 0 else { throw EPUBError.protectedBook }
            guard flags & 0x2000 == 0, method == 0 || method == 8,
                  size != Int(UInt32.max), compressedSize != Int(UInt32.max), local != Int(UInt32.max) else {
                throw EPUBError.unsupported
            }
            let nameData = data.subdata(in: position + 46..<position + 46 + nameSize)
            guard let name = String(data: nameData, encoding: .utf8), Self.safeEntryName(name), entries[name] == nil else {
                throw EPUBError.invalid
            }
            // Do not interpret symlink or special-file entries, even though no files are extracted.
            let mode = (data.u32(position + 38) >> 16) & 0xf000
            guard mode == 0 || mode == 0x8000 || mode == 0x4000 else { throw EPUBError.unsupported }
            expandedSize += size
            guard size <= 32 * 1024 * 1024, expandedSize <= 256 * 1024 * 1024 else { throw EPUBError.tooLarge }

            guard local + 30 <= directoryStart, data.u32(local) == 0x04034b50,
                  data.u16(local + 6) == flags, data.u16(local + 8) == method else { throw EPUBError.invalid }
            let localNameSize = Int(data.u16(local + 26))
            let start = local + 30 + localNameSize + Int(data.u16(local + 28))
            guard start + compressedSize <= directoryStart, localNameSize == nameSize,
                  data.subdata(in: local + 30..<local + 30 + localNameSize) == nameData else { throw EPUBError.invalid }
            if flags & 8 == 0 {
                guard data.u32(local + 14) == crc, Int(data.u32(local + 18)) == compressedSize,
                      Int(data.u32(local + 22)) == size else { throw EPUBError.invalid }
            }
            ranges.append(local..<start + compressedSize)
            entries[name] = Entry(method: method, crc: crc, size: size, compressedRange: start..<start + compressedSize)
            position = next
        }
        guard position == end else { throw EPUBError.invalid }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        for (left, right) in zip(sorted, sorted.dropFirst()) where left.upperBound > right.lowerBound {
            throw EPUBError.invalid
        }
        self.data = data
        self.entries = entries
    }

    func contains(_ name: String) -> Bool { entries[name] != nil }
    func size(of name: String) -> Int? { entries[name]?.size }

    mutating func read(_ name: String, limit: Int) throws -> Data {
        guard let entry = entries[name] else { throw EPUBError.invalid }
        guard entry.size <= limit, entry.compressedRange.count <= limit + 65_536,
              bytesRead + entry.size <= 12 * 1024 * 1024 else { throw EPUBError.tooLarge }
        bytesRead += entry.size
        let compressed = data.subdata(in: entry.compressedRange)
        let result: Data
        if entry.method == 0 {
            guard compressed.count == entry.size else { throw EPUBError.invalid }
            result = compressed
        } else {
            // One extra byte detects streams lying about their expanded size.
            var output = Data(count: entry.size + 1)
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw EPUBError.invalid
            }
            defer { inflateEnd(&stream) }
            let status: Int32 = compressed.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { destination in
                    stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(input.count)
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(destination.count)
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard status == Z_STREAM_END, stream.total_out == entry.size,
                  stream.total_in == compressed.count else { throw EPUBError.invalid }
            output.removeLast()
            result = output
        }
        let checksum = result.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
        guard UInt32(checksum) == entry.crc else { throw EPUBError.invalid }
        return result
    }

    private static func safeEntryName(_ name: String) -> Bool {
        let path = name.hasSuffix("/") ? String(name.dropLast()) : name
        return !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":") &&
            !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

private extension Data {
    // Callers check their containing record's bounds before reading integers.
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
}
