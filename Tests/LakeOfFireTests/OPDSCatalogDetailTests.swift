import XCTest
@testable import LakeOfFireReader

/// Controlled transport responses drive the production detail model and the
/// shared request owner. No test-owned publication or request policy is used.
@MainActor
private final class OPDSCatalogDetailFixture {
    typealias Value = ([Publication], String?)
    let model = OPDSCatalogDetailViewModel()
    private(set) var requestedURLs: [URL] = []
    private(set) var completedLoads: Set<Int> = []
    private var pending: [Int: CheckedContinuation<Value, Never>] = [:]
    private var startSignals: [Int: XCTestExpectation] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var closed = false

    init() {
        model.publicationFetcher = { [weak self] url in
            guard let self, !self.closed else { return ([], nil) }
            self.requestedURLs.append(url)
            let request = self.requestedURLs.count
            return await withCheckedContinuation { continuation in
                self.pending[request] = continuation
                self.startSignals.removeValue(forKey: request)?.fulfill()
            }
        }
    }

    func load(_ url: String, cancelledBeforeEntry: Bool = false) -> (Int, Task<Void, Never>) {
        let id = tasks.count
        let task = Task { @MainActor in
            await self.model.load(catalogURL: url)
            self.completedLoads.insert(id)
        }
        tasks.append(task)
        if cancelledBeforeEntry { task.cancel() }
        return (id, task)
    }

    func retry(_ url: String) throws -> Task<Void, Never> {
        let task = try XCTUnwrap(model.retry(catalogURL: url))
        tasks.append(task)
        return task
    }

    func waitForRequest(_ request: Int, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        if requestedURLs.count >= request { return true }
        let signal = XCTestExpectation(description: "catalog request \(request) started")
        startSignals[request] = signal
        let result = await XCTWaiter.fulfillment(of: [signal], timeout: 2)
        XCTAssertEqual(result, .completed, file: file, line: line)
        return result == .completed
    }

    func resolve(_ request: Int, titles: [String] = [], error: String? = nil,
                 file: StaticString = #filePath, line: UInt = #line) {
        guard let continuation = pending.removeValue(forKey: request) else {
            return XCTFail("Missing catalog response \(request)", file: file, line: line)
        }
        continuation.resume(returning: (titles.map { Publication(title: $0) }, error))
    }

    func cleanup() async {
        closed = true
        model.cancel()
        tasks.forEach { $0.cancel() }
        let continuations = Array(pending.values)
        pending.removeAll()
        continuations.forEach { $0.resume(returning: ([], nil)) }
        for task in tasks { await task.value }
    }
}

@MainActor
final class OPDSCatalogDetailTests: XCTestCase {
    private let firstURL = "https://catalog.example/first.xml"
    private let secondURL = "https://catalog.example/second.xml"

