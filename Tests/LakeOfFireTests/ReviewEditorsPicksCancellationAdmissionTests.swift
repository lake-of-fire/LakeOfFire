import XCTest
@testable import LakeOfFireReader

@MainActor
final class ReviewEditorsPicksCancellationAdmissionTests: XCTestCase {
    func testAlreadyCancelledCallerDoesNotStartARequest() async {
        let viewModel = BookLibraryViewModel()
        var requests = 0
        viewModel.publicationFetcher = { _ in
            requests += 1
            return ([], nil)
        }
        // Neither task can enter the main actor until this synchronous section ends.
        let cancelled = Task { @MainActor in
            XCTAssertTrue(Task.isCancelled)
            await viewModel.fetchAllData()
        }
        cancelled.cancel()
        await cancelled.value
        XCTAssertEqual(requests, 0)
    }

    func testAlreadyCancelledCallerPreservesHealthyInFlightRefresh() async {
        let viewModel = BookLibraryViewModel()
        let started = expectation(description: "healthy request started")
        var completion: CheckedContinuation<([Publication], String?), Never>?
        var requests = 0
        viewModel.publicationFetcher = { _ in
            requests += 1
            if requests != 1 {
                XCTFail("an already-cancelled caller must not start a replacement")
                return ([], nil)
            }
            return await withCheckedContinuation { continuation in
                completion = continuation
                started.fulfill()
            }
        }
        let healthy = Task { @MainActor in await viewModel.fetchAllData() }
        await fulfillment(of: [started], timeout: 2)
        guard let finish = completion else {
            healthy.cancel()
            return
        }
        let cancelled = Task { @MainActor in
            XCTAssertTrue(Task.isCancelled)
            await viewModel.fetchAllData()
        }
        cancelled.cancel()
        await cancelled.value
        XCTAssertEqual(requests, 1)
        completion = nil
        finish.resume(returning: ([Publication(title: "healthy")], nil))
        await healthy.value
        XCTAssertEqual(viewModel.editorsPicks.map(\.title), ["healthy"])
        XCTAssertNil(viewModel.errorMessage)
    }

    func testCancellationAfterAdmissionStillPreventsPublication() async {
        let viewModel = BookLibraryViewModel()
        let started = expectation(description: "admitted request started")
        var completion: CheckedContinuation<([Publication], String?), Never>?
        viewModel.publicationFetcher = { _ in
            await withCheckedContinuation { continuation in
                completion = continuation
                started.fulfill()
            }
        }
        let admitted = Task { @MainActor in await viewModel.fetchAllData() }
        await fulfillment(of: [started], timeout: 2)
        guard let finish = completion else {
            admitted.cancel()
            return
        }
        admitted.cancel()
        completion = nil
        finish.resume(returning: ([Publication(title: "cancelled")], "late error"))
        await admitted.value
        XCTAssertTrue(viewModel.editorsPicks.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }
}
