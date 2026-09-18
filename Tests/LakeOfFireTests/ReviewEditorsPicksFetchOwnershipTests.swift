import XCTest
#if canImport(Combine)
import Combine
#endif
@testable import LakeOfFireReader

@MainActor
final class ReviewEditorsPicksFetchOwnershipTests: XCTestCase {
    func testFetchAllDataDoesNotReturnBeforeCurrentFetchCompletes() async {
        let fixture = ReviewEditorsPicksHarness()
        let task = fixture.start()
        guard await fixture.waitForRequest(1) else { await fixture.cleanup(); return }
        XCTAssertFalse(fixture.hasFinished(task),
                       "refreshable completion must represent completed data refresh")
        fixture.resolve(1, publications: [Publication(title: "current")])
        guard await fixture.waitForCompletion(task) else { await fixture.cleanup(); return }
        XCTAssertEqual(fixture.viewModel.editorsPicks.map(\.title), ["current"])
        await fixture.cleanup()
    }

    private func checkOverlap(olderError: String?, newerError: String?) async {
        let fixture = ReviewEditorsPicksHarness()
        let older = fixture.start()
        guard await fixture.waitForRequest(1) else { await fixture.cleanup(); return }
        let newer = fixture.start()
        guard await fixture.waitForRequest(2) else { await fixture.cleanup(); return }
        fixture.resolve(2, publications: newerError == nil ? [Publication(title: "newer")] : [],
                        error: newerError)
        guard await fixture.waitForCompletion(newer) else { await fixture.cleanup(); return }
        let expectedTitles = newerError == nil ? ["newer"] : []
        XCTAssertEqual(fixture.viewModel.editorsPicks.map(\.title), expectedTitles)
        XCTAssertEqual(fixture.viewModel.errorMessage != nil, newerError != nil)

        // The older provider ignores cancellation. Wait for the actual old caller
        // to finish after releasing it, rather than hoping N yields were enough.
        fixture.resolve(1, publications: olderError == nil ? [Publication(title: "older")] : [],
                        error: olderError)
        guard await fixture.waitForCompletion(older) else { await fixture.cleanup(); return }
        XCTAssertEqual(fixture.viewModel.editorsPicks.map(\.title), expectedTitles)
        XCTAssertEqual(fixture.viewModel.errorMessage != nil, newerError != nil)
        await fixture.cleanup()
    }

    func testOlderSuccessCannotOverwriteNewerSuccess() async {
        await checkOverlap(olderError: nil, newerError: nil)
    }

    func testOlderErrorCannotReplaceNewerSuccess() async {
        await checkOverlap(olderError: "older failed", newerError: nil)
    }

    func testOlderSuccessCannotReplaceNewerError() async {
        await checkOverlap(olderError: nil, newerError: "newer failed")
    }

#if canImport(Combine)
    func testSynchronousRetryPublishesResult() async {
        let fixture = ReviewEditorsPicksHarness()
        let published = XCTestExpectation(description: "Retry published its current result")
        let observation = fixture.viewModel.$editorsPicks.sink { publications in
            if publications.map(\.title) == ["retry"] { published.fulfill() }
        }
        defer { observation.cancel() }
        fixture.viewModel.fetchEditorsPicks()
        guard await fixture.waitForRequest(1) else { await fixture.cleanup(); return }
        fixture.resolve(1, publications: [Publication(title: "retry")])
        let result = await XCTWaiter.fulfillment(of: [published], timeout: 2)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(fixture.viewModel.editorsPicks.map(\.title), ["retry"])
        await fixture.cleanup()
    }
#endif

}
