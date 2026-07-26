import SwiftUI
import SwiftUIWebView
import SwiftSoup
import RealmSwift
import Combine
import RealmSwiftGaps
import WebKit
import AVFoundation
import LakeOfFireContent
import JapaneseLanguageTools

@MainActor
protocol ReaderSpeechSynthesizing: AnyObject {
    var delegate: (any AVSpeechSynthesizerDelegate)? { get set }
    var isSpeaking: Bool { get }
    var isPaused: Bool { get }

    func speak(_ utterance: AVSpeechUtterance)
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool
    func continueSpeaking() -> Bool
}

extension AVSpeechSynthesizer: ReaderSpeechSynthesizing {}

@MainActor
final class ReaderReadAloudController {
    private let synthesizer: any ReaderSpeechSynthesizing

    init(synthesizer: any ReaderSpeechSynthesizing = AVSpeechSynthesizer()) {
        self.synthesizer = synthesizer
    }

    var delegate: (any AVSpeechSynthesizerDelegate)? {
        get { synthesizer.delegate }
        set { synthesizer.delegate = newValue }
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }
    var isPaused: Bool { synthesizer.isPaused }

    func speak(_ utterance: AVSpeechUtterance) {
        synthesizer.speak(utterance)
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        synthesizer.stopSpeaking(at: boundary)
    }

    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        synthesizer.pauseSpeaking(at: boundary)
    }

    func continueSpeaking() -> Bool {
        synthesizer.continueSpeaking()
    }
}

@MainActor
protocol ReaderReadAloudAudioSessionLease: AnyObject {
    func release() throws
}

extension ManabiSpokenAudioSessionLease: ReaderReadAloudAudioSessionLease {}

public enum ReaderPlaybackSource: String, Sendable {
    case recordedAudio
    case aiTextToSpeech
}

public struct ReaderTTSUtterance: Equatable, Sendable {
    public let sentenceIdentifier: String
    public let text: String

    public init(sentenceIdentifier: String, text: String) {
        self.sentenceIdentifier = sentenceIdentifier
        self.text = text
    }
}

public enum AITTSMarkerApplyResultEvaluator {
    public static func didApply(from rawResult: Any?) -> Bool {
        if let boolResult = rawResult as? Bool {
            return boolResult
        }
        if let numberResult = rawResult as? NSNumber {
            return numberResult.boolValue
        }
        return false
    }
}

public enum ReaderTTSProgressEvaluator {
    public static func fraction(text: String, spokenRange: NSRange?) -> Double {
        guard let spokenRange,
              spokenRange.location != NSNotFound,
              spokenRange.location >= 0,
              spokenRange.length >= 0 else { return 0 }
        let textLength = text.utf16.count
        guard textLength > 0 else { return 0 }
        let (sum, overflowed) = spokenRange.location.addingReportingOverflow(spokenRange.length)
        let spokenEnd = min(overflowed ? Int.max : sum, textLength)
        return Double(spokenEnd) / Double(textLength)
    }
}

@MainActor
public class ReaderMediaPlayerViewModel: NSObject, ObservableObject {
    @Published public var isMediaPlayerPresented = false
    @Published public var audioURLs = [URL]()
    @Published public var isPlaying = false
    @Published public private(set) var hasStartedPlaybackForCurrentContent = false
    @Published public var isTemporarilySuspendedForLoading = false
    @Published public private(set) var isRecordedAudioSuspendedForLookup = false
    @Published public private(set) var shouldResumeRecordedAudioAfterLookupDismissal = false
    @Published public private(set) var isAITTSSuspendedForLookup = false
    @Published public private(set) var shouldResumeAITTSAfterLookupDismissal = false
    @Published public var playbackSource: ReaderPlaybackSource = .recordedAudio
    @Published public var autoplayRequestToken: UUID?
    @Published public private(set) var ttsProgressValue: Double = 0
    @Published public private(set) var ttsProgressUpperBound: Double = 1
    @Published public private(set) var ttsCurrentSentenceIdentifier: String?
    @Published public private(set) var ttsCurrentSentenceText: String?
    @Published public private(set) var ttsUtteranceCount: Int = 0
    @Published public private(set) var hasPreparedAITTS = false
    @Published public private(set) var ttsQueueGeneration: Int = 0
    @Published public private(set) var ttsPreparedEbookSectionIndex: Int?

