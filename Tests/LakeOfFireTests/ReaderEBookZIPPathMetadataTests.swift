import Foundation
import XCTest
@testable import LakeOfFireContent

/// Real stored ZIP records with independently built central/local metadata.
/// No ZIPFoundation APIs run in this portable preflight fixture.
enum EBookZIPPathFixture {
    struct File {
        let name: Data
        var bytes = Data("abc".utf8)
        var flags: UInt64 = 0x0800
        var localExtra = Data()
        var centralExtra = Data()
    }

    static func integer(_ value: UInt64, bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    // Small bitwise reference. The production implementation uses a table.
    static func crc(_ bytes: Data) -> UInt64 {
        var value: UInt32 = 0xffffffff
        for byte in bytes {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = value & 1 == 0 ? value >> 1 : (value >> 1) ^ 0xedb88320 }
        }
        return UInt64(value ^ 0xffffffff)
    }

    static func field(_ payload: Data, kind: UInt64 = 0x7075) -> Data {
        integer(kind, bytes: 2) + integer(UInt64(payload.count), bytes: 2) + payload
    }

    static func unicode(_ name: Data, alternate: Data? = nil, version: UInt8 = 1,
                        checksum: UInt64? = nil) -> Data {
        field(Data([version]) + integer(checksum ?? crc(name), bytes: 4) + (alternate ?? name))
    }

    static func archive(_ files: [File]) -> Data {
        var local = Data(), central = Data()
        for file in files {
            let offset = local.count
            let checksum = crc(file.bytes), size = UInt64(file.bytes.count)
            local += integer(0x04034b50, bytes: 4)
            for value in [UInt64(20), file.flags, 0, 0, 0] { local += integer(value, bytes: 2) }
            for value in [checksum, size, size] { local += integer(value, bytes: 4) }
            local += integer(UInt64(file.name.count), bytes: 2)
            local += integer(UInt64(file.localExtra.count), bytes: 2)
            local += file.name + file.localExtra + file.bytes
            central += integer(0x02014b50, bytes: 4)
            for value in [UInt64(20), 20, file.flags, 0, 0, 0] { central += integer(value, bytes: 2) }
            for value in [checksum, size, size] { central += integer(value, bytes: 4) }
            for value in [UInt64(file.name.count), UInt64(file.centralExtra.count), 0, 0, 0] {
                central += integer(value, bytes: 2)
            }
            central += integer(0, bytes: 4) + integer(UInt64(offset), bytes: 4)
            central += file.name + file.centralExtra
        }
        var end = integer(0x06054b50, bytes: 4)
        for value in [UInt64(0), 0, UInt64(files.count), UInt64(files.count)] { end += integer(value, bytes: 2) }
        end += integer(UInt64(central.count), bytes: 4) + integer(UInt64(local.count), bytes: 4)
        end += integer(0, bytes: 2)
        return local + central + end
    }

    static func withFile<T>(_ bytes: Data, _ body: (URL) throws -> T) throws -> T {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url)
    }
}

final class ReaderEBookZIPPathMetadataTests: XCTestCase {
    private let resourceName = Data("OPS/日本語.xhtml".utf8)
    private func validate(name: Data? = nil, flags: UInt64 = 0x0800,
                          local: Data = Data(), central: Data = Data(), forceUTF8: Bool = false) throws -> Int {
        let file = EBookZIPPathFixture.File(name: name ?? self.resourceName, flags: flags,
                                           localExtra: local, centralExtra: central)
        return try EBookZIPPathFixture.withFile(EBookZIPPathFixture.archive([file])) {
            try ReaderEBookZIPDirectory.validate($0, maximumEntryCount: 10, requireUTF8Paths: forceUTF8)
        }
    }

    func testRedundantUnicodePathAcceptedWithUTF8Flag() throws {
        XCTAssertEqual(try validate(local: EBookZIPPathFixture.unicode(resourceName)), 1)
    }

