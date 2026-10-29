import XCTest
@preconcurrency import WebKit
import SwiftCloudDrive
import ZIPFoundation
import SwiftSoup
@testable import SwiftUIWebView
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
@testable import LakeOfFireContent
@testable import LakeOfFireFiles
@testable import LakeOfFireReader

private final class TestURLSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var responses = [URLResponse]()
    private(set) var data = [Data]()
    private(set) var finishCount = 0
    private(set) var failures = [any Swift.Error]()
    var onTerminal: (() -> Void)?

    init(request: URLRequest) {
        self.request = request
    }

    func didReceive(_ response: URLResponse) {
        responses.append(response)
    }

    func didReceive(_ data: Data) {
        self.data.append(data)
    }

    func didFinish() {
        finishCount += 1
        onTerminal?()
    }

    func didFailWithError(_ error: any Swift.Error) {
        failures.append(error)
        onTerminal?()
    }
}

private final class LockedCancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class ReaderAssetCookiePathCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URL: URLRequest] = [:]

    func takeRequest(for url: URL) -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests.removeValue(forKey: url)
    }

    func record(_ request: URLRequest) {
        guard let url = request.url else { return }
        lock.lock()
        defer { lock.unlock() }
        requests[url] = request
    }
}

private final class ReaderAssetCookiePathProtocol: URLProtocol {
    static let capture = ReaderAssetCookiePathCapture()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "cookie-path.example"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.capture.record(request)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/gif"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func requestWithoutURL() -> URLRequest {
    var request = URLRequest(url: URL(string: "about:blank")!)
    request.url = nil
    return request
}

@MainActor
private final class ReaderReadinessReplayProbe: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let loaded: XCTestExpectation
    var onState: (([String: Any]) -> Void)?

    init(loaded: XCTestExpectation) { self.loaded = loaded }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded.fulfill()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let state = message.body as? [String: Any] { onState?(state) }
    }
}

@MainActor
private func hostDarkReaderWebView(_ webView: WKWebView) -> () -> Void {
#if os(iOS)
    let controller = UIViewController()
    controller.view = webView
    let window = UIWindow(frame: webView.frame)
    window.overrideUserInterfaceStyle = .dark
    window.rootViewController = controller
    window.isHidden = false
    return {
        window.isHidden = true
        window.rootViewController = nil
    }
#elseif os(macOS)
    let window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = webView
    window.orderFront(nil)
    return { window.close() }
#endif
}

final class URLSchemeTaskCompletionOwnershipTests: XCTestCase {
    func testNativeAssetCookiesMatchEncodedRequestPaths() async throws {
        let owner = ReaderDocumentPresentation(
            sourceURL: URL(string: "https://cookie-path.example/article")!, generation: UUID())
        defer { owner.release() }
        let service = ReaderAssetService(protocolClasses: [ReaderAssetCookiePathProtocol.self])
        let encodedCookie = try XCTUnwrap(HTTPCookie(properties: [.name: "encoded", .value: "allowed",
            .domain: "cookie-path.example", .path: "/signed%20assets/"]))
        let decodedCookie = try XCTUnwrap(HTTPCookie(properties: [.name: "decoded", .value: "wrong-scope",
            .domain: "cookie-path.example", .path: "/signed assets/"]))
        let url = URL(string: "https://cookie-path.example/signed%20assets/pixel.gif?request=\(UUID())")!
        let id = try owner.register(.image(url))
        let entry = try XCTUnwrap(ReaderDocumentResourceRegistry.shared.entry(for: id))
        _ = try await service.load(entry: entry, cookies: [encodedCookie, decodedCookie])
        let request = try XCTUnwrap(ReaderAssetCookiePathProtocol.capture.takeRequest(for: url))
        let cookies = request.value(forHTTPHeaderField: "Cookie") ?? ""
        XCTAssertTrue(cookies.contains("encoded=allowed"), cookies)
        XCTAssertFalse(cookies.contains("decoded="), cookies)
    }