    // Test hook so unit tests can avoid real AVSpeechSynthesizer playback latency.
    var shouldEnqueueSpeechSynthesizerUtterances = true

    private let readAloudController: ReaderReadAloudController
    private var currentContentKey: String?
    private var currentContentURL: URL?
    private var ttsUtterances = [ReaderTTSUtterance]()
    private var ttsSentenceIdentifierToIndex = [String: Int]()
    private var ttsUtteranceObjectIdentifierToIndex = [ObjectIdentifier: Int]()
    private var ttsCurrentUtteranceIndex: Int = 0
    private var ttsCurrentCharacterRange: NSRange?
    private let readAloudAudioSessionLeaseFactory: () throws -> any ReaderReadAloudAudioSessionLease
    private var readAloudAudioSessionLease: (any ReaderReadAloudAudioSessionLease)?
    private var ttsVoiceLanguage = "ja-JP"
    private var nextAITTSUtteranceIndexToEnqueue = 0
    private let aittsQueueWindowSize = 8

    public override convenience init() {
        self.init(readAloudController: ReaderReadAloudController())
    }

    init(
        readAloudController: ReaderReadAloudController,
        readAloudAudioSessionLeaseFactory: @escaping () throws -> any ReaderReadAloudAudioSessionLease = {
            try ManabiSpokenAudioSession.acquire(.readAloud)
        }
    ) {
        self.readAloudController = readAloudController
        self.readAloudAudioSessionLeaseFactory = readAloudAudioSessionLeaseFactory
        super.init()
        readAloudController.delegate = self
    }

    public var hasAnyPlayableMedia: Bool {
        !audioURLs.isEmpty || hasPreparedAITTS
    }

    public var hasRecordedAudio: Bool {
        !audioURLs.isEmpty
    }

    @MainActor
    public func recordLookupRecordedAudioSuspension(wasPlaying: Bool) {
        guard !isRecordedAudioSuspendedForLookup else { return }
        isRecordedAudioSuspendedForLookup = true
        shouldResumeRecordedAudioAfterLookupDismissal = wasPlaying
    }

    @MainActor
    public func consumeLookupRecordedAudioResumeRequest() -> Bool {
        let shouldResume = isRecordedAudioSuspendedForLookup && shouldResumeRecordedAudioAfterLookupDismissal
        isRecordedAudioSuspendedForLookup = false
        shouldResumeRecordedAudioAfterLookupDismissal = false
        return shouldResume
    }

    @MainActor
    public func cancelLookupRecordedAudioSuspension() {
        isRecordedAudioSuspendedForLookup = false
        shouldResumeRecordedAudioAfterLookupDismissal = false
    }

    @MainActor
    public func recordLookupAITTSSuspension(wasPlaying: Bool) {
        guard !isAITTSSuspendedForLookup else { return }
        isAITTSSuspendedForLookup = true
        shouldResumeAITTSAfterLookupDismissal = wasPlaying
    }

    @MainActor
    public func consumeLookupAITTSResumeRequest() -> Bool {
        let shouldResume = isAITTSSuspendedForLookup && shouldResumeAITTSAfterLookupDismissal
        isAITTSSuspendedForLookup = false
        shouldResumeAITTSAfterLookupDismissal = false
        return shouldResume
    }

    @MainActor
    public func cancelLookupAITTSSuspension() {
        isAITTSSuspendedForLookup = false
        shouldResumeAITTSAfterLookupDismissal = false
    }

    public func hasPlayableMediaForCurrentSource(
        contentVoiceAudioURLs: [URL],
        hasLoadedRecordedMedia: Bool,
        currentRecordedMediaURL: URL?
    ) -> Bool {
        switch playbackSource {
        case .recordedAudio:
            return hasLoadedRecordedMedia
                || currentRecordedMediaURL != nil
                || hasRecordedAudio
                || !contentVoiceAudioURLs.isEmpty
        case .aiTextToSpeech:
            return hasPreparedAITTS
        }
    }