    func testRedundantASCIIPathAcceptedWithoutLanguageFlag() throws {
        let ascii = Data("OPS/chapter.xhtml".utf8)
        XCTAssertEqual(try validate(name: ascii, flags: 0, local: EBookZIPPathFixture.unicode(ascii)), 1)
    }

    func testFoundationUTF8OverrideAllowsConsistentUnflaggedMetadata() throws {
        XCTAssertEqual(try validate(flags: 0, local: EBookZIPPathFixture.unicode(resourceName), forceUTF8: true), 1)
    }

    func testOrdinaryUnflaggedNonASCIIPathCannotChangeDecoder() {
        XCTAssertThrowsError(try validate(flags: 0, local: EBookZIPPathFixture.unicode(resourceName)))
    }

    func testAlternateUnicodeNameRejectedInEitherHeader() {
        let alternate = EBookZIPPathFixture.unicode(resourceName, alternate: Data("OPS/other.xhtml".utf8))
        XCTAssertThrowsError(try validate(local: alternate))
        XCTAssertThrowsError(try validate(central: alternate))
    }

    func testCanonicalUnicodeEqualityDoesNotMergeDifferentPathBytes() {
        let composed = Data("OPS/caf\u{e9}.xhtml".utf8)
        let decomposed = Data("OPS/cafe\u{301}.xhtml".utf8)
        XCTAssertThrowsError(try validate(name: composed,
            local: EBookZIPPathFixture.unicode(composed, alternate: decomposed)))
    }

    func testUnicodeMetadataCannotChangeFileIntoDirectory() {
        XCTAssertThrowsError(try validate(local: EBookZIPPathFixture.unicode(resourceName, alternate: resourceName + Data([47]))))
    }

    func testShortUnicodeFieldRejectedBeforeLibraryCanReadIt() {
        // Development ZIPFoundation reads fixed fields without checking this
        // minimum payload size. Do not invoke that extractor on the red case.
        for count in 0..<6 {
            let extra = EBookZIPPathFixture.field(Data(repeating: 0, count: count))
            XCTAssertThrowsError(try validate(local: extra), "local payload length \(count)")
            XCTAssertThrowsError(try validate(central: extra), "central payload length \(count)")
        }
    }

    func testInvalidUTF8UnicodeMetadataRejected() {
        XCTAssertThrowsError(try validate(local: EBookZIPPathFixture.unicode(resourceName, alternate: Data([0xff]))))
    }

    func testUnknownUnicodeMetadataVersionRejected() {
        XCTAssertThrowsError(try validate(local: EBookZIPPathFixture.unicode(resourceName, version: 2)))
    }

    func testUnicodeMetadataCRCMustBindTheOriginalName() {
        XCTAssertEqual(EBookZIPPathFixture.crc(Data("123456789".utf8)), 0xcbf43926)
        XCTAssertThrowsError(try validate(local: EBookZIPPathFixture.unicode(resourceName, checksum: 0)))
    }

    func testDuplicateUnicodePathFieldsRejectedEvenWhenIdentical() {
        let field = EBookZIPPathFixture.unicode(resourceName)
        XCTAssertThrowsError(try validate(local: field + field))
        XCTAssertThrowsError(try validate(central: field + field))
    }

    func testUnrelatedExtraFieldsStillAccepted() throws {
        let extra = EBookZIPPathFixture.field(Data([1, 2, 3]), kind: 0x9999)
        XCTAssertEqual(try validate(local: extra, central: extra), 1)
    }

    func testUnflaggedLegacyNameWithoutOverrideStillAcceptedByPreflight() throws {
        XCTAssertEqual(try validate(name: Data([0x82, 0x2e, 0x78]), flags: 0), 1)
    }

    func testMatchingUnicodeFieldsInBothHeadersRemainAccepted() throws {
        let field = EBookZIPPathFixture.unicode(resourceName)
        XCTAssertEqual(try validate(local: field, central: field), 1)
    }
}
