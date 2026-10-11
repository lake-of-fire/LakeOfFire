import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

final class LibraryOPMLImportPresentationTests: XCTestCase {
    @MainActor
    func testImportFailureMessageReportsFailedAndSupersededFiles() {
        let committedURL = URL(fileURLWithPath: "/tmp/committed.opml")
        let failedURL = URL(fileURLWithPath: "/tmp/malformed.opml")
        let supersededURL = URL(fileURLWithPath: "/tmp/superseded.opml")
        let notStartedURL = URL(fileURLWithPath: "/tmp/not-started.opml")
        let result = LibraryDataManager.LocalOPMLImportResult(
            outcomes: [
                .committed(fileURL: committedURL),
                .failed(fileURL: failedURL, errorDescription: "Malformed OPML"),
                .superseded(fileURL: supersededURL),
                .notStarted(fileURL: notStartedURL),
            ]
        )

        XCTAssertEqual(
            LibraryManagerViewModel.importOPMLFailureMessage(for: result),
            "Couldn’t import malformed.opml. A newer import replaced this request before 2 files finished. Imported 1 other file."
        )
        XCTAssertNil(
            LibraryManagerViewModel.importOPMLFailureMessage(
                for: LibraryDataManager.LocalOPMLImportResult(
                    outcomes: [.committed(fileURL: committedURL)]
                )
            )
        )
    }
}
