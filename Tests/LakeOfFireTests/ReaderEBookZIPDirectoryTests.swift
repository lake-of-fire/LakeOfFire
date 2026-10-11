import Foundation
import XCTest
@testable import LakeOfFireContent

/// Exercises the production structural preflight without an extractor mock.
/// These fixtures have a real ordinary ZIP layout and a known CRC for "abc".
/// Full decompression/fingerprint coverage remains in the package scanner tests.
final class ReaderEBookZIPDirectoryTests: XCTestCase {
    private func integer(_ value: UInt64, _ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private func zipBytes(name: Data = Data("entry.bin".utf8), descriptor: Bool = false,
                          signed: Bool = true, extra: Data = Data(), comment: Data = Data()) -> Data {
        let flags: UInt64 = 0x0800 | (descriptor ? 8 : 0)
        let crc: UInt64 = 0x352441c2
        var local = integer(0x04034b50, 4)
        for value in [UInt64(20), flags, 0, 0, 0] { local += integer(value, 2) }
        for value in [descriptor ? 0 : crc, descriptor ? 0 : 3, descriptor ? 0 : 3] {
            local += integer(value, 4)
        }
        local += integer(UInt64(name.count), 2) + integer(UInt64(extra.count), 2) + name + extra
        local += Data("abc".utf8)
        if descriptor {
            if signed { local += integer(0x08074b50, 4) }
            local += integer(crc, 4) + integer(3, 4) + integer(3, 4)
        }
        var central = integer(0x02014b50, 4)
        for value in [UInt64(20), 20, flags, 0, 0, 0] { central += integer(value, 2) }
        central += integer(crc, 4) + integer(3, 4) + integer(3, 4)
        for value in [UInt64(name.count), UInt64(extra.count), 0, 0, 0] { central += integer(value, 2) }
        central += integer(0, 4) + integer(0, 4) + name + extra
        var end = integer(0x06054b50, 4)
        for value in [UInt64(0), 0, 1, 1] { end += integer(value, 2) }
        end += integer(UInt64(central.count), 4) + integer(UInt64(local.count), 4)
        end += integer(UInt64(comment.count), 2) + comment
        return local + central + end
    }
    private func centralOffset(_ bytes: Data) throws -> Int {
        try XCTUnwrap(bytes.range(of: Data([0x50, 0x4b, 0x01, 0x02]))).lowerBound
    }
    private func validate(_ bytes: Data, maximum: Int = 100) throws -> Int {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try bytes.write(to: url)
        return try ReaderEBookZIPDirectory.validate(url, maximumEntryCount: maximum)
    }
    func testOrdinaryStoredEntryAccepted() throws { XCTAssertEqual(try validate(zipBytes()), 1) }
    func testSignedDescriptorAccepted() throws { XCTAssertEqual(try validate(zipBytes(descriptor: true)), 1) }
    func testUnsignedDescriptorAccepted() throws { XCTAssertEqual(try validate(zipBytes(descriptor: true, signed: false)), 1) }
    func testOrdinaryCommentAccepted() throws {
        XCTAssertEqual(try validate(zipBytes(comment: Data("archive comment".utf8))), 1)
    }
    func testLocalFilenameCannotDisagreeWithCentralFilename() throws {
        var bytes = zipBytes(); bytes[30] ^= 1
        XCTAssertThrowsError(try validate(bytes))
    }
    func testLocalMethodCannotDisagreeWithCentralMethod() throws {
        var bytes = zipBytes(); bytes[8] = 8
        XCTAssertThrowsError(try validate(bytes))
    }
    func testLocalFlagsCannotDisagreeWithCentralFlags() throws {
        var bytes = zipBytes(); bytes[6] = 8
        XCTAssertThrowsError(try validate(bytes))
    }
    func testLocalCRCAndSizesCannotDisagreeWithoutDescriptor() throws {
        for offset in [14, 18, 22] {
            var bytes = zipBytes(); bytes[offset] ^= 1
            XCTAssertThrowsError(try validate(bytes), "field at \(offset)")
        }
    }
    func testCentralCRCMustAgreeWithDescriptor() throws {
        var bytes = zipBytes(descriptor: true)
        bytes[try centralOffset(bytes) + 16] ^= 1
        XCTAssertThrowsError(try validate(bytes))
    }
    func testDescriptorSizeCannotDisagreeWithCentralDirectory() throws {
        var bytes = zipBytes(descriptor: true)
        bytes[try centralOffset(bytes) - 4] ^= 1
        XCTAssertThrowsError(try validate(bytes))
    }
    func testEntryDiskNumberCannotHideInsideSingleDiskArchive() throws {
        var bytes = zipBytes(); bytes[try centralOffset(bytes) + 34] = 1
        XCTAssertThrowsError(try validate(bytes))
    }
    func testZIP64EntryVersionRejectedEvenWithOrdinaryEOCD() throws {
        var bytes = zipBytes(); bytes[try centralOffset(bytes) + 6] = 45
        XCTAssertThrowsError(try validate(bytes))
    }
    func testZIP64EntryExtraRejectedEvenWithoutSentinelSizes() throws {
        XCTAssertThrowsError(try validate(zipBytes(extra: Data([1, 0, 0, 0]))))
    }
    func testIncompleteExtraFieldRejected() throws {
        XCTAssertThrowsError(try validate(zipBytes(extra: Data([2, 0, 10, 0, 1]))))
    }
    func testInvalidUTF8FilenameRejectedRatherThanLossilyDecoded() throws {
        XCTAssertThrowsError(try validate(zipBytes(name: Data([0xff, 0xfe]))))
    }
    func testEntryCountBudgetAppliedBeforeDirectoryWalk() throws {
        var bytes = zipBytes()
        let end = bytes.count - 22
        bytes.replaceSubrange(end + 8..<end + 12, with: Data([0xe8, 3, 0xe8, 3]))
        XCTAssertThrowsError(try validate(bytes, maximum: 2)) {
            XCTAssertEqual($0 as? ReaderEBookFingerprintError, .limitExceeded)
        }
    }
    func testEOCDInsideCommentCannotSelectAnotherArchiveView() throws {
        XCTAssertThrowsError(try validate(zipBytes(comment: Data([0x50, 0x4b, 0x05, 0x06]))))
    }
    func testOverlappingLocalRecordsRejected() throws {
        let original = zipBytes()
        let offset = try centralOffset(original)
        let directory = original.subdata(in: offset..<original.count - 22)
        var end = original.subdata(in: original.count - 22..<original.count)
        end.replaceSubrange(8..<12, with: Data([2, 0, 2, 0]))
        end.replaceSubrange(12..<16, with: integer(UInt64(directory.count * 2), 4))
        XCTAssertThrowsError(try validate(original.prefix(offset) + directory + directory + end))
    }
    func testPayloadMustEndBeforeCentralDirectory() throws {
        var bytes = zipBytes()
        let central = try centralOffset(bytes)
        bytes.replaceSubrange(18..<26, with: integer(1000, 4) + integer(1000, 4))
        bytes.replaceSubrange(central + 20..<central + 28, with: integer(1000, 4) + integer(1000, 4))
        XCTAssertThrowsError(try validate(bytes))
    }
    func testEncryptionFlagsRejectedEvenWhenHeadersAgree() throws {
        var bytes = zipBytes()
        let central = try centralOffset(bytes)
        bytes[6] |= 1; bytes[central + 8] |= 1
        XCTAssertThrowsError(try validate(bytes))
    }
}
