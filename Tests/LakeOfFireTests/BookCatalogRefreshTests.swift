import Foundation
import XCTest
@testable import LakeOfFireReader

@MainActor
final class BookCatalogRefreshTests: XCTestCase {
    private final class SuspendedFetch {
        let started = XCTestExpectation(description: "Fetcher entered")
        private var continuation: CheckedContinuation<([Publication], String?), Never>?
        func fetch() async -> ([Publication], String?) {
            await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        func finish(_ title: String, error: String? = nil) {
            let saved = continuation
            continuation = nil
            saved?.resume(returning: ([Publication(title: title)], error))
        }
    }

    private func entered(_ fetch: SuspendedFetch) async {
        let result = await XCTWaiter.fulfillment(of: [fetch.started], timeout: 3)
        XCTAssertEqual(result, .completed)
    }

    func testNewerResultWinsWhenOldFetcherIgnoresCancellation() async throws {
        let owner = BookCatalogRefresh()
        let old = SuspendedFetch()
        var titles: [String] = []
        var errors: [String?] = []
        let first = try XCTUnwrap(owner.start(fetch: { await old.fetch() }, publish: {
            titles.append($0[0].title)
            errors.append($1)
        }))
        await entered(old)
        let second = try XCTUnwrap(owner.start(fetch: { ([Publication(title: "New")], nil) }, publish: {
            titles.append($0[0].title)
            errors.append($1)
        }))
        await second.value
        old.finish("Old", error: "Old failure")
        await first.value
        XCTAssertEqual(titles, ["New"])
        XCTAssertEqual(errors.count, 1)
        XCTAssertNil(errors[0])
    }

    func testCancelledEntrantDoesNotRevokeCurrentProducer() async throws {
        let owner = BookCatalogRefresh()
        let active = SuspendedFetch()
        var titles: [String] = []
        let healthy = try XCTUnwrap(owner.start(fetch: { await active.fetch() }, publish: { values, _ in
            titles.append(values[0].title)
        }))
        await entered(active)
        let cancelled = Task { @MainActor in
            await owner.load(fetch: { XCTFail("Cancelled entrant fetched"); return ([], nil) }, publish: { _, _ in
                XCTFail("Cancelled entrant published")
            })
        }
        cancelled.cancel()
        await cancelled.value
        active.finish("Healthy")
        await healthy.value
        XCTAssertEqual(titles, ["Healthy"])
    }

    func testCancellingOldAwaiterDoesNotCancelItsReplacement() async throws {
        let owner = BookCatalogRefresh()
        let old = SuspendedFetch()
        let new = SuspendedFetch()
        var titles: [String] = []
        let waiter = Task { @MainActor in
            await owner.load(fetch: { await old.fetch() }, publish: { values, _ in titles.append(values[0].title) })
        }
        await entered(old)
        let replacement = try XCTUnwrap(owner.start(fetch: { await new.fetch() }, publish: { values, _ in
            titles.append(values[0].title)
        }))
        await entered(new)
        waiter.cancel()
        old.finish("Old")
        await waiter.value
        new.finish("New")
        await replacement.value
        XCTAssertEqual(titles, ["New"])
    }

    func testOldCleanupCannotDetachTheReplacement() async throws {
        let owner = BookCatalogRefresh()
        let old = SuspendedFetch()
        let new = SuspendedFetch()
        var publications = 0
        let first = try XCTUnwrap(owner.start(fetch: { await old.fetch() }, publish: { _, _ in publications += 1 }))
        await entered(old)
        let second = try XCTUnwrap(owner.start(fetch: { await new.fetch() }, publish: { _, _ in publications += 1 }))
        await entered(new)
        old.finish("Old")
        await first.value
        owner.cancel()
        new.finish("New")
        await second.value
        XCTAssertEqual(publications, 0)
    }