    private func withFixture(
        _ body: @MainActor (OPDSCatalogDetailFixture) async throws -> Void
    ) async throws {
        let fixture = OPDSCatalogDetailFixture()
        do {
            try await body(fixture)
        } catch {
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
    }

    func testInvalidAndRelativeURLsPublishAnActionableErrorWithoutFetching() async {
        let model = OPDSCatalogDetailViewModel()
        var requests = 0
        model.publicationFetcher = { _ in
            requests += 1
            return ([Publication(title: "unexpected")], nil)
        }
        for rawURL in ["http://[", "relative/catalog.xml"] {
            await model.load(catalogURL: rawURL)
            XCTAssertEqual(model.errorMessage, "Invalid catalog URL")
            XCTAssertTrue(model.publications.isEmpty)
        }
        XCTAssertEqual(requests, 0)
    }

    func testLoadAwaitsTheCapturedCatalogAndPublishesItsTitles() async throws {
        try await withFixture { fixture in
            let (id, task) = fixture.load(firstURL)
            guard await fixture.waitForRequest(1) else { return }
            XCTAssertEqual(fixture.requestedURLs.map(\.absoluteString), [firstURL])
            XCTAssertFalse(fixture.completedLoads.contains(id))
            XCTAssertTrue(fixture.model.publications.isEmpty)

            fixture.resolve(1, titles: ["日本語", "A & B"])
            await task.value
            XCTAssertTrue(fixture.completedLoads.contains(id))
            XCTAssertEqual(fixture.model.publications.map(\.title), ["日本語", "A & B"])
            XCTAssertNil(fixture.model.errorMessage)
        }
    }

    func testRetryPublishesRecoveryAndClearsThePreviousError() async throws {
        try await withFixture { fixture in
            let (_, initial) = fixture.load(firstURL)
            guard await fixture.waitForRequest(1) else { return }
            fixture.resolve(1, error: "Failed to fetch data: offline")
            await initial.value
            XCTAssertEqual(fixture.model.errorMessage, "Failed to fetch data: offline")

            let retry = try fixture.retry(firstURL)
            guard await fixture.waitForRequest(2) else { return }
            fixture.resolve(2, titles: ["recovered"])
            await retry.value
            XCTAssertEqual(fixture.requestedURLs.map(\.absoluteString), [firstURL, firstURL])
            XCTAssertEqual(fixture.model.publications.map(\.title), ["recovered"])
            XCTAssertNil(fixture.model.errorMessage)
        }
    }

    private func checkReplacement(olderError: String?, newerError: String?) async throws {
        try await withFixture { fixture in
            let (_, older) = fixture.load(firstURL)
            guard await fixture.waitForRequest(1) else { return }
            let (_, newer) = fixture.load(secondURL)
            guard await fixture.waitForRequest(2) else { return }
            let currentTitles = newerError == nil ? ["current"] : []
            fixture.resolve(2, titles: currentTitles, error: newerError)
            await newer.value
            fixture.resolve(1, titles: olderError == nil ? ["retired"] : [], error: olderError)
            await older.value

            XCTAssertEqual(fixture.requestedURLs.map(\.absoluteString), [firstURL, secondURL])
            XCTAssertEqual(fixture.model.publications.map(\.title), currentTitles)
            XCTAssertEqual(fixture.model.errorMessage, newerError)
        }
    }

    func testOlderCatalogErrorCannotReplaceNewerCatalogSuccess() async throws {
        try await checkReplacement(olderError: "old catalog failed", newerError: nil)
    }

    func testOlderCatalogSuccessCannotHideNewerCatalogFailure() async throws {
        try await checkReplacement(olderError: nil, newerError: "current catalog failed")
    }

    func testDisappearanceRejectsLateResultsAndAllowsASeparateRetry() async throws {
        try await withFixture { fixture in
            let (_, old) = fixture.load(firstURL)
            guard await fixture.waitForRequest(1) else { return }
            fixture.model.cancel()
            fixture.resolve(1, titles: ["retired"], error: "retired failure")
            await old.value
            XCTAssertTrue(fixture.model.publications.isEmpty)
            XCTAssertNil(fixture.model.errorMessage)

            let retry = try fixture.retry(secondURL)
            guard await fixture.waitForRequest(2) else { return }
            fixture.resolve(2, titles: ["new presentation"])
            await retry.value
            XCTAssertEqual(fixture.model.publications.map(\.title), ["new presentation"])
            XCTAssertNil(fixture.model.errorMessage)
        }
    }

    func testCancelledInvalidEntrantDoesNotRevokeHealthyRequest() async throws {
        try await withFixture { fixture in
            let (_, healthy) = fixture.load(firstURL)
            guard await fixture.waitForRequest(1) else { return }
            let (_, cancelled) = fixture.load("relative/catalog.xml", cancelledBeforeEntry: true)
            await cancelled.value
            XCTAssertEqual(fixture.requestedURLs.count, 1)
            XCTAssertNil(fixture.model.errorMessage)

            fixture.resolve(1, titles: ["healthy"])
            await healthy.value
            XCTAssertEqual(fixture.model.publications.map(\.title), ["healthy"])
        }
    }

    func testCancellingOldViewTaskCannotCancelNewerRetry() async throws {
        try await withFixture { fixture in
            let (_, old) = fixture.load(firstURL)
            guard await fixture.waitForRequest(1) else { return }
            let retry = try fixture.retry(secondURL)
            guard await fixture.waitForRequest(2) else { return }
            old.cancel()
            fixture.resolve(1, error: "old response")
            await old.value
            XCTAssertFalse(retry.isCancelled)
            XCTAssertNil(fixture.model.errorMessage)

            fixture.resolve(2, titles: ["current Retry"])
            await retry.value
            XCTAssertEqual(fixture.model.publications.map(\.title), ["current Retry"])
        }
    }

    func testQueuedRetryCapturesItsURLAndProviderBeforeTaskEntry() async throws {
        let model = OPDSCatalogDetailViewModel()
        var capturedURLs: [URL] = []
        var replacementCalls = 0
        model.publicationFetcher = { url in
            capturedURLs.append(url)
            return ([Publication(title: "captured provider")], nil)
        }
        let task = try XCTUnwrap(model.retry(catalogURL: firstURL))
        model.publicationFetcher = { _ in
            replacementCalls += 1
            return ([Publication(title: "later provider")], nil)
        }
        await task.value
        XCTAssertEqual(capturedURLs.map(\.absoluteString), [firstURL])
        XCTAssertEqual(replacementCalls, 0)
        XCTAssertEqual(model.publications.map(\.title), ["captured provider"])
    }

    func testReleasedDetailOwnerDoesNotStartQueuedProvider() async throws {
        var model: OPDSCatalogDetailViewModel? = OPDSCatalogDetailViewModel()
        weak var releasedOwner = model
        var requests = 0
        model?.publicationFetcher = { _ in
            requests += 1
            return ([], nil)
        }
        let task = try XCTUnwrap(model?.retry(catalogURL: firstURL))
        model = nil
        XCTAssertNil(releasedOwner)
        await task.value
        XCTAssertEqual(requests, 0)
    }
}
