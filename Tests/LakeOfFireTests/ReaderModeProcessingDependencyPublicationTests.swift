import Combine
import XCTest
@testable import LakeOfFireReader

final class ReaderModeProcessingDependencyPublicationTests: XCTestCase {
    @MainActor
    func testProcessingDependencyBatchPublishesOneCompleteConfiguration() async {
        let viewModel = ReaderModeViewModel()
        var publicationCount = 0
        var observedCompleteConfiguration = false
        let observation = viewModel.objectWillChange.sink {
            publicationCount += 1
            Task { @MainActor in
                observedCompleteConfiguration = viewModel.processHTMLBytes != nil
                    && viewModel.processHTML != nil
                    && viewModel.ebookProcessedTextCacheReader != nil
            }
        }

        viewModel.performBatchProcessingDependencyUpdate {
            viewModel.processHTMLBytes = { bytes, _ in bytes }
            viewModel.processHTML = { html, _ in html }
            viewModel.ebookProcessedTextCacheReader = { _, _, _, _ in nil }
        }

        XCTAssertEqual(publicationCount, 1)
        XCTAssertEqual(viewModel.processingDependencyRevision, 1)
        await Task.yield()
        XCTAssertTrue(observedCompleteConfiguration)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testSingleProcessingDependencyAssignmentStillPublishes() {
        let viewModel = ReaderModeViewModel()
        var publicationCount = 0
        let observation = viewModel.objectWillChange.sink {
            publicationCount += 1
        }

        viewModel.processHTMLBytes = { bytes, _ in bytes }

        XCTAssertEqual(publicationCount, 1)
        XCTAssertEqual(viewModel.processingDependencyRevision, 1)

        viewModel.processHTMLBytes = { bytes, _ in bytes }

        XCTAssertEqual(publicationCount, 2)
        XCTAssertEqual(viewModel.processingDependencyRevision, 2)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testProcessingDependencyBatchSuppressesReentrantAssignmentPublication() {
        let viewModel = ReaderModeViewModel()
        var publicationCount = 0
        let observation = viewModel.objectWillChange.sink {
            publicationCount += 1
            if publicationCount == 1 {
                viewModel.processHTML = { html, _ in html }
            }
        }

        viewModel.performBatchProcessingDependencyUpdate {
            viewModel.processHTMLBytes = { bytes, _ in bytes }
        }

        XCTAssertEqual(publicationCount, 1)
        XCTAssertEqual(viewModel.processingDependencyRevision, 1)
        XCTAssertNotNil(viewModel.processHTML)
        XCTAssertNotNil(viewModel.processHTMLBytes)
        withExtendedLifetime(observation) {}
    }
}