    func testCancelSuppressesAnUncooperativeCurrentFetcher() async throws {
        let owner = BookCatalogRefresh()
        let fetch = SuspendedFetch()
        var publications = 0
        let task = try XCTUnwrap(owner.start(fetch: { await fetch.fetch() }, publish: { _, _ in publications += 1 }))
        await entered(fetch)
        owner.cancel()
        fetch.finish("Late")
        await task.value
        XCTAssertEqual(publications, 0)
    }

    func testCancellationBeforeScheduledEntryDoesNotCallFetcher() async throws {
        let owner = BookCatalogRefresh()
        var fetches = 0
        var publications = 0
        let task = try XCTUnwrap(owner.start(fetch: { fetches += 1; return ([], nil) }, publish: { _, _ in
            publications += 1
        }))
        owner.cancel()
        await task.value
        XCTAssertEqual(fetches, 0)
        XCTAssertEqual(publications, 0)
    }

    func testOwnerReleaseDoesNotRetainOrPublishTheRequest() async throws {
        var owner: BookCatalogRefresh? = BookCatalogRefresh()
        weak var weakOwner = owner
        let fetch = SuspendedFetch()
        var publications = 0
        let task = try XCTUnwrap(owner?.start(fetch: { await fetch.fetch() }, publish: { _, _ in publications += 1 }))
        await entered(fetch)
        owner = nil
        XCTAssertNil(weakOwner)
        fetch.finish("Orphan")
        await task.value
        XCTAssertEqual(publications, 0)
    }

    func testReentrantPublicationCanStartANewRequest() async throws {
        let owner = BookCatalogRefresh()
        var titles: [String] = []
        var second: Task<Void, Never>?
        let first = try XCTUnwrap(owner.start(fetch: { ([Publication(title: "First")], nil) }, publish: { values, _ in
            titles.append(values[0].title)
            second = owner.start(fetch: { ([Publication(title: "Second")], nil) }, publish: { values, _ in
                titles.append(values[0].title)
            })
        }))
        await first.value
        await second?.value
        XCTAssertEqual(titles, ["First", "Second"])
    }

    func testLoadWaitsForItsProducerToFinish() async {
        let owner = BookCatalogRefresh()
        let fetch = SuspendedFetch()
        var completed = false
        var title: String?
        let waiter = Task { @MainActor in
            await owner.load(fetch: { await fetch.fetch() }, publish: { values, _ in title = values[0].title })
            completed = true
        }
        await entered(fetch)
        XCTAssertFalse(completed)
        fetch.finish("Complete")
        await waiter.value
        XCTAssertTrue(completed)
        XCTAssertEqual(title, "Complete")
    }

    func testLatestErrorIsDeliveredAndRetryCanSucceed() async throws {
        let owner = BookCatalogRefresh()
        var error: String?
        var titles: [String] = []
        let failed = try XCTUnwrap(owner.start(fetch: { ([], "Unavailable") }, publish: { values, message in
            titles = values.map(\.title)
            error = message
        }))
        await failed.value
        XCTAssertEqual(error, "Unavailable")
        let retry = try XCTUnwrap(owner.start(fetch: { ([Publication(title: "Recovered")], nil) }, publish: { values, message in
            titles = values.map(\.title)
            error = message
        }))
        await retry.value
        XCTAssertEqual(titles, ["Recovered"])
        XCTAssertNil(error)
    }

    func testCancellingOnlyTheReturnedHandleSuppressesPublication() async throws {
        let owner = BookCatalogRefresh()
        let fetch = SuspendedFetch()
        var publications = 0
        let task = try XCTUnwrap(owner.start(fetch: { await fetch.fetch() }, publish: { _, _ in publications += 1 }))
        await entered(fetch)
        task.cancel()
        fetch.finish("Cancelled")
        await task.value
        XCTAssertEqual(publications, 0)
        let next = try XCTUnwrap(owner.start(fetch: { ([], nil) }, publish: { _, _ in publications += 1 }))
        await next.value
        XCTAssertEqual(publications, 1)
    }
}
