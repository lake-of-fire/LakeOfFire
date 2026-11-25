import Combine
import XCTest
@testable import LakeOfFireReader

/// Controlled transport responses drive the production detail model and the
/// shared request owner. No test-owned publication or request policy is used.
@MainActor
private final class OPDSCatalogDetailFixture {
    typealias Value = BookCatalogPageLoad
    let model = OPDSCatalogDetailViewModel()
    private(set) var requestedURLs: [URL] = []
    private(set) var completedLoads: Set<Int> = []
    private var pending: [Int: CheckedContinuation<Value, Never>] = [:]
    private var startSignals: [Int: XCTestExpectation] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var closed = false

    init() {
        model.pageFetcher = { [weak self] request in
            guard let self, !self.closed else { return .cancelled }
            self.requestedURLs.append(request.url)
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

    func loadMore() throws -> Task<Void, Never> {
        let task = try XCTUnwrap(model.loadMore())
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

    func resolve(_ request: Int, titles: [String] = [], error: String? = nil, nextURL: URL? = nil,
                 file: StaticString = #filePath, line: UInt = #line) {
        guard let continuation = pending.removeValue(forKey: request) else {
            return XCTFail("Missing catalog response \(request)", file: file, line: line)
        }
        let value = error.map(Value.failure) ?? .page(BookCatalogPage(
            publications: titles.map { Publication(title: $0) },
            nextURL: nextURL
        ))
        continuation.resume(returning: value)
    }

    func cleanup() async {
        closed = true
        model.cancel()
        tasks.forEach { $0.cancel() }
        let continuations = Array(pending.values)
        pending.removeAll()
        continuations.forEach { $0.resume(returning: .cancelled) }
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

    func testRefreshCannotBeOverwrittenByAnOlderContinuation() async throws {
        try await withFixture { fixture in
            let continuationURL = try XCTUnwrap(URL(string: "https://catalog.example/more"))
            let (_, initial) = fixture.load(firstURL)
            guard await fixture.waitForRequest(1) else { return }
            fixture.resolve(1, titles: ["initial"], nextURL: continuationURL)
            await initial.value

            let oldPage = try fixture.loadMore()
            guard await fixture.waitForRequest(2) else { return }
            let (_, replacement) = fixture.load(secondURL)
            guard await fixture.waitForRequest(3) else { return }
            XCTAssertFalse(fixture.model.isLoadingNextPage)
            XCTAssertFalse(fixture.model.canLoadMore)

            fixture.resolve(3, titles: ["replacement"])
            await replacement.value
            fixture.resolve(2, titles: ["retired"], nextURL: continuationURL)
            await oldPage.value
            XCTAssertTrue(oldPage.isCancelled)
            XCTAssertEqual(fixture.model.publications.map(\.title), ["replacement"])
            XCTAssertFalse(fixture.model.canLoadMore)
            XCTAssertNil(fixture.model.pageErrorMessage)
        }
    }

    func testClosingCatalogRejectsALateContinuationError() async throws {
        try await withFixture { fixture in
            let continuationURL = try XCTUnwrap(URL(string: "https://catalog.example/more"))
            let (_, initial) = fixture.load(firstURL)
            guard await fixture.waitForRequest(1) else { return }
            fixture.resolve(1, titles: ["initial"], nextURL: continuationURL)
            await initial.value

            let page = try fixture.loadMore()
            guard await fixture.waitForRequest(2) else { return }
            fixture.model.cancel()
            fixture.resolve(2, error: "retired request failed")
            await page.value
            XCTAssertTrue(page.isCancelled)
            XCTAssertEqual(fixture.model.publications.map(\.title), ["initial"])
            XCTAssertFalse(fixture.model.isLoadingNextPage)
            XCTAssertFalse(fixture.model.canLoadMore)
            XCTAssertNil(fixture.model.pageErrorMessage)
        }
    }

    func testCancelledContinuationRetainsCursorForAnotherTap() async throws {
        try await withFixture { fixture in
            let continuationURL = try XCTUnwrap(URL(string: "https://catalog.example/more"))
            let (_, initial) = fixture.load(firstURL)
            guard await fixture.waitForRequest(1) else { return }
            fixture.resolve(1, titles: ["initial"], nextURL: continuationURL)
            await initial.value

            let page = try fixture.loadMore()
            guard await fixture.waitForRequest(2) else { return }
            page.cancel()
            fixture.resolve(2, titles: ["cancelled"])
            await page.value
            XCTAssertFalse(fixture.model.isLoadingNextPage)
            XCTAssertTrue(fixture.model.canLoadMore)
            XCTAssertEqual(fixture.model.publications.map(\.title), ["initial"])

            let retry = try fixture.loadMore()
            guard await fixture.waitForRequest(3) else { return }
            XCTAssertEqual(fixture.requestedURLs.suffix(2), [continuationURL, continuationURL][...])
            fixture.resolve(3, titles: ["next"])
            await retry.value
            XCTAssertEqual(fixture.model.publications.map(\.title), ["initial", "next"])
        }
    }

    func testSynchronousDismissalWhileAnnouncingLoadMoreCancelsTheReservedRequest() async throws {
        try await withFixture { fixture in
            let continuationURL = try XCTUnwrap(URL(string: "https://catalog.example/more"))
            let (_, initial) = fixture.load(firstURL)
            guard await fixture.waitForRequest(1) else { return }
            fixture.resolve(1, titles: ["initial"], nextURL: continuationURL)
            await initial.value

            let model = fixture.model
            var didDismiss = false
            let observation = model.objectWillChange.sink { [weak model] _ in
                guard !didDismiss else { return }
                didDismiss = true
                model?.cancel()
            }
            defer { observation.cancel() }
            let page = try fixture.loadMore()
            await page.value
            XCTAssertTrue(didDismiss)
            XCTAssertTrue(page.isCancelled)
            XCTAssertEqual(fixture.requestedURLs.count, 1)
            XCTAssertEqual(model.publications.map(\.title), ["initial"])
            XCTAssertFalse(model.isLoadingNextPage)
            XCTAssertFalse(model.canLoadMore)
        }
    }

    func testSynchronousDismissalWhileAnnouncingPageSettlementRejectsTheWholeAppend() async throws {
        try await withFixture { fixture in
            let continuationURL = try XCTUnwrap(URL(string: "https://catalog.example/more"))
            let (_, initial) = fixture.load(firstURL)
            guard await fixture.waitForRequest(1) else { return }
            fixture.resolve(1, titles: ["initial"], nextURL: continuationURL)
            await initial.value

            let page = try fixture.loadMore()
            guard await fixture.waitForRequest(2) else { return }
            let model = fixture.model
            var didDismiss = false
            let observation = model.objectWillChange.sink { [weak model] _ in
                guard !didDismiss else { return }
                didDismiss = true
                model?.cancel()
            }
            defer { observation.cancel() }
            fixture.resolve(2, titles: ["retired"], nextURL: continuationURL)
            await page.value
            XCTAssertTrue(didDismiss)
            XCTAssertEqual(model.publications.map(\.title), ["initial"])
            XCTAssertFalse(model.isLoadingNextPage)
            XCTAssertFalse(model.canLoadMore)
        }
    }

    func testFailureSettlesLoadingAndRetryInOnePresentationChange() async throws {
        try await withFixture { fixture in
            let continuationURL = try XCTUnwrap(URL(string: "https://catalog.example/more"))
            let (_, initial) = fixture.load(firstURL)
            guard await fixture.waitForRequest(1) else { return }
            fixture.resolve(1, titles: ["initial"], nextURL: continuationURL)
            await initial.value

            let page = try fixture.loadMore()
            guard await fixture.waitForRequest(2) else { return }
            let model = fixture.model
            var changes = 0
            let observation = model.objectWillChange.sink { _ in changes += 1 }
            defer { observation.cancel() }
            fixture.resolve(2, error: "Cannot load next page")
            await page.value
            XCTAssertEqual(changes, 1)
            XCTAssertFalse(model.isLoadingNextPage)
            XCTAssertTrue(model.canLoadMore)
            XCTAssertEqual(model.pageErrorMessage, "Cannot load next page")
            XCTAssertEqual(model.publications.map(\.title), ["initial"])
        }
    }

    func testDirectCancellationDuringSettlementRejectsAppendAndRetainsCursor() async throws {
        try await withFixture { fixture in
            let continuationURL = try XCTUnwrap(URL(string: "https://catalog.example/more"))
            let (_, initial) = fixture.load(firstURL)
            guard await fixture.waitForRequest(1) else { return }
            fixture.resolve(1, titles: ["initial"], nextURL: continuationURL)
            await initial.value

            let page = try fixture.loadMore()
            guard await fixture.waitForRequest(2) else { return }
            let model = fixture.model
            var didCancel = false
            let observation = model.objectWillChange.sink { _ in
                guard !didCancel else { return }
                didCancel = true
                page.cancel()
            }
            defer { observation.cancel() }
            fixture.resolve(2, titles: ["cancelled"])
            await page.value
            XCTAssertTrue(didCancel)
            XCTAssertEqual(model.publications.map(\.title), ["initial"])
            XCTAssertFalse(model.isLoadingNextPage)
            XCTAssertTrue(model.canLoadMore)
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

@MainActor
final class OPDSCatalogPaginationTests: XCTestCase {
    private let host = "\(UUID().uuidString.lowercased()).pagination.example"
    private var firstURL: URL { URL(string: "https://\(host)/catalog")! }
    private var finalURL: URL { URL(string: "https://\(host)/redirected/catalog.xml?page=1")! }
    private var secondURL: URL { URL(string: "https://\(host)/redirected/catalog.xml?page=2")! }
    private var thirdURL: URL { URL(string: "https://\(host)/redirected/page-3.json")! }

    private func withProvider(
        _ replies: [URL: [CatalogPageURLProtocol.Reply]],
        _ body: @MainActor (OPDSCatalogDetailViewModel) async throws -> Void
    ) async rethrows {
        CatalogPageURLProtocol.scripts.set(replies, for: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogPageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            CatalogPageURLProtocol.scripts.remove(host)
        }
        let model = OPDSCatalogDetailViewModel()
        model.pageFetcher = { await BookLibraryViewModel.fetchCatalogPage($0, session: session) }
        try await body(model)
    }

    private var firstPage: String {
        """
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Books</title>
          <link rel="next" href="?page=2#next" />
          <entry><id>urn:book:a</id><title>Same title</title>
            <link rel="http://opds-spec.org/acquisition" href="a.epub" type="application/epub+zip" />
          </entry>
          <entry><title>Without ID</title>
            <link rel="http://opds-spec.org/acquisition" href="without-id.epub" type="application/epub+zip" />
          </entry>
        </feed>
        """
    }

    func testLoadMoreRetriesTheSamePageAndAppendsDistinctBooksInSourceOrder() async throws {
        let secondPage = """
        {"metadata":{"title":"Books"},
         "publications":[
           {"metadata":{"title":"Renamed duplicate","identifier":"urn:book:a"},"links":[{"rel":"download","href":"new-a.epub"}]},
           {"metadata":{"title":"Duplicate without ID"},"links":[{"rel":"download","href":"without-id.epub"}]},
           {"metadata":{"title":"Same title","identifier":"urn:book:b"},"links":[{"rel":"download","href":"b.epub"}]},
           {"metadata":{"title":"Last book","identifier":"urn:book:c"},"links":[{"rel":"download","href":"c.epub"}]}
         ]}
        """
        try await withProvider([
            firstURL: [.init(body: firstPage, finalURL: finalURL)],
            secondURL: [.init(body: "", status: 503), .init(body: secondPage)]
        ]) { model in
            await model.load(catalogURL: firstURL.absoluteString)
            XCTAssertEqual(model.publications.map(\.title), ["Same title", "Without ID"])
            let initialIDs = model.publications.map(\.id)
            XCTAssertTrue(model.canLoadMore)
            let firstAttempt = try XCTUnwrap(model.loadMore())
            XCTAssertNil(model.loadMore(), "A second tap must not start another request")
            await firstAttempt.value
            XCTAssertFalse(model.isLoadingNextPage)
            XCTAssertNotNil(model.pageErrorMessage)
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(model.publications.map(\.id), initialIDs)
            XCTAssertTrue(model.canLoadMore)

            // The cursor must still use the first page's captured provider.
            model.pageFetcher = { _ in .failure("Unexpected new provider") }
            let retry = try XCTUnwrap(model.loadMore())
            await retry.value
            XCTAssertEqual(model.publications.map(\.title), ["Same title", "Without ID", "Same title", "Last book"])
            XCTAssertEqual(Array(model.publications.prefix(2)).map(\.id), initialIDs)
            XCTAssertNil(model.pageErrorMessage)
            XCTAssertFalse(model.canLoadMore)
        }
    }

    func testEmptyPageAdvancesOnlyOneDocumentPerClickAndStopsAtPreviouslySeenNextLink() async throws {
        let emptyPage = """
        {"metadata":{"title":"Empty"},"links":[{"rel":"next","href":"page-3.json"}],"publications":[]}
        """
        let thirdPage = """
        {"metadata":{"title":"Books"},"links":[{"rel":"next","href":"catalog.xml?page=1#top"}],
         "publications":[{"metadata":{"title":"Third page","identifier":"urn:book:c"}}]}
        """
        try await withProvider([
            firstURL: [.init(body: firstPage, finalURL: finalURL)],
            secondURL: [.init(body: emptyPage)],
            thirdURL: [.init(body: thirdPage)]
        ]) { model in
            await model.load(catalogURL: firstURL.absoluteString)
            let empty = try XCTUnwrap(model.loadMore())
            await empty.value
            XCTAssertEqual(model.publications.map(\.title), ["Same title", "Without ID"])
            XCTAssertTrue(model.canLoadMore)

            let third = try XCTUnwrap(model.loadMore())
            await third.value
            XCTAssertEqual(model.publications.map(\.title), ["Same title", "Without ID", "Third page"])
            XCTAssertFalse(model.canLoadMore)
            XCTAssertNil(model.loadMore())
        }
    }

    func testRedirectToAnAlreadyLoadedCatalogDoesNotAppendOrRetryACycle() async throws {
        try await withProvider([
            firstURL: [.init(body: firstPage, finalURL: finalURL)],
            secondURL: [.init(body: firstPage, finalURL: finalURL)]
        ]) { model in
            await model.load(catalogURL: firstURL.absoluteString)
            let ids = model.publications.map(\.id)
            let cycle = try XCTUnwrap(model.loadMore())
            await cycle.value
            XCTAssertEqual(model.publications.map(\.id), ids)
            XCTAssertEqual(model.pageErrorMessage, BookCatalogPageLoad.cycleMessage)
            XCTAssertFalse(model.canLoadMore)
        }
    }
}

private final class CatalogPageURLProtocol: URLProtocol {
    struct Reply {
        let body: String
        var finalURL: URL? = nil
        var status = 200
    }

    final class Scripts: @unchecked Sendable {
        private let lock = NSLock()
        private var scripts: [String: [URL: [Reply]]] = [:]

        func set(_ replies: [URL: [Reply]], for host: String) {
            lock.lock()
            defer { lock.unlock() }
            scripts[host] = replies
        }

        func remove(_ host: String) {
            lock.lock()
            defer { lock.unlock() }
            scripts.removeValue(forKey: host)
        }

        func next(at url: URL, host: String) -> Reply? {
            lock.lock()
            defer { lock.unlock() }
            guard var replies = scripts[host]?[url], !replies.isEmpty else { return nil }
            let reply = replies.removeFirst()
            scripts[host]?[url] = replies
            return reply
        }
    }

    static let scripts = Scripts()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let host = url.host,
              let reply = Self.scripts.next(at: url, host: host),
              let response = HTTPURLResponse(
                url: reply.finalURL ?? url, statusCode: reply.status, httpVersion: nil, headerFields: nil
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