    @MainActor
    public func onNavigationCommitted(content: any ReaderContentProtocol, newState: WebViewState) async throws {
        let incomingContentKey = content.compoundKey
        if currentContentKey != incomingContentKey {
            currentContentKey = incomingContentKey
            resetPlaybackStateForIncomingContent()
        }
        currentContentURL = content.url
        let voiceAudioURLs = content.resolvedVoiceAudioURLs
        debugPrint(
            "# MEDIA mediaPlayer.navigation",
            "pageURL=\(newState.pageURL.absoluteString)",
            "contentURL=\(content.url.absoluteString)",
            "contentKey=\(content.compoundKey)",
            "voiceCount=\(voiceAudioURLs.count)",
            "autoOpen=\(content.autoOpenMediaPlayer)",
            "isNativeReaderView=\(newState.pageURL.isNativeReaderView)",
            "playbackSource=\(playbackSource.rawValue)"
        )
#if DEBUG
        debugPrint(
            "# AUDIO ReaderMediaPlayerViewModel.onNavigationCommitted url=\(newState.pageURL.absoluteString) voiceCount=\(voiceAudioURLs.count) host=\(newState.pageURL.host ?? "nil") isReaderMode=\(newState.pageURL.isNativeReaderView)"
        )
#endif
        if !newState.pageURL.isNativeReaderView, newState.pageURL.host != nil, !newState.pageURL.isFileURL {
            if voiceAudioURLs != audioURLs {
#if DEBUG
                debugPrint(
                    "# AUDIO ReaderMediaPlayerViewModel.audioURLsUpdated old=\(audioURLs.map { $0.absoluteString }) new=\(voiceAudioURLs.map { $0.absoluteString })"
                )
#endif
                audioURLs = voiceAudioURLs
            }
            if !voiceAudioURLs.isEmpty && content.autoOpenMediaPlayer {
                debugPrint(
                    "# MEDIA mediaPlayer.autoOpen",
                    "contentURL=\(content.url.absoluteString)",
                    "voiceCount=\(voiceAudioURLs.count)"
                )
#if DEBUG
                if !isMediaPlayerPresented {
                    debugPrint("# AUDIO ReaderMediaPlayerViewModel.presentingNowPlaying reason=navigation voiceCount=\(voiceAudioURLs.count)")
                }
#endif
                isMediaPlayerPresented = true
            } else if playbackSource == .recordedAudio, isMediaPlayerPresented {
#if DEBUG
                debugPrint("# AUDIO ReaderMediaPlayerViewModel.dismissNowPlaying reason=noRecordedAudio")
#endif
                cancelAutoplayRequest(reason: "navigation.noRecordedAudio")
                isMediaPlayerPresented = false
            }
        } else if newState.pageURL.isNativeReaderView {
            Task { @MainActor [weak self] in
                try Task.checkCancellation()
                guard let self = self else { return }
                if self.isMediaPlayerPresented {
#if DEBUG
                    debugPrint("# AUDIO ReaderMediaPlayerViewModel.dismissNowPlaying reason=readerMode")
#endif
                    self.isMediaPlayerPresented = false
                }
                if !audioURLs.isEmpty {
#if DEBUG
                    debugPrint("# AUDIO ReaderMediaPlayerViewModel.audioURLsCleared reason=readerMode")
#endif
                    audioURLs.removeAll()
                }
                self.stopAITTSPlayback(clearQueue: true)
            }
        }
    }

    @MainActor
    public func requestAutoplay() {
        let token = UUID()
        autoplayRequestToken = token
        debugPrint(
            "# READALOUD autoplay.request",
            "source=\(playbackSource.rawValue)",
            "token=\(token.uuidString)"
        )
    }

    @MainActor
    public func cancelAutoplayRequest(reason: String) {
        guard let token = autoplayRequestToken else { return }
        autoplayRequestToken = nil
        debugPrint(
            "# READALOUD autoplay.cancel",
            "source=\(playbackSource.rawValue)",
            "token=\(token.uuidString)",
            "reason=\(reason)"
        )
    }

    @MainActor
    @discardableResult
    public func consumeAutoplayRequestIfMatches(_ token: UUID) -> Bool {
        let didMatch = autoplayRequestToken == token
        if didMatch {
            autoplayRequestToken = nil
        }
        debugPrint(
            "# READALOUD autoplay.consume",
            "source=\(playbackSource.rawValue)",
            "token=\(token.uuidString)",
            "didMatch=\(didMatch)"
        )
        return didMatch
    }

