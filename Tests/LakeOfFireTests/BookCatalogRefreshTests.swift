import Foundation
import XCTest
@testable import LakeOfFireReader

@MainActor
final class BookCatalogRefreshTests: XCTestCase {
    private final class SuspendedFetch {
        let started = XCTestExpectation(description: "Fetcher entered")
        private var continuation: CheckedContinuation<([Publication], String?), Never>?
        private var finishedResult: ([Publication], String?)?

        func fetch() async -> ([Publication], String?) {
            started.fulfill()
            if let finishedResult { return finishedResult }
            return await withCheckedContinuation { continuation = $0 }
        }

        func finish(_ title: String, error: String? = nil) {
            guard finishedResult == nil else { return }
            let result: ([Publication], String?) = ([Publication(title: title)], error)
            finishedResult = result
            let saved = continuation
            continuation = nil
            saved?.resume(returning: result)
        }
    }

    private final class WeakOwner {
        weak var value: BookCatalogRefresh?
        init(_ value: BookCatalogRefresh) { self.value = value }
    }

    private var owners: [WeakOwner] = []
    private var fetches: [SuspendedFetch] = []
    private var tasks: [Task<Void, Never>] = []
    private var admissionClosed = false
    private var cleanupRegistered = false

    private func makeOwner() -> BookCatalogRefresh {
        registerCleanupIfNeeded()
        let owner = BookCatalogRefresh()
        owners.append(WeakOwner(owner))
        return owner
    }

    private func makeFetch() -> SuspendedFetch {
        let fetch = SuspendedFetch()
        fetches.append(fetch)
        return fetch
    }

    private func start(
        _ owner: BookCatalogRefresh?,
        fetch: @escaping @MainActor () async -> ([Publication], String?),
        publish: @escaping @MainActor ([Publication], String?) -> Void
    ) -> Task<Void, Never>? {
        guard !admissionClosed, let task = owner?.start(fetch: fetch, publish: publish) else { return nil }
        tasks.append(task)
        return task
    }

    private func trackedTask(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let task = Task { @MainActor in
            guard !self.admissionClosed else { return }
            await operation()
        }
        tasks.append(task)
        return task
    }

    private func registerCleanupIfNeeded() {
        guard !cleanupRegistered else { return }
        cleanupRegistered = true
        addTeardownBlock { @MainActor in await self.cleanup() }
    }

    private func cleanup() async {
        admissionClosed = true
        owners.forEach { $0.value?.cancel() }
        tasks.forEach { $0.cancel() }
        fetches.forEach { $0.finish("Teardown") }
        for task in tasks { await task.value }
        owners.removeAll()
        fetches.removeAll()
        tasks.removeAll()
    }

    private func entered(_ fetch: SuspendedFetch) async -> Bool {
        let result = await XCTWaiter.fulfillment(of: [fetch.started], timeout: 3)
        XCTAssertEqual(result, .completed)
        return result == .completed
    }

