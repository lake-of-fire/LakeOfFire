import XCTest
import AVFoundation
import Combine
import RealmSwift
import RealmSwiftGaps
@testable import LakeOfFireContent
@testable import LakeOfFireReader

@MainActor
private final class FakeReaderSpeechSynthesizer: ReaderSpeechSynthesizing {
    weak var delegate: (any AVSpeechSynthesizerDelegate)?
    private(set) weak var delegateAtLastSpeak: (any AVSpeechSynthesizerDelegate)?
    var isSpeaking = false
    var isPaused = false
    private(set) var spokenTexts = [String]()
    private(set) var spokenUtterances = [AVSpeechUtterance]()

    func speak(_ utterance: AVSpeechUtterance) {
        delegateAtLastSpeak = delegate
        spokenTexts.append(utterance.speechString)
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

private final class ReaderSpeechDelegateProbe: NSObject, AVSpeechSynthesizerDelegate {}

final class ReaderMediaMetadataTests: XCTestCase {
    @MainActor
    func testSpeechControllerIdleOperationsAndDelegateChangesDoNotCreateSynthesizer() {
        var factoryCount = 0
        let controller = ReaderReadAloudController(synthesizerFactory: {
            factoryCount += 1
            return FakeReaderSpeechSynthesizer()
        })
        let firstDelegate = ReaderSpeechDelegateProbe()
        let replacementDelegate = ReaderSpeechDelegateProbe()

        XCTAssertNil(controller.delegate)
        controller.delegate = firstDelegate
        XCTAssertTrue(controller.delegate === firstDelegate)
        controller.delegate = replacementDelegate
        XCTAssertTrue(controller.delegate === replacementDelegate)
        controller.delegate = nil
        XCTAssertNil(controller.delegate)
        XCTAssertFalse(controller.isSpeaking)
        XCTAssertFalse(controller.isPaused)
        XCTAssertFalse(controller.stopSpeaking(at: .immediate))
        XCTAssertFalse(controller.pauseSpeaking(at: .immediate))
        XCTAssertFalse(controller.continueSpeaking())
        XCTAssertEqual(factoryCount, 0)
    }

    @MainActor
    func testSpeechControllerFirstSpeakCreatesOnceWithCurrentDelegateAndReusesSynthesizer() {
        let synthesizer = FakeReaderSpeechSynthesizer()
        var factoryCount = 0
        let controller = ReaderReadAloudController(synthesizerFactory: {
            factoryCount += 1
            return synthesizer
        })
        let firstDelegate = ReaderSpeechDelegateProbe()
        let replacementDelegate = ReaderSpeechDelegateProbe()
        controller.delegate = firstDelegate
        controller.delegate = replacementDelegate
        controller.speak(AVSpeechUtterance(string: "One."))

        XCTAssertEqual(factoryCount, 1)
        XCTAssertTrue(synthesizer.delegateAtLastSpeak === replacementDelegate)
        XCTAssertTrue(controller.isSpeaking)
        XCTAssertTrue(controller.pauseSpeaking(at: .immediate))
        XCTAssertTrue(controller.isPaused)
        XCTAssertTrue(controller.continueSpeaking())
        controller.delegate = firstDelegate
        XCTAssertTrue(synthesizer.delegate === firstDelegate)
        controller.speak(AVSpeechUtterance(string: "Two."))
        XCTAssertTrue(synthesizer.delegateAtLastSpeak === firstDelegate)
        controller.delegate = nil
        controller.speak(AVSpeechUtterance(string: "Three."))
        XCTAssertNil(synthesizer.delegateAtLastSpeak)
        XCTAssertTrue(controller.stopSpeaking(at: .immediate))
        controller.speak(AVSpeechUtterance(string: "Four."))
        XCTAssertEqual(synthesizer.spokenTexts, ["One.", "Two.", "Three.", "Four."])
        XCTAssertEqual(factoryCount, 1)
    }

    @MainActor
    func testSpeechControllerDoesNotRetainDelegateBeforeOrAfterCreation() {
        let synthesizer = FakeReaderSpeechSynthesizer()
        var factoryCount = 0
        let controller = ReaderReadAloudController(synthesizerFactory: {
            factoryCount += 1
            return synthesizer
        })
        var delegate: ReaderSpeechDelegateProbe? = ReaderSpeechDelegateProbe()
        weak var releasedDelegate = delegate
        controller.delegate = delegate
        delegate = nil
        XCTAssertNil(releasedDelegate)
        XCTAssertNil(controller.delegate)
        XCTAssertEqual(factoryCount, 0)

        controller.speak(AVSpeechUtterance(string: "One."))
        XCTAssertNil(synthesizer.delegateAtLastSpeak)
        delegate = ReaderSpeechDelegateProbe()
        releasedDelegate = delegate
        controller.delegate = delegate
        delegate = nil
        XCTAssertNil(releasedDelegate)
        XCTAssertNil(controller.delegate)
        XCTAssertNil(synthesizer.delegate)
        XCTAssertEqual(factoryCount, 1)
    }

    @MainActor
    func testSpeechControllerExplicitInjectionUsesExistingSynthesizerAndDelegate() {
        let synthesizer = FakeReaderSpeechSynthesizer()
        let originalDelegate = ReaderSpeechDelegateProbe()
        let replacementDelegate = ReaderSpeechDelegateProbe()
        synthesizer.delegate = originalDelegate
        synthesizer.isSpeaking = true
        let controller = ReaderReadAloudController(synthesizer: synthesizer)

        XCTAssertTrue(controller.delegate === originalDelegate)
        XCTAssertTrue(controller.isSpeaking)
        XCTAssertTrue(controller.pauseSpeaking(at: .immediate))
        XCTAssertTrue(controller.isPaused)
        XCTAssertTrue(controller.continueSpeaking())
        controller.delegate = replacementDelegate
        XCTAssertTrue(synthesizer.delegate === replacementDelegate)
        controller.speak(AVSpeechUtterance(string: "One."))
        XCTAssertTrue(synthesizer.delegateAtLastSpeak === replacementDelegate)
        XCTAssertEqual(synthesizer.spokenTexts, ["One."])
        XCTAssertTrue(controller.stopSpeaking(at: .immediate))
        synthesizer.delegate = originalDelegate
        XCTAssertTrue(controller.delegate === originalDelegate)
    }

    func testAudioAvailabilitySnapshotKeepsRecordedAndReadAloudIndependent() {
        let ebookURL = URL(string: "ebook://book/section.epub")!
        let ebook = ReaderAudioAvailabilitySnapshot(
            contentURL: ebookURL,
            pageURL: ebookURL,
            isReaderModeContent: false,
            recordedAudioURLs: []
        )
        XCTAssertFalse(ebook.hasRecordedAudio)
        XCTAssertTrue(ebook.canReadAloud)
        XCTAssertTrue(ebook.hasAnyPlayableAudio)

        let articleURL = URL(string: "https://example.com/article")!
        let recordedArticle = ReaderAudioAvailabilitySnapshot(
            contentURL: articleURL,
            pageURL: articleURL,
            isReaderModeContent: false,
            recordedAudioURLs: [URL(string: "https://example.com/audio.m4a")!]
        )
        XCTAssertTrue(recordedArticle.hasRecordedAudio)
        XCTAssertFalse(recordedArticle.canReadAloud)
        XCTAssertTrue(recordedArticle.hasAnyPlayableAudio)
    }

    @MainActor
    func testInjectedSpeechControllerMakesReadAloudPlaybackDeterministic() {
        let synthesizer = FakeReaderSpeechSynthesizer()
        let controller = ReaderReadAloudController(synthesizer: synthesizer)
        let viewModel = ReaderMediaPlayerViewModel(readAloudController: controller)

        XCTAssertTrue(viewModel.presentAITTS(
            utterances: [
                ReaderTTSUtterance(sentenceIdentifier: "s1", text: "One."),
                ReaderTTSUtterance(sentenceIdentifier: "s2", text: "Two."),
            ],
            preferredLanguage: "en-US",
            autoplay: true
        ))
        XCTAssertEqual(synthesizer.spokenTexts, ["One.", "Two."])
        XCTAssertTrue(viewModel.isPlaying)

        viewModel.pauseAITTS()
        XCTAssertTrue(synthesizer.isPaused)
        XCTAssertFalse(viewModel.isPlaying)

        viewModel.playAITTS()
        XCTAssertTrue(synthesizer.isSpeaking)
        XCTAssertTrue(viewModel.isPlaying)
    }

    @MainActor
    func testSpeechProgressPublishesOneCoherentChangeAndSkipsIdenticalCallbacks() throws {
        let synthesizer = FakeReaderSpeechSynthesizer()
        let controller = ReaderReadAloudController(synthesizer: synthesizer)
        let viewModel = ReaderMediaPlayerViewModel(readAloudController: controller)

        XCTAssertTrue(viewModel.presentAITTS(
            utterances: [ReaderTTSUtterance(sentenceIdentifier: "s1", text: "One.")],
            preferredLanguage: "en-US",
            autoplay: true
        ))
        let utterance = try XCTUnwrap(synthesizer.spokenUtterances.first)
        var publicationCount = 0
        let cancellable = viewModel.objectWillChange.sink {
            publicationCount += 1
        }

        let spokenRange = NSRange(location: 0, length: 2)
        viewModel.speechSynthesizer(
            AVSpeechSynthesizer(),
            willSpeakRangeOfSpeechString: spokenRange,
            utterance: utterance
        )

        XCTAssertEqual(publicationCount, 1)
        XCTAssertEqual(viewModel.ttsProgressValue, 0.5)
        XCTAssertEqual(viewModel.ttsProgressUpperBound, 1)
        XCTAssertEqual(viewModel.ttsCurrentSentenceIdentifier, "s1")
        XCTAssertEqual(viewModel.ttsCurrentSentenceText, "One.")

        viewModel.speechSynthesizer(
            AVSpeechSynthesizer(),
            willSpeakRangeOfSpeechString: spokenRange,
            utterance: utterance
        )
        XCTAssertEqual(publicationCount, 1)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testReadAloudVoiceResolutionIsReusedAcrossLookupStyleQueueResumes() async {
        let synthesizer = FakeReaderSpeechSynthesizer()
        let controller = ReaderReadAloudController(synthesizer: synthesizer)
        var resolutionCount = 0
        let viewModel = ReaderMediaPlayerViewModel(
            readAloudController: controller,
            readAloudVoiceResolver: { _, _ in
                resolutionCount += 1
                return nil
            }
        )
        let utterances = (1...10).map {
            ReaderTTSUtterance(sentenceIdentifier: "s\($0)", text: "Sentence \($0).")
        }

        XCTAssertTrue(viewModel.presentAITTS(
            utterances: utterances,
            preferredLanguage: "en-US",
            autoplay: true
        ))
        XCTAssertEqual(resolutionCount, 1)

        viewModel.seekAITTS(toSentenceIdentifier: "s4", shouldPlay: false)
        viewModel.playAITTS()
        XCTAssertEqual(resolutionCount, 1)

        NotificationCenter.default.post(
            name: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
            object: nil
        )
        await Task.yield()
        viewModel.seekAITTS(toSentenceIdentifier: "s7", shouldPlay: false)
        viewModel.playAITTS()
        XCTAssertEqual(resolutionCount, 2)
    }

    @MainActor
    func testReadAloudInterruptionResumesOnlyWhenSystemPermitsIt() {
        for permitsResume in [false, true] {
            let synthesizer = FakeReaderSpeechSynthesizer()
            let viewModel = ReaderMediaPlayerViewModel(
                readAloudController: ReaderReadAloudController(synthesizer: synthesizer),
                readAloudVoiceResolver: { _, _ in nil }
            )
            defer { viewModel.stopAITTSIfNeeded() }
            XCTAssertTrue(viewModel.presentAITTS(
                utterances: [ReaderTTSUtterance(sentenceIdentifier: "s1", text: "One.")],
                preferredLanguage: "en-US", autoplay: true
            ))
            viewModel.beginReadAloudAudioInterruption()
            XCTAssertFalse(viewModel.isPlaying)
            XCTAssertTrue(synthesizer.isPaused)
            viewModel.endReadAloudAudioInterruption(permitsResume: permitsResume)
            XCTAssertEqual(viewModel.isPlaying, permitsResume)
            XCTAssertEqual(synthesizer.isSpeaking, permitsResume)
        }
    }

    @MainActor
    func testNewReadAloudIntentRevokesInterruptedPlaybackResume() {
        for action in ["pause", "stop", "seek", "dismiss", "replacement", "background"] {
            let synthesizer = FakeReaderSpeechSynthesizer()
            let viewModel = ReaderMediaPlayerViewModel(
                readAloudController: ReaderReadAloudController(synthesizer: synthesizer),
                readAloudVoiceResolver: { _, _ in nil }
            )
            defer { viewModel.stopAITTSIfNeeded() }
            XCTAssertTrue(viewModel.presentAITTS(
                utterances: [ReaderTTSUtterance(sentenceIdentifier: "s1", text: "One.")],
                preferredLanguage: "en-US", autoplay: true
            ))
            viewModel.beginReadAloudAudioInterruption()
            switch action {
            case "pause": viewModel.pauseAITTS()
            case "stop": viewModel.stopAITTSIfNeeded()
            case "seek": viewModel.seekAITTS(toSentenceIdentifier: "s1", shouldPlay: false)
            case "dismiss": viewModel.isMediaPlayerPresented = false
            case "replacement":
                XCTAssertTrue(viewModel.presentAITTS(
                    utterances: [ReaderTTSUtterance(sentenceIdentifier: "s2", text: "Two.")],
                    preferredLanguage: "en-US", autoplay: false
                ))
            default: viewModel.pauseReadAloudForBackgroundIfNeeded()
            }
            let speechCount = synthesizer.spokenTexts.count
            viewModel.endReadAloudAudioInterruption(permitsResume: true)
            XCTAssertFalse(viewModel.isPlaying, action)
            XCTAssertFalse(synthesizer.isSpeaking, action)
            XCTAssertEqual(synthesizer.spokenTexts.count, speechCount, action)
        }
    }

    private func makeRealmConfiguration(name: String = UUID().uuidString) -> Realm.Configuration {
        let realmURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
            .appendingPathExtension("realm")
        var configuration = Realm.Configuration(fileURL: realmURL)
        configuration.objectTypes = [Bookmark.self, ContentFile.self, HistoryRecord.self, FeedEntry.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let fixtureConfiguration = configuration
        addTeardownBlock {
            await RealmBackgroundActor.shared.removeCachedRealm(for: fixtureConfiguration)
            let sidecarExtensions = ["realm", "realm.lock", "realm.management", "realm.note"]
            for ext in sidecarExtensions {
                try? FileManager.default.removeItem(
                    at: realmURL.deletingPathExtension().appendingPathExtension(ext)
                )
            }
        }
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
    func testClosingReadAloudRetainsPreparedQueueForManualResume() {
        let viewModel = ReaderMediaPlayerViewModel()
        XCTAssertTrue(
            viewModel.presentAITTS(
                utterances: [ReaderTTSUtterance(sentenceIdentifier: "s1", text: "One.")],
                preferredLanguage: "en-US",
                autoplay: false
            )
        )

        viewModel.closePlaybackPresentation()

        XCTAssertFalse(viewModel.isMediaPlayerPresented)
        XCTAssertFalse(viewModel.isPlaying)
        XCTAssertTrue(viewModel.hasPreparedAITTS)
    }

    @MainActor
    func testBackgroundPauseKeepsReadAloudPreparedForManualResume() {
        let viewModel = ReaderMediaPlayerViewModel()
        XCTAssertTrue(
            viewModel.presentAITTS(
                utterances: [ReaderTTSUtterance(sentenceIdentifier: "s1", text: "One.")],
                preferredLanguage: "en-US",
                autoplay: false
            )
        )
        viewModel.isPlaying = true

        viewModel.pauseReadAloudForBackgroundIfNeeded()

        XCTAssertFalse(viewModel.isPlaying)
        XCTAssertTrue(viewModel.hasPreparedAITTS)
        XCTAssertTrue(viewModel.isMediaPlayerPresented)
    }

    @MainActor
    func testSeekingReadAloudToEndClearsSavedResumePosition() {
        let viewModel = ReaderMediaPlayerViewModel()
        viewModel.registerPlaybackStart(contentKey: "read-aloud-end-\(UUID().uuidString)")
        let utterances = [
            ReaderTTSUtterance(sentenceIdentifier: "s1", text: "One."),
            ReaderTTSUtterance(sentenceIdentifier: "s2", text: "Two."),
        ]
        XCTAssertTrue(viewModel.presentAITTS(utterances: utterances, autoplay: false))
        viewModel.seekAITTS(toProgressValue: 1, shouldPlay: false)
        viewModel.seekAITTS(toProgressValue: 2, shouldPlay: false)

        XCTAssertTrue(viewModel.presentAITTS(utterances: utterances, autoplay: false))

        XCTAssertEqual(viewModel.ttsProgressValue, 0)
        XCTAssertEqual(viewModel.ttsCurrentSentenceIdentifier, "s1")
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