    @MainActor
    public func presentRecordedAudio(autoplay: Bool) {
        debugPrint(
            "# MEDIA mediaPlayer.presentRecordedAudio",
            "autoplay=\(autoplay)",
            "hasRecordedAudio=\(hasRecordedAudio)",
            "audioURLCount=\(audioURLs.count)",
            "contentURL=\(currentContentURL?.absoluteString ?? "nil")"
        )
        debugPrint(
            "# READALOUD present.recorded",
            "autoplay=\(autoplay)",
            "hasRecordedAudio=\(hasRecordedAudio)"
        )
        transitionToRecordedAudioPresentation(reason: "presentRecordedAudio")
        persistAutoOpenMediaPlayerIfNeeded()
        if autoplay {
            requestAutoplay()
        }
    }

    @MainActor
    public func persistAutoOpenMediaPlayerIfNeeded() {
        guard let currentContentURL else { return }
        Task { @RealmBackgroundActor in
            do {
                try await ReaderContentLoader.updateContent(url: currentContentURL) { object in
                    guard !object.autoOpenMediaPlayer else { return false }
                    debugPrint(
                        "# MEDIA autoOpen.persist",
                        "contentURL=\(object.url.absoluteString)",
                        "contentType=\(String(describing: type(of: object)))"
                    )
                    object.autoOpenMediaPlayer = true
                    return true
                }
            } catch {
                debugPrint("# AUDIO autoOpenMediaPlayer.persist.error", error.localizedDescription)
            }
        }
    }

    @MainActor
    public func transitionToRecordedAudioPresentation(reason: String) {
        if autoplayRequestToken != nil {
            cancelAutoplayRequest(reason: "recordedTransition.\(reason)")
        }
        if playbackSource != .recordedAudio {
            stopAITTSIfNeeded()
        }
        playbackSource = .recordedAudio
        isMediaPlayerPresented = true
        debugPrint(
            "# READALOUD present.recorded.transition",
            "reason=\(reason)",
            "hasRecordedAudio=\(hasRecordedAudio)",
            "hasPreparedAITTS=\(hasPreparedAITTS)"
        )
    }

    @MainActor
    @discardableResult
    public func presentAITTS(
        utterances: [ReaderTTSUtterance],
        preferredLanguage: String = "ja-JP",
        ebookSectionIndex: Int? = nil,
        autoplay: Bool
    ) -> Bool {
        debugPrint(
            "# READALOUD present.ai",
            "incomingUtteranceCount=\(utterances.count)",
            "preferredLanguage=\(preferredLanguage)",
            "autoplay=\(autoplay)"
        )
        guard configureAITTSQueue(utterances: utterances, preferredLanguage: preferredLanguage) else {
            debugPrint("# READALOUD present.ai.rejected", "reason=queueConfigurationFailed")
            return false
        }
        playbackSource = .aiTextToSpeech
        isMediaPlayerPresented = true
        ttsPreparedEbookSectionIndex = ebookSectionIndex
        if autoplay {
            requestAutoplay()
        }
        debugPrint(
            "# READALOUD present.ai.ready",
            "queueCount=\(ttsUtteranceCount)",
            "source=\(playbackSource.rawValue)"
        )
        return true
    }

