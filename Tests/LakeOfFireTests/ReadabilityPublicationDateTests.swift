import XCTest
@preconcurrency import WebKit
import LakeOfFireContent

@MainActor
private final class PublicationDateFixtureDelegate: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let loaded: XCTestExpectation
    let parsed: XCTestExpectation
    var navigationError: Error?
    var outputHTML: String?
    var publishedTime: String?
    var publishedTimeIsNull = false

    init(loaded: XCTestExpectation, parsed: XCTestExpectation) {
        self.loaded = loaded
        self.parsed = parsed
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded.fulfill()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationError = error
        loaded.fulfill()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationError = error
        loaded.fulfill()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any]
        outputHTML = body?["outputHTML"] as? String
        publishedTime = body?["publishedTime"] as? String
        publishedTimeIsNull = body?["publishedTime"] is NSNull
        parsed.fulfill()
    }
}

@MainActor
final class ReadabilityPublicationDateTests: XCTestCase {
    func test_invalidDateMarkup_isPreservedAsText() async throws {
        for value in [
            #"<span id="date-injected">not a date</span>"#,
            #"<img src="missing" onerror="dateProbe=1">invalid"#,
            "unknown & pending <time>"
        ] {
            let result = try await parseDate(value)
            XCTAssertEqual(result["payloadDate"], value)
            XCTAssertEqual(result["dateText"], value)
            XCTAssertEqual(result["dateChildren"], "0")
            XCTAssertEqual(result["injectedNodes"], "0")
        }
    }

    func test_validDate_keepsFormattedPayloadAndText() async throws {
        let result = try await parseDate("2026-10-22")
        XCTAssertEqual(result["dateText"], result["expectedFormattedDate"])
        XCTAssertEqual(result["payloadDate"], result["expectedFormattedDate"])
        XCTAssertEqual(result["dateChildren"], "0")
        XCTAssertEqual(result["datePresent"], "true")
    }

    func test_emptyDate_omitsDateLabelAndPreservesNullPayload() async throws {
        let result = try await parseDate("")
        XCTAssertEqual(result["datePresent"], "false")
        XCTAssertEqual(result["payloadHasDateValue"], "false")
        XCTAssertEqual(result["payloadIsNull"], "true")
    }

    func test_externalArticleWithoutDate_includesOriginalLink() async throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://reader.example/article?x=one&quote=%22&tag=%3Cpart%3E"))
        let result = try await parseDate("", sourceURL: sourceURL)
        XCTAssertEqual(result["originalCount"], "1")
        XCTAssertEqual(result["originalHref"], sourceURL.absoluteString)
        XCTAssertEqual(result["originalText"], "View Original")
        XCTAssertEqual(result["metaCount"], "1")
        XCTAssertEqual(result["dividerCount"], "0")
    }

    func test_externalArticleWithDate_separatesDateAndOriginalLink() async throws {
        let result = try await parseDate("2026-10-22")
        XCTAssertEqual(result["originalCount"], "1")
        XCTAssertEqual(result["dateText"], result["expectedFormattedDate"])
        XCTAssertEqual(result["dividerCount"], "1")
    }

    // Execute the actual bundled parser, sanitizer and initialization template. Inspect the
    // generated DOM without executing it; this does not test rendered layout or image loading.
    private func parseDate(
        _ value: String,
        sourceURL: URL = URL(string: "https://reader.example/article")!
    ) async throws -> [String: String] {
        let loaded = expectation(description: "Article fixture loaded")
        let parsed = expectation(description: "Production readability payload received")
        let delegate = PublicationDateFixtureDelegate(loaded: loaded, parsed: parsed)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(delegate, name: "readabilityParsed")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = delegate
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            configuration.userContentController.removeScriptMessageHandler(forName: "readabilityParsed")
        }
        let paragraph = """
            <p>This is a substantive article paragraph with several sentences, written to test date metadata.
            It contains enough ordinary text to retain the article when parsed for reading.</p>
            """
        webView.loadHTMLString("""
            <!doctype html><html><head><title>Reader date fixture</title></head><body>
            <article><h1>Reader date fixture</h1>\(String(repeating: paragraph, count: 12))</article>
            </body></html>
            """, baseURL: sourceURL)
        await fulfillment(of: [loaded], timeout: 10)
        if let error = delegate.navigationError { throw error }
        _ = try await call("""
            const meta = document.createElement('meta');
            meta.setAttribute('property', 'article:published_time');
            meta.setAttribute('content', value);
            document.head.append(meta);
            return {};
            """, arguments: ["value": value], in: webView)
        try await evaluate(LakeOfFireContent.Readability.shared.userScriptSource, in: webView)
        try await evaluate("window.manabi_readability();", in: webView)
        await fulfillment(of: [parsed], timeout: 10)
        let outputHTML = try XCTUnwrap(delegate.outputHTML)
        return try await call("""
            const output = new DOMParser().parseFromString(outputHTML, 'text/html');
            const date = output.getElementById('reader-publication-date');
            let expectedFormattedDate = '';
            if (value) {
                const parsed = new Date(value);
                if (Number.isNaN(parsed.getTime())) {
                    expectedFormattedDate = value;
                } else {
                    try {
                        expectedFormattedDate = new Intl.DateTimeFormat(undefined, {dateStyle:'short'}).format(parsed);
                    } catch (_) {
                        expectedFormattedDate = parsed.toLocaleDateString();
                    }
                }
            }
            return {
                payloadDate,
                payloadHasDateValue: String(payloadHasDateValue),
                payloadIsNull: String(payloadIsNull),
                dateText: date?.textContent || '',
                datePresent: String(!!date),
                dateChildren: String(date?.children.length || 0),
                injectedNodes: String(output.querySelectorAll('#date-injected,img[onerror]').length),
                originalCount: String(output.querySelectorAll('.reader-view-original').length),
                originalHref: output.querySelector('.reader-view-original')?.getAttribute('href') || '',
                originalText: output.querySelector('.reader-view-original')?.textContent || '',
                metaCount: String(output.querySelectorAll('#reader-meta-line').length),
                dividerCount: String(output.querySelectorAll('.reader-meta-divider').length),
                expectedFormattedDate
            };
            """, arguments: [
                "outputHTML": outputHTML,
                "value": value,
                "payloadDate": delegate.publishedTime ?? "",
                "payloadHasDateValue": delegate.publishedTime != nil,
                "payloadIsNull": delegate.publishedTimeIsNull
            ], in: webView)
    }

    private func evaluate(_ source: String, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webView.evaluateJavaScript(source) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func call(
        _ source: String,
        arguments: [String: Any],
        in webView: WKWebView
    ) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(source, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    guard let values = value as? [String: String] else {
                        continuation.resume(throwing: PublicationDateProbeError.unexpectedResult)
                        return
                    }
                    continuation.resume(returning: values)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private enum PublicationDateProbeError: Error {
        case unexpectedResult
    }
}
