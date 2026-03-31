import XCTest
import BravePlaylist
@testable import LakeOfFireWeb

final class BravePlaylistWebSupportTests: XCTestCase {
    func testScriptFactoryBuildsExpectedScripts() throws {
        let scriptSet = try BravePlaylistWebScripts.make(
            messageHandlerName: "playlistHandler",
            allowedDomains: ["youtube.com"],
            configuration: PlaylistScriptConfiguration(
                messageHandlerName: "playlistHandler",
                securityToken: "security-token",
                namespaceToken: "namespace"
            )
        )

        XCTAssertEqual(scriptSet.userScripts.count, 3)
        XCTAssertEqual(scriptSet.userScripts.first?.allowedDomains, ["youtube.com"])
        XCTAssertTrue(scriptSet.userScripts[2].source.contains("playlistHandler"))
        XCTAssertTrue(scriptSet.userScripts[2].source.contains("security-token"))
        XCTAssertEqual(
            scriptSet.processDocumentLoadJavaScript,
            "window.__firefox__.playlistProcessDocumentLoad_namespace()"
        )
    }

    func testMessageDecoderUsesScriptSecurityToken() throws {
        let scriptSet = try BravePlaylistWebScripts.make(
            messageHandlerName: "playlistHandler",
            configuration: PlaylistScriptConfiguration(
                messageHandlerName: "playlistHandler",
                securityToken: "expected-token",
                namespaceToken: "namespace"
            )
        )

        let body: [String: Any] = [
            "securityToken": "expected-token",
            "state": "interactive",
        ]

        let decoded = BravePlaylistWebMessageDecoder.decode(body: body, scriptSet: scriptSet)
        XCTAssertEqual(decoded, .readyState(.init(state: "interactive")))
    }

    func testCandidateSelectorPrefersVisibleDirectAudio() {
        let invisibleVideo = PlaylistInfo(
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
        let visibleAudio = PlaylistInfo(
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

        let preferred = BravePlaylistCandidateSelector.preferredCandidate(
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

        let context = BravePlaylistRequestContextBuilder.make(
            userAgent: "Manabi",
            referer: URL(string: "https://example.com/watch")!,
            cookies: [cookie]
        )

        XCTAssertEqual(context.headers["User-Agent"], "Manabi")
        XCTAssertEqual(context.headers["Referer"], "https://example.com/watch")
        XCTAssertEqual(context.headers["Cookie"], "session=abc123")
    }

    func testMediaDownloaderWritesTemporaryFile() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=abc123")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mp4"]
            )!
            return (response, Data("abc".utf8))
        }

        let media = PlaylistResolvedMedia(
            playlistInfo: PlaylistInfo(
                name: "Audio",
                src: "https://cdn.example.com/audio.m4a",
                pageSrc: "https://example.com/watch",
                pageTitle: "Audio",
                mimeType: "audio/mp4",
                duration: 1,
                detected: true,
                tagId: "audio",
                isInvisible: false
            ),
            url: URL(string: "https://cdn.example.com/audio.m4a")!,
            mimeType: "audio/mp4",
            requestHeaders: ["Cookie": "session=abc123"],
            resolutionMethod: .direct
        )

        let download = try await BravePlaylistMediaDownloader.download(
            media,
            using: makeSession()
        )

        let data = try Data(contentsOf: download.fileURL)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "abc")
        try? FileManager.default.removeItem(at: download.fileURL)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

private final class URLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            XCTFail("URLProtocolStub.handler not set")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