    func testNewerResultWinsWhenOldFetcherIgnoresCancellation() async throws {
        let owner = makeOwner()
        let old = makeFetch()
        var titles: [String] = []
        var errors: [String?] = []
        let first = try XCTUnwrap(start(owner, fetch: { await old.fetch() }, publish: {
            titles.append($0[0].title)
            errors.append($1)
        }))
        guard await entered(old) else { return }
        let second = try XCTUnwrap(start(owner, fetch: { ([Publication(title: "New")], nil) }, publish: {
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
        let owner = makeOwner()
        let active = makeFetch()
        var titles: [String] = []
        let healthy = try XCTUnwrap(start(owner, fetch: { await active.fetch() }, publish: { values, _ in
            titles.append(values[0].title)
        }))
        guard await entered(active) else { return }
        let cancelled = trackedTask {
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
        let owner = makeOwner()
        let old = makeFetch()
        let new = makeFetch()
        var titles: [String] = []
        let waiter = trackedTask {
            await owner.load(fetch: { await old.fetch() }, publish: { values, _ in titles.append(values[0].title) })
        }
        guard await entered(old) else { return }
        let replacement = try XCTUnwrap(start(owner, fetch: { await new.fetch() }, publish: { values, _ in
            titles.append(values[0].title)
        }))
        guard await entered(new) else { return }
        waiter.cancel()
        old.finish("Old")
        await waiter.value
        new.finish("New")
        await replacement.value
        XCTAssertEqual(titles, ["New"])
    }

    func testOldCleanupCannotDetachTheReplacement() async throws {
        let owner = makeOwner()
        let old = makeFetch()
        let new = makeFetch()
        var publications = 0
        let first = try XCTUnwrap(start(owner, fetch: { await old.fetch() }, publish: { _, _ in publications += 1 }))
        guard await entered(old) else { return }
        let second = try XCTUnwrap(start(owner, fetch: { await new.fetch() }, publish: { _, _ in publications += 1 }))
        guard await entered(new) else { return }
        old.finish("Old")
        await first.value
        owner.cancel()
        new.finish("New")
        await second.value
        XCTAssertEqual(publications, 0)
    }

    func testCancelSuppressesAnUncooperativeCurrentFetcher() async throws {
        let owner = makeOwner()
        let fetch = makeFetch()
        var publications = 0
        let task = try XCTUnwrap(start(owner, fetch: { await fetch.fetch() }, publish: { _, _ in publications += 1 }))
        guard await entered(fetch) else { return }
        owner.cancel()
        fetch.finish("Late")
        await task.value
        XCTAssertEqual(publications, 0)
    }

    func testCancellationBeforeScheduledEntryDoesNotCallFetcher() async throws {
        let owner = makeOwner()
        var fetches = 0
        var publications = 0
        let task = try XCTUnwrap(start(owner, fetch: { fetches += 1; return ([], nil) }, publish: { _, _ in
            publications += 1
        }))
        owner.cancel()
        await task.value
        XCTAssertEqual(fetches, 0)
        XCTAssertEqual(publications, 0)
    }

    func testOwnerReleaseDoesNotRetainOrPublishTheRequest() async throws {
        var owner: BookCatalogRefresh? = makeOwner()
        weak var weakOwner = owner
        let fetch = makeFetch()
        var publications = 0
        let task = try XCTUnwrap(start(owner, fetch: { await fetch.fetch() }, publish: { _, _ in publications += 1 }))
        guard await entered(fetch) else { return }
        owner = nil
        XCTAssertNil(weakOwner)
        fetch.finish("Orphan")
        await task.value
        XCTAssertEqual(publications, 0)
    }

    func testReentrantPublicationCanStartANewRequest() async throws {
        let owner = makeOwner()
        var titles: [String] = []
        var second: Task<Void, Never>?
        let first = try XCTUnwrap(start(owner, fetch: { ([Publication(title: "First")], nil) }, publish: { values, _ in
            titles.append(values[0].title)
            second = self.start(owner, fetch: { ([Publication(title: "Second")], nil) }, publish: { values, _ in
                titles.append(values[0].title)
            })
        }))
        await first.value
        await second?.value
        XCTAssertEqual(titles, ["First", "Second"])
    }

    func testLoadWaitsForItsProducerToFinish() async {
        let owner = makeOwner()
        let fetch = makeFetch()
        var completed = false
        var title: String?
        let waiter = trackedTask {
            await owner.load(fetch: { await fetch.fetch() }, publish: { values, _ in title = values[0].title })
            completed = true
        }
        guard await entered(fetch) else { return }
        XCTAssertFalse(completed)
        fetch.finish("Complete")
        await waiter.value
        XCTAssertTrue(completed)
        XCTAssertEqual(title, "Complete")
    }

    func testLatestErrorIsDeliveredAndRetryCanSucceed() async throws {
        let owner = makeOwner()
        var error: String?
        var titles: [String] = []
        let failed = try XCTUnwrap(start(owner, fetch: { ([], "Unavailable") }, publish: { values, message in
            titles = values.map(\.title)
            error = message
        }))
        await failed.value
        XCTAssertEqual(error, "Unavailable")
        let retry = try XCTUnwrap(start(owner, fetch: { ([Publication(title: "Recovered")], nil) }, publish: { values, message in
            titles = values.map(\.title)
            error = message
        }))
        await retry.value
        XCTAssertEqual(titles, ["Recovered"])
        XCTAssertNil(error)
    }

    func testCancellingOnlyTheReturnedHandleSuppressesPublication() async throws {
        let owner = makeOwner()
        let fetch = makeFetch()
        var publications = 0
        let task = try XCTUnwrap(start(owner, fetch: { await fetch.fetch() }, publish: { _, _ in publications += 1 }))
        guard await entered(fetch) else { return }
        task.cancel()
        fetch.finish("Cancelled")
        await task.value
        XCTAssertEqual(publications, 0)
        let next = try XCTUnwrap(start(owner, fetch: { ([], nil) }, publish: { _, _ in publications += 1 }))
        await next.value
        XCTAssertEqual(publications, 1)
    }
}
