import XCTest
@testable import LakeOfFireReader

@MainActor
final class ReviewEditorsPicksQueuedAdmissionTests: XCTestCase {
    func testOnlyLatestQueuedRetryStartsProvider() async {
        let viewModel = BookLibraryViewModel()
        var requests = 0
        viewModel.publicationFetcher = { _ in
            requests += 1
            return ([Publication(title: "current")], nil)
        }
        // All three are queued in one main-actor turn, before any provider can run.
        let first = viewModel.fetchEditorsPicks()
        let second = viewModel.fetchEditorsPicks()
        let current = viewModel.fetchEditorsPicks()
        await first.value
        await second.value
        await current.value
        XCTAssertEqual(requests, 1, "Superseded queued work must not start network requests")
        XCTAssertEqual(viewModel.editorsPicks.map(\.title), ["current"])
    }

    func testCancelledQueuedRetryDoesNotStartProvider() async {
        let viewModel = BookLibraryViewModel()
        var requests = 0
        viewModel.publicationFetcher = { _ in
            requests += 1
            return ([Publication(title: "cancelled")], "cancelled")
        }
        let task = viewModel.fetchEditorsPicks()
        task.cancel()
        await task.value
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(viewModel.editorsPicks.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testReleasedOwnerDoesNotStartQueuedProvider() async {
        var viewModel: BookLibraryViewModel? = BookLibraryViewModel()
        weak var owner = viewModel
        var requests = 0
        viewModel?.publicationFetcher = { _ in
            requests += 1
            return ([], nil)
        }
        let task = viewModel!.fetchEditorsPicks()
        viewModel = nil
        XCTAssertNil(owner)
        await task.value
        XCTAssertEqual(requests, 0)
    }

    func testCompletedRetryDoesNotPreventLaterRetry() async {
        let viewModel = BookLibraryViewModel()
        var requests = 0
        viewModel.publicationFetcher = { _ in
            requests += 1
            return ([Publication(title: "request-\(requests)")], nil)
        }
        await viewModel.fetchEditorsPicks().value
        await viewModel.fetchEditorsPicks().value
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(viewModel.editorsPicks.map(\.title), ["request-2"])
    }
}
