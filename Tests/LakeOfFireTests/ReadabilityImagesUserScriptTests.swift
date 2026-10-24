import XCTest
@preconcurrency import WebKit
import LakeOfFireContent

@MainActor
private final class ReadabilityImageNavigationDelegate: NSObject, WKNavigationDelegate {
    let completion: XCTestExpectation
    private(set) var error: Error?

    init(completion: XCTestExpectation) {
        self.completion = completion
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        completion.fulfill()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error
        completion.fulfill()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
        completion.fulfill()
    }
}

@MainActor
final class ReadabilityImagesUserScriptTests: XCTestCase {
    func test_lateLoadAfterVerticalSwitch_preservesVerticalPresentation() async throws {
        let styles = try await runLoad(after: """
            document.body.dataset.mnbWritingDirection = 'vertical';
            document.body.classList.add('reader-vertical-writing');
            window.manabiUpdateReadabilityImageMargins();
            """)
        XCTAssertEqual(styles["width"], "")
        XCTAssertEqual(styles["maxWidth"], "")
        XCTAssertEqual(styles["verticalWrapper"], "true")
        XCTAssertEqual(styles["borderRadius"], "6px")
        assertUnrelatedStyles(styles)
    }

    func test_lateLoadAfterLeavingReaderMode_doesNotApplySizing() async throws {
        let styles = try await runLoad(after: "document.body.classList.remove('readability-mode');")
        XCTAssertEqual(styles["width"], "")
        XCTAssertEqual(styles["maxWidth"], "")
        XCTAssertEqual(styles["managed"], "")
        assertUnrelatedStyles(styles)
    }

    func test_verticalImageWrapperWithText_preservesParagraphFlow() async throws {
        let styles = try await runLoad(after: """
            document.getElementById('wrapper').prepend('Caption text ');
            document.body.dataset.mnbWritingDirection = 'vertical';
            window.manabiUpdateReadabilityImageMargins();
            """)
        XCTAssertEqual(styles["verticalWrapper"], "false")
        XCTAssertEqual(styles["borderRadius"], "6px")
        XCTAssertEqual(styles["width"], "")
        XCTAssertEqual(styles["maxWidth"], "")
        assertUnrelatedStyles(styles)
    }

    func test_lateLoadAfterContentResize_usesCurrentContentWidth() async throws {
        let styles = try await runLoad(after: "window.fixtureContentWidth = 400;")
        XCTAssertFalse(try XCTUnwrap(styles["width"]).isEmpty)
        XCTAssertEqual(styles["width"], styles["maxWidth"])
        XCTAssertEqual(styles["widthPriority"], "important")
        assertUnrelatedStyles(styles)
    }

    func test_lateLoadAfterImageRemoval_doesNotResizeDetachedImage() async throws {
        let styles = try await runLoad(after: "window.fixtureImage.remove();")
        XCTAssertEqual(styles["width"], "")
        XCTAssertEqual(styles["maxWidth"], "")
        XCTAssertEqual(styles["managed"], "")
        assertUnrelatedStyles(styles)
    }

    func test_currentHorizontalLoad_appliesManagedSizing() async throws {
        let styles = try await runLoad(after: "")
        XCTAssertFalse(try XCTUnwrap(styles["width"]).isEmpty)
        XCTAssertFalse(try XCTUnwrap(styles["maxWidth"]).isEmpty)
        XCTAssertEqual(styles["widthPriority"], "important")
        XCTAssertEqual(styles["managed"], "1")
        assertUnrelatedStyles(styles)
    }

    private func assertUnrelatedStyles(
        _ styles: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(styles["color"], "red", file: file, line: line)
        XCTAssertEqual(styles["marginLeft"], "7px", file: file, line: line)
    }

    // Controlled dimensions and an explicitly delivered pending callback exercise the production
    // script's state transitions. These tests do not claim network/decode timing or rendered layout.
    private func runLoad(after transition: String) async throws -> [String: String] {
        let webView = WKWebView(frame: .zero)
        let finished = expectation(description: "Image fixture loaded")
        let navigationDelegate = ReadabilityImageNavigationDelegate(completion: finished)
        webView.navigationDelegate = navigationDelegate
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
        }
        webView.loadHTMLString("""
            <!doctype html><html><body class="readability-mode">
            <div id="reader-content"><p id="wrapper"><img style="color:red;margin-left:7px"></p></div>
            </body></html>
            """, baseURL: URL(string: "https://reader.example/article"))
        await fulfillment(of: [finished], timeout: 10)
        if let error = navigationDelegate.error { throw error }
        _ = try await evaluate("""
            window.fixtureLoaded = false;
            window.fixtureContentWidth = 800;
            window.fixtureImage = document.querySelector('img');
            Object.defineProperty(document.getElementById('reader-content'), 'offsetWidth', {
                get: () => window.fixtureContentWidth
            });
            Object.defineProperty(window.fixtureImage, 'naturalWidth', {
                get: () => window.fixtureLoaded ? 300 : 0
            });
            Object.defineProperty(window.fixtureImage, 'naturalHeight', {
                get: () => window.fixtureLoaded ? 200 : 0
            });
            Object.defineProperty(window.fixtureImage, 'width', {
                get: () => window.fixtureLoaded ? 300 : 0
            });
            ({});
            """, in: webView)
        _ = try await evaluate(ReadabilityImagesUserScript.shared.userScriptSource + "\n({});", in: webView)
        return try await evaluate("""
            (() => {
                const image = window.fixtureImage;
                \(transition)
                window.fixtureLoaded = true;
                image.dispatchEvent(new Event('load'));
                return {
                    width: image.style.width,
                    maxWidth: image.style.maxWidth,
                    widthPriority: image.style.getPropertyPriority('width'),
                    color: image.style.color,
                    marginLeft: image.style.marginLeft,
                    borderRadius: image.style.borderRadius,
                    managed: image.dataset.manabiManagedReaderImageSizing || '',
                    verticalWrapper: String(document.getElementById('wrapper')
                        .classList.contains('mnb-vertical-inline-image-wrapper'))
                };
            })();
            """, in: webView)
    }

    private func evaluate(_ script: String, in webView: WKWebView) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let values = value as? [String: String] {
                    continuation.resume(returning: values)
                } else {
                    continuation.resume(throwing: ImageProbeError.unexpectedResult)
                }
            }
        }
    }

    private enum ImageProbeError: Error {
        case unexpectedResult
    }
}
