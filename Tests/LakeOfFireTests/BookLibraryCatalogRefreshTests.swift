import XCTest
@testable import LakeOfFireReader

/// Own every caller and continuation so a failed setup cannot strand teardown.
/// This drives BookLibraryViewModel, not a replacement ownership state machine.
@MainActor
final class BookLibraryCatalogRefreshHarness {
    typealias Value = ([Publication], String?)
    let viewModel = BookLibraryViewModel()
    private(set) var requestCount = 0
    private var pending: [Int: CheckedContinuation<Value, Never>] = [:]
    private var startSignals: [Int: XCTestExpectation] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var finishSignals: [Int: [XCTestExpectation]] = [:]
    private var finished: Set<Int> = []
    private var closed = false

    init() {
        viewModel.publicationFetcher = { [weak self] _ in
            guard let self, !self.closed else { return ([], nil) }
            self.requestCount += 1
            let request = self.requestCount
            // A newly admitted cancelled request can finish immediately; older
            // requests already suspended below deliberately ignore cancellation.
            if Task.isCancelled {
                self.startSignals.removeValue(forKey: request)?.fulfill()
                return ([], nil)
            }
            return await withCheckedContinuation { continuation in
                self.pending[request] = continuation
                self.startSignals.removeValue(forKey: request)?.fulfill()
            }
        }
    }

    @discardableResult
    func start(cancelBeforeAdmission: Bool = false) -> Int {
        let id = tasks.count
        let task = Task { @MainActor in
            if cancelBeforeAdmission { XCTAssertTrue(Task.isCancelled) }
            await self.viewModel.fetchAllData()
            self.finished.insert(id)
            self.finishSignals.removeValue(forKey: id)?.forEach { $0.fulfill() }
        }
        tasks.append(task)
        // This synchronous main-actor section ends before the task can enter.
        if cancelBeforeAdmission { task.cancel() }
        return id
    }

    func cancel(_ id: Int) { tasks[id].cancel() }
    func hasFinished(_ id: Int) -> Bool { finished.contains(id) }

    func waitForRequest(_ request: Int, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        if requestCount >= request { return true }
        let signal = XCTestExpectation(description: "request \(request) started")
        startSignals[request] = signal
        let result = await XCTWaiter.fulfillment(of: [signal], timeout: 2)
        XCTAssertEqual(result, .completed, "request did not start", file: file, line: line)
        return result == .completed
    }

    func waitForCompletion(_ id: Int, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        if !finished.contains(id) {
            let signal = XCTestExpectation(description: "refresh caller \(id) completed")
            finishSignals[id, default: []].append(signal)
            let result = await XCTWaiter.fulfillment(of: [signal], timeout: 2)
            finishSignals[id]?.removeAll { $0 === signal }
            XCTAssertEqual(result, .completed, "refresh caller did not finish", file: file, line: line)
            guard result == .completed else { return false }
        }
        await tasks[id].value
        return true
    }

    func resolve(_ request: Int, publications: [Publication], error: String? = nil,
                 file: StaticString = #filePath, line: UInt = #line) {
        guard let continuation = pending.removeValue(forKey: request) else {
            return XCTFail("request \(request) has no pending continuation", file: file, line: line)
        }
        continuation.resume(returning: (publications, error))
    }

    func cleanup() async {
        // Closing admission first also handles a task entering after setup timed out.
        closed = true
        tasks.forEach { $0.cancel() }
        let continuations = Array(pending.values)
        pending.removeAll()
        continuations.forEach { $0.resume(returning: ([], nil)) }
        for id in tasks.indices { _ = await waitForCompletion(id) }
    }
}

