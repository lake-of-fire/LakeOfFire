import Foundation
import XCTest
import LakeOfFireContent
import LakeOfFireCore

final class TranscriptPageRegistryRouteIdentityTests: XCTestCase {
    private func asset(
        key: String = "shared-key",
        source: String = "https://example.com/video?language=en#chapter-2",
        html: String = "<p>Transcript café</p>",
        webVTT: String? = "WEBVTT\n\n00:00.000 --> 00:01.000\nHello 世界\n"
    ) throws -> TranscriptPageAsset {
        TranscriptPageAsset(
            key: key,
            canonicalContentURL: try XCTUnwrap(URL(string: source)),
            title: "Transcript",
            html: html,
            webVTT: webVTT
        )
    }

    private func changing(
        _ url: URL,
        _ change: (inout URLComponents) -> Void
    ) throws -> URL {
        var components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        change(&components)
        return try XCTUnwrap(components.url)
    }

    private func assertRejected(
        _ urls: [URL],
        by registry: TranscriptPageRegistry,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for url in urls {
            let html = await registry.htmlData(for: url)
            let webVTT = await registry.webVTTData(for: url)
            XCTAssertNil(html, url.absoluteString, file: file, line: line)
            XCTAssertNil(webVTT, url.absoluteString, file: file, line: line)
        }
    }

    func testExactRoutesReturnBytesAndPreserveEmbeddedSourceQueryAndFragment() async throws {
        let registry = TranscriptPageRegistry()
        let asset = try asset()
        await registry.register(asset)
        let page = try XCTUnwrap(asset.pageURL)
        let vtt = try XCTUnwrap(asset.webVTTURL)
        XCTAssertEqual(page.transcriptContentURL?.absoluteString, asset.canonicalContentURL.absoluteString)
        XCTAssertEqual(vtt.transcriptContentURL?.absoluteString, asset.canonicalContentURL.absoluteString)
        XCTAssertNil(page.fragment)
        XCTAssertNil(vtt.fragment)

        let html = await registry.htmlData(for: page)
        let webVTT = await registry.webVTTData(for: vtt)
        XCTAssertEqual(html, Data(asset.html.utf8))
        XCTAssertEqual(webVTT, Data(try XCTUnwrap(asset.webVTT).utf8))

        let htmlForVTT = await registry.htmlData(for: vtt)
        let vttForHTML = await registry.webVTTData(for: page)
        XCTAssertNil(htmlForVTT)
        XCTAssertNil(vttForHTML)
    }

    func testRejectsOuterRouteMutationsEvenWhenKeyStillMatches() async throws {
        let registry = TranscriptPageRegistry()
        let asset = try asset()
        await registry.register(asset)
        for route in [try XCTUnwrap(asset.pageURL), try XCTUnwrap(asset.webVTTURL)] {
            let variants = [
                try changing(route) { $0.queryItems = nil },
                try changing(route) { $0.queryItems = [URLQueryItem(name: "content-url", value: "https://example.com/other")] },
                try changing(route) { $0.queryItems?.append(URLQueryItem(name: "extra", value: "1")) },
                try changing(route) { $0.queryItems?.append(URLQueryItem(name: "content-url", value: asset.canonicalContentURL.absoluteString)) },
                try changing(route) { $0.fragment = "outer-fragment" },
                try changing(route) { $0.user = "user" },
                try changing(route) { $0.port = 1234 },
                try changing(route) { $0.path += "/" },
                try changing(route) { $0.path = $0.path.replacingOccurrences(of: "/shared-key", with: "/extra/shared-key") }
            ]
            for variant in variants {
                XCTAssertEqual(variant.transcriptAssetKey, asset.key)
            }
            await assertRejected(variants, by: registry)
            await assertRejected([
                try changing(route) { $0.host = "other" },
                try changing(route) { $0.scheme = "https" },
                try changing(route) { $0.path = "/unknown/shared-key" },
                try changing(route) { $0.path = "/page/" }
            ], by: registry)
        }
    }

    func testMissingAssetAndMissingWebVTT() async throws {
        let registry = TranscriptPageRegistry()
        let asset = try asset(webVTT: nil)
        let page = try XCTUnwrap(asset.pageURL)
        let vtt = try XCTUnwrap(asset.webVTTURL)
        await assertRejected([page, vtt], by: registry)
        await registry.register(asset)
        let html = await registry.htmlData(for: page)
        let webVTT = await registry.webVTTData(for: vtt)
        XCTAssertEqual(html, Data(asset.html.utf8))
        XCTAssertNil(webVTT)
    }

    func testSameKeyReplacementRejectsOldSourceAndServesLatestBytes() async throws {
        let registry = TranscriptPageRegistry()
        let first = try asset()
        let second = try asset(source: "https://example.com/video?language=en#chapter-3", html: "second", webVTT: "second VTT")
        await registry.register(first)
        await registry.register(second)
        await assertRejected([try XCTUnwrap(first.pageURL), try XCTUnwrap(first.webVTTURL)], by: registry)
        let page = try XCTUnwrap(second.pageURL)
        let vtt = try XCTUnwrap(second.webVTTURL)
        let secondHTML = await registry.htmlData(for: page)
        let secondVTT = await registry.webVTTData(for: vtt)
        XCTAssertEqual(secondHTML, Data(second.html.utf8))
        XCTAssertEqual(secondVTT, Data(try XCTUnwrap(second.webVTT).utf8))

        let latest = try asset(source: second.canonicalContentURL.absoluteString, html: "latest", webVTT: "latest VTT")
        await registry.register(latest)
        let latestHTML = await registry.htmlData(for: page)
        let latestVTT = await registry.webVTTData(for: vtt)
        let stored = await registry.asset(forKey: latest.key)
        XCTAssertEqual(latestHTML, Data(latest.html.utf8))
        XCTAssertEqual(latestVTT, Data(try XCTUnwrap(latest.webVTT).utf8))
        XCTAssertEqual(stored, latest)
    }

    func testRemoveAndRemoveAllKeepKeyBasedBehavior() async throws {
        let registry = TranscriptPageRegistry()
        let first = try asset()
        let other = try asset(key: "other-key")
        await registry.register(first)
        await registry.register(other)
        await registry.remove(key: first.key)
        let removed = await registry.asset(forKey: first.key)
        let retained = await registry.asset(forKey: other.key)
        XCTAssertNil(removed)
        XCTAssertEqual(retained, other)
        await assertRejected([try XCTUnwrap(first.pageURL), try XCTUnwrap(first.webVTTURL)], by: registry)
        let retainedHTML = await registry.htmlData(for: try XCTUnwrap(other.pageURL))
        let retainedVTT = await registry.webVTTData(for: try XCTUnwrap(other.webVTTURL))
        XCTAssertEqual(retainedHTML, Data(other.html.utf8))
        XCTAssertEqual(retainedVTT, Data(try XCTUnwrap(other.webVTT).utf8))
        await registry.removeAll()
        let cleared = await registry.asset(forKey: other.key)
        XCTAssertNil(cleared)
        await assertRejected([try XCTUnwrap(other.pageURL), try XCTUnwrap(other.webVTTURL)], by: registry)
    }
}