    @MainActor
    @discardableResult
    public func configureAITTSQueue(
        utterances: [ReaderTTSUtterance],
        preferredLanguage: String = "ja-JP"
    ) -> Bool {
        var seenSentenceIdentifiers = Set<String>()
        let normalized = utterances.compactMap { utterance -> ReaderTTSUtterance? in
            let trimmedIdentifier = utterance.sentenceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedText = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedIdentifier.isEmpty, !trimmedText.isEmpty else { return nil }
            guard seenSentenceIdentifiers.insert(trimmedIdentifier).inserted else { return nil }
            return ReaderTTSUtterance(sentenceIdentifier: trimmedIdentifier, text: trimmedText)
        }
        guard !normalized.isEmpty else {
            debugPrint(
                "# READALOUD ai.queue.invalid",
                "incomingUtteranceCount=\(utterances.count)",
                "normalizedUtteranceCount=\(normalized.count)"
            )
            stopAITTSPlayback(clearQueue: true)
            return false
        }
        stopAITTSPlayback(clearQueue: true)
        ttsQueueGeneration &+= 1
        ttsUtterances = normalized
        ttsSentenceIdentifierToIndex = Dictionary(
            uniqueKeysWithValues: normalized.enumerated().map { ($0.element.sentenceIdentifier, $0.offset) }
        )
        ttsUtteranceCount = normalized.count
        ttsProgressUpperBound = max(Double(normalized.count), 1)
        ttsVoiceLanguage = preferredLanguage
        hasPreparedAITTS = true
        ttsCurrentUtteranceIndex = 0
        ttsCurrentCharacterRange = nil
        ttsCurrentSentenceIdentifier = normalized.first?.sentenceIdentifier
        ttsCurrentSentenceText = normalized.first?.text
        ttsProgressValue = 0
        debugPrint(
            "# READALOUD ai.queue.ready",
            "utteranceCount=\(normalized.count)",
            "preferredLanguage=\(preferredLanguage)",
            "generation=\(ttsQueueGeneration)"
        )
        return true
    }

    @MainActor
    public func clearAITTSPlaybackQueue() {
        stopAITTSPlayback(clearQueue: true)
    }

    @MainActor
    public func invalidateReadAloudForEbookSectionChange(_ sectionIndex: Int) {
        guard playbackSource == .aiTextToSpeech,
              let preparedSectionIndex = ttsPreparedEbookSectionIndex,
              preparedSectionIndex != sectionIndex else {
            return
        }
        stopAITTSPlayback(clearQueue: true)
        isMediaPlayerPresented = false
    }

    @MainActor
    public func toggleAITTSPlayPause() {
        if isPlaying {
            pauseAITTS()
        } else {
            playAITTS()
        }
    }

    @MainActor
    public func playAITTS() {
        guard hasPreparedAITTS else {
            debugPrint("# READALOUD ai.play.skip", "reason=queueNotPrepared")
            return
        }
        guard !ttsUtterances.isEmpty else {
            debugPrint("# READALOUD ai.play.skip", "reason=emptyQueue")
            return
        }
        if readAloudController.isPaused {
            guard activateReadAloudAudioSession() else { return }
            guard readAloudController.continueSpeaking() else {
                deactivateReadAloudAudioSession()
                debugPrint("# READALOUD ai.play.resumeFailed")
                return
            }
            isPlaying = true
            registerPlaybackStart(contentKey: currentContentKey)
            debugPrint("# READALOUD ai.play.resumed")
            return
        }
        let upperBound = max(ttsProgressUpperBound, 1)
        if ttsProgressValue >= (upperBound - 0.0001) {
            ttsCurrentUtteranceIndex = 0
            ttsCurrentCharacterRange = nil
            if let firstUtterance = ttsUtterances.first {
                ttsCurrentSentenceIdentifier = firstUtterance.sentenceIdentifier
                ttsCurrentSentenceText = firstUtterance.text
            }
            updateAITTSProgress()
            debugPrint("# READALOUD ai.play.restartFromBeginning", "upperBound=\(upperBound)")
        }
        debugPrint(
            "# READALOUD ai.play.begin",
            "startIndex=\(ttsCurrentUtteranceIndex)",
            "queueCount=\(ttsUtterances.count)"
        )
        beginSpeakingFromCurrentUtterance()
    }

    @MainActor
    public func pauseAITTS() {
        guard readAloudController.isSpeaking else {
            debugPrint("# READALOUD ai.pause.skip", "reason=notSpeaking")
            return
        }
        guard readAloudController.pauseSpeaking(at: .word) else {
            debugPrint("# READALOUD ai.pause.failed")
            return
        }
        isPlaying = false
        deactivateReadAloudAudioSession()
        debugPrint("# READALOUD ai.pause")
    }

    @MainActor
    public func stopAITTSIfNeeded() {
        stopAITTSPlayback(clearQueue: false)
    }