@MainActor
final class BookLibraryCatalogRefreshTests: XCTestCase {
    func testFetchAllDataDoesNotReturnBeforeCurrentFetchCompletes() async {
        let fixture = BookLibraryCatalogRefreshHarness()
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
        let fixture = BookLibraryCatalogRefreshHarness()
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

    func testSynchronousRetryPublishesResult() async {
        let fixture = BookLibraryCatalogRefreshHarness()
        guard let retry = fixture.viewModel.fetchEditorsPicks() else {
            XCTFail("Current Retry must be admitted")
            await fixture.cleanup()
            return
        }
        guard await fixture.waitForRequest(1) else {
            retry.cancel()
            await fixture.cleanup()
            await retry.value
            return
        }
        fixture.resolve(1, publications: [Publication(title: "retry")])
        await retry.value
        XCTAssertEqual(fixture.viewModel.editorsPicks.map(\.title), ["retry"])
        XCTAssertNil(fixture.viewModel.errorMessage)
        await fixture.cleanup()
    }

    func testRetryResultSurvivesOlderViewRefreshFailure() async {
        let fixture = BookLibraryCatalogRefreshHarness()
        let older = fixture.start()
        guard await fixture.waitForRequest(1) else {
            await fixture.cleanup()
            return
        }
        guard let retry = fixture.viewModel.fetchEditorsPicks() else {
            XCTFail("Current Retry must replace the pending refresh")
            await fixture.cleanup()
            return
        }
        guard await fixture.waitForRequest(2) else {
            retry.cancel()
            await fixture.cleanup()
            await retry.value
            return
        }
        fixture.resolve(2, publications: [Publication(title: "retry")])
        await retry.value
        fixture.resolve(1, publications: [], error: "old request failed")
        guard await fixture.waitForCompletion(older) else {
            await fixture.cleanup()
            return
        }
        XCTAssertEqual(fixture.viewModel.editorsPicks.map(\.title), ["retry"])
        XCTAssertNil(fixture.viewModel.errorMessage)
        await fixture.cleanup()
    }

}

@MainActor
final class BookLibraryCatalogCancellationTests: XCTestCase {
    func testAlreadyCancelledCallerDoesNotStartARequest() async {
        let fixture = BookLibraryCatalogRefreshHarness()
        let cancelled = fixture.start(cancelBeforeAdmission: true)
        guard await fixture.waitForCompletion(cancelled) else { await fixture.cleanup(); return }
        XCTAssertEqual(fixture.requestCount, 0)
        await fixture.cleanup()
    }

    func testAlreadyCancelledCallerPreservesHealthyInFlightRefresh() async {
        let fixture = BookLibraryCatalogRefreshHarness()
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
        let fixture = BookLibraryCatalogRefreshHarness()
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

@MainActor
final class BookLibraryCatalogQueuedAdmissionTests: XCTestCase {
    func testOnlyLatestQueuedRetryStartsProvider() async throws {
        let viewModel = BookLibraryViewModel()
        var requests = 0
        viewModel.publicationFetcher = { _ in
            requests += 1
            return ([Publication(title: "current")], nil)
        }
        // All three are queued in one main-actor turn, before any provider can run.
        let first = try XCTUnwrap(viewModel.fetchEditorsPicks())
        let second = try XCTUnwrap(viewModel.fetchEditorsPicks())
        let current = try XCTUnwrap(viewModel.fetchEditorsPicks())
        await first.value
        await second.value
        await current.value
        XCTAssertEqual(requests, 1, "Superseded queued work must not start network requests")
        XCTAssertEqual(viewModel.editorsPicks.map(\.title), ["current"])
    }

    func testCancelledQueuedRetryDoesNotStartProvider() async throws {
        let viewModel = BookLibraryViewModel()
        var requests = 0
        viewModel.publicationFetcher = { _ in
            requests += 1
            return ([Publication(title: "cancelled")], "cancelled")
        }
        let task = try XCTUnwrap(viewModel.fetchEditorsPicks())
        task.cancel()
        await task.value
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(viewModel.editorsPicks.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testReleasedOwnerDoesNotStartQueuedProvider() async throws {
        var viewModel: BookLibraryViewModel? = BookLibraryViewModel()
        weak var owner = viewModel
        var requests = 0
        viewModel?.publicationFetcher = { _ in
            requests += 1
            return ([], nil)
        }
        let task = try XCTUnwrap(viewModel?.fetchEditorsPicks())
        viewModel = nil
        XCTAssertNil(owner)
        await task.value
        XCTAssertEqual(requests, 0)
    }

    func testCompletedRetryDoesNotPreventLaterRetry() async throws {
        let viewModel = BookLibraryViewModel()
        var requests = 0
        viewModel.publicationFetcher = { _ in
            requests += 1
            return ([Publication(title: "request-\(requests)")], nil)
        }
        let first = try XCTUnwrap(viewModel.fetchEditorsPicks())
        await first.value
        let second = try XCTUnwrap(viewModel.fetchEditorsPicks())
        await second.value
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(viewModel.editorsPicks.map(\.title), ["request-2"])
    }
}
