import WebKit
import XCTest
@testable import LakeOfFireReader

@MainActor
private final class SettingsDOMNavigationObserver: NSObject, WKNavigationDelegate {
    let finished: XCTestExpectation

    init(finished: XCTestExpectation) {
        self.finished = finished
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished.fulfill()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        XCTFail("Reader settings document failed to load: \(error)")
        finished.fulfill()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        XCTFail("Reader settings document failed before commit: \(error)")
        finished.fulfill()
    }
}

final class ReaderSettingsSignatureInvalidationTests: XCTestCase {
    private let cached = ["pending:bootstrap", "presentation", "font", "global-font"]
    private let cleared = Array(repeating: "missing", count: 4)

    @MainActor
    func testAdaptiveWidthInvalidatesOnlyAnActualWidthChange() async throws {
        let webView = try await makeWebView()
        defer { webView.stopLoading() }
        let evaluator = evaluator(for: webView)
        try await run("document.body.style.setProperty('--mnb-reader-max-width-override', '1px')", in: webView)
        try await seedSignatures(in: webView)

        await applyAdaptiveReaderWidth(
            readerFontSize: 20, reason: "test", requestGeometryBake: false,
            hasAsyncCaller: true, evaluateJavaScript: evaluator
        )
        let appliedWidth = try await webView.evaluateJavaScript(
            "document.body.style.getPropertyValue('--mnb-reader-max-width-override')"
        ) as? String
        let invalidated = try await signatures(in: webView)
        XCTAssertEqual(appliedWidth, readerAdaptiveMaxWidthOverrideCSSValue(readerFontSize: 20))
        XCTAssertEqual(invalidated, cleared)

        try await seedSignatures(in: webView)
        await applyAdaptiveReaderWidth(
            readerFontSize: 20, reason: "test", requestGeometryBake: false,
            hasAsyncCaller: true, evaluateJavaScript: evaluator
        )
        let unchanged = try await signatures(in: webView)
        XCTAssertEqual(unchanged, cached)
    }

    @MainActor
    func testForwardedFontSizeInvalidatesTheChangedFrameAndAggregateCache() async throws {
        let webView = try await makeWebView()
        defer { webView.stopLoading() }
        let evaluator = evaluator(for: webView)
        let variants: [(size: Double, cssSize: String)] = [(20, "20px"), (20.25, "20.25px")]
        for (size, cssSize) in variants {
            try await run("""
                document.body.style.fontSize = '\(cssSize)'
                document.querySelector('iframe').contentDocument.body.style.fontSize = '17px'
                """, in: webView)
            try await seedSignatures(in: webView)

            await applyReaderFontSize(
                size, readerFontSize: size, lightModeTheme: .white, darkModeTheme: .black,
                reason: "test", hasAsyncCaller: true, evaluateJavaScript: evaluator
            )
            let frameFontSize = try await webView.evaluateJavaScript(
                "document.querySelector('iframe').contentDocument.body.style.fontSize"
            ) as? String
            let changedFrame = try await signatures(in: webView, childFrame: true)
            let unchangedHost = try await signatures(in: webView)
            XCTAssertEqual(frameFontSize, cssSize)
            XCTAssertEqual(changedFrame, cleared)
            XCTAssertEqual(unchangedHost, Array(cached.prefix(3)) + ["missing"])

            try await seedSignatures(in: webView)
            await applyReaderFontSize(
                size, readerFontSize: size, lightModeTheme: .white, darkModeTheme: .black,
                reason: "test", hasAsyncCaller: true, evaluateJavaScript: evaluator
            )
            let unchangedFrame = try await signatures(in: webView, childFrame: true)
            let hostAfterRepeat = try await signatures(in: webView)
            XCTAssertEqual(unchangedFrame, cached)
            XCTAssertEqual(hostAfterRepeat, cached)
        }
    }

