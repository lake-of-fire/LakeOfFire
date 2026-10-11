import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LakeOfFireOPDS

@MainActor
final class OPDSAsyncLoadingTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AsyncCatalogProtocol.self]
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }

    func testAsyncResultTransfersMutableFeedToTheReceivingActor() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let result = try await OPDSParser.parseURL(url: url("json"), session: session)
        MainActor.preconditionIsolated()
        let feed = try XCTUnwrap(result.feed)
        XCTAssertEqual(feed.metadata.title, "JSON")
        feed.metadata.title = "Receiver owns this graph"
        XCTAssertEqual(feed.metadata.title, "Receiver owns this graph")
    }

    func testSeparateAsyncCallsDoNotShareGraphs() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let first = try await OPDSParser.parseURL(url: url("json"), session: session)
        let second = try await OPDSParser.parseURL(url: url("json"), session: session)
        first.feed?.metadata.title = "Changed"
        XCTAssertEqual(second.feed?.metadata.title, "JSON")
        XCTAssertFalse(first.feed === second.feed)
    }

    func testXMLAndJSONUseTheSameSelectionAsTheCallbackAPI() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        for path in ["xml", "json", "publication"] {
            let asyncResult = try await OPDSParser.parseURL(url: url(path), session: session)
            let callbackResult: (ParseData?, Error?) = await withCheckedContinuation { continuation in
                OPDSParser.parseURL(url: url(path), session: session) {
                    continuation.resume(returning: ($0, $1))
                }
            }
            XCTAssertNil(callbackResult.1)
            XCTAssertEqual(asyncResult.feed?.metadata.title, callbackResult.0?.feed?.metadata.title)
            XCTAssertEqual(asyncResult.publication?.metadata.title, callbackResult.0?.publication?.metadata.title)
        }
    }

    func testFinalResponseURLAndRelativePublicationLinkArePreserved() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let result = try await OPDSParser.parseURL(url: url("publication"), session: session)
        XCTAssertEqual(result.documentURL.absoluteString, "https://cdn.example/books/entry.json")
        XCTAssertEqual(result.publication?.links.first?.href, "https://cdn.example/books/book.epub")
    }

    func testHTTPFailuresAndPartialBodiesNeverProduceACatalog() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        for status in [206, 301, 304, 401, 404, 429, 500, 503] {
            do {
                _ = try await OPDSParser.parseURL(url: url("status-\(status)"), session: session)
                XCTFail("Admitted HTTP \(status)")
            } catch let error as OPDSParserError {
                switch (status, error) {
                case (206, .partialDocument): break
                case (_, .httpStatus(let actual)): XCTAssertEqual(actual, status)
                default: XCTFail("Unexpected error: \(error)")
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testInvalidBodyReportsTheExistingGenericParserError() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await OPDSParser.parseURL(url: url("invalid"), session: session)
            XCTFail("Invalid document was accepted")
        } catch OPDSParserError.documentNotValid {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testTransportFailureRemainsATransportFailure() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await OPDSParser.parseURL(url: url("failure"), session: session)
            XCTFail("Transport failure was accepted")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
    }

    func testAlreadyCancelledCallerDoesNotStartTransport() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let probe = AsyncCatalogProbe()
        let key = UUID().uuidString
        AsyncCatalogProtocol.probes.set(probe, key: key)
        defer { AsyncCatalogProtocol.probes.remove(key: key) }
        let task = Task { @MainActor in
            _ = try await OPDSParser.parseURL(url: url("held/\(key)"), session: session)
        }
        task.cancel() // Same actor: the operation has not had a chance to begin.
        do {
            try await task.value
            XCTFail("Cancelled call succeeded")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(probe.startCount, 0)
    }

    func testCancellationStopsAnAlreadyStartedURLSessionRequest() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let probe = AsyncCatalogProbe()
        let key = UUID().uuidString
        AsyncCatalogProtocol.probes.set(probe, key: key)
        defer { AsyncCatalogProtocol.probes.remove(key: key) }
        let task = Task { @MainActor in
            _ = try await OPDSParser.parseURL(url: url("held/\(key)"), session: session)
        }
        let started = await XCTWaiter.fulfillment(of: [probe.started], timeout: 3)
        XCTAssertEqual(started, .completed)
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled call succeeded")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        let stopped = await XCTWaiter.fulfillment(of: [probe.stopped], timeout: 3)
        XCTAssertEqual(stopped, .completed)
        XCTAssertEqual(probe.startCount, 1)
    }

    private func url(_ path: String) -> URL {
        URL(string: "https://async-catalog.example/\(path)")!
    }
}

private final class AsyncCatalogProbe: @unchecked Sendable {
    let started = XCTestExpectation(description: "Transport started")
    let stopped = XCTestExpectation(description: "Transport stopped")
    private let lock = NSLock()
    private var starts = 0
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    func start() { lock.lock(); starts += 1; lock.unlock(); started.fulfill() }
}

private final class AsyncCatalogProbes: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: AsyncCatalogProbe] = [:]
    func set(_ value: AsyncCatalogProbe, key: String) { lock.lock(); values[key] = value; lock.unlock() }
    func get(key: String) -> AsyncCatalogProbe? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func remove(key: String) { lock.lock(); values.removeValue(forKey: key); lock.unlock() }
}

private final class AsyncCatalogProtocol: URLProtocol {
    static let probes = AsyncCatalogProbes()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "async-catalog.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        if request.url!.path.hasPrefix("/held/") {
            Self.probes.get(key: path)?.start()
            return
        }
        if path == "failure" {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        var finalURL = request.url!
        let body: String
        switch path {
        case "xml": body = "<feed><title>XML</title></feed>"
        case "publication":
            finalURL = URL(string: "https://cdn.example/books/entry.json")!
            body = #"{"metadata":{"title":"Standalone"},"links":[{"href":"book.epub"}]}"#
        case "invalid": body = "not an OPDS document"
        default: body = #"{"metadata":{"title":"JSON"},"publications":[]}"#
        }
        let status = path.hasPrefix("status-") ? Int(path.dropFirst(7))! : 200
        let response = HTTPURLResponse(url: finalURL, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        if request.url?.path.hasPrefix("/held/") == true, let key = request.url?.lastPathComponent {
            Self.probes.get(key: key)?.stopped.fulfill()
        }
    }
}
