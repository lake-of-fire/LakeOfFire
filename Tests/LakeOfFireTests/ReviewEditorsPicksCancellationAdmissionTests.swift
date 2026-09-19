import XCTest
@testable import LakeOfFireReader

@MainActor
final class ReviewEditorsPicksCancellationAdmissionTests: XCTestCase {
    func testAlreadyCancelledCallerDoesNotStartARequest() async {
        let fixture = ReviewEditorsPicksHarness()
        let cancelled = fixture.start(cancelBeforeAdmission: true)
        guard await fixture.waitForCompletion(cancelled) else { await fixture.cleanup(); return }
        XCTAssertEqual(fixture.requestCount, 0)
        await fixture.cleanup()
    }

    func testAlreadyCancelledCallerPreservesHealthyInFlightRefresh() async {
        let fixture = ReviewEditorsPicksHarness()
        let healthy = fixture.start()
        guard await fixture.waitForRequest(1) else { await fixture.cleanup(); return }
        let cancelled = fixture.start(cancelBeforeAdmission: true)
        guard await fixture.waitForCompletion(cancelled) else { await fixture.cleanup(); return }
        XCTAssertEqual(fixture.requestCount, 1,
                       "an already-cancelled caller must not start a replacement")
        fixture.resolve(1, publications: [Publication(title: "healthy")])
        guard await fixture.waitForCompletion(healthy) else { await fixture.cleanup(); return }
        XCTAssertEqual(fixture.viewModel.editorsPicks.map(\.title), ["healthy"])
        XCTAssertNil(fixture.viewModel.errorMessage)
        await fixture.cleanup()
    }

    func testCancellationAfterAdmissionStillPreventsPublication() async {
        let fixture = ReviewEditorsPicksHarness()
        let admitted = fixture.start()
        guard await fixture.waitForRequest(1) else { await fixture.cleanup(); return }
        fixture.cancel(admitted)
        fixture.resolve(1, publications: [Publication(title: "cancelled")], error: "late error")
        guard await fixture.waitForCompletion(admitted) else { await fixture.cleanup(); return }
        XCTAssertTrue(fixture.viewModel.editorsPicks.isEmpty)
        XCTAssertNil(fixture.viewModel.errorMessage)
        await fixture.cleanup()
    }
}
