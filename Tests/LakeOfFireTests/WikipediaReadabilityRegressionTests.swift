import XCTest
import WebKit
import SwiftSoup
import SwiftReadability
@testable import LakeOfFireContent

@MainActor
private final class WikipediaReadabilityNavigationDelegate: NSObject, WKNavigationDelegate {
    let didFinishExpectation: XCTestExpectation

    init(didFinishExpectation: XCTestExpectation) {
        self.didFinishExpectation = didFinishExpectation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinishExpectation.fulfill()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        XCTFail("WKWebView navigation failed: \(error.localizedDescription)")
        didFinishExpectation.fulfill()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        XCTFail("WKWebView provisional navigation failed: \(error.localizedDescription)")
        didFinishExpectation.fulfill()
    }
}

@MainActor
private final class WikipediaReadabilityMessageHandler: NSObject, WKScriptMessageHandler {
    let readabilityParsedExpectation: XCTestExpectation
    private(set) var readabilityParsedBody: [String: Any]? = nil
    private(set) var readabilityUnavailableBodies: [[String: Any]] = []

    init(readabilityParsedExpectation: XCTestExpectation) {
        self.readabilityParsedExpectation = readabilityParsedExpectation
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else {
            return
        }

        switch message.name {
        case "readabilityParsed":
            guard readabilityParsedBody == nil else {
                return
            }
            readabilityParsedBody = body
            readabilityParsedExpectation.fulfill()
        case "readabilityModeUnavailable":
            readabilityUnavailableBodies.append(body)
        case "readabilityFramePing":
            break
        default:
            XCTFail("Unexpected readability message: \(message.name)")
        }
    }
}

final class WikipediaReadabilityRegressionTests: XCTestCase {
    private static let expectedCollapsedSectionMarkers = [
        "Venture incubation",
        "Other activities",
        "Controversies",
    ]

    private static let expectedCollapsedSectionBodyMarkers = [
        "Throughout 2020, Mozilla ran Mozilla Builders",
        "Mozilla VR is a team focused on bringing tools, specifications, and standards to the open Web.",
        "In February 2014, Mozilla released Directory Tiles",
        "On December 15, 2017, Mozilla installed an add-on in all Firefox Quantum browsers, titled \"Looking Glass,\"",
    ]

    private static let appRepositoryRootURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let readabilityScriptURL = appRepositoryRootURL
        .appendingPathComponent("Vendor/swift-readability/Sources/SwiftReadability/Resources/Readability.js")

    private static let domPurifyScriptURL = appRepositoryRootURL
        .appendingPathComponent("Vendor/LakeOfFire/Sources/LakeOfFireContent/Resources/User Scripts/dompurify.min.js")

    private static let readabilityInitializationTemplateURL = appRepositoryRootURL
        .appendingPathComponent("Vendor/LakeOfFire/Sources/LakeOfFireContent/Resources/User Scripts/readability_initialization.template.js")

    private static let sourcePageURL = URL(string: "https://en.wikipedia.org/wiki/Mozilla?useskin=minerva")!

