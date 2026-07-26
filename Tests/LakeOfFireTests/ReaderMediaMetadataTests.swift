import XCTest
import AVFoundation
import RealmSwift
import RealmSwiftGaps
@testable import LakeOfFireContent
@testable import LakeOfFireReader

@MainActor
private final class FakeReaderSpeechSynthesizer: ReaderSpeechSynthesizing {
    var delegate: (any AVSpeechSynthesizerDelegate)?
    var isSpeaking = false
    var isPaused = false
    private(set) var spokenUtterances = [AVSpeechUtterance]()

    func speak(_ utterance: AVSpeechUtterance) {
        spokenUtterances.append(utterance)
        isSpeaking = true
        isPaused = false
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        let wasActive = isSpeaking || isPaused
        isSpeaking = false
        isPaused = false
        return wasActive
    }

    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        guard isSpeaking else { return false }
        isSpeaking = false
        isPaused = true
        return true
    }

    func continueSpeaking() -> Bool {
        guard isPaused else { return false }
        isPaused = false
        isSpeaking = true
        return true
    }
}

@MainActor
private final class FakeReadAloudAudioSessionLease: ReaderReadAloudAudioSessionLease {
    private(set) var releaseCount = 0

    func release() throws {
        releaseCount += 1
    }
}

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
        XCTAssertEqual(subtitleOnlyEntry.contentSubtitleURL, URL(string: "https://example.com/subtitles.vtt")!)

        let mediaSubtitleEntry = FeedEntry()
        mediaSubtitleEntry.audioSubtitlesURL = URL(string: "https://example.com/media-subtitles.vtt")!
        mediaSubtitleEntry.audioSubtitlesRoleRawValue = AudioSubtitlesRole.media.rawValue
        XCTAssertFalse(mediaSubtitleEntry.hasContentAudio)
        XCTAssertNil(mediaSubtitleEntry.contentSubtitleURL)
        XCTAssertEqual(mediaSubtitleEntry.mediaSubtitleURL, URL(string: "https://example.com/media-subtitles.vtt")!)
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

    @MainActor
    func testBookmarkAndHistoryRecordCopyFeedEntryCollectionMetadata() async throws {
        let configuration = makeRealmConfiguration()
        let previousBookmarkConfiguration = ReaderContentLoader.bookmarkRealmConfiguration
        let previousHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = previousBookmarkConfiguration
            ReaderContentLoader.historyRealmConfiguration = previousHistoryConfiguration
        }

        let entry = FeedEntry()
        entry.url = URL(string: "https://example.com/listing")!
        entry.title = "Listing"
        entry.readerContentKind = .contentListing
        entry.feedEntryCollectionKey = "feed|scheme|issue-38"
        entry.feedEntryCollectionScheme = "https://example.com/feed.atom#collections"
        entry.feedEntryCollectionTerm = "issue-38"
        entry.feedEntryCollectionTitle = "Issue 38"
        entry.updateCompoundKey()

        try await entry.addBookmark(realmConfiguration: configuration)
        _ = try await entry.addHistoryRecord(realmConfiguration: configuration, pageURL: entry.url)

        let realm = try await Realm(configuration: configuration)
        let bookmark = try XCTUnwrap(realm.objects(Bookmark.self).first)
        XCTAssertEqual(bookmark.readerContentKind, .contentListing)
        XCTAssertEqual(bookmark.feedEntryCollectionKey, "feed|scheme|issue-38")
        XCTAssertEqual(bookmark.feedEntryCollectionScheme, "https://example.com/feed.atom#collections")
        XCTAssertEqual(bookmark.feedEntryCollectionTerm, "issue-38")
        XCTAssertEqual(bookmark.feedEntryCollectionTitle, "Issue 38")

        let historyRecord = try XCTUnwrap(realm.objects(HistoryRecord.self).first)
        XCTAssertEqual(historyRecord.readerContentKind, .contentListing)
        XCTAssertEqual(historyRecord.feedEntryCollectionKey, "feed|scheme|issue-38")
        XCTAssertEqual(historyRecord.feedEntryCollectionScheme, "https://example.com/feed.atom#collections")
        XCTAssertEqual(historyRecord.feedEntryCollectionTerm, "issue-38")
        XCTAssertEqual(historyRecord.feedEntryCollectionTitle, "Issue 38")
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
    func testAddBookmarkCopiesMediaMetadataForManagedFeedEntry() async throws {
        let configuration = makeRealmConfiguration()
        let previousBookmarkConfiguration = ReaderContentLoader.bookmarkRealmConfiguration
        let previousHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        let previousFeedConfiguration = ReaderContentLoader.feedEntryRealmConfiguration
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = previousBookmarkConfiguration
            ReaderContentLoader.historyRealmConfiguration = previousHistoryConfiguration
            ReaderContentLoader.feedEntryRealmConfiguration = previousFeedConfiguration
        }
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration

        let realm = try await Realm(configuration: configuration)
        let entry = FeedEntry()
        entry.url = URL(string: "https://example.com/articles/test")!
        entry.updateCompoundKey()
        entry.voiceFrameUrl = URL(string: "https://example.com/frame")!
        entry.voiceAudioURL = URL(string: "https://example.com/audio-1.m4a")!
        entry.voiceAudioURLs.append(URL(string: "https://example.com/audio-1.m4a")!)
        entry.voiceAudioURLs.append(URL(string: "https://example.com/audio-2.m4a")!)
        entry.audioSubtitlesURL = URL(string: "https://example.com/subtitles.vtt")!
        entry.audioSubtitlesRoleRawValue = AudioSubtitlesRole.content.rawValue

        try await realm.asyncWrite {
            realm.add(entry, update: .modified)
        }
        let managedEntry = try XCTUnwrap(
            realm.object(ofType: FeedEntry.self, forPrimaryKey: entry.compoundKey)
        )

        try await managedEntry.addBookmark(realmConfiguration: configuration)

        try await realm.asyncRefresh()
        let bookmark = try XCTUnwrap(realm.objects(Bookmark.self).first)
        XCTAssertEqual(bookmark.voiceFrameUrl, entry.voiceFrameUrl)
        XCTAssertEqual(bookmark.voiceAudioURL, entry.voiceAudioURL)
        XCTAssertEqual(
            Array(bookmark.voiceAudioURLs),
            [
                URL(string: "https://example.com/audio-1.m4a")!,
                URL(string: "https://example.com/audio-2.m4a")!,
            ]
        )
        XCTAssertEqual(bookmark.audioSubtitlesURL, entry.audioSubtitlesURL)
        XCTAssertEqual(bookmark.audioSubtitlesRole, .content)
        XCTAssertEqual(bookmark.rssContainsFullContent, false)
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
        entry.url = URL(string: "https://example.com/articles/unmanaged-test")!
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
    func testConsumeAutoplayRequestClearsPendingToken() throws {
        let viewModel = ReaderMediaPlayerViewModel()
        viewModel.playbackSource = .aiTextToSpeech
        viewModel.requestAutoplay()

        let token = try XCTUnwrap(viewModel.autoplayRequestToken)
        XCTAssertTrue(viewModel.consumeAutoplayRequestIfMatches(token))
        XCTAssertNil(viewModel.autoplayRequestToken)
    }

    @MainActor
    func testPresentRecordedAudioSetsPlaybackSourceAndAutoplay() {
        let viewModel = ReaderMediaPlayerViewModel()
        viewModel.playbackSource = .aiTextToSpeech

        viewModel.presentRecordedAudio(autoplay: true)

        XCTAssertEqual(viewModel.playbackSource, .recordedAudio)
        XCTAssertTrue(viewModel.isMediaPlayerPresented)
        XCTAssertNotNil(viewModel.autoplayRequestToken)
    }

    @MainActor
    func testLookupRecordedAudioSuspensionConsumesResumeRequestOnce() {
        let viewModel = ReaderMediaPlayerViewModel()

        viewModel.recordLookupRecordedAudioSuspension(wasPlaying: true)

        XCTAssertTrue(viewModel.isRecordedAudioSuspendedForLookup)
        XCTAssertTrue(viewModel.consumeLookupRecordedAudioResumeRequest())
        XCTAssertFalse(viewModel.isRecordedAudioSuspendedForLookup)
        XCTAssertFalse(viewModel.consumeLookupRecordedAudioResumeRequest())
    }

    @MainActor
    func testLookupRecordedAudioSuspensionDoesNotResumeWhenAudioWasPaused() {
        let viewModel = ReaderMediaPlayerViewModel()

        viewModel.recordLookupRecordedAudioSuspension(wasPlaying: false)

        XCTAssertTrue(viewModel.isRecordedAudioSuspendedForLookup)
        XCTAssertFalse(viewModel.consumeLookupRecordedAudioResumeRequest())
        XCTAssertFalse(viewModel.isRecordedAudioSuspendedForLookup)
    }

    @MainActor
    func testPresentAITTSPreparesQueueWithoutStartingPlayback() {
        let viewModel = ReaderMediaPlayerViewModel()
        viewModel.shouldEnqueueSpeechSynthesizerUtterances = false

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

        XCTAssertEqual(viewModel.playbackSource, .aiTextToSpeech)
        XCTAssertTrue(viewModel.isMediaPlayerPresented)
        XCTAssertTrue(viewModel.hasPreparedAITTS)
        XCTAssertFalse(viewModel.isPlaying)
        XCTAssertEqual(viewModel.ttsUtteranceCount, 2)
    }

    @MainActor
    func testAITTSQueueDeduplicatesSentenceIdentifiersBeforeIndexing() {
        let synthesizer = FakeReaderSpeechSynthesizer()
        let viewModel = ReaderMediaPlayerViewModel(
            readAloudController: ReaderReadAloudController(synthesizer: synthesizer)
        )

        XCTAssertTrue(viewModel.presentAITTS(
            utterances: [
                ReaderTTSUtterance(sentenceIdentifier: "s1", text: "First."),
                ReaderTTSUtterance(sentenceIdentifier: "s1", text: "Duplicate."),
                ReaderTTSUtterance(sentenceIdentifier: "s2", text: "Second."),
            ],
            autoplay: false
        ))

        XCTAssertEqual(viewModel.ttsUtteranceCount, 2)
        viewModel.seekAITTS(toSentenceIdentifier: "s2", shouldPlay: false)
        XCTAssertEqual(viewModel.ttsCurrentSentenceIdentifier, "s2")
        XCTAssertEqual(viewModel.ttsCurrentSentenceText, "Second.")
    }

    @MainActor
    func testAITTSPlaybackKeepsOnlyBoundedUtterancesInFlight() {
        let synthesizer = FakeReaderSpeechSynthesizer()
        let viewModel = ReaderMediaPlayerViewModel(
            readAloudController: ReaderReadAloudController(synthesizer: synthesizer)
        )
        let utterances = (0..<20).map {
            ReaderTTSUtterance(sentenceIdentifier: "s\($0)", text: "Sentence \($0).")
        }

        XCTAssertTrue(viewModel.presentAITTS(utterances: utterances, autoplay: false))
        viewModel.playAITTS()

        XCTAssertEqual(synthesizer.spokenUtterances.count, 8)
    }

    @MainActor
    func testAITTSQueueReplenishesOneUtteranceWhenOneFinishes() throws {
        let synthesizer = FakeReaderSpeechSynthesizer()
        let viewModel = ReaderMediaPlayerViewModel(
            readAloudController: ReaderReadAloudController(synthesizer: synthesizer)
        )
        let utterances = (0..<10).map {
            ReaderTTSUtterance(sentenceIdentifier: "s\($0)", text: "Sentence \($0).")
        }
        XCTAssertTrue(viewModel.presentAITTS(utterances: utterances, autoplay: false))
        viewModel.playAITTS()
        let firstUtterance = try XCTUnwrap(synthesizer.spokenUtterances.first)

        viewModel.handleSpeechSynthesizerDidFinish(
            firstUtterance,
            synthesizerIsSpeaking: synthesizer.isSpeaking
        )

        XCTAssertEqual(synthesizer.spokenUtterances.count, 9)
        XCTAssertEqual(synthesizer.spokenUtterances.last?.speechString, "Sentence 8.")
    }

    @MainActor
    func testAITTSIgnoresStaleCallbacksAfterQueueReplacement() throws {
        let synthesizer = FakeReaderSpeechSynthesizer()
        let viewModel = ReaderMediaPlayerViewModel(
            readAloudController: ReaderReadAloudController(synthesizer: synthesizer)
        )
        XCTAssertTrue(viewModel.presentAITTS(
            utterances: [
                ReaderTTSUtterance(sentenceIdentifier: "old", text: "Old."),
                ReaderTTSUtterance(sentenceIdentifier: "old-2", text: "Old two."),
            ],
            autoplay: false
        ))
        viewModel.playAITTS()
        let staleUtterance = try XCTUnwrap(synthesizer.spokenUtterances.first)

        XCTAssertTrue(viewModel.presentAITTS(
            utterances: [ReaderTTSUtterance(sentenceIdentifier: "new", text: "New.")],
            autoplay: false
        ))
        viewModel.handleSpeechSynthesizerDidFinish(
            staleUtterance,
            synthesizerIsSpeaking: synthesizer.isSpeaking
        )
        viewModel.handleSpeechSynthesizerDidCancel(
            staleUtterance,
            synthesizerIsSpeaking: synthesizer.isSpeaking
        )

        XCTAssertEqual(viewModel.ttsCurrentSentenceIdentifier, "new")
        XCTAssertEqual(viewModel.ttsCurrentSentenceText, "New.")
        XCTAssertFalse(viewModel.isPlaying)
    }

    @MainActor
    func testEbookSectionChangeInvalidatesPreparedReadAloudWithoutAffectingSameSection() {
        let viewModel = ReaderMediaPlayerViewModel()
        XCTAssertTrue(
            viewModel.presentAITTS(
                utterances: [ReaderTTSUtterance(sentenceIdentifier: "s1", text: "One.")],
                preferredLanguage: "en-US",
                ebookSectionIndex: 4,
                autoplay: false
            )
        )

        viewModel.invalidateReadAloudForEbookSectionChange(4)
        XCTAssertTrue(viewModel.hasPreparedAITTS)
        XCTAssertTrue(viewModel.isMediaPlayerPresented)

        viewModel.invalidateReadAloudForEbookSectionChange(5)
        XCTAssertFalse(viewModel.hasPreparedAITTS)
        XCTAssertFalse(viewModel.isMediaPlayerPresented)
    }

    @MainActor
    func testReadAloudAudioSessionLeaseFollowsPlaybackLifecycle() {
        let synthesizer = FakeReaderSpeechSynthesizer()
        let firstLease = FakeReadAloudAudioSessionLease()
        let secondLease = FakeReadAloudAudioSessionLease()
        var leases = [firstLease, secondLease]
        let viewModel = ReaderMediaPlayerViewModel(
            readAloudController: ReaderReadAloudController(synthesizer: synthesizer),
            readAloudAudioSessionLeaseFactory: {
                leases.removeFirst()
            }
        )
        XCTAssertTrue(
            viewModel.presentAITTS(
                utterances: [ReaderTTSUtterance(sentenceIdentifier: "s1", text: "One.")],
                autoplay: false
            )
        )

        viewModel.playAITTS()
        XCTAssertTrue(viewModel.isPlaying)
        XCTAssertEqual(firstLease.releaseCount, 0)

        viewModel.pauseAITTS()
        XCTAssertFalse(viewModel.isPlaying)
        XCTAssertEqual(firstLease.releaseCount, 1)

        viewModel.playAITTS()
        XCTAssertTrue(viewModel.isPlaying)
        XCTAssertEqual(secondLease.releaseCount, 0)

        viewModel.stopAITTSIfNeeded()
        XCTAssertFalse(viewModel.isPlaying)
        XCTAssertEqual(secondLease.releaseCount, 1)
        XCTAssertTrue(viewModel.hasPreparedAITTS)
    }

    @MainActor
    func testReadAloudDoesNotStartWhenAudioSessionLeaseCannotBeAcquired() {
        enum TestError: Error { case rejected }
        let synthesizer = FakeReaderSpeechSynthesizer()
        let viewModel = ReaderMediaPlayerViewModel(
            readAloudController: ReaderReadAloudController(synthesizer: synthesizer),
            readAloudAudioSessionLeaseFactory: {
                throw TestError.rejected
            }
        )
        XCTAssertTrue(
            viewModel.presentAITTS(
                utterances: [ReaderTTSUtterance(sentenceIdentifier: "s1", text: "One.")],
                autoplay: false
            )
        )

        viewModel.playAITTS()

        XCTAssertFalse(viewModel.isPlaying)
        XCTAssertTrue(synthesizer.spokenUtterances.isEmpty)
        XCTAssertTrue(viewModel.hasPreparedAITTS)
    }

    @MainActor
    func testReadAloudReleasesAudioSessionLeaseAfterFinalUtterance() throws {
        let synthesizer = FakeReaderSpeechSynthesizer()
        let lease = FakeReadAloudAudioSessionLease()
        let viewModel = ReaderMediaPlayerViewModel(
            readAloudController: ReaderReadAloudController(synthesizer: synthesizer),
            readAloudAudioSessionLeaseFactory: { lease }
        )
        XCTAssertTrue(
            viewModel.presentAITTS(
                utterances: [ReaderTTSUtterance(sentenceIdentifier: "s1", text: "One.")],
                autoplay: false
            )
        )
        viewModel.playAITTS()
        let utterance = try XCTUnwrap(synthesizer.spokenUtterances.first)

        viewModel.handleSpeechSynthesizerDidFinish(
            utterance,
            synthesizerIsSpeaking: false
        )

        XCTAssertFalse(viewModel.isPlaying)
        XCTAssertEqual(lease.releaseCount, 1)
    }

    @RealmBackgroundActor
    func testAddHistoryRecordReplacesRecordedAudioAndSubtitles() async throws {
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
        content.audioSubtitlesRoleRawValue = AudioSubtitlesRole.content.rawValue
        try await realm.asyncWrite {
            realm.add(content, update: .modified)
        }

        _ = try await content.addHistoryRecord(realmConfiguration: configuration, pageURL: content.url)

        try await realm.asyncWrite {
            content.voiceAudioURL = URL(string: "https://example.com/new-audio-1.m4a")!
            content.voiceAudioURLs.removeAll()
            content.voiceAudioURLs.append(URL(string: "https://example.com/new-audio-1.m4a")!)
            content.voiceAudioURLs.append(URL(string: "https://example.com/new-audio-2.m4a")!)
            content.audioSubtitlesURL = URL(string: "https://example.com/new-subtitles.vtt")!
            content.audioSubtitlesRoleRawValue = AudioSubtitlesRole.content.rawValue
        }

        _ = try await content.addHistoryRecord(realmConfiguration: configuration, pageURL: content.url)

        await realm.asyncRefresh()
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
