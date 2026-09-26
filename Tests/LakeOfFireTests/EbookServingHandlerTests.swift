import Foundation
import XCTest
@preconcurrency import WebKit
@testable import LakeOfFireContent
@testable import LakeOfFireReader

/// Full-host boundary tests. These are not part of the isolated fingerprint
/// package: they execute the real WKURLSchemeHandler, decoder and lease store.
private final class ServingSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    let completed = XCTestExpectation(description: "scheme terminal callback")
    private(set) var responses = [URLResponse]()
    private(set) var bytes = Data()
    private(set) var failures = [Error]()
    private(set) var finishCount = 0

    init(_ request: URLRequest) { self.request = request }
    func didReceive(_ response: URLResponse) {
        XCTAssertTrue(Thread.isMainThread)
        responses.append(response)
    }
    func didReceive(_ data: Data) { bytes.append(data) }
    func didFinish() { finishCount += 1; completed.fulfill() }
    func didFailWithError(_ error: Error) { failures.append(error); completed.fulfill() }
}

final class EbookServingHandlerTests: XCTestCase {
    private let sourceURL = URL(string: "ebook://ebook/load/local/Books/shared.epub")!

    private func package(_ text: String, selected: String = "OPS/book.opf") async throws -> ReaderEBookServingPackage {
        let files: [(String, String)] = [
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='OPS/book.opf' media-type='application/oebps-package+xml'/><rootfile full-path='Other/book.opf' media-type='application/oebps-package+xml'/></rootfiles></container>"),
            ("OPS/book.opf", "<package><spine/></package>"),
            ("Other/book.opf", "<package><spine/></package>"),
            ("OPS/chapter.xhtml", text),
        ]
        let bytes = EBookZIPPathFixture.archive(files.map {
            .init(name: Data($0.0.utf8), bytes: Data($0.1.utf8))
        })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try await ReaderEBookPackageSnapshot.capture(at: url)
        return try .init(sourceURL: sourceURL, snapshot: snapshot, packageDocumentPath: selected)
    }

    private func request(route: String = "entry", session: String?, subpath: String? = "OPS/chapter.xhtml") -> URLRequest {
        var components = URLComponents(string: "ebook://ebook/" + route)!
        components.queryItems = [URLQueryItem(name: "sourceURL", value: sourceURL.absoluteString)]
        if let session { components.queryItems?.append(.init(name: "packageSessionID", value: session)) }
        if let subpath { components.queryItems?.append(.init(name: "subpath", value: subpath)) }
        var request = URLRequest(url: components.url!)
        request.mainDocumentURL = sourceURL
        request.setValue(sourceURL.absoluteString, forHTTPHeaderField: "X-Ebook-Source-URL")
        if let session { request.setValue(session, forHTTPHeaderField: "X-Ebook-Package-Session") }
        return request
    }

    @MainActor
    private func handler(_ store: ReaderEBookServingSessionStore) -> EbookURLSchemeHandler {
        let handler = EbookURLSchemeHandler()
        handler.packageSessions = store
        // The physical file URL is intentionally unresolvable. Bound resources
        // must be supplied by their owned package rather than this manager.
        handler.readerFileManager = ReaderFileManager()
        return handler
    }

    @MainActor
    func testEntryUsesOwnedSnapshotAfterOriginalRemoval() async throws {
        let package = try await package("Retained original")
        let store = ReaderEBookServingSessionStore(), lease = try store.install(package)
        let handler = handler(store), webView = WKWebView()
        let task = ServingSchemeTask(request(session: lease.id))
        handler.webView(webView, start: task)
        await fulfillment(of: [task.completed], timeout: 10)
        XCTAssertEqual(task.bytes, Data("Retained original".utf8))
        XCTAssertEqual(task.finishCount, 1)
        XCTAssertTrue(task.failures.isEmpty)
    }