    @MainActor
    public func seekAITTS(toProgressValue value: Double, shouldPlay: Bool) {
        guard !ttsUtterances.isEmpty else { return }
        let upperBound = max(ttsProgressUpperBound, 1)
        let clamped = min(max(value, 0), upperBound)
        let endScrubEpsilon = 0.001
        if clamped >= (upperBound - endScrubEpsilon) {
            seekAITTSToEnd()
            return
        }
        let boundedIndex = min(max(Int(floor(clamped)), 0), ttsUtterances.count - 1)
        seekAITTS(toUtteranceIndex: boundedIndex, shouldPlay: shouldPlay)
    }

    @MainActor
    public func seekAITTS(toSentenceIdentifier sentenceIdentifier: String, shouldPlay: Bool) {
        guard let index = ttsSentenceIdentifierToIndex[sentenceIdentifier] else { return }
        seekAITTS(toUtteranceIndex: index, shouldPlay: shouldPlay)
    }

    @MainActor
    public func registerPlaybackStart(contentKey: String?) {
        guard let key = contentKey else { return }
        if currentContentKey != key {
            currentContentKey = key
        }
        if !hasStartedPlaybackForCurrentContent {
            hasStartedPlaybackForCurrentContent = true
        }
    }

    @MainActor
    private func seekAITTS(toUtteranceIndex index: Int, shouldPlay: Bool) {
        guard !ttsUtterances.isEmpty else { return }
        let boundedIndex = min(max(index, 0), ttsUtterances.count - 1)
        ttsCurrentUtteranceIndex = boundedIndex
        ttsCurrentCharacterRange = nil
        let utterance = ttsUtterances[boundedIndex]
        ttsCurrentSentenceIdentifier = utterance.sentenceIdentifier
        ttsCurrentSentenceText = utterance.text
        updateAITTSProgress()

        stopAITTSSynthesizerForQueueSwap()

        if shouldPlay {
            beginSpeakingFromCurrentUtterance()
        } else {
            deactivateReadAloudAudioSession()
            isPlaying = false
        }
    }

    @MainActor
    private func seekAITTSToEnd() {
        guard !ttsUtterances.isEmpty else { return }
        let lastIndex = ttsUtterances.count - 1
        ttsCurrentUtteranceIndex = lastIndex
        let utterance = ttsUtterances[lastIndex]
        ttsCurrentSentenceIdentifier = utterance.sentenceIdentifier
        ttsCurrentSentenceText = utterance.text
        ttsCurrentCharacterRange = NSRange(location: utterance.text.utf16.count, length: 0)
        stopAITTSSynthesizerForQueueSwap()
        deactivateReadAloudAudioSession()
        isPlaying = false
        updateAITTSProgress(forceEndOfUtterance: true)
    }

    @MainActor
    private func beginSpeakingFromCurrentUtterance() {
        guard !ttsUtterances.isEmpty else { return }
        let startIndex = min(max(ttsCurrentUtteranceIndex, 0), ttsUtterances.count - 1)
        ttsCurrentUtteranceIndex = startIndex
        ttsCurrentCharacterRange = nil
        ttsUtteranceObjectIdentifierToIndex.removeAll(keepingCapacity: true)

        stopAITTSSynthesizerForQueueSwap()
        guard activateReadAloudAudioSession() else {
            isPlaying = false
            return
        }

        guard shouldEnqueueSpeechSynthesizerUtterances else {
            isPlaying = true
            registerPlaybackStart(contentKey: currentContentKey)
            updateAITTSProgress()
            debugPrint(
                "# READALOUD ai.speak.queued",
                "startIndex=\(startIndex)",
                "queuedCount=\(ttsUtterances.count - startIndex)",
                "language=\(ttsVoiceLanguage)",
                "missingPreferredVoice=false",
                "synthesizerQueueingEnabled=false"
            )
            return
        }

        nextAITTSUtteranceIndexToEnqueue = startIndex
        var hasMissingVoice = false
        let preferredVoice = AVSpeechSynthesisVoice(language: ttsVoiceLanguage)
        if preferredVoice == nil {
            hasMissingVoice = true
        }
        fillAITTSQueueWindow(preferredVoice: preferredVoice)

        isPlaying = true
        registerPlaybackStart(contentKey: currentContentKey)
        updateAITTSProgress()
        debugPrint(
            "# READALOUD ai.speak.queued",
            "startIndex=\(startIndex)",
            "queuedCount=\(ttsUtteranceObjectIdentifierToIndex.count)",
            "language=\(ttsVoiceLanguage)",
            "missingPreferredVoice=\(hasMissingVoice)",
            "synthesizerQueueingEnabled=true"
        )
    }