    func testExternalSVGUseRetainsPlacementAndCompositingDuringPreparation() throws {
        let document = try SwiftSoup.parse("""
        <main id="reader-content"><svg viewBox="0 0 300 200">
        <defs><clipPath id="chart-clip"><rect width="80" height="40"/></clipPath></defs>
        <use id="chart" href="https://publisher.example/symbols.svg#plot"
            x="10" y="20" width="80" height="40" transform="translate(100 50) scale(2)"
            style="opacity:0.4;clip-path:url(#chart-clip)" mask="url(https://external.example/mask.svg#m)"
            aria-label="Chart"/>
        </svg></main>
        """)
        let owner = try prepareReaderOwnedDocument(document,
            sourceURL: URL(string: "https://publisher.example/article")!, generation: UUID())
        defer { owner.release() }
        let image = try XCTUnwrap(document.select("svg > image#chart").first())
        XCTAssertEqual(try image.attr("transform"), "translate(100 50) scale(2)")
        XCTAssertEqual(try image.attr("opacity"), "0.4")
        XCTAssertEqual(try image.attr("clip-path"), "url(#chart-clip)")
        XCTAssertFalse(image.hasAttr("mask"), "External effect resources must stay removed")
        XCTAssertEqual(try image.attr("x"), "10")
        XCTAssertEqual(try image.attr("y"), "20")
        XCTAssertEqual(try image.attr("aria-label"), "Chart")
        let url = try XCTUnwrap(URL(string: image.attr("href")))
        let registration = try XCTUnwrap(readerRegistrationID(in: url, prefix: "reader-asset"))
        XCTAssertEqual(ReaderDocumentResourceRegistry.shared.entry(for: registration)?.resource.remoteURL?.absoluteString,
            "https://publisher.example/symbols.svg#plot")
    }

