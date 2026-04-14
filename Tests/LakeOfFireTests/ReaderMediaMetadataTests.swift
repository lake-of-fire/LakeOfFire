import XCTest
import RealmSwift
import RealmSwiftGaps
@testable import LakeOfFire

final class ReaderMediaMetadataTests: XCTestCase {
    private func makeRealmConfiguration(name: String = UUID().uuidString) -> Realm.Configuration {
        let realmURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
            .appendingPathExtension("realm")
        addTeardownBlock {
            let sidecarExtensions = ["realm", "realm.lock", "realm.management", "realm.note"]
            for ext in sidecarExtensions {
                try? FileManager.default.removeItem(
                    at: realmURL.deletingPathExtension().appendingPathExtension(ext)
                )
            }
        }
        var configuration = Realm.Configuration(fileURL: realmURL)
        configuration.objectTypes = [Bookmark.self, ContentFile.self, HistoryRecord.self, FeedEntry.self]
        return configuration
    }

    func testHasContentAudioRecognizesAudioURLListsAndContentSubtitles() {
        let listOnlyEntry = FeedEntry()
        XCTAssertFalse(listOnlyEntry.hasContentAudio)

        let audioURL = URL(string: "https://example.com/audio-1.m4a")!
        listOnlyEntry.voiceAudioURLs.append(audioURL)
        XCTAssertTrue(listOnlyEntry.hasContentAudio)
        XCTAssertTrue(listOnlyEntry.hasAudio)

        let subtitleOnlyEntry = FeedEntry()
        subtitleOnlyEntry.audioSubtitlesURL = URL(string: "https://example.com/subtitles.vtt")!
        subtitleOnlyEntry.audioSubtitlesRoleRawValue = AudioSubtitlesRole.content.rawValue
        XCTAssertTrue(subtitleOnlyEntry.hasContentAudio)
        XCTAssertEqual(
            subtitleOnlyEntry.contentSubtitleURL,
            URL(string: "https://example.com/subtitles.vtt")!
        )

        let mediaSubtitleEntry = FeedEntry()
        mediaSubtitleEntry.audioSubtitlesURL = URL(string: "https://example.com/media-subtitles.vtt")!
        mediaSubtitleEntry.audioSubtitlesRoleRawValue = AudioSubtitlesRole.media.rawValue
        XCTAssertFalse(mediaSubtitleEntry.hasContentAudio)
        XCTAssertNil(mediaSubtitleEntry.contentSubtitleURL)
    }

    func testCopyReaderMediaStatePromotesFirstListAudioURLAndCopiesSubtitles() {
        let source = FeedEntry()
        let voiceFrameURL = URL(string: "https://example.com/frame")!
        let firstAudioURL = URL(string: "https://example.com/audio-1.m4a")!
        let secondAudioURL = URL(string: "https://example.com/audio-2.m4a")!
        let subtitleURL = URL(string: "https://example.com/subtitles.vtt")!

        source.voiceFrameUrl = voiceFrameURL
        source.voiceAudioURLs.append(firstAudioURL)
        source.voiceAudioURLs.append(secondAudioURL)
        source.audioSubtitlesURL = subtitleURL

        let bookmark = Bookmark()
        source.copyReaderMediaState(
            to: bookmark,
            preservingExistingVoiceAudioURL: false,
            defaultAudioSubtitlesRole: .content
        )

        XCTAssertEqual(bookmark.voiceFrameUrl, voiceFrameURL)
        XCTAssertEqual(bookmark.voiceAudioURL, firstAudioURL)
        XCTAssertEqual(Array(bookmark.voiceAudioURLs), [firstAudioURL, secondAudioURL])
        XCTAssertEqual(bookmark.audioSubtitlesURL, subtitleURL)
        XCTAssertEqual(bookmark.audioSubtitlesRole, .content)
        XCTAssertEqual(bookmark.contentSubtitleURL, subtitleURL)
    }

    func testResolvedVoiceAudioURLsPreservesVoiceAudioURLAndAdditionalListEntries() {
        let entry = FeedEntry()
        let primaryAudioURL = URL(string: "https://example.com/audio-primary.m4a")!
        let fallbackAudioURL = URL(string: "https://example.com/audio-fallback.m4a")!
        let alternateAudioURL = URL(string: "https://example.com/audio-alt.m4a")!

        entry.voiceAudioURL = primaryAudioURL
        entry.voiceAudioURLs.append(fallbackAudioURL)
        entry.voiceAudioURLs.append(alternateAudioURL)

        XCTAssertEqual(
            entry.resolvedVoiceAudioURLs,
            [primaryAudioURL, fallbackAudioURL, alternateAudioURL]
        )
    }

    @MainActor
    func testHasPlayableMediaForCurrentSourceRecognizesResolvedVoiceAudioURLLists() {
        let viewModel = ReaderMediaPlayerViewModel()
        viewModel.playbackSource = .recordedAudio

        XCTAssertTrue(
            viewModel.hasPlayableMediaForCurrentSource(
                contentVoiceAudioURLs: [URL(string: "https://example.com/audio-only-in-list.m4a")!],
                hasLoadedRecordedMedia: false,
                currentRecordedMediaURL: nil
            )
        )
    }

