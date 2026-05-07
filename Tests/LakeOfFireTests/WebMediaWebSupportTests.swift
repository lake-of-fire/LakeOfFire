import XCTest
@testable import WebMedia

final class WebMediaWebSupportTests: XCTestCase {
    func testScriptFactoryBuildsExpectedScripts() throws {
        let scriptSet = try WebMediaScripts.make(
            messageHandlerName: "mediaHandler",
            allowedDomains: ["youtube.com"],
            configuration: WebMediaScriptConfiguration(
                messageHandlerName: "mediaHandler",
                securityToken: "security-token",
                namespaceToken: "namespace"
            )
        )

        XCTAssertEqual(scriptSet.userScripts.count, 3)
        XCTAssertEqual(scriptSet.userScripts.first?.allowedDomains, ["youtube.com"])
        XCTAssertTrue(scriptSet.userScripts[2].source.contains("mediaHandler"))
        XCTAssertTrue(scriptSet.userScripts[2].source.contains("security-token"))
        XCTAssertEqual(
            scriptSet.processDocumentLoadJavaScript,
            "window.__firefox__.webMediaProcessDocumentLoad_namespace()"
        )
    }

    func testMessageDecoderUsesScriptSecurityToken() throws {
        let scriptSet = try WebMediaScripts.make(
            messageHandlerName: "mediaHandler",
            configuration: WebMediaScriptConfiguration(
                messageHandlerName: "mediaHandler",
                securityToken: "expected-token",
                namespaceToken: "namespace"
            )
        )

        let body: [String: Any] = [
            "securityToken": "expected-token",
            "state": "interactive",
        ]

        let decoded = WebMediaMessageDecoder.decode(body: body, scriptSet: scriptSet)
        XCTAssertEqual(decoded, .readyState(.init(state: "interactive")))
    }

    func testCandidateSelectorPrefersVisibleDirectAudio() {
        let invisibleVideo = WebMediaInfo(
            name: "Video",
            src: "https://example.com/video.mp4",
            pageSrc: "https://example.com/watch",
            pageTitle: "Watch",
            mimeType: "video/mp4",
            duration: 100,
            detected: true,
            tagId: "video",
            isInvisible: true
        )
        let visibleAudio = WebMediaInfo(
            name: "Audio",
            src: "https://example.com/audio.m4a",
            pageSrc: "https://example.com/watch",
            pageTitle: "Watch",
            mimeType: "audio/mp4",
            duration: 30,
            detected: true,
            tagId: "audio",
            isInvisible: false
        )

        let preferred = WebMediaCandidateSelector.preferredCandidate(
            from: [invisibleVideo, visibleAudio]
        )

        XCTAssertEqual(preferred?.tagId, "audio")
    }

    func testRequestContextIncludesCookieRefererAndUserAgent() {
        let cookie = HTTPCookie(properties: [
            .domain: "example.com",
            .path: "/",
            .name: "session",
            .value: "abc123",
            .secure: "FALSE",
            .expires: Date().addingTimeInterval(60),
        ])!

        let context = WebMediaRequestContextBuilder.make(
            userAgent: "Manabi",
            referer: URL(string: "https://example.com/watch")!,
            cookies: [cookie]
        )

        XCTAssertEqual(context.headers["User-Agent"], "Manabi")
        XCTAssertEqual(context.headers["Referer"], "https://example.com/watch")
        XCTAssertEqual(context.headers["Cookie"], "session=abc123")
    }

}
