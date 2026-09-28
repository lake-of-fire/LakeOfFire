import Foundation
import XCTest
@testable import LakeOfFireContent

final class ReaderFileStoragePathsTests: XCTestCase {
    func testRemoteIdentityIncludesHostPathAndQueryNotJustFilename() throws {
        let urls = [
            "https://a.example/books/book.epub",
            "https://b.example/books/book.epub",
            "https://a.example/other/book.epub",
            "https://a.example/books/book.epub?id=1",
            "https://a.example/books/book.epub?id=2",
        ]
        let identities = try urls.map { ReaderFileStoragePaths.downloadIdentity(for: try XCTUnwrap(URL(string: $0))) }
        XCTAssertEqual(Set(identities).count, urls.count)
    }

    func testFragmentsShareAResourceButEscapedFragmentsDoNot() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/a%23b.epub?signature=a%2Fb+%2523#chapter"))
        XCTAssertEqual(ReaderFileStoragePaths.downloadIdentity(for: url), "https://example.com/a%23b.epub?signature=a%2Fb+%2523")
        let different = try XCTUnwrap(URL(string: "https://example.com/a.epub?signature=a%2Fb+%2523"))
        XCTAssertNotEqual(ReaderFileStoragePaths.downloadIdentity(for: url), ReaderFileStoragePaths.downloadIdentity(for: different))
    }

    func testDownloadFilenamePreservesJapaneseAndExtension() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/吾輩は猫である.epub?token=abc#chapter"))
        XCTAssertEqual(try ReaderFileStoragePaths.downloadFilename(for: url), "吾輩は猫である.epub")
    }

    func testDownloadFilenameRejectsPathInjectionAndOversizedComponents() throws {
        for raw in ["https://example.com/a%2Fb.epub", "https://example.com/a%5Cb.epub", "https://example.com/a%00b.epub", "https://example.com/" + String(repeating: "a", count: 256) + ".epub"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertThrowsError(try ReaderFileStoragePaths.downloadFilename(for: url), raw)
        }
    }

    func testTransferStagingArtifactsAreNotBooks() {
        let id = "01234567-89AB-CDEF-0123-456789ABCDEF"
        for name in ["book.downloading.\(id).epub", "book.downloading.\(id).epub.br", "book.downloading.\(id)", "book.v2.downloading.\(id.lowercased()).txt", "book.epub.decompressing.\(id)", "book.epub.sha1verified.json"] {
            XCTAssertTrue(ReaderFileStoragePaths.isDownloadArtifact(URL(fileURLWithPath: "/library/" + name)), name)
        }
    }

    func testOrdinaryBooksAreNotHiddenBySubstringMatching() {
        for name in ["book.epub", "downloading.epub", "book.downloading.notes.epub", "book.decompressing.notes.txt", "book.downloading.01234567-89AB-CDEF-0123-456789ABCDEF.notes.txt", "book.downloading.0123456789abcdef.epub", "book.downloading.01234567-89AB-CDEF-0123-456789ABCDEF.one.two.three.epub"] {
            XCTAssertFalse(ReaderFileStoragePaths.isDownloadArtifact(URL(fileURLWithPath: "/library/" + name)), name)
        }
    }
}
