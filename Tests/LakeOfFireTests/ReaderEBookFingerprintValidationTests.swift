import Foundation
import XCTest
import ZIPFoundation
@testable import LakeOfFireContent

final class ReaderEBookFingerprintValidationTests: XCTestCase {
    private let files: [(String, Data)] = [
        ("mimetype", Data("application/epub+zip".utf8)),
        ("META-INF/container.xml", Data("<container/>".utf8)),
        ("OPS/book.opf", Data("<package/>".utf8))
    ]
    private func withZIP(extra: [(String, Data)] = [], directories: [String] = [],
                         _ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let archive = try Archive(url: url, accessMode: .create)
            for path in directories {
                try archive.addEntry(with: path, type: .directory, uncompressedSize: Int64(0)) { _, _ in Data() }
            }
            for (path, bytes) in files + extra {
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count)) { offset, count in
                    bytes.subdata(in: Int(offset)..<Int(offset) + count)
                }
            }
        }
        try body(url)
    }
    private func fingerprint(_ url: URL) throws -> ReaderEBookPackageFingerprint {
        try .readSnapshot(at: url, packageDocumentPath: "OPS/book.opf")
    }
    func testExplicitEmptyDirectoriesDoNotChangeFingerprint() throws {
        try withZIP { plain in
            try withZIP(directories: ["OPS/", "META-INF/", "empty/"]) { directoryEntries in
                XCTAssertEqual(try fingerprint(plain), try fingerprint(directoryEntries))
            }
        }
    }
    func testDuplicateDirectoryEntriesAreAmbiguous() throws {
        try withZIP(directories: ["empty/", "empty/"]) { url in
            XCTAssertThrowsError(try fingerprint(url))
        }
    }
    func testFileCannotAlsoBeAnExplicitDirectory() throws {
        try withZIP(extra: [("empty", Data())], directories: ["empty/"]) { url in
            XCTAssertThrowsError(try fingerprint(url))
        }
    }
    func testFileCannotAlsoBeAnImplicitDirectoryInEitherEntryOrder() throws {
        let entries = [("section", Data([1])), ("section/chapter.xhtml", Data([2]))]
        for extra in [entries, entries.reversed().map { $0 }] {
            try withZIP(extra: extra) { url in XCTAssertThrowsError(try fingerprint(url)) }
        }
    }
    func testPrefixSearchDoesNotMissFileDirectoryCollisionBehindSiblingName() throws {
        try withZIP(extra: [("a", Data()), ("a-else", Data()), ("a/child", Data())]) { url in
            XCTAssertThrowsError(try fingerprint(url))
        }
    }
    func testUnicodeEquivalentNamesCannotAliasInsideOneArchive() throws {
        try withZIP(extra: [("caf\u{e9}.xhtml", Data([1])), ("cafe\u{301}.xhtml", Data([2]))]) { url in
            XCTAssertThrowsError(try fingerprint(url))
        }
    }
    func testDistinctUnicodePathBytesRemainDistinctAcrossArchives() throws {
        try withZIP(extra: [("caf\u{e9}.xhtml", Data([1]))]) { first in
            try withZIP(extra: [("cafe\u{301}.xhtml", Data([1]))]) { second in
                XCTAssertNotEqual(try fingerprint(first).packageSHA256, try fingerprint(second).packageSHA256)
            }
        }
    }
    func testConsistentButIncorrectHeaderCRCCannotProduceFingerprint() throws {
        try withZIP { url in
            var bytes = try Data(contentsOf: url)
            let central = try XCTUnwrap(bytes.range(of: Data([0x50, 0x4b, 0x01, 0x02]))).lowerBound
            bytes.replaceSubrange(14..<18, with: Data(repeating: 0, count: 4))
            bytes.replaceSubrange(central + 16..<central + 20, with: Data(repeating: 0, count: 4))
            try bytes.write(to: url)
            XCTAssertThrowsError(try fingerprint(url))
        }
    }
}
