import Foundation
import WebKit
import XCTest
@preconcurrency @testable import LakeOfFireReader
@testable import SwiftUIWebView

final class EBookRenderReadyNativeIntegrationTests: XCTestCase {
    @MainActor
    private final class Fixture: NSObject, WKURLSchemeHandler, WKNavigationDelegate, WKScriptMessageHandler {
        let loaded: XCTestExpectation
        let pending: XCTestExpectation
        let ready: XCTestExpectation
        private(set) var readyBody: [String: Any]?
        private var didReportReady = false

        init(loaded: XCTestExpectation, pending: XCTestExpectation, ready: XCTestExpectation) {
            self.loaded = loaded
            self.pending = pending
            self.ready = ready
        }

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            let html = """
            <!doctype html><html data-mnb-font-pending="1"><body>
            <foliate-view><p>本文</p></foliate-view>
            </body></html>
            """
            let url = urlSchemeTask.request.url!
            urlSchemeTask.didReceive(URLResponse(
                url: url, mimeType: "text/html", expectedContentLength: html.utf8.count,
                textEncodingName: "utf-8"))
            urlSchemeTask.didReceive(Data(html.utf8))
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded.fulfill()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if body["reason"] as? String == "font-pending" {
                pending.fulfill()
            }
            guard body["hasReaderRenderReady"] as? Bool == true else { return }
            readyBody = body
            guard !didReportReady else { return }
            didReportReady = true
            ready.fulfill()
        }
    }

    @MainActor
    func testEBookFontCompletionPublishesReadinessWithoutAnotherRendererEvent() async throws {
        let loaded = expectation(description: "native EPUB document loaded")
        let pending = expectation(description: "renderer readiness waits for font completion")
        let ready = expectation(description: "font completion publishes native EPUB readiness")
        let fixture = Fixture(loaded: loaded, pending: pending, ready: ready)
        let controller = WKUserContentController()
        controller.add(fixture, name: "readerDocState")
        var script = ReaderDocStateUserScript().userScript
        controller.addUserScript(script.webKitUserScript)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(fixture, forURLScheme: "ebook")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 430, height: 932), configuration: configuration)
        webView.navigationDelegate = fixture
        defer {
            webView.stopLoading()
            controller.removeScriptMessageHandler(forName: "readerDocState")
            webView.navigationDelegate = nil
        }
        webView.load(URLRequest(url: URL(string: "ebook://ebook/load/fixture.epub")!))
        await fulfillment(of: [loaded], timeout: 10)
        let href = try await webView.evaluateJavaScript("window.location.href") as? String
        XCTAssertEqual(href, "ebook://ebook/load/fixture.epub")
        try await webView.evaluateJavaScript("""
            document.documentElement.dataset.mnbReaderRenderReady = '1';
            window.__manabiPostReaderDocStateEvent('font-pending');
            """)
        await fulfillment(of: [pending], timeout: 5)
        XCTAssertNil(fixture.readyBody, "Unfinished font work cannot publish render readiness")
        // Production font completion clears this root attribute. EPUBs have no
        // polling or whole-document observer and may have no later display event.
        try await webView.evaluateJavaScript("delete document.documentElement.dataset.mnbFontPending")
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(fixture.readyBody?["hasReaderRenderReady"] as? Bool, true)
        XCTAssertEqual(fixture.readyBody?["href"] as? String, href)
        withExtendedLifetime(fixture) {}
        withExtendedLifetime(webView) {}
    }
}
