import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LakeOfFireReader

private struct CatalogTraversalResponse: Sendable {
    var body = ""
    var finalURL: URL?
    var error: URLError.Code?
    var held = false
}

private final class CatalogTraversalRegistry: @unchecked Sendable {
    static let shared = CatalogTraversalRegistry()
    private let lock = NSLock()
    private var fixtures: [String: CatalogTraversalFixture] = [:]

    func install(_ fixture: CatalogTraversalFixture, host: String) {
        lock.withLock { fixtures[host] = fixture }
    }

    func fixture(for host: String?) -> CatalogTraversalFixture? {
        lock.withLock { host.flatMap { fixtures[$0] } }
    }

    func remove(host: String) {
        lock.withLock { fixtures.removeValue(forKey: host) }
    }
}

/// Finite transport scripts, not a replacement parser or traversal policy.
/// An unexpected extra request fails rather than leaving a cycle test running.
private final class CatalogTraversalFixture: @unchecked Sendable {
    private struct TaskRecord: Sendable {
        let cancel: @Sendable () -> Void
        let wait: @Sendable () async -> Void
    }

    let rootURL: URL
    let session: URLSession
    private let lock = NSLock()
    private var responses: [String: [CatalogTraversalResponse]] = [:]
    private var requested: [URL] = []
    private var pending: [(CatalogTraversalProtocol, CatalogTraversalResponse)] = []
    private var signals: [(Int, XCTestExpectation)] = []
    private var tasks: [TaskRecord] = []
    private var closed = false

    init() {
        rootURL = URL(string: "https://\(UUID().uuidString.lowercased()).book-catalog.example/")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogTraversalProtocol.self]
        configuration.timeoutIntervalForRequest = 3
        session = URLSession(configuration: configuration)
        CatalogTraversalRegistry.shared.install(self, host: rootURL.host!)
    }

    func url(_ path: String) -> URL {
        URL(string: path, relativeTo: rootURL)!.absoluteURL
    }

    var requests: [URL] {
        lock.withLock { requested }
    }

    func enqueue(_ path: String, _ response: CatalogTraversalResponse) {
        let key = Self.key(url(path))
        lock.withLock { responses[key, default: []].append(response) }
    }

    func signalRequest(_ number: Int, with expectation: XCTestExpectation) {
        let reached = lock.withLock {
            if requested.count >= number { return true }
            signals.append((number, expectation))
            return false
        }
        if reached { expectation.fulfill() }
    }

    func track<Success: Sendable, Failure: Error>(_ task: Task<Success, Failure>) {
        lock.withLock {
            tasks.append(TaskRecord(cancel: { task.cancel() }, wait: { _ = await task.result }))
        }
    }

    fileprivate func receive(_ protocolInstance: CatalogTraversalProtocol, url: URL) {
        let (response, notifications) = lock.withLock {
            requested.append(url)
            let notifications = signals.filter { $0.0 <= requested.count }.map { $0.1 }
            signals.removeAll { $0.0 <= requested.count }
            let key = Self.key(url)
            let response: CatalogTraversalResponse
            if !closed, var values = responses[key], !values.isEmpty {
                response = values.removeFirst()
                responses[key] = values
            } else {
                response = CatalogTraversalResponse(error: .resourceUnavailable)
            }
            if response.held { pending.append((protocolInstance, response)) }
            return (response, notifications)
        }
        notifications.forEach { $0.fulfill() }
        if !response.held { protocolInstance.deliver(response) }
    }

    func releaseResponses() {
        let deliveries = lock.withLock {
            let result = pending
            pending.removeAll()
            return result
        }
        deliveries.forEach { $0.0.deliver($0.1) }
    }

    func close() async {
        let tracked = lock.withLock {
            closed = true
            return tasks
        }
        tracked.forEach { $0.cancel() }
        releaseResponses()
        session.invalidateAndCancel()
        for task in tracked { await task.wait() }
        CatalogTraversalRegistry.shared.remove(host: rootURL.host!)
    }

    private static func key(_ url: URL) -> String {
        url.path + (url.query.map { "?" + $0 } ?? "")
    }
}

private final class CatalogTraversalProtocol: URLProtocol, @unchecked Sendable {
    private let deliveryLock = NSLock()
    private var finished = false