    @MainActor
    func testThemeInvalidatesSharedStyleCachesWithoutRetiringFontSizeCaches() async throws {
        let webView = try await makeWebView()
        defer { webView.stopLoading() }
        let evaluator = evaluator(for: webView)
        try await run("""
            for (const doc of [document, document.querySelector('iframe').contentDocument]) {
                doc.body.dataset.mnbColorScheme = 'light'
                doc.body.dataset.mnbLightTheme = '\(LightModeTheme.white.rawValue)'
                doc.body.dataset.mnbDarkTheme = '\(DarkModeTheme.black.rawValue)'
            }
            document.querySelector('iframe').contentDocument.body.dataset.mnbDarkTheme = 'previous-theme'
            """, in: webView)
        try await seedSignatures(in: webView)

        await applyReaderTheme(
            colorScheme: .light, lightModeTheme: .white, darkModeTheme: .black,
            reason: "test", hasAsyncCaller: true, evaluateJavaScript: evaluator
        )
        let frameTheme = try await webView.evaluateJavaScript(
            "document.querySelector('iframe').contentDocument.body.dataset.mnbDarkTheme"
        ) as? String
        let changedFrame = try await signatures(in: webView, childFrame: true)
        let unchangedHost = try await signatures(in: webView)
        XCTAssertEqual(frameTheme, DarkModeTheme.black.rawValue)
        XCTAssertEqual(changedFrame, ["missing", "missing", "font", "global-font"])
        XCTAssertEqual(unchangedHost, cached)

        try await seedSignatures(in: webView)
        await applyReaderTheme(
            colorScheme: .light, lightModeTheme: .white, darkModeTheme: .black,
            reason: "test", hasAsyncCaller: true, evaluateJavaScript: evaluator
        )
        let unchangedFrame = try await signatures(in: webView, childFrame: true)
        XCTAssertEqual(unchangedFrame, cached)
    }

    @MainActor
    private func makeWebView() async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let loaded = expectation(description: "Reader settings document and iframe loaded")
        let observer = SettingsDOMNavigationObserver(finished: loaded)
        webView.navigationDelegate = observer
        _ = try XCTUnwrap(webView.loadHTMLString("<!doctype html><body><iframe></iframe></body>", baseURL: nil))
        await fulfillment(of: [loaded], timeout: 5)
        withExtendedLifetime(observer) { webView.navigationDelegate = nil }
        try await run("""
            const doc = document.querySelector('iframe').contentDocument
            window.reader = { view: { renderer: { getContents: () => [{ doc }] } } }
            """, in: webView)
        return webView
    }

    @MainActor
    private func evaluator(for webView: WKWebView) -> ReaderSettingsJavaScriptEvaluator {
        { source, _ in
            try await self.run(source, in: webView)
        }
    }

    @MainActor
    private func run(_ script: String, in webView: WKWebView) async throws {
        _ = try await webView.callAsyncJavaScript(
            "await eval(source)", arguments: ["source": script], in: nil, contentWorld: .page
        )
    }

    @MainActor
    private func seedSignatures(in webView: WKWebView) async throws {
        try await run("""
            for (const doc of [document, document.querySelector('iframe').contentDocument]) {
                doc.body.dataset.mnbMessageHandlerSettingsApplicationSignature = 'pending:bootstrap'
                doc.body.dataset.mnbMessageHandlerSettingsSignature = 'presentation'
                doc.body.dataset.mnbReaderFontSizeSignature = 'font'
                doc.defaultView.__manabiReaderFontSizeSyncSignature = 'global-font'
            }
            """, in: webView)
    }

    @MainActor
    private func signatures(in webView: WKWebView, childFrame: Bool = false) async throws -> [String] {
        let result = try await webView.callAsyncJavaScript(
            """
            const doc = childFrame ? document.querySelector('iframe').contentDocument : document
            return [
                doc.body.dataset.mnbMessageHandlerSettingsApplicationSignature,
                doc.body.dataset.mnbMessageHandlerSettingsSignature,
                doc.body.dataset.mnbReaderFontSizeSignature,
                doc.defaultView.__manabiReaderFontSizeSyncSignature
            ].map(value => value ?? 'missing')
            """, arguments: ["childFrame": childFrame], in: nil, contentWorld: .page
        )
        return try XCTUnwrap(result as? [String])
    }
}