    @MainActor
    func testEntriesDescriptorPublishesTheActuallySelectedRendition() async throws {
        let package = try await package("Rendition", selected: "Other/book.opf")
        let store = ReaderEBookServingSessionStore(), lease = try store.install(package)
        let handler = handler(store), webView = WKWebView()
        let task = ServingSchemeTask(request(route: "entries", session: lease.id, subpath: nil))
        handler.webView(webView, start: task)
        await fulfillment(of: [task.completed], timeout: 10)
        let descriptor = try XCTUnwrap(JSONSerialization.jsonObject(with: task.bytes) as? [String: Any])
        XCTAssertEqual(descriptor["packageDocumentPath"] as? String, "Other/book.opf")
        XCTAssertEqual(task.finishCount, 1)
        XCTAssertTrue(task.failures.isEmpty)
    }

    @MainActor
    func testSamePhysicalURLInTwoReadersKeepsDistinctRevisions() async throws {
        let first = try await package("First"), second = try await package("Second")
        let a = ReaderEBookServingSessionStore(), b = ReaderEBookServingSessionStore()
        let leaseA = try a.install(first), leaseB = try b.install(second)
        let handlerA = handler(a), handlerB = handler(b)
        let webA = WKWebView(), webB = WKWebView()
        let taskA = ServingSchemeTask(request(session: leaseA.id))
        let taskB = ServingSchemeTask(request(session: leaseB.id))
        handlerA.webView(webA, start: taskA)
        handlerB.webView(webB, start: taskB)
        await fulfillment(of: [taskA.completed, taskB.completed], timeout: 10)
        XCTAssertEqual(taskA.bytes, Data("First".utf8))
        XCTAssertEqual(taskB.bytes, Data("Second".utf8))
        XCTAssertTrue(taskA.failures.isEmpty && taskB.failures.isEmpty)
    }

    @MainActor
    func testWithdrawalBeforeTerminalPublicationRejectsTheCapturedRequest() async throws {
        let package = try await package("Must not publish")
        let store = ReaderEBookServingSessionStore(), lease = try store.install(package)
        let handler = handler(store), webView = WKWebView()
        let task = ServingSchemeTask(request(session: lease.id))
        handler.webView(webView, start: task)
        // start captures synchronously. Terminal callbacks run on MainActor;
        // revoke before this actor yields, without sleeping for a guessed race.
        store.withdraw(lease)
        await fulfillment(of: [task.completed], timeout: 10)
        XCTAssertEqual(task.failures.count, 1)
        XCTAssertEqual(task.finishCount, 0)
        XCTAssertTrue(task.responses.isEmpty && task.bytes.isEmpty)
    }

    @MainActor
    func testBoundReaderRejectsMissingForeignAndWithdrawnCapabilitiesWithoutFallback() async throws {
        let package = try await package("No fallback")
        let store = ReaderEBookServingSessionStore(), foreign = ReaderEBookServingSessionStore()
        let lease = try store.install(package), other = try foreign.install(package)
        let handler = handler(store), webView = WKWebView()
        store.withdraw(lease)
        for id in [nil, other.id, lease.id] as [String?] {
            let task = ServingSchemeTask(request(session: id))
            handler.webView(webView, start: task)
            XCTAssertEqual(task.failures.count, 1)
            XCTAssertEqual(task.finishCount, 0)
            XCTAssertTrue(task.responses.isEmpty && task.bytes.isEmpty)
        }
    }

    @MainActor
    func testConflictingSourceHeaderCannotOverrideTheRequestOwner() async throws {
        let package = try await package("No retarget")
        let store = ReaderEBookServingSessionStore(), lease = try store.install(package)
        let handler = handler(store), webView = WKWebView()
        var source = request(session: lease.id)
        source.setValue("ebook://ebook/load/local/Books/other.epub", forHTTPHeaderField: "X-Ebook-Source-URL")
        let task = ServingSchemeTask(source)
        handler.webView(webView, start: task)
        XCTAssertEqual(task.failures.count, 1)
        XCTAssertTrue(task.responses.isEmpty && task.bytes.isEmpty)
    }
}
