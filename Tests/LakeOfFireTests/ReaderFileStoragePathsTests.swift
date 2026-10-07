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

    func testDownloadFilenameDecodesOnlyTheFinalEncodedComponentOnce() throws {
        let cases = [
            ("https://example.com/books/a%23b.epub?ignored=a%2Fb#chapter", "a#b.epub"),
            ("https://example.com/books/a%20b.epub", "a b.epub"),
            ("https://example.com/books/100%25.epub", "100%.epub"),
            ("https://example.com/books/a%252Fb.epub", "a%2Fb.epub"),
            ("https://example.com/books/a%255Cb.epub", "a%5Cb.epub"),
            ("https://example.com/books/a%2500b.epub", "a%00b.epub"),
            ("https://example.com/books/%252e%252e", "%2e%2e"),
            ("https://example.com/books/吾輩は猫である.epub", "吾輩は猫である.epub"),
        ]
        for (raw, expected) in cases {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertEqual(try ReaderFileStoragePaths.downloadFilename(for: url), expected, raw)
        }
    }

    func testDownloadFilenameRejectsEncodedSeparatorsControlsAndTraversal() throws {
        for component in ["a%2fb.epub", "a%2Fb.epub", "a%5cb.epub", "a%5Cb.epub",
                          "a%00b.epub", "a%1fb.epub", "a%7fb.epub", ".", "..", "%2e", "%2E%2e"] {
            let url = try XCTUnwrap(URL(string: "https://example.com/books/" + component))
            XCTAssertThrowsError(try ReaderFileStoragePaths.downloadFilename(for: url), component)
        }
        let directoryURL = try XCTUnwrap(URL(string: "https://example.com/books/"))
        XCTAssertThrowsError(try ReaderFileStoragePaths.downloadFilename(for: directoryURL))
    }

    func testDownloadFilenameLengthLimitUsesDecodedUTF8Bytes() throws {
        for name in [String(repeating: "a", count: 255), String(repeating: "猫", count: 85)] {
            let url = try XCTUnwrap(URL(string: "https://example.com/books/" + name))
            XCTAssertEqual(try ReaderFileStoragePaths.downloadFilename(for: url), name)
        }
        for name in [String(repeating: "a", count: 256), String(repeating: "猫", count: 86)] {
            let url = try XCTUnwrap(URL(string: "https://example.com/books/" + name))
            XCTAssertThrowsError(try ReaderFileStoragePaths.downloadFilename(for: url), name)
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

    func testOwnedPartStagesAreFilteredThroughTheSharedContract() {
        let owner = String(repeating: "a", count: 64)
        let id = "01234567-89AB-CDEF-0123-456789ABCDEF"
        for phase in ["transfer", "compressed", "expanded"] {
            let name = ".swiftui-download-v1.\(owner).\(phase).\(id).part"
            XCTAssertTrue(ReaderFileStoragePaths.isDownloadArtifact(URL(fileURLWithPath: "/library/" + name)), name)
        }
    }

    func testPartSuffixAloneDoesNotIdentifyAnOwnedArtifact() {
        let owner = String(repeating: "a", count: 64)
        let id = "01234567-89AB-CDEF-0123-456789ABCDEF"
        for name in ["book.epub.part", "unfinished.part",
                     ".swiftui-download-v1.\(owner).transfer.not-a-uuid.part",
                     ".swiftui-download-v1.\(owner).unknown.\(id).part"] {
            XCTAssertFalse(ReaderFileStoragePaths.isDownloadArtifact(URL(fileURLWithPath: "/library/" + name)), name)
        }
    }
}