    @MainActor
    private func stopAITTSPlayback(clearQueue: Bool) {
        stopAITTSSynthesizerForQueueSwap()
        deactivateReadAloudAudioSession()
        isPlaying = false
        ttsUtteranceObjectIdentifierToIndex.removeAll(keepingCapacity: false)
        nextAITTSUtteranceIndexToEnqueue = 0

        if clearQueue {
            ttsUtterances.removeAll()
            ttsSentenceIdentifierToIndex.removeAll()
            ttsUtteranceCount = 0
            ttsCurrentUtteranceIndex = 0
            ttsCurrentCharacterRange = nil
            ttsCurrentSentenceIdentifier = nil
            ttsCurrentSentenceText = nil
            ttsProgressValue = 0
            ttsProgressUpperBound = 1
            hasPreparedAITTS = false
            ttsPreparedEbookSectionIndex = nil
        } else {
            ttsCurrentCharacterRange = nil
            updateAITTSProgress()
        }
    }

    @MainActor
    private func updateAITTSProgress(forceEndOfUtterance: Bool = false) {
        let upperBound = max(Double(ttsUtterances.count), 1)
        ttsProgressUpperBound = upperBound
        guard !ttsUtterances.isEmpty else {
            ttsProgressValue = 0
            return
        }
        let boundedIndex = min(max(ttsCurrentUtteranceIndex, 0), ttsUtterances.count - 1)
        let currentText = ttsUtterances[boundedIndex].text
        let locationFraction: Double
        if forceEndOfUtterance {
            locationFraction = 1
        } else {
            locationFraction = ReaderTTSProgressEvaluator.fraction(
                text: currentText,
                spokenRange: ttsCurrentCharacterRange
            )
        }
        let absoluteProgress = min(Double(boundedIndex) + locationFraction, upperBound)
        ttsProgressValue = absoluteProgress
        ttsCurrentSentenceIdentifier = ttsUtterances[boundedIndex].sentenceIdentifier
        ttsCurrentSentenceText = ttsUtterances[boundedIndex].text
    }

    @MainActor
    private func stopAITTSSynthesizerForQueueSwap() {
        // Remove callbacks' ownership before stopping so synchronous or delayed
        // callbacks from the replaced queue cannot affect the current queue.
        ttsUtteranceObjectIdentifierToIndex.removeAll(keepingCapacity: true)
        _ = readAloudController.stopSpeaking(at: .immediate)
    }

    @MainActor
    private func fillAITTSQueueWindow(preferredVoice: AVSpeechSynthesisVoice? = nil) {
        let voice = preferredVoice ?? AVSpeechSynthesisVoice(language: ttsVoiceLanguage)
        while ttsUtteranceObjectIdentifierToIndex.count < aittsQueueWindowSize,
              nextAITTSUtteranceIndexToEnqueue < ttsUtterances.count {
            let index = nextAITTSUtteranceIndexToEnqueue
            nextAITTSUtteranceIndexToEnqueue += 1
            let item = ttsUtterances[index]
            let speechUtterance = AVSpeechUtterance(string: item.text)
            speechUtterance.voice = voice
            ttsUtteranceObjectIdentifierToIndex[ObjectIdentifier(speechUtterance)] = index
            readAloudController.speak(speechUtterance)
        }
    }

    @MainActor
    @discardableResult
    private func activateReadAloudAudioSession() -> Bool {
        guard readAloudAudioSessionLease == nil else { return true }
        do {
            readAloudAudioSessionLease = try readAloudAudioSessionLeaseFactory()
            return true
        } catch {
            debugPrint("# READALOUD audioSession.activate.failed", error.localizedDescription)
            return false
        }
    }

    @MainActor
    private func deactivateReadAloudAudioSession() {
        guard let lease = readAloudAudioSessionLease else { return }
        readAloudAudioSessionLease = nil
        do {
            try lease.release()
        } catch {
            debugPrint("# READALOUD audioSession.deactivate.failed", error.localizedDescription)
        }
    }

