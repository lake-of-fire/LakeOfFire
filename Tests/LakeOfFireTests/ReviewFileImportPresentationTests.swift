import Foundation
import XCTest
@testable import LakeOfFireContent

final class ReviewFileImportPresentationTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/private/test/reader-book.epub")

    func testMissingImportResultHasVisibleFilenameWithoutAbsolutePath() throws {
        let message = try XCTUnwrap(ReaderFileImportPresentation.missingResult(for: url))
        XCTAssertTrue(message.contains("reader-book.epub"))
        XCTAssertFalse(message.contains("/private/test"))
    }

    func testImportFailurePreservesUsefulErrorDetail() throws {
        let error = NSError(domain: "ReviewImport", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "storage unavailable"])
        let message = try XCTUnwrap(ReaderFileImportPresentation.failure(error, importing: url))
        XCTAssertTrue(message.contains("reader-book.epub"))
        XCTAssertTrue(message.contains("storage unavailable"))
    }

    func testPickerFailureIsVisible() throws {
        let error = NSError(domain: "ReviewPicker", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "selection failed"])
        let message = try XCTUnwrap(ReaderFileImportPresentation.failure(error))
        XCTAssertTrue(message.contains("select"))
        XCTAssertTrue(message.contains("selection failed"))
    }

    func testSwiftTaskCancellationIsNotPresentedAsFailure() {
        XCTAssertNil(ReaderFileImportPresentation.failure(CancellationError(), importing: url))
    }

    func testPickerCancellationIsNotPresentedAsFailure() {
        XCTAssertNil(ReaderFileImportPresentation.failure(CocoaError(.userCancelled)))
    }

    func testNetworkCancellationIsNotPresentedAsFailure() {
        XCTAssertNil(ReaderFileImportPresentation.failure(URLError(.cancelled), importing: url))
    }
}