    private func loadFixtureHTML() throws -> String {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "mozilla-wikipedia-minerva",
                withExtension: "html",
                subdirectory: "Fixtures/Readability"
            ) ?? Bundle.module.url(
                forResource: "mozilla-wikipedia-minerva",
                withExtension: "html"
            )
        )
        return try String(contentsOf: fixtureURL, encoding: .utf8)
    }

    private func stripExecutableScripts(from html: String) -> String {
        html.replacingOccurrences(
            of: #"(?is)<script\b[^>]*>.*?</script>"#,
            with: "",
            options: .regularExpression
        )
    }

    private func loadReadabilityUserScriptSource() throws -> String {
        let readabilitySource = try String(contentsOf: Self.readabilityScriptURL, encoding: .utf8)
        let domPurifySource = try String(contentsOf: Self.domPurifyScriptURL, encoding: .utf8)
        let initializationTemplate = try String(
            contentsOf: Self.readabilityInitializationTemplateURL,
            encoding: .utf8
        )

        let initializedSource = initializationTemplate
            .replacingOccurrences(of: "##CHAR_THRESHOLD##", with: "1")
            .replacingOccurrences(of: "##CSS##", with: "")
            .replacingOccurrences(of: "##SCRIPT##", with: "")

        return readabilitySource + domPurifySource + initializedSource
    }

    private func collapseWhitespace(in text: String) -> String {
        text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func parseFixtureWithReadabilityUserScript(_ html: String) async throws -> [String: Any] {
        let sanitizedHTML = stripExecutableScripts(from: html)
        let userContentController = WKUserContentController()
        let readabilityParsedExpectation = expectation(description: "readability parsed")
        let messageHandler = WikipediaReadabilityMessageHandler(
            readabilityParsedExpectation: readabilityParsedExpectation
        )
        for name in ["readabilityFramePing", "readabilityModeUnavailable", "readabilityParsed"] {
            userContentController.add(messageHandler, name: name)
        }

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: try loadReadabilityUserScriptSource(),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 430, height: 932), configuration: configuration)
        let didFinishExpectation = expectation(description: "wikipedia fixture loaded")
        let navigationDelegate = WikipediaReadabilityNavigationDelegate(
            didFinishExpectation: didFinishExpectation
        )
        webView.navigationDelegate = navigationDelegate
        webView.loadHTMLString(sanitizedHTML, baseURL: Self.sourcePageURL)
        await fulfillment(of: [didFinishExpectation, readabilityParsedExpectation], timeout: 10)
        withExtendedLifetime(navigationDelegate) {}
        withExtendedLifetime(messageHandler) {}
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(
            messageHandler.readabilityUnavailableBodies.isEmpty,
            "Readability unexpectedly reported the Wikimedia fixture as unavailable"
        )
        return try XCTUnwrap(messageHandler.readabilityParsedBody)
    }

    func testMozillaWikipediaFixtureContainsCollapsedSectionMarkers() throws {
        let html = try loadFixtureHTML()

        for marker in Self.expectedCollapsedSectionMarkers {
            XCTAssertTrue(
                html.contains(marker),
                "Fixture no longer contains expected Wikipedia section marker '\(marker)'"
            )
        }
    }

    @MainActor
    func testReadabilityUserScriptKeepsCollapsedWikipediaSectionMarkers() async throws {
        let html = try loadFixtureHTML()
        let result = try await parseFixtureWithReadabilityUserScript(html)
        let outputHTML = try XCTUnwrap(result["outputHTML"] as? String)
        let normalizedOutputHTML = collapseWhitespace(in: outputHTML)

        for marker in Self.expectedCollapsedSectionMarkers {
            XCTAssertTrue(
                normalizedOutputHTML.contains(marker),
                "Readability user script dropped Wikimedia collapsed section marker '\(marker)'"
            )
        }

        for marker in Self.expectedCollapsedSectionBodyMarkers {
            XCTAssertTrue(
                normalizedOutputHTML.contains(marker),
                "Readability user script dropped Wikimedia collapsed section body text '\(marker)'"
            )
        }
    }

    @MainActor
    func testReadabilityUserScriptKeepsRubyInsideInlineFormatting() async throws {
        let expectedText = "東京を　旅行するときに　よく　使う「JR渋谷駅」から、よく　使われる　改札までの　行き方を　紹介します。"
        let html = #"""
        <html>
        <body>
        <article>
        <p><ruby><rb>東京</rb><rp>(</rp><rt>とうきょう</rt><rp>)</rp></ruby>を　<ruby><rb>旅行</rb><rp>(</rp><rt>りょこう</rt><rp>)</rp></ruby>するときに　よく　<ruby><rb>使</rb><rp>(</rp><rt>つか</rt><rp>)</rp></ruby>う「<b>JR<ruby><rb>渋谷</rb><rp>(</rp><rt>しぶや</rt><rp>)</rp></ruby><ruby><rb>駅</rb><rp>(</rp><rt>えき</rt><rp>)</rp></ruby></b>」から、よく　<ruby><rb>使</rb><rp>(</rp><rt>つか</rt><rp>)</rp></ruby>われる　<ruby><rb>改札</rb><rp>(</rp><rt>かいさつ</rt><rp>)</rp></ruby>までの　<ruby><rb>行</rb><rp>(</rp><rt>い</rt><rp>)</rp></ruby>き<ruby><rb>方</rb><rp>(</rp><rt>かた</rt><rp>)</rp></ruby>を　<ruby><rb>紹介</rb><rp>(</rp><rt>しょうかい</rt><rp>)</rp></ruby>します。</p>
        </article>
        </body>
        </html>
        """#

        let result = try await parseFixtureWithReadabilityUserScript(html)
        let outputHTML = try XCTUnwrap(result["outputHTML"] as? String)
        let textDocument = try SwiftSoup.parse(outputHTML)
        let readerContent = try XCTUnwrap(textDocument.getElementById("reader-content") ?? textDocument.body())
        try readerContent.select("rt, rp").remove()
        let actualText = try readerContent
            .text(trimAndNormaliseWhitespace: false)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(actualText, expectedText, "Output: \(outputHTML)")

        let rubyDocument = try SwiftSoup.parse(outputHTML)
        let ruby = try rubyDocument.select("ruby").array()
        XCTAssertTrue(
            try ruby.contains { try $0.text(trimAndNormaliseWhitespace: false).contains("渋谷") && $0.select("rt").text() == "しぶや" },
            "Expected JavaScript Readability output to retain source ruby for 渋谷. Output: \(outputHTML)"
        )
        XCTAssertTrue(
            try ruby.contains { try $0.text(trimAndNormaliseWhitespace: false).contains("駅") && $0.select("rt").text() == "えき" },
            "Expected JavaScript Readability output to retain source ruby for 駅. Output: \(outputHTML)"
        )
    }
}