    // This protocol is installed only on a fixture's private session. Even an
    // unexpected host is intercepted and failed; tests cannot use the network.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let fixture = CatalogTraversalRegistry.shared.fixture(for: url.host) else {
            deliver(CatalogTraversalResponse(error: .unsupportedURL))
            return
        }
        fixture.receive(self, url: url)
    }

    fileprivate func deliver(_ result: CatalogTraversalResponse) {
        let ownsDelivery = deliveryLock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
        guard ownsDelivery else { return }
        if let code = result.error {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        guard let finalURL = result.finalURL ?? request.url,
              let response = HTTPURLResponse(url: finalURL, statusCode: 200,
                  httpVersion: nil, headerFields: ["Content-Type": "application/opds+json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        // A controlled response URL exercises document identity. This does
        // not simulate URLSession's redirect delegate or an actual HTTP 3xx.
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(result.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        deliveryLock.withLock { finished = true }
    }
}

@MainActor
final class BookCatalogLoadingTests: XCTestCase {
    private let publication = #"{"metadata":{"title":"日本語 & Friends","author":["Author One","Author Two"],"published":"2020-01-02","description":"Summary","subtitle":"Subtitle"},"links":[{"href":"book.epub","rel":"http://opds-spec.org/acquisition"}],"images":[{"href":"cover.png","rel":"cover"}]}"#

    private var feed: String {
        "{\"metadata\":{\"title\":\"Catalog\"},\"publications\":[\(publication)]}"
    }

    private func navigation(_ href: String, title: String = "All Books") throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: [
            "metadata": ["title": "Catalog"],
            "navigation": [["href": href, "title": title]],
        ]), as: UTF8.self)
    }

    private func withFixture(
        _ body: @MainActor (CatalogTraversalFixture) async throws -> Void
    ) async throws {
        let fixture = CatalogTraversalFixture()
        do {
            try await body(fixture)
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    func testActualLibraryCallerPreservesMetadataAndRequestedDocumentURLs() async throws {
        try await withFixture { fixture in
            fixture.enqueue("catalog/feed", CatalogTraversalResponse(
                body: feed, finalURL: URL(string: "https://response.example/moved/catalog.json")!
            ))
            let (books, error) = await BookLibraryViewModel.fetchPublications(
                from: fixture.url("catalog/feed"), session: fixture.session
            )
            XCTAssertNil(error)
            let book = try XCTUnwrap(books.first)
            XCTAssertEqual(books.count, 1)
            XCTAssertEqual(book.title, "日本語 & Friends")
            XCTAssertEqual(book.author, "Author One, Author Two")
            XCTAssertEqual(book.publicationDate?.timeIntervalSince1970, 1_577_923_200)
            XCTAssertEqual(book.summary, "Summary")
            XCTAssertEqual(book.coverURL, fixture.url("catalog/cover.png"))
            XCTAssertEqual(book.downloadURL, fixture.url("catalog/book.epub"))
            XCTAssertFalse(book.hasContentAudio)
            XCTAssertEqual(fixture.requests, [fixture.url("catalog/feed")])
        }
    }

    func testExactAcquisitionAndCoverPriorityRemain() async throws {
        try await withFixture { fixture in
            fixture.enqueue("priority", CatalogTraversalResponse(body: #"{"metadata":{"title":"Catalog"},"publications":[{"metadata":{"title":"Priority","subtitle":"Fallback"},"links":[{"href":"buy","rel":"http://opds-spec.org/acquisition/buy"},{"href":"open.epub","rel":"http://opds-spec.org/acquisition/open-access"},{"href":"original.epub","rel":"http://opds-spec.org/acquisition"}],"images":[{"href":"thumb.png","rel":"http://opds-spec.org/image/thumbnail"},{"href":"image.png","rel":"http://opds-spec.org/image"},{"href":"cover.png","rel":"cover"}]}]}"#))
            let books = try await BookCatalogLoading.publications(from: fixture.url("priority"), session: fixture.session)
            let book = try XCTUnwrap(books.first)
            XCTAssertEqual(book.downloadURL, fixture.url("original.epub"))
            XCTAssertEqual(book.coverURL, fixture.url("cover.png"))
            XCTAssertEqual(book.summary, "Fallback")
        }
    }

    func testRelatedAcquisitionRelationsRemainExcludedFromFullDownloads() async throws {
        try await withFixture { fixture in
            fixture.enqueue("related", CatalogTraversalResponse(body: #"{"metadata":{"title":"Catalog"},"publications":[{"metadata":{"title":"Related"},"links":[{"href":"buy","rel":"http://opds-spec.org/acquisition/buy"},{"href":"sample.epub","rel":"http://opds-spec.org/acquisition/sample"},{"href":"open.epub","rel":"http://opds-spec.org/acquisition/open-access"}],"images":[{"href":"thumb.png","rel":"http://opds-spec.org/image/thumbnail"}]}]}"#))
            let books = try await BookCatalogLoading.publications(from: fixture.url("related"), session: fixture.session)
            XCTAssertNil(try XCTUnwrap(books.first).downloadURL)
            XCTAssertEqual(books.first?.coverURL, fixture.url("thumb.png"))
        }
    }

    func testStandalonePublicationKeepsTheSelectedNoPublicationsOutcome() async throws {
        try await withFixture { fixture in
            fixture.enqueue("standalone", CatalogTraversalResponse(body: publication))
            let (books, error) = await BookLibraryViewModel.fetchPublications(
                from: fixture.url("standalone"), session: fixture.session
            )
            XCTAssertTrue(books.isEmpty)
            XCTAssertEqual(error, "No publications or navigable links found")
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testLastPermittedDocumentCanPublishAndKeepsRelativeNavigation() async throws {
        try await withFixture { fixture in
            fixture.enqueue("catalog/start", CatalogTraversalResponse(body: try navigation("leaf")))
            fixture.enqueue("catalog/leaf", CatalogTraversalResponse(body: feed))
            let books = try await BookCatalogLoading.publications(
                from: fixture.url("catalog/start"), session: fixture.session, maximumDocuments: 2
            )
            XCTAssertEqual(books.map(\.title), ["日本語 & Friends"])
            XCTAssertEqual(books.first?.downloadURL, fixture.url("catalog/book.epub"))
            XCTAssertEqual(fixture.requests, [fixture.url("catalog/start"), fixture.url("catalog/leaf")])
        }
    }

    func testSelfCycleStopsBeforeAnotherRequest() async throws {
        try await withFixture { fixture in
            fixture.enqueue("cycle", CatalogTraversalResponse(body: try navigation(fixture.url("cycle").absoluteString)))
            do {
                _ = try await BookCatalogLoading.publications(from: fixture.url("cycle"), session: fixture.session)
                XCTFail("Expected the repeated document to be rejected")
            } catch BookCatalogLoadingError.navigationCycle {
            }
            XCTAssertEqual(fixture.requests, [fixture.url("cycle")])
        }
    }

    func testFragmentOnlyCycleStopsBeforeAnotherRequest() async throws {
        try await withFixture { fixture in
            fixture.enqueue("cycle", CatalogTraversalResponse(body: try navigation(fixture.url("cycle#new-fragment").absoluteString)))
            do {
                _ = try await BookCatalogLoading.publications(from: fixture.url("cycle"), session: fixture.session)
                XCTFail("A new fragment cannot identify another catalog document")
            } catch BookCatalogLoadingError.navigationCycle {
            }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testTwoDocumentCycleStopsBeforeRequestingTheFirstAgain() async throws {
        try await withFixture { fixture in
            fixture.enqueue("a", CatalogTraversalResponse(body: try navigation(fixture.url("b").absoluteString)))
            fixture.enqueue("b", CatalogTraversalResponse(body: try navigation(fixture.url("a").absoluteString)))
            do {
                _ = try await BookCatalogLoading.publications(from: fixture.url("a"), session: fixture.session)
                XCTFail("Expected A to B to A to be rejected")
            } catch BookCatalogLoadingError.navigationCycle {
            }
            XCTAssertEqual(fixture.requests, [fixture.url("a"), fixture.url("b")])
        }
    }

    func testControlledFinalResponseURLCannotBeRequestedAgain() async throws {
        try await withFixture { fixture in
            fixture.enqueue("requested", CatalogTraversalResponse(
                body: try navigation(fixture.url("final#fragment").absoluteString), finalURL: fixture.url("final")
            ))
            do {
                _ = try await BookCatalogLoading.publications(from: fixture.url("requested"), session: fixture.session)
                XCTFail("The response document is already visited")
            } catch BookCatalogLoadingError.navigationCycle {
            }
            XCTAssertEqual(fixture.requests, [fixture.url("requested")])
        }
    }

    func testLaterResponseConvergingOnAnEarlierDocumentIsRejected() async throws {
        try await withFixture { fixture in
            fixture.enqueue("a", CatalogTraversalResponse(body: try navigation(fixture.url("b").absoluteString)))
            fixture.enqueue("b", CatalogTraversalResponse(body: feed, finalURL: fixture.url("a")))
            do {
                _ = try await BookCatalogLoading.publications(from: fixture.url("a"), session: fixture.session)
                XCTFail("A changed request URL cannot disguise a visited response document")
            } catch BookCatalogLoadingError.navigationCycle {
            }
            XCTAssertEqual(fixture.requests, [fixture.url("a"), fixture.url("b")])
        }
    }

    func testDifferentQueriesRemainDistinctDocuments() async throws {
        try await withFixture { fixture in
            fixture.enqueue("catalog?page=1", CatalogTraversalResponse(body: try navigation(fixture.url("catalog?page=2").absoluteString)))
            fixture.enqueue("catalog?page=2", CatalogTraversalResponse(body: feed))
            let books = try await BookCatalogLoading.publications(from: fixture.url("catalog?page=1"), session: fixture.session)
            XCTAssertEqual(books.count, 1)
            XCTAssertEqual(fixture.requests, [fixture.url("catalog?page=1"), fixture.url("catalog?page=2")])
        }
    }

    func testDistinctDocumentsStopAtTheRequestedBudget() async throws {
        try await withFixture { fixture in
            for step in 0..<4 {
                fixture.enqueue("step-\(step)", CatalogTraversalResponse(body: try navigation(fixture.url("step-\(step + 1)").absoluteString)))
            }
            do {
                _ = try await BookCatalogLoading.publications(from: fixture.url("step-0"), session: fixture.session, maximumDocuments: 3)
                XCTFail("Expected a bounded traversal failure")
            } catch BookCatalogLoadingError.navigationLimit {
            }
            XCTAssertEqual(fixture.requests, (0..<3).map { fixture.url("step-\($0)") })
        }
    }

    func testDefaultBudgetStopsAfterSixteenDocuments() async throws {
        try await withFixture { fixture in
            for step in 0..<17 {
                fixture.enqueue("step-\(step)", CatalogTraversalResponse(body: try navigation(fixture.url("step-\(step + 1)").absoluteString)))
            }
            do {
                _ = try await BookCatalogLoading.publications(from: fixture.url("step-0"), session: fixture.session)
                XCTFail("The ordinary loader must have a finite default budget")
            } catch BookCatalogLoadingError.navigationLimit {
            }
            XCTAssertEqual(fixture.requests.count, 16)
        }
    }

    func testNonpositiveBudgetsDoNotRequestAFirstDocument() async throws {
        try await withFixture { fixture in
            for limit in [0, -1, Int.min] {
                do {
                    _ = try await BookCatalogLoading.publications(from: fixture.url("unused"), session: fixture.session, maximumDocuments: limit)
                    XCTFail("A nonpositive budget must be rejected")
                } catch BookCatalogLoadingError.navigationLimit {
                }
            }
            XCTAssertTrue(fixture.requests.isEmpty)
        }
    }

    func testUnrelatedNavigationIsNotFollowed() async throws {
        try await withFixture { fixture in
            fixture.enqueue("unrelated", CatalogTraversalResponse(body: try navigation(fixture.url("unused").absoluteString, title: "Featured")))
            do {
                _ = try await BookCatalogLoading.publications(from: fixture.url("unrelated"), session: fixture.session)
                XCTFail("The loader only follows the existing All Books route")
            } catch BookCatalogLoadingError.noPublications {
            }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testActualCallerRetainsEmptyCatalogError() async throws {
        try await withFixture { fixture in
            fixture.enqueue("empty", CatalogTraversalResponse(body: #"{"metadata":{"title":"Empty"},"publications":[]}"#))
            let (books, error) = await BookLibraryViewModel.fetchPublications(from: fixture.url("empty"), session: fixture.session)
            XCTAssertTrue(books.isEmpty)
            XCTAssertEqual(error, "No publications or navigable links found")
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testActualCallerRetainsTransportErrorAndDoesNotRequestAnotherDocument() async throws {
        try await withFixture { fixture in
            fixture.enqueue("offline", CatalogTraversalResponse(error: .cannotConnectToHost))
            let (books, error) = await BookLibraryViewModel.fetchPublications(from: fixture.url("offline"), session: fixture.session)
            XCTAssertTrue(books.isEmpty)
            XCTAssertEqual(error, "Failed to fetch data: \(URLError(.cannotConnectToHost).localizedDescription)")
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testMalformedDocumentReturnsTheExistingFetchFailureShape() async throws {
        try await withFixture { fixture in
            fixture.enqueue("malformed", CatalogTraversalResponse(body: "not an OPDS document"))
            let (books, error) = await BookLibraryViewModel.fetchPublications(from: fixture.url("malformed"), session: fixture.session)
            XCTAssertTrue(books.isEmpty)
            XCTAssertTrue(try XCTUnwrap(error).hasPrefix("Failed to fetch data: "))
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testPrecancelledCallerStartsNoRequest() async throws {
        try await withFixture { fixture in
            let task = Task { @MainActor in
                try await BookCatalogLoading.publications(from: fixture.url("unused"), session: fixture.session)
            }
            fixture.track(task)
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("Expected cancelled entry to be rejected")
            } catch is CancellationError {
            }
            XCTAssertTrue(fixture.requests.isEmpty)
        }
    }

    func testCancellationDuringCallbackWaitStopsTheNextHop() async throws {
        try await withFixture { fixture in
            fixture.enqueue("held", CatalogTraversalResponse(body: try navigation(fixture.url("unused").absoluteString), held: true))
            let started = XCTestExpectation(description: "the actual parser's request is waiting for its response")
            fixture.signalRequest(1, with: started)
            let task = Task { @MainActor in
                try await BookCatalogLoading.publications(from: fixture.url("held"), session: fixture.session)
            }
            fixture.track(task)
            let outcome = await XCTWaiter.fulfillment(of: [started], timeout: 2)
            XCTAssertEqual(outcome, .completed)
            guard outcome == .completed else { return }
            task.cancel()
            // Cancellation is advisory for this callback transport. Deliberately
            // finish it successfully; traversal must still refuse another hop.
            fixture.releaseResponses()
            do {
                _ = try await task.value
                XCTFail("The cancelled caller must not continue traversal")
            } catch is CancellationError {
            }
            XCTAssertEqual(fixture.requests, [fixture.url("held")])
        }
    }

    func testActualDetailPublishesCycleErrorAndOwnedRetryRecovers() async throws {
        try await withFixture { fixture in
            fixture.enqueue("cycle", CatalogTraversalResponse(body: try navigation(fixture.url("cycle").absoluteString)))
            fixture.enqueue("cycle", CatalogTraversalResponse(body: feed))
            let model = OPDSCatalogDetailViewModel()
            model.publicationFetcher = { url in
                await BookLibraryViewModel.fetchPublications(from: url, session: fixture.session)
            }
            await model.load(catalogURL: fixture.url("cycle").absoluteString)
            XCTAssertTrue(model.publications.isEmpty)
            XCTAssertEqual(model.errorMessage, BookCatalogLoadingError.navigationCycle.localizedDescription)

            let retry = try XCTUnwrap(model.retry(catalogURL: fixture.url("cycle").absoluteString))
            fixture.track(retry)
            await retry.value
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(model.publications.map(\.title), ["日本語 & Friends"])
            XCTAssertEqual(fixture.requests, [fixture.url("cycle"), fixture.url("cycle")])
        }
    }

    func testDetailCancellationRejectsLateBooksAndKeepsTheNextPresentationUsable() async throws {
        try await withFixture { fixture in
            fixture.enqueue("held", CatalogTraversalResponse(body: feed, held: true))
            fixture.enqueue("valid", CatalogTraversalResponse(body: feed))
            let model = OPDSCatalogDetailViewModel()
            model.publicationFetcher = { url in
                await BookLibraryViewModel.fetchPublications(from: url, session: fixture.session)
            }
            let started = XCTestExpectation(description: "detail's actual parser request is waiting")
            fixture.signalRequest(1, with: started)
            let original = Task { @MainActor in
                await model.load(catalogURL: fixture.url("held").absoluteString)
            }
            fixture.track(original)
            let outcome = await XCTWaiter.fulfillment(of: [started], timeout: 2)
            XCTAssertEqual(outcome, .completed)
            guard outcome == .completed else { return }
            model.cancel()
            fixture.releaseResponses()
            await original.value
            XCTAssertTrue(model.publications.isEmpty)
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(fixture.requests, [fixture.url("held")])

            let retry = try XCTUnwrap(model.retry(catalogURL: fixture.url("valid").absoluteString))
            fixture.track(retry)
            await retry.value
            XCTAssertEqual(model.publications.map(\.title), ["日本語 & Friends"])
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(fixture.requests, [fixture.url("held"), fixture.url("valid")])
        }
    }
}
