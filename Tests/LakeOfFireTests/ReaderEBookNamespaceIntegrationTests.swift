import Foundation
import XCTest
import ZIPFoundation
@testable import LakeOfFireContent

final class ReaderEBookNamespaceIntegrationTests: XCTestCase {
    private func withPackage(extra: [String], _ body: (ReaderEBookPackageFingerprint) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let archive = try Archive(url: url, accessMode: .create)
            let files = [("mimetype", Data("application/epub+zip".utf8)),
                         ("META-INF/container.xml", Data("<container/>".utf8)),
                         ("OPS/book.opf", Data("<package/>".utf8))] + extra.map { ($0, Data([42])) }
            for (path, bytes) in files {
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count)) { offset, count in
                    bytes.subdata(in: Int(offset)..<Int(offset) + count)
                }
            }
        }
        try body(ReaderEBookPackageFingerprint.readSnapshot(at: url, packageDocumentPath: "OPS/book.opf"))
    }
    func testScannerRejectsCaseFoldedLeafAndImplicitParentCollisions() throws {
        for names in [["OPS/Book.xhtml", "OPS/book.xhtml"], ["Other/a.xhtml", "other/b.xhtml"],
                      ["café/a", "cafe\u{301}/b"], ["Straße/a", "STRASSE/b"],
                      ["Part", "part/a.xhtml"], ["OPS/a.xhtml", "ops/b.xhtml"]] {
            XCTAssertThrowsError(try withPackage(extra: names) { _ in XCTFail("Ambiguous package accepted") }) {
                guard case .ambiguousPath = $0 as? ReaderEBookFingerprintError else {
                    return XCTFail("Expected namespace rejection, got \($0)")
                }
            }
        }
    }
    func testFoldedSpellingIsNeverUsedAsTheFingerprintPath() throws {
        var first: String?
        try withPackage(extra: ["OPS/Book.xhtml"]) { first = $0.packageSHA256 }
        try withPackage(extra: ["OPS/book.xhtml"]) { result in
            XCTAssertNotEqual(first, result.packageSHA256)
            XCTAssertTrue(result.resources.contains { $0.path == "OPS/book.xhtml" })
        }
    }
    func testDistinctJapaneseAndDiacriticNamesAreNotOverNormalized() throws {
        try withPackage(extra: ["本/一.xhtml", "本/二.xhtml", "café/a.xhtml", "cafe/b.xhtml"]) {
            XCTAssertEqual($0.resources.count, 7)
        }
    }
}
