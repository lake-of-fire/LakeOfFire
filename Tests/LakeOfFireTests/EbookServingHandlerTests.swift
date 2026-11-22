import Foundation
import SwiftSoup
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

    private func request(
        route: String = "entry", session: String?, subpath: String? = "OPS/chapter.xhtml", direct: Bool = false
    ) -> URLRequest {
        var components = URLComponents(string: "ebook://ebook/" + route)!
        components.queryItems = [URLQueryItem(name: "sourceURL", value: sourceURL.absoluteString)]
        if let session { components.queryItems?.append(.init(name: "packageSessionID", value: session)) }
        if let subpath { components.queryItems?.append(.init(name: "subpath", value: subpath)) }
        if direct { components.queryItems?.append(.init(name: "direct", value: "1")) }
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
    func testProcessedSectionCarriesItsOriginalSnapshotThroughCacheAndProcessor() async throws {
        let package = try await package("Original processing input")
        let store = ReaderEBookServingSessionStore(), lease = try store.install(package)
        let handler = handler(store), webView = WKWebView()
        let cacheRead = expectation(description: "cache reader retains bound source")
        let processed = expectation(description: "processor retains bound source")
        handler.ebookProcessedTextCacheReader = { _, _, _ in
            let source = try XCTUnwrap(EbookPackageProcessingContext.source)
            XCTAssertTrue(source.lease === lease)
            try await source.validate()
            cacheRead.fulfill()
            return nil
        }
        handler.ebookTextProcessor = { _, _, text, _, _, _, _, _, _ in
            let source = try XCTUnwrap(EbookPackageProcessingContext.source)
            XCTAssertTrue(source.lease === lease)
            XCTAssertEqual(text, "Original processing input")
            try await source.validate()
            processed.fulfill()
            return EbookProcessedSectionPayload(
                documentHTML: Data("<html><body>processed</body></html>".utf8),
                segmentSidecar: Data()
            )
        }
        let task = ServingSchemeTask(request(route: "processed-section", session: lease.id))
        handler.webView(webView, start: task)
        await fulfillment(of: [cacheRead, processed, task.completed], timeout: 10)
        XCTAssertEqual(task.finishCount, 1)
        XCTAssertTrue(task.failures.isEmpty)
        withExtendedLifetime((handler, store, webView)) {}
    }

    @MainActor
    func testDirectSectionServesPassiveNetworkResourcesWithoutChangingArchiveReferences() async throws {
        let markup = #"""
        <html xmlns="http://www.w3.org/1999/xhtml"><head>
        <base id="publisher-base" href="//publisher.example/" />
        <link id="publisher-style" rel="stylesheet" href="//cdn.example/book.css" />
        </head><body>
        <m-c pid="p"><m-s sid="s" o="true"><m-m id="m">本文</m-m></m-s></m-c>
        <img id="signed" src="//ebook/art%2Fone%5Ctwo.png?sig=a%2Bb&amp;v=1#part" />
        <img id="local" src="../images/cover%20art.png?edition=2#part" />
        <img id="absolute" src="https://cdn.example/cover.png?sig=x%2Fy" />
        <img id="inline" src="data:image/png;base64,AA==" />
        <img id="blob" src="blob:https://cdn.example/owned-image" />
        <img id="fragment" src="#local-image" />
        <img id="invalid" src="///missing-authority.png" />
        <img id="backslash" src="//cdn.example\ambiguous.png" />
        <video id="video" src="//cdn.example/clip.mp4#t=3" poster="//cdn.example/poster.jpg">
        <source id="media-source" src="//cdn.example/alt.mp4?sig=x%2By" />
        <track id="captions" src="//cdn.example/captions.vtt?sig=x%2By" />
        </video>
        <audio id="audio" src="//cdn.example/sound.mp3"></audio>
        <picture><source id="responsive" srcset="data:image/png;base64,a,b 1x, //cdn.example/a?sig=one,two&amp;v=2 2x, //cdn.example/b#part, local.png 3x" />
        <img id="no-whitespace" srcset="//cdn.example/a,//cdn.example/b 1x, //cdn.example/c 2x" />
        </picture>
        <img id="descriptor" srcset="//cdn.example/a shape(1,//ignored), //cdn.example/b 2x" />
        <img id="style" style="background:url(//cdn.example/style.png)" />
        <a id="anchor" href="//cdn.example/page?token=a%2Bb">link</a>
        <script id="script" src="//cdn.example/script.js"></script>
        <iframe id="iframe" src="//cdn.example/frame"></iframe>
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
        <image id="svg-image" href="//cdn.example/vector.svg" xlink:href="#legacy" />
        </svg>
        </body></html>
        """#
        let signedURL = "https://ebook/art%2Fone%5Ctwo.png?sig=a%2Bb&v=1#part"
        let sidecar = Data(#"{"v":\#(ReaderCompactSegmentSidecarSchema.currentVersion),"t":{"j":[],"n":[],"s":[],"ns":[],"p":[],"h":["h"],"x":["本文"],"sid":["s"],"pid":["p"]},"s":[["!m",0,null,null,null,null,null,null,0,0,0]]}"#.utf8)

        for useCallback in [true, false] {
            let content = useCallback ? markup : "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + markup
            let package = try await package(content)
            let store = ReaderEBookServingSessionStore(), lease = try store.install(package)
            let handler = handler(store), webView = WKWebView()
            handler.ebookTextProcessor = ebookTextProcessor
            if useCallback {
                handler.processReadabilityContent = { text, _, _, _, _, _, transform in
                    let parsed = try SwiftSoup.parse(text)
                    parsed.outputSettings().prettyPrint(pretty: false)
                    let transformed = await transform(parsed)
                    // The mounted provider may serialize here, before Lake's later sentinel work.
                    XCTAssertEqual(try transformed.getElementById("signed")?.attr("src"), signedURL)
                    return transformed
                }
            }
            handler.processHTMLDocument = { document, _, proof in
                proof.complete(documentHTML: Data(try document.outerHtmlUTF8()), segmentSidecar: sidecar)
            }

            let task = ServingSchemeTask(request(route: "processed-section", session: lease.id, direct: true))
            handler.webView(webView, start: task)
            await fulfillment(of: [task.completed], timeout: 10)
            XCTAssertEqual(task.finishCount, 1)
            XCTAssertTrue(task.failures.isEmpty)
            let response = try XCTUnwrap(task.responses.first as? HTTPURLResponse)
            XCTAssertEqual(response.mimeType, "text/html")
            XCTAssertEqual(response.value(forHTTPHeaderField: "X-Manabi-Processing-Authoritative"), "true")
            let document = try SwiftSoup.parse(String(decoding: task.bytes, as: UTF8.self))
            let packageBase = try XCTUnwrap(document.select("base").first()?.attr("href"))
            XCTAssertEqual(URL(string: packageBase)?.scheme, "ebook")
            XCTAssertEqual(URL(string: packageBase)?.host, "ebook")
            let expected = [
                ("signed", "src", signedURL),
                ("video", "src", "https://cdn.example/clip.mp4#t=3"),
                ("video", "poster", "https://cdn.example/poster.jpg"),
                ("audio", "src", "https://cdn.example/sound.mp3"),
                ("media-source", "src", "https://cdn.example/alt.mp4?sig=x%2By"),
                ("captions", "src", "https://cdn.example/captions.vtt?sig=x%2By"),
                ("responsive", "srcset", "data:image/png;base64,a,b 1x, https://cdn.example/a?sig=one,two&v=2 2x, https://cdn.example/b#part, local.png 3x"),
                ("no-whitespace", "srcset", "https://cdn.example/a,//cdn.example/b 1x, https://cdn.example/c 2x"),
                ("descriptor", "srcset", "https://cdn.example/a shape(1,//ignored), https://cdn.example/b 2x"),
                ("local", "src", "../images/cover%20art.png?edition=2#part"),
                ("absolute", "src", "https://cdn.example/cover.png?sig=x%2Fy"),
                ("inline", "src", "data:image/png;base64,AA=="),
                ("blob", "src", "blob:https://cdn.example/owned-image"),
                ("fragment", "src", "#local-image"),
                ("invalid", "src", "///missing-authority.png"),
                ("backslash", "src", #"//cdn.example\ambiguous.png"#),
                ("publisher-base", "href", "//publisher.example/"),
                ("publisher-style", "href", "//cdn.example/book.css"),
                ("style", "style", "background:url(//cdn.example/style.png)"),
                ("anchor", "href", "//cdn.example/page?token=a%2Bb"),
                ("script", "src", "//cdn.example/script.js"),
                ("iframe", "src", "//cdn.example/frame"),
                ("svg-image", "href", "//cdn.example/vector.svg"),
                ("svg-image", "xlink:href", "#legacy"),
            ]
            for (id, attribute, value) in expected {
                let element = try XCTUnwrap(document.getElementById(id), id)
                XCTAssertEqual(try element.attr(attribute), value, "\(id).\(attribute)")
            }
            withExtendedLifetime((handler, store, webView)) {}
        }
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
        // Production WebKit retains its registered handler. This direct-call
        // fixture must retain it until the detached serving work settles too.
        defer { withExtendedLifetime(handler) {} }
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
