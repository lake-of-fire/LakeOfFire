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
        let snapshot = try await packageSnapshot(entries: [("OPS/chapter.xhtml", Data(text.utf8))])
        return try .init(sourceURL: sourceURL, snapshot: snapshot, packageDocumentPath: selected)
    }

    private func packageSnapshot(
        defaultOPF: String = "<package><spine/></package>",
        alternateOPF: String = "<package><spine/></package>",
        entries: [(String, Data)]
    ) async throws -> ReaderEBookPackageSnapshot {
        let documents = [
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='OPS/book.opf' media-type='application/oebps-package+xml'/><rootfile full-path='Other/book.opf' media-type='application/oebps-package+xml'/></rootfiles></container>"),
            ("OPS/book.opf", defaultOPF),
            ("Other/book.opf", alternateOPF),
        ]
        let files = documents.map { ($0.0, Data($0.1.utf8)) } + entries
        let bytes = EBookZIPPathFixture.archive(files.map {
            .init(name: Data($0.0.utf8), bytes: $0.1)
        })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await ReaderEBookPackageSnapshot.capture(at: url)
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

    private func assetRequest(_ url: URL, section: URLRequest) -> URLRequest {
        var request = URLRequest(url: url)
        request.mainDocumentURL = section.url
        return request
    }

    @MainActor
    private func serve(
        _ request: URLRequest, using handler: EbookURLSchemeHandler, in webView: WKWebView
    ) async throws -> (HTTPURLResponse, Data) {
        let task = ServingSchemeTask(request)
        handler.webView(webView, start: task)
        await fulfillment(of: [task.completed], timeout: 10)
        if task.finishCount == 0 && task.failures.isEmpty {
            handler.webView(webView, stop: task)
        }
        XCTAssertEqual(task.finishCount, 1, request.url?.absoluteString ?? "")
        XCTAssertTrue(task.failures.isEmpty, String(describing: task.failures))
        let response = try XCTUnwrap(task.responses.first as? HTTPURLResponse)
        XCTAssertEqual(response.statusCode, 200)
        return (response, task.bytes)
    }

    @MainActor
    func testDirectSectionServesDeclaredExtensionlessStylesheetsAndRelativeImports() async throws {
        let chapter = "OPS/Text/chapter.xhtml"
        let outerReference = "../Styles/outer?rev=7#theme"
        let importReference = "../Nested/%E6%97%A5%E6%9C%AC%252F?rev=4"
        let outerCSS = Data("@import url(\"\(importReference)\");\nbody { color: green; }".utf8)
        let nestedCSS = Data([0xFF, 0xFE]) + Data("p { color: blue; }".utf16.flatMap { codeUnit in
            [UInt8(truncatingIfNeeded: codeUnit), UInt8(codeUnit >> 8)]
        })
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <manifest>
            <item id="chapter" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/>
            <item id="outer" href="Styles/outer" media-type="text/css"/>
            <item id="nested" href="Nested/%E6%97%A5%E6%9C%AC%252F" media-type="text/css"/>
          </manifest>
          <spine><itemref idref="chapter"/></spine>
        </package>
        """
        let markup = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head>
        <link rel="stylesheet" href="\(outerReference)"/>
        </head><body><p>Chapter</p></body></html>
        """
        let snapshot = try await packageSnapshot(defaultOPF: opf, entries: [
            (chapter, Data(markup.utf8)), ("OPS/Styles/outer", outerCSS), ("OPS/Nested/日本%2F", nestedCSS),
        ])
        let package = try ReaderEBookServingPackage(sourceURL: sourceURL, snapshot: snapshot, packageDocumentPath: "OPS/book.opf")
        let store = ReaderEBookServingSessionStore()
        defer { store.close() }
        let lease = try store.install(package)
        let handler = handler(store), webView = WKWebView()
        handler.ebookTextProcessor = { _, _, text, _, _, _, _, _, _ in
            EbookProcessedSectionPayload(documentHTML: Data(text.utf8), segmentSidecar: Data())
        }

        let section = request(route: "processed-section", session: lease.id, subpath: chapter, direct: true)
        let (chapterResponse, chapterBytes) = try await serve(section, using: handler, in: webView)
        XCTAssertEqual(chapterResponse.mimeType, "text/html")
        let document = try SwiftSoup.parse(String(decoding: chapterBytes, as: UTF8.self))
        let baseHref = try XCTUnwrap(document.select("base").first()?.attr("href"))
        let base = try XCTUnwrap(URL(string: baseHref))
        let href = try XCTUnwrap(document.select("link[rel=stylesheet]").first()?.attr("href"))
        XCTAssertEqual(href, outerReference)
        let outerURL = try XCTUnwrap(URL(string: href, relativeTo: base)?.absoluteURL)
        let (outerResponse, outerBytes) = try await serve(assetRequest(outerURL, section: section), using: handler, in: webView)
        XCTAssertEqual(outerResponse.mimeType, "text/css")
        XCTAssertEqual(outerBytes, outerCSS)

        let nestedURL = try XCTUnwrap(URL(string: importReference, relativeTo: outerURL)?.absoluteURL)
        let (nestedResponse, nestedBytes) = try await serve(assetRequest(nestedURL, section: section), using: handler, in: webView)
        XCTAssertEqual(nestedResponse.value(forHTTPHeaderField: "Content-Type"), "text/css; charset=utf-16le")
        XCTAssertEqual(nestedBytes, nestedCSS)

        let raw = request(session: lease.id, subpath: "OPS/Styles/outer")
        let (rawResponse, rawBytes) = try await serve(raw, using: handler, in: webView)
        XCTAssertEqual(rawResponse.mimeType, "application/octet-stream")
        XCTAssertEqual(rawBytes, outerCSS)
    }

    @MainActor
    func testBoundStylesheetMIMEUsesTheSelectedOPFForTheSamePackageURL() async throws {
        func opf(_ mediaType: String) -> String {
            """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <manifest><item id="style" href="../Shared/style" media-type="\(mediaType)"/></manifest>
              <spine/>
            </package>
            """
        }
        let css = Data("body { color: purple; }".utf8)
        let snapshot = try await packageSnapshot(
            defaultOPF: opf("application/octet-stream"), alternateOPF: opf("text/css"), entries: [("Shared/style", css)]
        )
        let store = ReaderEBookServingSessionStore()
        defer { store.close() }
        let handler = handler(store), webView = WKWebView()
        for (opfPath, mimeType) in [("OPS/book.opf", "application/octet-stream"), ("Other/book.opf", "text/css")] {
            let package = try ReaderEBookServingPackage(sourceURL: sourceURL, snapshot: snapshot, packageDocumentPath: opfPath)
            let lease = try store.install(package)
            let section = request(route: "processed-section", session: lease.id, direct: true)
            let base = ebookProcessedSectionBaseURL(
                sourceURL: sourceURL, sectionHref: "OPS/chapter.xhtml", generationID: lease.generationID, packageSessionID: lease.id
            )
            let baseURL = try XCTUnwrap(URL(string: base))
            let url = try XCTUnwrap(URL(string: "../Shared/style", relativeTo: baseURL)?.absoluteURL)
            let (response, bytes) = try await serve(assetRequest(url, section: section), using: handler, in: webView)
            XCTAssertEqual(response.mimeType, mimeType, opfPath)
            XCTAssertEqual(bytes, css, opfPath)
        }
    }

    @MainActor
    func testUntrustedManifestRowsDoNotOverrideNativeFilenameMIME() async throws {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:foreign="urn:foreign" version="3.0">
          <manifest>
            <foreign:item id="foreign" href="foreign" media-type="text/css"/>
            <item id="css" href="conflict" media-type="text/css"/>
            <item id="binary" href="./conflict" media-type="application/octet-stream"/>
            <item id="composed" href="が" media-type="text/css"/>
          </manifest>
          <spine/>
        </package>
        """
        let names = ["foreign", "conflict", "undeclared", "か\u{3099}"]
        let css = Data("body { color: red; }".utf8)
        let snapshot = try await packageSnapshot(defaultOPF: opf, entries: names.map { ("OPS/" + $0, css) })
        let package = try ReaderEBookServingPackage(sourceURL: sourceURL, snapshot: snapshot, packageDocumentPath: "OPS/book.opf")
        let store = ReaderEBookServingSessionStore()
        defer { store.close() }
        let lease = try store.install(package)
        let handler = handler(store), webView = WKWebView()
        let section = request(route: "processed-section", session: lease.id, direct: true)
        let base = ebookProcessedSectionBaseURL(
            sourceURL: sourceURL, sectionHref: "OPS/chapter.xhtml", generationID: lease.generationID, packageSessionID: lease.id
        )
        let baseURL = try XCTUnwrap(URL(string: base))
        for (name, reference) in zip(names, ["foreign", "conflict", "undeclared", "%E3%81%8B%E3%82%99"]) {
            let url = try XCTUnwrap(URL(string: reference, relativeTo: baseURL)?.absoluteURL)
            let (response, bytes) = try await serve(assetRequest(url, section: section), using: handler, in: webView)
            XCTAssertEqual(response.mimeType, "application/octet-stream", name)
            XCTAssertEqual(bytes, css, name)
        }
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
        <img id="path-space" src="//cdn.example/cover art.png?sig=a%2Bb&amp;label=cover art#part one" />
        <img id="authority-space" src="//cdn .example/cover.png" />
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
        <image id="svg-image" href="//cdn.example/vector%2Fone%5Ctwo.svg?sig=a%2Bb&amp;v=1#part" xlink:href="//cdn.example/ignored.svg" />
        <image id="svg-legacy" xlink:href="//cdn.example/legacy.svg?sig=x%2Fy#part" />
        <image id="svg-empty" href="" xlink:href="//cdn.example/ignored.svg" />
        <image id="svg-local" href="../images/vector%20art.svg?edition=2#part" />
        <image id="svg-fragment" xlink:href="#local-image" />
        <image id="svg-wrong-namespace" xmlns="urn:foreign" href="//cdn.example/foreign.svg" />
        <use id="svg-use" href="//cdn.example/symbol.svg#symbol" />
        <filter><feImage id="svg-filter" href="//cdn.example/filter.svg" /></filter>
        <foreignObject><svg><image id="svg-foreign-object" href="//cdn.example/object.svg" /></svg></foreignObject>
        </svg>
        <svg><image id="svg-implicit" href="//cdn.example/implicit.svg" /></svg>
        </body></html>
        """#
        let signedURL = "https://ebook/art%2Fone%5Ctwo.png?sig=a%2Bb&v=1#part"
        let signedSVGURL = "https://cdn.example/vector%2Fone%5Ctwo.svg?sig=a%2Bb&v=1#part"
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
                    XCTAssertEqual(try transformed.getElementById("svg-image")?.attr("href"), signedSVGURL)
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
                ("path-space", "src", "https://cdn.example/cover art.png?sig=a%2Bb&label=cover art#part one"),
                ("authority-space", "src", "//cdn .example/cover.png"),
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
                ("svg-image", "href", signedSVGURL),
                ("svg-image", "xlink:href", "//cdn.example/ignored.svg"),
                ("svg-legacy", "xlink:href", "https://cdn.example/legacy.svg?sig=x%2Fy#part"),
                ("svg-empty", "href", ""),
                ("svg-empty", "xlink:href", "//cdn.example/ignored.svg"),
                ("svg-local", "href", "../images/vector%20art.svg?edition=2#part"),
                ("svg-fragment", "xlink:href", "#local-image"),
                ("svg-wrong-namespace", "href", "//cdn.example/foreign.svg"),
                ("svg-use", "href", "//cdn.example/symbol.svg#symbol"),
                ("svg-filter", "href", "//cdn.example/filter.svg"),
                ("svg-foreign-object", "href", "//cdn.example/object.svg"),
                ("svg-implicit", "href", "https://cdn.example/implicit.svg"),
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
