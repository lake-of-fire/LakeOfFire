import Foundation

/// Structural preflight for the exact-identity reader, not a replacement ZIP
/// extractor. ZIPFoundation must see the same complete ordinary ZIP that this
/// check sees. Its public Entry API can prefer descriptor/local-header values
/// over central-directory fields; comparing only Entry.checksum is insufficient.
enum ReaderEBookZIPDirectory {
    static func validate(_ url: URL, maximumEntryCount: Int, requireUTF8Paths: Bool = false) throws -> Int {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let length = try input.seekToEnd()
        guard length >= 22 else { throw ReaderEBookFingerprintError.invalidPackage }
        let tailLength = Int(min(length, 65_557))
        let tail = try read(input, at: length - UInt64(tailLength), count: tailLength)
        guard let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
            u32(tail, $0) == 0x06054b50 && $0 + 22 + Int(u16(tail, $0 + 20)) == tail.count
        }) else { throw ReaderEBookFingerprintError.invalidPackage }
        // Do not let the library choose a different EOCD hidden in the comment.
        let comment = tail.subdata(in: end + 22..<tail.count)
        guard comment.range(of: Data([0x50, 0x4b, 0x05, 0x06])) == nil else {
            throw ReaderEBookFingerprintError.invalidPackage
        }
        let count = u16(tail, end + 10)
        let size = u32(tail, end + 12)
        let offset = u32(tail, end + 16)
        guard count != 0xffff, size != 0xffffffff, offset != 0xffffffff,
              u16(tail, end + 4) == 0, u16(tail, end + 6) == 0,
              u16(tail, end + 8) == count else {
            throw ReaderEBookFingerprintError.unsupportedEntry("ZIP64 or multidisk archive")
        }
        guard count <= UInt64(max(0, maximumEntryCount)) else {
            throw ReaderEBookFingerprintError.limitExceeded
        }
        let endOffset = length - UInt64(tailLength) + UInt64(end)
        guard offset <= endOffset, size == endOffset - offset else {
            throw ReaderEBookFingerprintError.invalidPackage
        }
        var position = offset
        var spans = [(start: UInt64, end: UInt64)]()
        for _ in 0..<Int(count) {
            try Task.checkCancellation()
            guard position <= endOffset, endOffset - position >= 46 else {
                throw ReaderEBookFingerprintError.invalidPackage
            }
            let central = try read(input, at: position, count: 46)
            guard u32(central, 0) == 0x02014b50 else { throw ReaderEBookFingerprintError.invalidPackage }
            let nameLength = u16(central, 28)
            let extraLength = u16(central, 30)
            let recordSize = 46 + nameLength + extraLength + u16(central, 32)
            guard nameLength > 0, recordSize <= endOffset - position else {
                throw ReaderEBookFingerprintError.invalidPackage
            }
            let flags = u16(central, 8)
            let method = u16(central, 10)
            let compressed = u32(central, 20)
            let uncompressed = u32(central, 24)
            let localOffset = u32(central, 42)
            // v1 deliberately supports stored/deflated ordinary ZIPs only.
            // Bits 1/2 are deflate options, 3 is a descriptor, 11 is UTF-8.
            guard flags & ~UInt64(0x080e) == 0, method == 0 || method == 8,
                  u16(central, 6) < 45, u16(central, 34) == 0,
                  compressed != 0xffffffff, uncompressed != 0xffffffff,
                  localOffset != 0xffffffff else {
                throw ReaderEBookFingerprintError.unsupportedEntry("ZIP entry representation")
            }
            let name = try read(input, at: position + 46, count: Int(nameLength))
            guard (!requireUTF8Paths && flags & 0x0800 == 0) || String(data: name, encoding: .utf8) != nil else {
                throw ReaderEBookFingerprintError.invalidPackage
            }
            try validateExtra(try read(input, at: position + 46 + nameLength, count: Int(extraLength)))
            guard localOffset <= offset, offset - localOffset >= 30 else {
                throw ReaderEBookFingerprintError.invalidPackage
            }
            let local = try read(input, at: localOffset, count: 30)
            guard u32(local, 0) == 0x04034b50,
                  u16(local, 4) < 45, u16(local, 6) == flags,
                  u16(local, 8) == method, u16(local, 26) == nameLength else {
                throw ReaderEBookFingerprintError.invalidPackage
            }
            let localExtraLength = u16(local, 28)
            let localHeaderSize = 30 + nameLength + localExtraLength
            guard localHeaderSize <= offset - localOffset else { throw ReaderEBookFingerprintError.invalidPackage }
            let localName = try read(input, at: localOffset + 30, count: Int(nameLength))
            guard localName == name else { throw ReaderEBookFingerprintError.invalidPackage }
            try validateExtra(try read(input, at: localOffset + 30 + nameLength, count: Int(localExtraLength)))
            let dataStart = localOffset + localHeaderSize
            guard compressed <= offset - dataStart else { throw ReaderEBookFingerprintError.invalidPackage }
            let crc = u32(central, 16)
            let hasDescriptor = flags & 8 != 0
            let localValues = [u32(local, 14), u32(local, 18), u32(local, 22)]
            let centralValues = [crc, compressed, uncompressed]
            guard zip(localValues, centralValues).allSatisfy({ local, central in
                local == central || (hasDescriptor && local == 0)
            }), method != 0 || compressed == uncompressed else {
                throw ReaderEBookFingerprintError.invalidPackage
            }
            var recordEnd = dataStart + compressed
            if hasDescriptor {
                // Both signed and unsigned descriptors are legal. Check values,
                // not just the signature (which can also be an unsigned CRC).
                let available = min(UInt64(16), offset - recordEnd)
                guard available >= 12 else { throw ReaderEBookFingerprintError.invalidPackage }
                let descriptor = try read(input, at: recordEnd, count: Int(available))
                let unsigned = u32(descriptor, 0) == crc && u32(descriptor, 4) == compressed
                    && u32(descriptor, 8) == uncompressed
                let signed = available == 16 && u32(descriptor, 0) == 0x08074b50
                    && u32(descriptor, 4) == crc && u32(descriptor, 8) == compressed
                    && u32(descriptor, 12) == uncompressed
                guard unsigned || signed else { throw ReaderEBookFingerprintError.invalidPackage }
                recordEnd += signed ? 16 : 12
            }
            spans.append((localOffset, recordEnd))
            position += recordSize
        }
        guard position == endOffset else { throw ReaderEBookFingerprintError.invalidPackage }
        var previousEnd: UInt64 = 0
        for span in spans.sorted(by: { $0.start < $1.start }) {
            guard span.start >= previousEnd else { throw ReaderEBookFingerprintError.invalidPackage }
            previousEnd = span.end
        }
        return Int(count)
    }

    private static func validateExtra(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            guard data.count - offset >= 4 else { throw ReaderEBookFingerprintError.invalidPackage }
            let kind = u16(data, offset)
            let size = Int(u16(data, offset + 2))
            guard size <= data.count - offset - 4 else { throw ReaderEBookFingerprintError.invalidPackage }
            guard kind != 0x0001 else { throw ReaderEBookFingerprintError.unsupportedEntry("ZIP64 entry") }
            offset += 4 + size
        }
    }
    private static func read(_ file: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try Task.checkCancellation()
        if count == 0 { return Data() }
        try file.seek(toOffset: offset)
        guard let data = try file.read(upToCount: count), data.count == count else {
            throw ReaderEBookFingerprintError.invalidPackage
        }
        return data
    }
    private static func u16(_ data: Data, _ index: Int) -> UInt64 {
        UInt64(data[index]) | (UInt64(data[index + 1]) << 8)
    }
    private static func u32(_ data: Data, _ index: Int) -> UInt64 {
        u16(data, index) | (u16(data, index + 2) << 16)
    }
}
