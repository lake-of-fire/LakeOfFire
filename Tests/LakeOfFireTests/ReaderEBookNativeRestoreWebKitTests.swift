#if os(macOS)
import AppKit
import Foundation
import WebKit
import XCTest
import LakeOfFireContent
@testable import LakeOfFireReader

/// Uses the production request dictionary as WKWebView's named arguments, not
/// JSON embedded into script text. Local HTML and ephemeral website data only.
final class ReaderEBookNativeRestoreWebKitTests: XCTestCase {
    @MainActor
    func testRealWebKitReceivesNumericEndpointsAndInteriorFraction() async throws {
        for fraction: Float in [0, -0.0, 0.375, 1] {
            let request = try XCTUnwrap(try ReaderEBookInitialRestoreBridgeRequest(
                restore: .init(cfi: "", fractionalCompletion: fraction)
            ))
            let value = try await receive(request)
            XCTAssertEqual(value["fractionType"] as? String, "number")
            XCTAssertEqual(value["fraction"] as? Double, Double(fraction))
            XCTAssertEqual(value["locator"] as? String, "fraction")
            XCTAssertEqual(value["requestID"] as? String, request.requestID)
            XCTAssertEqual(value["isNull"] as? Bool, false)
        }
    }

    @MainActor
    func testRealWebKitPreservesCFIBytesAndHistoricalZeroPriority() async throws {
        let cfi = "epubcfi(/6/4[日本語-e\u{301}]!/4/2:0)"
        let request = try XCTUnwrap(try ReaderEBookInitialRestoreBridgeRequest(
            restore: .init(cfi: cfi, fractionalCompletion: 0)
        ))
        let value = try await receive(request)
        XCTAssertEqual(Array(try XCTUnwrap(value["cfi"] as? String).utf8), Array(cfi.utf8))
        XCTAssertEqual(value["locator"] as? String, "cfi")
        XCTAssertEqual(value["fractionType"] as? String, "number")
        XCTAssertEqual(value["fraction"] as? Double, 0)
    }

    @MainActor
    func testRealWebKitDistinguishesNoRequestFromCFIOnlyRequest() async throws {
        let absent = try await receive(nil)
        XCTAssertEqual(absent["isNull"] as? Bool, true)
        let request = try XCTUnwrap(try ReaderEBookInitialRestoreBridgeRequest(
            restore: .init(cfi: "epubcfi(/6/4!)", fractionalCompletion: nil)
        ))
        let value = try await receive(request)
        XCTAssertEqual(value["isNull"] as? Bool, false)
        XCTAssertEqual(value["hasFraction"] as? Bool, false)
        XCTAssertEqual(value["fractionType"] as? String, "undefined")
        XCTAssertEqual(value["locator"] as? String, "cfi")
    }

    @MainActor
    func testRealWebKitPreservesIndependentNativeRequestIDs() async throws {
        let saved = ReaderContentEbookInitialRestore(cfi: "", fractionalCompletion: 0)
        let first = try XCTUnwrap(try ReaderEBookInitialRestoreBridgeRequest(restore: saved))
        let second = try XCTUnwrap(try ReaderEBookInitialRestoreBridgeRequest(restore: saved))
        let one = try await receive(first)
        let two = try await receive(second)
        XCTAssertEqual(one["requestID"] as? String, first.requestID)
        XCTAssertEqual(two["requestID"] as? String, second.requestID)
        XCTAssertNotEqual(one["requestID"] as? String, two["requestID"] as? String)
    }

    @MainActor
    private func receive(_ request: ReaderEBookInitialRestoreBridgeRequest?) async throws -> [String: Any] {
        let probe = NativeRestoreWebKitProbe()
        let json = try await probe.run(request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
}

@MainActor
private final class NativeRestoreWebKitProbe: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<String, Error>?
    private var view: WKWebView?
    private var request: ReaderEBookInitialRestoreBridgeRequest?
    private var watchdog: Task<Void, Never>?

    func run(_ request: ReaderEBookInitialRestoreBridgeRequest?) async throws -> String {
        _ = NSApplication.shared
        self.request = request
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
        view = webView
        webView.navigationDelegate = self
        defer {
            watchdog?.cancel()
            watchdog = nil
            webView.stopLoading()
            webView.navigationDelegate = nil
            view = nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            watchdog = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 15_000_000_000) }
                catch { return }
                self?.finish(.failure(URLError(.timedOut)))
            }
            webView.loadHTMLString("<!doctype html><html><head><meta charset='utf-8'></head><body></body></html>", baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let argument: Any = request?.javaScriptArgument ?? NSNull()
        webView.callAsyncJavaScript("""
            if (initialRestore === null) return JSON.stringify({isNull: true});
            return JSON.stringify({isNull: false, requestID: initialRestore.requestID,
              locator: initialRestore.requestedLocator, cfi: initialRestore.cfi,
              hasFraction: Object.prototype.hasOwnProperty.call(initialRestore, 'fractionalCompletion'),
              fractionType: typeof initialRestore.fractionalCompletion,
              fraction: initialRestore.fractionalCompletion});
            """, arguments: ["initialRestore": argument], in: nil, in: .page) { [weak self] result in
                switch result {
                case .success(let value):
                    guard let text = value as? String else {
                        self?.finish(.failure(URLError(.cannotParseResponse)))
                        return
                    }
                    self?.finish(.success(text))
                case .failure(let error): self?.finish(.failure(error))
                }
            }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(URLError(.networkConnectionLost)))
    }
    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        watchdog?.cancel()
        continuation.resume(with: result)
    }
}
#endif
