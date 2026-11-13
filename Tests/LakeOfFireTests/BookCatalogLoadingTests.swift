import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LakeOfFireReader

@MainActor
final class BookCatalogLoadingTests: XCTestCase {
    private func load(_ path: String, limit: Int = 16) async throws -> [Publication] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BookCatalogProtocol.self]
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await BookCatalogLoading.publications(
            from: URL(string: "https://book-catalog.example/\(path)")!,
            session: session, maximumDocuments: limit
        )
    }

    func testFeedMappingPreservesMetadataAndFinalRelativeURLs() async throws {
        let result = try await load("redirected")
        let book = try XCTUnwrap(result.first)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(book.title, "A Book")
        XCTAssertEqual(book.author, "Author One, Author Two")
        XCTAssertEqual(book.publicationDate?.timeIntervalSince1970, 1_577_923_200)
        XCTAssertEqual(book.summary, "Summary")
        XCTAssertEqual(book.coverURL?.absoluteString, "https://cdn.example/catalog/cover.png")
        XCTAssertEqual(book.downloadURL?.absoluteString, "https://cdn.example/catalog/book.epub")
        XCTAssertFalse(book.hasContentAudio)
    }

    func testStandalonePublicationIsDisplayed() async throws {
        let result = try await load("standalone")
        XCTAssertEqual(result.map(\.title), ["A Book"])
    }

    func testFollowsAllBooksAndPreservesDocumentDirectory() async throws {
        let result = try await load("navigation/start")
        XCTAssertEqual(result.first?.downloadURL?.absoluteString, "https://book-catalog.example/navigation/book.epub")
    }

    func testStopsASelfCycleIgnoringFragmentOnlyDifferences() async {
        do { _ = try await load("cycle"); XCTFail("Cycle was accepted") }
        catch BookCatalogLoadingError.navigationCycle {}
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testStopsATwoDocumentCycle() async {
        do { _ = try await load("cycle-a"); XCTFail("Cycle was accepted") }
        catch BookCatalogLoadingError.navigationCycle {}
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRecordsRedirectedDocumentIdentity() async {
        do { _ = try await load("redirect-cycle"); XCTFail("Cycle was accepted") }
        catch BookCatalogLoadingError.navigationCycle {}
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testDistinctUnboundedLinksStopAtTheDocumentBudget() async {
        do { _ = try await load("chain-0", limit: 3); XCTFail("Unbounded chain was accepted") }
        catch BookCatalogLoadingError.navigationLimit {}
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testLastPermittedDocumentMayContainPublications() async throws {
        let result = try await load("navigation/start", limit: 2)
        XCTAssertEqual(result.map(\.title), ["A Book"])
    }

    func testZeroAndNegativeBudgetsAreRejected() async {
        for limit in [0, -1, Int.min] {
            do { _ = try await load("standalone", limit: limit); XCTFail("Invalid budget accepted") }
            catch BookCatalogLoadingError.navigationLimit {}
            catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testUnrelatedNavigationIsNotCrawled() async {
        do { _ = try await load("unrelated"); XCTFail("Unrelated navigation was crawled") }
        catch BookCatalogLoadingError.noPublications {}
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testEmptyCatalogIsExplicitFailure() async {
        do { _ = try await load("empty"); XCTFail("Empty catalog accepted") }
        catch BookCatalogLoadingError.noPublications {}
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testOpenAccessIsUsedWithoutSelectingBuyOrSampleLinks() async throws {
        let result = try await load("open-access")
        XCTAssertEqual(result.first?.downloadURL?.lastPathComponent, "full.epub")
    }

    func testBuyAndSampleAloneDoNotBecomeFullDownloads() async throws {
        let result = try await load("buy-only")
        XCTAssertNil(result.first?.downloadURL)
    }

    func testOriginalAcquisitionAndCoverPriorityRemain() async throws {
        let result = try await load("priority")
        XCTAssertEqual(result.first?.downloadURL?.lastPathComponent, "original.epub")
        XCTAssertEqual(result.first?.coverURL?.lastPathComponent, "cover.png")
    }

    func testHTTPErrorDoesNotPublishValidLookingBooks() async {
        do { _ = try await load("http-error"); XCTFail("HTTP error was accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("503")) }
    }

    func testPrecancelledCallerCannotReturnBooks() async {
        let task = Task { @MainActor in try await self.load("standalone") }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled task succeeded") }
        catch is CancellationError {}
        catch { XCTFail("Unexpected error: \(error)") }
    }
}

private final class BookCatalogProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "book-catalog.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let path = url.lastPathComponent
        var finalURL = url
        var body: String
        func navigation(_ href: String, title: String = "All Books") -> String {
            "{\"metadata\":{\"title\":\"Catalog\"},\"navigation\":[{\"href\":\"\(href)\",\"title\":\"\(title)\"}]}"
        }
        let publication = #"{"metadata":{"title":"A Book","author":["Author One","Author Two"],"published":"2020-01-02","description":"Summary","subtitle":"Subtitle"},"links":[{"href":"book.epub","rel":"http://opds-spec.org/acquisition"}],"images":[{"href":"cover.png","rel":"cover"}]}"#
        switch path {
        case "cycle": body = navigation("cycle#different-fragment")
        case "cycle-a": body = navigation("cycle-b")
        case "cycle-b": body = navigation("cycle-a")
        case "redirect-cycle":
            finalURL = URL(string: "https://book-catalog.example/landing")!
            body = navigation("landing#fragment")
        case "start": body = navigation("leaf")
        case "unrelated": body = navigation("leaf", title: "Featured")
        case "empty": body = #"{"metadata":{"title":"Empty"},"publications":[]}"#
        case "standalone": body = publication
        case "open-access", "buy-only", "priority":
            var links = #"{"href":"purchase","rel":"http://opds-spec.org/acquisition/buy"},{"href":"sample.epub","rel":"http://opds-spec.org/acquisition/sample"}"#
            if path != "buy-only" { links += #",{"href":"full.epub","rel":"http://opds-spec.org/acquisition/open-access"}"# }
            if path == "priority" { links += #",{"href":"original.epub","rel":"http://opds-spec.org/acquisition"}"# }
            body = "{\"metadata\":{\"title\":\"Catalog\"},\"publications\":[{\"metadata\":{\"title\":\"Links\"},\"links\":[\(links)],\"images\":[{\"href\":\"thumbnail.png\",\"rel\":\"http://opds-spec.org/image/thumbnail\"},{\"href\":\"cover.png\",\"rel\":\"cover\"}]}]}"
        default:
            if path.hasPrefix("chain-"), let step = Int(path.dropFirst(6)) {
                body = navigation("chain-\(step + 1)")
            } else {
                body = "{\"metadata\":{\"title\":\"Catalog\"},\"publications\":[\(publication)]}"
            }
        }
        if path == "redirected" { finalURL = URL(string: "https://cdn.example/catalog/feed.json")! }
        let response = HTTPURLResponse(url: finalURL, statusCode: path == "http-error" ? 503 : 200,
            httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
