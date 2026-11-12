import Foundation
import XCTest
@testable import LakeOfFireReader

@MainActor
final class BookLibraryCatalogPortTests: XCTestCase {
    private final class Pending {
        let entered = XCTestExpectation(description: "Catalog fetch entered")
        private var continuation: CheckedContinuation<([Publication], String?), Never>?
        func fetch() async -> ([Publication], String?) {
            await withCheckedContinuation {
                continuation = $0
                entered.fulfill()
            }
        }
        func finish(_ title: String, error: String? = nil) {
            let saved = continuation
            continuation = nil
            saved?.resume(returning: ([Publication(title: title)], error))
        }
    }

    func testNewerModelRefreshWinsOverAnUncooperativeOlderResult() async throws {
        let model = BookLibraryViewModel()
        let old = Pending()
        model.publicationFetcher = { _ in await old.fetch() }
        let first = try XCTUnwrap(model.fetchEditorsPicks())
        let entered = await XCTWaiter.fulfillment(of: [old.entered], timeout: 3)
        XCTAssertEqual(entered, .completed)
        model.publicationFetcher = { _ in ([Publication(title: "New")], nil) }
        let second = try XCTUnwrap(model.fetchEditorsPicks())
        await second.value
        old.finish("Old", error: "Late error")
        await first.value
        XCTAssertEqual(model.editorsPicks.map(\.title), ["New"])
        XCTAssertNil(model.errorMessage)
    }

    func testFetchAllDataWaitsUntilModelPublication() async {
        let model = BookLibraryViewModel()
        let pending = Pending()
        model.publicationFetcher = { _ in await pending.fetch() }
        var returned = false
        let request = Task { @MainActor in
            await model.fetchAllData()
            returned = true
        }
        let entered = await XCTWaiter.fulfillment(of: [pending.entered], timeout: 3)
        XCTAssertEqual(entered, .completed)
        XCTAssertFalse(returned)
        pending.finish("Ready")
        await request.value
        XCTAssertTrue(returned)
        XCTAssertEqual(model.editorsPicks.map(\.title), ["Ready"])
    }

    func testCancelledAwaiterCannotPublishAnUncooperativeResult() async {
        let model = BookLibraryViewModel()
        model.editorsPicks = [Publication(title: "Keep")]
        let pending = Pending()
        model.publicationFetcher = { _ in await pending.fetch() }
        let request = Task { @MainActor in await model.fetchAllData() }
        let entered = await XCTWaiter.fulfillment(of: [pending.entered], timeout: 3)
        XCTAssertEqual(entered, .completed)
        request.cancel()
        pending.finish("Cancelled", error: "Late error")
        await request.value
        XCTAssertEqual(model.editorsPicks.map(\.title), ["Keep"])
        XCTAssertNil(model.errorMessage)
    }
}
