import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireCore

final class LakeOfFireTests: XCTestCase {
    func testExample() throws {
        XCTAssertNotNil(DefaultRealmConfiguration.configuration)
    }

    @MainActor
    func testTranscriptPageRegistryProducesEphemeralReaderContent() async throws {
        let contentURL = try XCTUnwrap(URL(string: "https://example.com/watch?v=1#fragment"))
        let asset = TranscriptPageAsset(
            key: "episode-1",
            canonicalContentURL: contentURL,
            title: "Episode 1 Transcript",
            html: "<html><body><div id='reader-content'>Transcript</div></body></html>",
            webVTT: "WEBVTT\n\n00:00.000 --> 00:01.000\nHello"
        )

        await TranscriptPageRegistry.shared.register(asset)
        defer {
            Task {
                await TranscriptPageRegistry.shared.remove(key: asset.key)
            }
        }

        let pageURL = try XCTUnwrap(asset.pageURL)
        XCTAssertTrue(pageURL.isTranscriptURL)
        XCTAssertTrue(pageURL.isTranscriptPageURL)
        XCTAssertEqual(pageURL.transcriptAssetKey, asset.key)
        XCTAssertEqual(pageURL.transcriptContentURL?.absoluteString, contentURL.absoluteString)

        let loaded = try await ReaderContentLoader.load(url: pageURL, persist: false)
        let content = try XCTUnwrap(loaded)
        let historyRecord = try XCTUnwrap(content as? HistoryRecord)
        XCTAssertEqual(content.url.absoluteString, pageURL.absoluteString)
        XCTAssertEqual(content.title, asset.title)
        XCTAssertEqual(historyRecord.sourceDownloadURL?.absoluteString, contentURL.absoluteString)
        XCTAssertTrue(content.rssContainsFullContent)
        XCTAssertTrue(content.isReaderModeByDefault)
        XCTAssertEqual(content.html, asset.html)

        let vttURL = try XCTUnwrap(asset.webVTTURL)
        XCTAssertTrue(vttURL.isTranscriptVTTURL)
        let vttData = await TranscriptPageRegistry.shared.webVTTData(for: vttURL)
        XCTAssertEqual(String(decoding: try XCTUnwrap(vttData), as: UTF8.self), asset.webVTT)
    }

    func testTranscriptPageAssetBuildsHTMLFromWebVTT() throws {
        let contentURL = try XCTUnwrap(URL(string: "https://example.com/watch?v=2"))
        let asset = TranscriptPageAsset.fromWebVTT(
            key: "episode-2",
            canonicalContentURL: contentURL,
            title: "Episode 2 Transcript",
            webVTT: """
            WEBVTT

            1
            00:00.000 --> 00:01.250
            Hello <c.voice>world</c>

            2
            00:02.000 --> 00:03.500
            Goodbye
            """
        )

        XCTAssertTrue(asset.html.contains(#"data-manabi-transcript-page="true""#))
        XCTAssertTrue(asset.html.contains(#"id="reader-content""#))
        XCTAssertTrue(asset.html.contains("Hello world"))
        XCTAssertTrue(asset.html.contains(#"data-transcript-start="00:00.000""#))
        XCTAssertTrue(asset.html.contains(#"data-transcript-end="00:03.500""#))
        XCTAssertEqual(TranscriptPageAsset.cues(fromWebVTT: asset.webVTT ?? "").count, 2)
    }

    func testMediaTranscriptRoundTripsCompressedWebVTTAndCanonicalKey() throws {
        let loaderURL = try XCTUnwrap(URL(string: "internal://local/load/reader?reader-url=https%3A%2F%2Fexample.com%2Fwatch%3Fv%3D7%23frag"))
        let mediaURL = try XCTUnwrap(URL(string: "https://cdn.example.com/video/master.m3u8#t=1"))

        let transcript = MediaTranscript()
        transcript.contentURL = MediaTranscript.canonicalContentURL(from: loaderURL)
        transcript.stableMediaIdentity = MediaTranscript.stableMediaIdentity(url: mediaURL)
        transcript.languageCode = "en-CA"
        try transcript.setWebVTT(
            "WEBVTT\n\n00:00.000 --> 00:01.000\nHello world",
            isGenerated: true,
            transcriptLocale: "en-ca",
            sourceDuration: 42
        )

        XCTAssertEqual(
            transcript.compoundKey,
            MediaTranscript.makeCompoundKey(
                contentURL: try XCTUnwrap(URL(string: "https://example.com/watch?v=7")),
                stableMediaIdentity: "url:https://cdn.example.com/video/master.m3u8",
                languageCode: "en-CA"
            )
        )
        XCTAssertEqual(try transcript.webVTTString(), "WEBVTT\n\n00:00.000 --> 00:01.000\nHello world")
        XCTAssertTrue(
            transcript.matchesReuse(
                stableMediaIdentity: "url:https://cdn.example.com/video/master.m3u8",
                languageCode: "en-ca",
                transcriptLocale: "en-ca",
                sourceDuration: 42.4,
                mediaFingerprint: nil
            )
        )
        XCTAssertFalse(
            transcript.matchesReuse(
                stableMediaIdentity: "url:https://cdn.example.com/video/master.m3u8",
                languageCode: "ja",
                transcriptLocale: "ja",
                sourceDuration: 42,
                mediaFingerprint: nil
            )
        )
    }
}
