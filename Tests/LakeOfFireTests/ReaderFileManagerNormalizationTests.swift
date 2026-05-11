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
