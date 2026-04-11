import XCTest
import RealmSwift
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

    func testSoftDeleteTranscriptsWhenLastOwnerIsDeleted() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/watch?v=cleanup"))
        let (configuration, restoreConfiguration) = try makeReaderContentConfiguration()
        defer { restoreConfiguration() }
        let transcriptCompoundKey = try await MainActor.run { () throws -> String in
            let realm = try Realm(configuration: configuration)
            let bookmark = Bookmark()
            bookmark.url = url
            bookmark.updateCompoundKey()

            let transcript = MediaTranscript()
            transcript.contentURL = MediaTranscript.canonicalContentURL(from: url)
            transcript.stableMediaIdentity = MediaTranscript.stableMediaIdentity(
                url: try XCTUnwrap(URL(string: "https://cdn.example.com/watch.m3u8"))
            )
            transcript.languageCode = "en"
            transcript.updateCompoundKey()
            try transcript.setWebVTT(
                "WEBVTT\n\n00:00.000 --> 00:01.000\nHello world",
                isGenerated: true,
                transcriptLocale: "en",
                sourceDuration: 15
            )

            try realm.write {
                realm.add(bookmark)
                realm.add(transcript)
            }

            try realm.write {
                bookmark.isDeleted = true
            }

            return transcript.compoundKey
        }

        try await ReaderContentLoader.softDeleteTranscriptsIfNoRemainingOwners(contentURL: url)
        let transcriptWasDeleted = try await MainActor.run { () throws -> Bool in
            let realm = try Realm(configuration: configuration)
            realm.refresh()
            let storedTranscript = try XCTUnwrap(
                realm.object(ofType: MediaTranscript.self, forPrimaryKey: transcriptCompoundKey)
            )
            return storedTranscript.isDeleted
        }
        XCTAssertTrue(transcriptWasDeleted)
    }

    func testSoftDeleteTranscriptsKeepsSharedContentWithRemainingOwner() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/watch?v=keep"))
        let (configuration, restoreConfiguration) = try makeReaderContentConfiguration()
        defer { restoreConfiguration() }
        let transcriptCompoundKey = try await MainActor.run { () throws -> String in
            let realm = try Realm(configuration: configuration)

            let bookmark = Bookmark()
            bookmark.url = url
            bookmark.updateCompoundKey()

            let historyRecord = HistoryRecord()
            historyRecord.url = url
            historyRecord.updateCompoundKey()

            let transcript = MediaTranscript()
            transcript.contentURL = MediaTranscript.canonicalContentURL(from: url)
            transcript.stableMediaIdentity = MediaTranscript.stableMediaIdentity(
                url: try XCTUnwrap(URL(string: "https://cdn.example.com/watch.mp4"))
            )
            transcript.languageCode = "en"
            transcript.updateCompoundKey()
            try transcript.setWebVTT(
                "WEBVTT\n\n00:00.000 --> 00:01.000\nStill here",
                isGenerated: false,
                transcriptLocale: "en",
                sourceDuration: 20
            )

            try realm.write {
                realm.add(bookmark)
                realm.add(historyRecord)
                realm.add(transcript)
            }

            try realm.write {
                bookmark.isDeleted = true
            }

            return transcript.compoundKey
        }

        try await ReaderContentLoader.softDeleteTranscriptsIfNoRemainingOwners(contentURL: url)
        let transcriptWasDeleted = try await MainActor.run { () throws -> Bool in
            let realm = try Realm(configuration: configuration)
            realm.refresh()
            let storedTranscript = try XCTUnwrap(
                realm.object(ofType: MediaTranscript.self, forPrimaryKey: transcriptCompoundKey)
            )
            return storedTranscript.isDeleted
        }
        XCTAssertFalse(transcriptWasDeleted)
    }

    private func makeReaderContentConfiguration() throws -> (Realm.Configuration, () -> Void) {
        let originalBookmarkConfiguration = ReaderContentLoader.bookmarkRealmConfiguration
        let originalHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        let originalFeedEntryConfiguration = ReaderContentLoader.feedEntryRealmConfiguration
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LakeOfFireTranscriptTests-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var configuration = Realm.Configuration()
        configuration.fileURL = directoryURL.appendingPathComponent("reader-content.realm")
        configuration.schemaVersion = 1
        configuration.deleteRealmIfMigrationNeeded = true
        configuration.objectTypes = [
            Bookmark.self,
            HistoryRecord.self,
            FeedEntry.self,
            MediaTranscript.self,
        ]
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        return (
            configuration,
            {
                ReaderContentLoader.bookmarkRealmConfiguration = originalBookmarkConfiguration
                ReaderContentLoader.historyRealmConfiguration = originalHistoryConfiguration
                ReaderContentLoader.feedEntryRealmConfiguration = originalFeedEntryConfiguration
                try? FileManager.default.removeItem(at: directoryURL)
            }
        )
    }
}