    @MainActor
    func testCancelAutoplayRequestClearsPendingToken() {
        let viewModel = ReaderMediaPlayerViewModel()
        viewModel.playbackSource = .aiTextToSpeech
        viewModel.requestAutoplay()

        XCTAssertNotNil(viewModel.autoplayRequestToken)

        viewModel.cancelAutoplayRequest(reason: "unit-test")

        XCTAssertNil(viewModel.autoplayRequestToken)
    }

    @MainActor
    func testTransitionToRecordedAudioPresentationStopsAITTSAndClearsAutoplay() {
        let viewModel = ReaderMediaPlayerViewModel()
        XCTAssertTrue(
            viewModel.presentAITTS(
                utterances: [
                    ReaderTTSUtterance(sentenceIdentifier: "s1", text: "One."),
                    ReaderTTSUtterance(sentenceIdentifier: "s2", text: "Two."),
                ],
                preferredLanguage: "en-US",
                autoplay: false
            )
        )
        viewModel.requestAutoplay()

        viewModel.transitionToRecordedAudioPresentation(reason: "unit-test")

        XCTAssertEqual(viewModel.playbackSource, .recordedAudio)
        XCTAssertTrue(viewModel.isMediaPlayerPresented)
        XCTAssertNil(viewModel.autoplayRequestToken)
        XCTAssertTrue(viewModel.hasPreparedAITTS)
        XCTAssertFalse(viewModel.isPlaying)
    }

    @MainActor
    func testAddBookmarkCopiesMediaMetadataForUnmanagedContent() async throws {
        let configuration = makeRealmConfiguration()
        let previousBookmarkConfiguration = ReaderContentLoader.bookmarkRealmConfiguration
        let previousHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = previousBookmarkConfiguration
            ReaderContentLoader.historyRealmConfiguration = previousHistoryConfiguration
        }
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration

        let entry = FeedEntry()
        entry.url = URL(string: "https://example.com/articles/test")!
        entry.updateCompoundKey()
        entry.voiceFrameUrl = URL(string: "https://example.com/frame")!
        entry.voiceAudioURLs.append(URL(string: "https://example.com/audio-1.m4a")!)
        entry.voiceAudioURLs.append(URL(string: "https://example.com/audio-2.m4a")!)
        entry.audioSubtitlesURL = URL(string: "https://example.com/subtitles.vtt")!

        try await entry.addBookmark(realmConfiguration: configuration)

        let realm = try await Realm(configuration: configuration)
        let bookmark = try XCTUnwrap(realm.objects(Bookmark.self).first)
        XCTAssertEqual(bookmark.voiceFrameUrl, entry.voiceFrameUrl)
        XCTAssertEqual(bookmark.voiceAudioURL, URL(string: "https://example.com/audio-1.m4a")!)
        XCTAssertEqual(
            Array(bookmark.voiceAudioURLs),
            [
                URL(string: "https://example.com/audio-1.m4a")!,
                URL(string: "https://example.com/audio-2.m4a")!,
            ]
        )
        XCTAssertEqual(bookmark.audioSubtitlesURL, URL(string: "https://example.com/subtitles.vtt")!)
        XCTAssertEqual(bookmark.audioSubtitlesRole, AudioSubtitlesRole.content)
    }

    @RealmBackgroundActor
    func testAddHistoryRecordReplacesStaleVoiceAudioURLLists() async throws {
        let configuration = makeRealmConfiguration()
        let previousBookmarkConfiguration = ReaderContentLoader.bookmarkRealmConfiguration
        let previousHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = previousBookmarkConfiguration
            ReaderContentLoader.historyRealmConfiguration = previousHistoryConfiguration
        }
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration

        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let content = FeedEntry()
        content.url = URL(string: "https://example.com/articles/history")!
        content.updateCompoundKey()
        content.rssContainsFullContent = true
        content.voiceAudioURL = URL(string: "https://example.com/old-audio.m4a")!
        content.voiceAudioURLs.append(URL(string: "https://example.com/old-audio.m4a")!)
        try await realm.asyncWrite {
            realm.add(content, update: .modified)
        }

        _ = try await content.addHistoryRecord(
            realmConfiguration: configuration,
            pageURL: content.url
        )

        try await realm.asyncWrite {
            content.voiceAudioURL = URL(string: "https://example.com/new-audio-1.m4a")!
            content.voiceAudioURLs.removeAll()
            content.voiceAudioURLs.append(URL(string: "https://example.com/new-audio-1.m4a")!)
            content.voiceAudioURLs.append(URL(string: "https://example.com/new-audio-2.m4a")!)
            content.audioSubtitlesURL = URL(string: "https://example.com/new-subtitles.vtt")!
        }

        _ = try await content.addHistoryRecord(
            realmConfiguration: configuration,
            pageURL: content.url
        )

        let historyRecord = try XCTUnwrap(realm.objects(HistoryRecord.self).first)
        XCTAssertEqual(historyRecord.voiceAudioURL, URL(string: "https://example.com/new-audio-1.m4a")!)
        XCTAssertEqual(
            Array(historyRecord.voiceAudioURLs),
            [
                URL(string: "https://example.com/new-audio-1.m4a")!,
                URL(string: "https://example.com/new-audio-2.m4a")!,
            ]
        )
        XCTAssertEqual(historyRecord.audioSubtitlesURL, URL(string: "https://example.com/new-subtitles.vtt")!)
        XCTAssertEqual(historyRecord.audioSubtitlesRole, AudioSubtitlesRole.content)
    }
}
