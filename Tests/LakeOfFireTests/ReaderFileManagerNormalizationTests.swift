import XCTest
@testable import LakeOfFireContent

final class ReaderFileManagerNormalizationTests: XCTestCase {
    func testCanonicalReaderBackingURL_stripsQueryAndFragmentFromReaderFileURL() {
        let manager = ReaderFileManager()
        let url = URL(string: "reader-file://file/load/icloud/Books/test.cbz?subpath=cover.jpg#fragment")!

        let result = manager.canonicalReaderBackingURL(for: url)

        XCTAssertEqual(result?.absoluteString, "reader-file://file/load/icloud/Books/test.cbz")
    }

    func testCanonicalReaderBackingURL_mapsEbookURLToReaderBackingURL() {
        let manager = ReaderFileManager()
        let url = URL(string: "ebook://ebook/load/icloud/Books/test.epub?subpath=OPS/chapter1.xhtml")!

        let result = manager.canonicalReaderBackingURL(for: url)

        XCTAssertEqual(result?.absoluteString, "reader-file://file/load/icloud/Books/test.epub")
    }

    func testCanonicalReaderBackingURL_mapsMokuroURLToReaderBackingURL() {
        let manager = ReaderFileManager()
        let url = URL(string: "mokuro://mokuro/load/local/Manga/series.mokuro?subpath=page-1.json")!

        let result = manager.canonicalReaderBackingURL(for: url)

        XCTAssertEqual(result?.absoluteString, "reader-file://file/load/local/Manga/series.mokuro")
    }

    func testCanonicalReaderBackingURL_returnsNilForNonReaderBackedURL() {
        let manager = ReaderFileManager()

        XCTAssertNil(manager.canonicalReaderBackingURL(for: URL(string: "https://example.com/book")!))
    }

    func testCanonicalReaderBackingURL_rejectsTraversalAndEncodedSeparators() {
        let manager = ReaderFileManager()
        let invalidURLs = [
            "ebook://ebook/load/local/../../Library/Application%20Support",
            "ebook://ebook/load/local/Books/../other.epub",
            "ebook://ebook/load/local/Books/%2e%2e/other.epub",
            "ebook://ebook/load/local/Books%2fother.epub",
            "ebook://ebook/load/local/Books%5cother.epub",
            "ebook://ebook/load/local//other.epub",
            "ebook://ebook/load/other.epub",
        ]

        for rawURL in invalidURLs {
            XCTAssertNil(
                manager.canonicalReaderBackingURL(for: URL(string: rawURL)!),
                "Unsafe backing path must be rejected: \(rawURL)"
            )
        }
    }

    func testCanonicalReaderBackingURL_acceptsSafeEncodedPackagePath() {
        let manager = ReaderFileManager()
        let url = URL(string: "ebook://ebook/load/local/Books/My%20Book.epub")!

        XCTAssertEqual(
            manager.canonicalReaderBackingURL(for: url)?.absoluteString,
            "reader-file://file/load/local/Books/My%20Book.epub"
        )
    }

    func testCanonicalReaderBackingURL_acceptsLiteralPercentInFilename() {
        let manager = ReaderFileManager()
        let url = URL(string: "ebook://ebook/load/local/Books/100%25.epub")!

        XCTAssertEqual(
            manager.canonicalReaderBackingURL(for: url)?.absoluteString,
            "reader-file://file/load/local/Books/100%25.epub"
        )
    }

    func testRelativePathRequiresAComponentBoundary() throws {
        let root = URL(fileURLWithPath: "/tmp/manabi/Documents", isDirectory: true)
        let siblingPrefix = URL(fileURLWithPath: "/tmp/manabi/Documents2/book.epub")

        XCTAssertNil(ReaderFileManager.relativePath(for: siblingPrefix, relativeTo: root))
        XCTAssertEqual(
            ReaderFileManager.relativePath(
                for: root.appendingPathComponent("Books/book.epub"),
                relativeTo: root
            ),
            "Books/book.epub"
        )
    }

    func testRelativePathStandardizesDotSegmentsBeforeContainmentCheck() {
        let root = URL(fileURLWithPath: "/tmp/manabi/Documents", isDirectory: true)
        let escaped = root.appendingPathComponent("../outside/book.epub")

        XCTAssertNil(ReaderFileManager.relativePath(for: escaped, relativeTo: root))
    }

    func testPackageManifestDigestIsDeterministicAndDoesNotFollowEscapingSymlink() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let first = temporaryRoot.appendingPathComponent("first", isDirectory: true)
        let second = temporaryRoot.appendingPathComponent("second", isDirectory: true)
        let outside = temporaryRoot.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("same".utf8).write(to: outside)
        for root in [first, second] {
            try Data("two".utf8).write(to: root.appendingPathComponent("b.txt"))
            try Data("one".utf8).write(to: root.appendingPathComponent("a.txt"))
        }
        try FileManager.default.createSymbolicLink(
            at: first.appendingPathComponent("outside-link.txt"),
            withDestinationURL: outside
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let firstDigest = try first.packageManifestDigest()
        XCTAssertEqual(firstDigest, try first.packageManifestDigest())
        // The link is represented as a link record, rather than causing the
        // digest to read bytes from outside the package.
        XCTAssertNotEqual(firstDigest, try second.packageManifestDigest())
    }
}

final class ReaderFileOperationMessageMapperTests: XCTestCase {
    func testOpenMessage_mapsDownloadInProgress() {
        XCTAssertEqual(
            ReaderFileOperationMessageMapper.openMessage(for: ReaderFileAccessError.downloadInProgress),
            "Downloading from iCloud. Try opening again when the download finishes."
        )
    }

    func testOpenMessage_mapsNotAvailableOffline() {
        XCTAssertEqual(
            ReaderFileOperationMessageMapper.openMessage(for: ReaderFileAccessError.notAvailableOffline),
            "This book is in iCloud and isn’t available offline yet."
        )
    }

    func testDeleteAlert_mapsBlockedCloudOnly() {
        let alert = ReaderFileOperationMessageMapper.deleteAlert(for: ReaderFileDeleteError.blockedCloudOnly)

        XCTAssertEqual(alert?.title, "Delete Failed")
        XCTAssertEqual(alert?.message, "Download this iCloud file first, then delete it.")
    }

    func testDeleteAlert_mapsRemoveFailedDescription() {
        let alert = ReaderFileOperationMessageMapper.deleteAlert(
            for: ReaderFileDeleteError.removeFailed(underlyingDescription: "The file couldn’t be coordinated.")
        )

        XCTAssertEqual(alert?.title, "Delete Failed")
        XCTAssertEqual(alert?.message, "Couldn't delete the iCloud file. The file couldn’t be coordinated.")
    }
}