    @MainActor
    func testArticleNavigationFinishReplaysInitialReadiness() async throws {
        let loaded = expectation(description: "article loaded before native readiness admission")
        let probe = ReaderReadinessReplayProbe(loaded: loaded)
        let controller = WKUserContentController()
        controller.add(probe, name: "readerDocState")
        var script = ReaderDocStateUserScript().userScript
        controller.addUserScript(script.webKitUserScript)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = controller
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 430, height: 932), configuration: configuration)
        webView.navigationDelegate = probe
        let caller = WebViewScriptCaller()
        let bindingOwner = UUID()
        let pageWorld = WKContentWorld.page
        caller.installBinding(
            ownedBy: bindingOwner,
            asyncCaller: { js, arguments, frame, world in
                let result = try await webView.callAsyncJavaScript(
                    js, arguments: arguments ?? [:], in: frame, contentWorld: world ?? pageWorld
                )
                return .init(result)
            },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { nil }
        )
        defer {
            _ = caller.clearBinding(ownedBy: bindingOwner)
            webView.stopLoading()
            webView.navigationDelegate = nil
            controller.removeScriptMessageHandler(forName: "readerDocState")
        }
        let url = URL(string: "https://example.com/restored-news")!
        let generation = UUID().uuidString
        // The probe deliberately ignores initial messages, modelling a native
        // handler which could not admit readiness during the first commit.
        webView.loadHTMLString("""
        <!doctype html><html data-mnb-reader-render-ready="1" data-mnb-reader-render-generation="\(generation)">
        <body><article id="reader-content">記事です。</article></body></html>
        """, baseURL: url)
        await fulfillment(of: [loaded], timeout: 10)
        let replayed = expectation(description: "semantic navigation finish replays readiness")
        probe.onState = { state in
            guard state["reason"] as? String == "navigation-finished" else { return }
            XCTAssertEqual(state["hasReaderRenderReady"] as? Bool, true)
            XCTAssertEqual(state["readerRenderGeneration"] as? String, generation)
            replayed.fulfill()
        }
        var state = WebViewState.empty
        state.pageURL = url
        let viewModel = ReaderModeViewModel()
        await viewModel.onNavigationFinished(newState: state, scriptCaller: caller)
        await fulfillment(of: [replayed], timeout: 5)

        // A later native commit/finish can inject fonts after the script has
        // already stopped observing its initial readiness. Its replay must
        // rearm the root font flag rather than leave the article pending.
        _ = try await webView.evaluateJavaScript("document.documentElement.dataset.mnbFontPending = '1'")
        let pending = expectation(description: "native finish respects the active font gate")
        probe.onState = { state in
            guard state["reason"] as? String == "navigation-finished" else { return }
            XCTAssertEqual(state["hasReaderRenderReady"] as? Bool, false)
            pending.fulfill()
        }
        await viewModel.onNavigationFinished(newState: state, scriptCaller: caller)
        await fulfillment(of: [pending], timeout: 5)
        let completed = expectation(description: "font completion recovers the cold-launch readiness signal")
        probe.onState = { state in
            guard state["reason"] as? String == "mutation" else { return }
            XCTAssertEqual(state["hasReaderRenderReady"] as? Bool, true)
            XCTAssertEqual(state["readerRenderGeneration"] as? String, generation)
            completed.fulfill()
        }
        _ = try await webView.evaluateJavaScript("delete document.documentElement.dataset.mnbFontPending")
        await fulfillment(of: [completed], timeout: 5)
        withExtendedLifetime(probe) {}
    }

    @MainActor
    func testInternalReaderLoaderHasAThemedEmptyDocument() throws {
        let handler = InternalURLSchemeHandler()
        let task = TestURLSchemeTask(request: URLRequest(
            url: URL(string: "internal://local/load/reader?url=https%3A%2F%2Fexample.com%2Fnews")!
        ))
        let webView = WKWebView()
        handler.webView(webView, start: task)

        XCTAssertEqual(task.finishCount, 1)
        XCTAssertTrue(task.failures.isEmpty)
        let bytes = task.data.reduce(into: Data()) { $0.append($1) }
        let response = try XCTUnwrap(task.responses.first)
        XCTAssertEqual(response.expectedContentLength, Int64(bytes.count))
        let document = try SwiftSoup.parse(String(decoding: bytes, as: UTF8.self))
        XCTAssertEqual(try document.select("meta[name=color-scheme]").attr("content"), "light dark")
        XCTAssertEqual(try document.body()?.text(), "")
        XCTAssertFalse(try document.select("head style").isEmpty())
        XCTAssertTrue(try document.select("[data-mnb-reader-render-ready]").isEmpty(),
                      "The themed loader must not claim that the article is ready")
    }

    @MainActor
    func testRestoredReaderDocumentReplaysReadinessWithoutBypassingFontGate() async throws {
        let loaded = expectation(description: "reader document loaded")
        let firstPageShow = expectation(description: "initial ready document shown")
        let probe = ReaderReadinessReplayProbe(loaded: loaded)
        probe.onState = { state in
            guard state["reason"] as? String == "pageshow" else { return }
            XCTAssertEqual(state["hasReaderRenderReady"] as? Bool, true)
            firstPageShow.fulfill()
        }
        let controller = WKUserContentController()
        controller.add(probe, name: "readerDocState")
        var script = ReaderDocStateUserScript().userScript
        controller.addUserScript(script.webKitUserScript)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = controller
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 430, height: 932), configuration: configuration)
        webView.navigationDelegate = probe
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            controller.removeScriptMessageHandler(forName: "readerDocState")
        }
        let generation = UUID().uuidString
        webView.loadHTMLString("""
        <!doctype html><html data-mnb-reader-render-ready="1" data-mnb-reader-render-generation="\(generation)">
        <body><article id="reader-content">記事です。</article></body></html>
        """, baseURL: URL(string: "https://example.com/news")!)
        await fulfillment(of: [loaded, firstPageShow], timeout: 10)

        let pending = expectation(description: "restored document still respects pending font")
        probe.onState = { state in
            guard state["reason"] as? String == "pageshow" else { return }
            XCTAssertEqual(state["hasReaderRenderReady"] as? Bool, false)
            pending.fulfill()
        }
        _ = try await webView.evaluateJavaScript("""
        document.documentElement.dataset.mnbFontPending = '1';
        window.dispatchEvent(new Event('pageshow'));
        """)
        await fulfillment(of: [pending], timeout: 5)

        let restored = expectation(description: "font completion announces readiness without another lifecycle event")
        probe.onState = { state in
            guard state["reason"] as? String == "mutation" else { return }
            XCTAssertEqual(state["hasReaderRenderReady"] as? Bool, true)
            XCTAssertEqual(state["readerRenderGeneration"] as? String, generation)
            restored.fulfill()
        }
        _ = try await webView.evaluateJavaScript("delete document.documentElement.dataset.mnbFontPending")
        await fulfillment(of: [restored], timeout: 5)

        let replayed = expectation(description: "ready document replays on a later page show")
        probe.onState = { state in
            guard state["reason"] as? String == "pageshow" else { return }
            XCTAssertEqual(state["hasReaderRenderReady"] as? Bool, true)
            XCTAssertEqual(state["readerRenderGeneration"] as? String, generation)
            replayed.fulfill()
        }
        _ = try await webView.evaluateJavaScript("window.dispatchEvent(new Event('pageshow'))")
        await fulfillment(of: [replayed], timeout: 5)
        withExtendedLifetime(probe) {}
    }

    @MainActor
    func testInternalReaderLoaderPaintsDarkCanvasBeforeArticleProcessing() async throws {
        let loaded = expectation(description: "themed loader loaded")
        let probe = ReaderReadinessReplayProbe(loaded: loaded)
        let handler = InternalURLSchemeHandler()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: "internal")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 430, height: 932), configuration: configuration)
        let closeHost = hostDarkReaderWebView(webView)
        defer { closeHost() }
        webView.navigationDelegate = probe
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
        }
        webView.load(URLRequest(url: URL(string: "internal://local/load/reader?url=https%3A%2F%2Fexample.com%2Fnews")!))
        await fulfillment(of: [loaded], timeout: 10)
        let darkAppearance = try await webView.evaluateJavaScript("matchMedia('(prefers-color-scheme: dark)').matches")
        XCTAssertEqual(darkAppearance as? Bool, true)
        let background = try await webView.evaluateJavaScript("getComputedStyle(document.documentElement).backgroundColor")
        let expected = UserDefaults.standard.string(forKey: "darkModeTheme") == "gray"
            ? "rgb(49, 50, 52)" : "rgb(0, 0, 0)"
        XCTAssertEqual(background as? String, expected)
        withExtendedLifetime(probe) {}
    }

    @MainActor
    func testReaderArticlePaintsDarkCanvasWhileFontsHideBody() async throws {
        let document = try SwiftSoup.parse("""
        <!doctype html><html><head></head><body class="readability-mode">
        <article id="reader-content">記事です。</article></body></html>
        """)
        try processForReaderMode(
            doc: document,
            url: URL(string: "https://example.com/news")!,
            contentSectionLocationIdentifier: nil,
            isEBook: false,
            isCacheWarmer: false,
            defaultTitle: nil,
            imageURL: nil,
            injectEntryImageIntoHeader: false,
            defaultFontSize: 21
        )
        XCTAssertEqual(try document.body()?.attr("data-mnb-dark-theme"),
                       UserDefaults.standard.string(forKey: "darkModeTheme") ?? "black")
        XCTAssertEqual(try document.body()?.attr("data-mnb-light-theme"),
                       UserDefaults.standard.string(forKey: "lightModeTheme") ?? "white")
        try upsertDeferredSharedReaderFontGate(in: document)
        let loaded = expectation(description: "article loaded behind its font gate")
        let probe = ReaderReadinessReplayProbe(loaded: loaded)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 430, height: 932), configuration: configuration)
        let closeHost = hostDarkReaderWebView(webView)
        defer { closeHost() }
        webView.navigationDelegate = probe
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
        }
        webView.loadHTMLString(try document.outerHtml(), baseURL: URL(string: "https://example.com/news")!)
        await fulfillment(of: [loaded], timeout: 10)
        let visibility = try await webView.evaluateJavaScript("getComputedStyle(document.body).visibility")
        XCTAssertEqual(visibility as? String, "hidden")
        let background = try await webView.evaluateJavaScript("getComputedStyle(document.documentElement).backgroundColor")
        let expected = UserDefaults.standard.string(forKey: "darkModeTheme") == "gray"
            ? "rgb(49, 50, 52)" : "rgb(0, 0, 0)"
        XCTAssertEqual(background as? String, expected)
        _ = try await webView.evaluateJavaScript("""
        document.body.dataset.mnbColorScheme = 'dark';
        document.body.dataset.mnbDarkTheme = 'gray';
        """)
        let changedBackground = try await webView.evaluateJavaScript("getComputedStyle(document.documentElement).backgroundColor")
        XCTAssertEqual(changedBackground as? String, "rgb(49, 50, 52)",
                       "The canvas must follow native theme changes after its initial paint")
        withExtendedLifetime(probe) {}
    }

    func testCancellationRejectsLaterCompletion() {
        let ownership = URLSchemeTaskCompletionOwnership()
        let task = NSObject()

        ownership.begin(task)

        XCTAssertTrue(ownership.cancel(task))
        XCTAssertFalse(ownership.claimCompletion(task))
    }

    func testOnlyOneTerminalClaimSucceeds() {
        let ownership = URLSchemeTaskCompletionOwnership()
        let task = NSObject()

        ownership.begin(task)

        XCTAssertTrue(ownership.claimCompletion(task))
        XCTAssertFalse(ownership.claimCompletion(task))
        XCTAssertFalse(ownership.cancel(task))
    }

    func testEqualHashObjectsRetainIndependentOwnership() {
        final class CollidingTask: NSObject {
            override var hash: Int { 1 }
        }

        let ownership = URLSchemeTaskCompletionOwnership()
        let first = CollidingTask()
        let second = CollidingTask()
        XCTAssertEqual(first.hash, second.hash)

        ownership.begin(first)
        ownership.begin(second)

        XCTAssertTrue(ownership.cancel(first))
        XCTAssertFalse(ownership.claimCompletion(first))
        XCTAssertTrue(ownership.claimCompletion(second))
    }

    func testCancellationInvokesAttachedWorkCancellationExactlyOnce() {
        let ownership = URLSchemeTaskCompletionOwnership()
        let task = NSObject()
        let cancellationCount = LockedCancellationCounter()

        ownership.begin(task)
        XCTAssertTrue(ownership.attachCancellation(task) {
            cancellationCount.increment()
        })

        XCTAssertTrue(ownership.cancel(task))
        XCTAssertEqual(cancellationCount.value, 1)
        XCTAssertFalse(ownership.cancel(task))
        XCTAssertEqual(cancellationCount.value, 1)
    }

    func testLateWorkAttachmentCancelsImmediatelyAfterTaskStops() {
        let ownership = URLSchemeTaskCompletionOwnership()
        let task = NSObject()
        let cancellationCount = LockedCancellationCounter()

        ownership.begin(task)
        XCTAssertTrue(ownership.cancel(task))
        XCTAssertFalse(ownership.attachCancellation(task) {
            cancellationCount.increment()
        })
        XCTAssertEqual(cancellationCount.value, 1)
    }

    func testSuccessfulCompletionReleasesWorkWithoutCancellingIt() {
        let ownership = URLSchemeTaskCompletionOwnership()
        let task = NSObject()
        let cancellationCount = LockedCancellationCounter()

        ownership.begin(task)
        XCTAssertTrue(ownership.attachCancellation(task) {
            cancellationCount.increment()
        })

        XCTAssertTrue(ownership.claimCompletion(task))
        XCTAssertEqual(cancellationCount.value, 0)
        XCTAssertFalse(ownership.cancel(task))
        XCTAssertEqual(cancellationCount.value, 0)
    }

    @MainActor
    func testReaderFileHandlerTerminatesMalformedRequest() {
        let handler = ReaderFileURLSchemeHandler()
        let task = TestURLSchemeTask(request: requestWithoutURL())
        let webView = WKWebView()

        handler.webView(webView, start: task)
        handler.webView(webView, stop: task)

        XCTAssertEqual(task.failures.count, 1)
        XCTAssertEqual(task.finishCount, 0)
        XCTAssertTrue(task.responses.isEmpty)
    }

    @MainActor
    func testReaderFileHandlerRespondsWithPackageEntryMIMEAndEncoding() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-package-response-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let drive = try await CloudDrive(storage: .localDirectory(rootURL: root))
        let archiveURL = drive.rootDirectory.appendingPathComponent("book.epub")
        guard let archive = Archive(url: archiveURL, accessMode: .create) else {
            XCTFail("Expected package archive to be created")
            return
        }
        let entries: [(String, Data, String, String?)] = [
            ("cover.jpg", Data([0xFF, 0xD8, 0xFF]), "image/jpeg", nil),
            ("diagram.svg", Data("<svg/>".utf8), "image/svg+xml", "utf-8"),
            ("opaque.unknown-manabi-format", Data([0x01, 0x02]), "application/octet-stream", nil),
        ]
        for (path, data, _, _) in entries {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }

        let manager = ReaderFileManager()
        manager.localDrive = drive
        let handler = ReaderFileURLSchemeHandler()
        await { @ReaderFileURLSchemeActor in
            handler.readerFileManager = manager
        }()
        let webView = WKWebView()

        for (path, data, expectedMIME, expectedEncoding) in entries {
            var components = URLComponents(string: "reader-file://file/load/local/book.epub")!
            components.queryItems = [URLQueryItem(name: "subpath", value: path)]
            let task = TestURLSchemeTask(request: URLRequest(url: try XCTUnwrap(components.url)))
            let terminal = expectation(description: "Package response for \(path)")
            task.onTerminal = { terminal.fulfill() }

            handler.webView(webView, start: task)
            await fulfillment(of: [terminal], timeout: 5)

            XCTAssertTrue(task.failures.isEmpty, path)
            XCTAssertEqual(task.finishCount, 1, path)
            XCTAssertEqual(task.responses.first?.mimeType, expectedMIME, path)
            XCTAssertEqual(task.responses.first?.textEncodingName, expectedEncoding, path)
            XCTAssertEqual(task.data.first, data, path)
        }
    }

    @MainActor
    func testEbookHandlerTerminatesMalformedRequest() {
        let handler = EbookURLSchemeHandler()
        let task = TestURLSchemeTask(request: requestWithoutURL())
        let webView = WKWebView()

        handler.webView(webView, start: task)
        handler.webView(webView, stop: task)

        XCTAssertEqual(task.failures.count, 1)
        XCTAssertEqual(task.finishCount, 0)
        XCTAssertTrue(task.responses.isEmpty)
    }
}