    @MainActor
    private func resetPlaybackStateForIncomingContent() {
        hasStartedPlaybackForCurrentContent = false
        isTemporarilySuspendedForLoading = false
        cancelLookupRecordedAudioSuspension()
        cancelLookupAITTSSuspension()
        playbackSource = .recordedAudio
        autoplayRequestToken = nil
        stopAITTSPlayback(clearQueue: true)
    }
}

@MainActor
extension ReaderMediaPlayerViewModel: @preconcurrency AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard let index = ttsUtteranceObjectIdentifierToIndex[ObjectIdentifier(utterance)] else { return }
        ttsCurrentUtteranceIndex = index
        ttsCurrentCharacterRange = nil
        isPlaying = true
        registerPlaybackStart(contentKey: currentContentKey)
        updateAITTSProgress()
        debugPrint(
            "# READALOUD ai.delegate.didStart",
            "index=\(index)",
            "textLength=\(utterance.speechString.count)"
        )
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        guard let index = ttsUtteranceObjectIdentifierToIndex[ObjectIdentifier(utterance)] else { return }
        ttsCurrentUtteranceIndex = index
        ttsCurrentCharacterRange = characterRange
        isPlaying = true
        registerPlaybackStart(contentKey: currentContentKey)
        updateAITTSProgress()
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        guard ttsUtteranceObjectIdentifierToIndex[ObjectIdentifier(utterance)] != nil else { return }
        isPlaying = false
        debugPrint("# READALOUD ai.delegate.didPause")
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        guard ttsUtteranceObjectIdentifierToIndex[ObjectIdentifier(utterance)] != nil else { return }
        isPlaying = true
        registerPlaybackStart(contentKey: currentContentKey)
        debugPrint("# READALOUD ai.delegate.didContinue")
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        handleSpeechSynthesizerDidFinish(
            utterance,
            synthesizerIsSpeaking: synthesizer.isSpeaking || synthesizer.isPaused
        )
    }

    @MainActor
    func handleSpeechSynthesizerDidFinish(
        _ utterance: AVSpeechUtterance,
        synthesizerIsSpeaking: Bool
    ) {
        let key = ObjectIdentifier(utterance)
        guard let index = ttsUtteranceObjectIdentifierToIndex[key] else { return }
        ttsUtteranceObjectIdentifierToIndex.removeValue(forKey: key)
        fillAITTSQueueWindow()
        if index >= (ttsUtterances.count - 1) {
            ttsCurrentUtteranceIndex = max(ttsUtterances.count - 1, 0)
            ttsCurrentCharacterRange = NSRange(location: utterance.speechString.count, length: 0)
            updateAITTSProgress(forceEndOfUtterance: true)
            if !synthesizerIsSpeaking {
                isPlaying = false
                deactivateReadAloudAudioSession()
            }
        } else {
            ttsCurrentUtteranceIndex = index + 1
            ttsCurrentCharacterRange = nil
            updateAITTSProgress()
        }
        debugPrint(
            "# READALOUD ai.delegate.didFinish",
            "index=\(index)",
            "remainingQueued=\(ttsUtteranceObjectIdentifierToIndex.count)",
            "isSpeaking=\(synthesizerIsSpeaking)"
        )
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        handleSpeechSynthesizerDidCancel(
            utterance,
            synthesizerIsSpeaking: synthesizer.isSpeaking || synthesizer.isPaused
        )
    }

    @MainActor
    func handleSpeechSynthesizerDidCancel(
        _ utterance: AVSpeechUtterance,
        synthesizerIsSpeaking: Bool
    ) {
        let key = ObjectIdentifier(utterance)
        guard ttsUtteranceObjectIdentifierToIndex[key] != nil else {
            return
        }
        ttsUtteranceObjectIdentifierToIndex.removeValue(forKey: key)
        if !synthesizerIsSpeaking {
            isPlaying = false
            deactivateReadAloudAudioSession()
        }
        debugPrint(
            "# READALOUD ai.delegate.didCancel",
            "remainingQueued=\(ttsUtteranceObjectIdentifierToIndex.count)",
            "isSpeaking=\(synthesizerIsSpeaking)"
        )
    }
}
