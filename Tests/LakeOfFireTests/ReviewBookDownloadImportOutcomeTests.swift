import Foundation
import XCTest
@testable import LakeOfFireReader

@MainActor
final class ReviewBookDownloadImportOutcomeTests: XCTestCase {
    private let sourceURL = URL(
        fileURLWithPath: "/tmp/review-downloaded-book.epub"
    )

    func testSuccessfulImportMarksDownloadedAndContinuesSelection() async {
        let importedURL = URL(
            string: "ebook://ebook/load/local/review.epub"
        )!

        let outcome = await BookDownloadImportAttempt.perform(
            importing: sourceURL
        ) {
            importedURL
        }

        XCTAssertEqual(outcome.importedURL, importedURL)
        XCTAssertTrue(outcome.shouldMarkDownloaded)
        XCTAssertTrue(outcome.shouldContinueSelection)
        XCTAssertNil(outcome.userFacingMessage)
    }

    func testNilImportResultStaysRetryableAndVisible() async throws {
        let outcome = await BookDownloadImportAttempt.perform(
            importing: sourceURL
        ) {
            nil
        }

        XCTAssertNil(outcome.importedURL)
        XCTAssertFalse(
            outcome.shouldMarkDownloaded,
            "A failed import must remain retryable on a later refresh"
        )
        XCTAssertFalse(
            outcome.shouldContinueSelection,
            "Selection/opening must not advance after an import failure"
        )
        XCTAssertNotNil(
            outcome.userFacingMessage,
            "A user-initiated downloaded-book import failure must be visible"
        )
    }

    func testThrownImportFailureStaysRetryableAndVisible() async throws {
        let error = NSError(
            domain: "ReviewBookImport",
            code: 17,
            userInfo: [
                NSLocalizedDescriptionKey: "library storage unavailable"
            ]
        )

        let outcome = await BookDownloadImportAttempt.perform(
            importing: sourceURL
        ) {
            throw error
        }

        XCTAssertNil(outcome.importedURL)
        XCTAssertFalse(outcome.shouldMarkDownloaded)
        XCTAssertFalse(outcome.shouldContinueSelection)
        let message = try XCTUnwrap(outcome.userFacingMessage)
        XCTAssertTrue(message.contains("review-downloaded-book.epub"))
        XCTAssertTrue(message.contains("library storage unavailable"))
    }

    func testCancellationDoesNotMarkDownloadedOrPresentFailure() async {
        let outcome = await BookDownloadImportAttempt.perform(
            importing: sourceURL
        ) {
            throw CancellationError()
        }

        XCTAssertNil(outcome.importedURL)
        XCTAssertFalse(outcome.shouldMarkDownloaded)
        XCTAssertFalse(outcome.shouldContinueSelection)
        XCTAssertNil(outcome.userFacingMessage)
    }

    func testDownloadedBookOpenFailureIsVisible() throws {
        let error = NSError(
            domain: "ReviewBookOpen",
            code: 23,
            userInfo: [
                NSLocalizedDescriptionKey: "reader could not load package"
            ]
        )

        let message = try XCTUnwrap(
            BookDownloadOpenFailurePresentation.message(
                for: error,
                title: "Review Book"
            )
        )

        XCTAssertTrue(message.contains("Review Book"))
        XCTAssertTrue(message.contains("reader could not load package"))
    }

    func testDownloadedBookOpenCancellationStaysSilent() {
        XCTAssertNil(
            BookDownloadOpenFailurePresentation.message(
                for: CancellationError(),
                title: "Review Book"
            )
        )
    }
}
