import SwiftUI
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore
import SwiftUIWebView
import SwiftSoup
import RealmSwift
import Combine
import RealmSwiftGaps
import WebKit
import AVFoundation
import JapaneseLanguageTools

@inline(__always)
private func mediaDebugPrint(_ values: Any..., separator: String = " ", terminator: String = "\n") {
#if DEBUG
    let output = values.map { String(describing: $0) }.joined(separator: separator)
    Swift.print(output, terminator: terminator)
#endif
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
    @Published public private(set) var ttsPlaybackCompletionGeneration: Int = 0
    @Published public private(set) var readAloudPreparationState: ReaderReadAloudPreparationState = .idle
    @Published public private(set) var playbackFailure: ReaderPlaybackFailure?
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
    private var readAloudAudioSessionLease: ManabiSpokenAudioSessionLease?
    private var ttsVoiceLanguage = "ja-JP"
    private var ignoresCancellationCallbacksForQueueSwap = false
    private var readAloudPreparationID: UUID?
    private var nextAITTSUtteranceIndexToEnqueue = 0
    private let aittsQueueWindowSize = 8
    private var shouldResumeAITTSAfterAudioInterruption = false
    private var didPublishCompletionForCurrentQueue = false
    private static let readAloudPositionsKey = "readerReadAloudPlaybackPositions"

    public override convenience init() {
        self.init(readAloudController: ReaderReadAloudController())
    }

    init(readAloudController: ReaderReadAloudController) {
        self.readAloudController = readAloudController
        super.init()
        readAloudController.delegate = self
#if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
#endif
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public var hasAnyPlayableMedia: Bool {
        !audioURLs.isEmpty || hasPreparedAITTS
    }

    public var hasRecordedAudio: Bool {
        !audioURLs.isEmpty
    }

    public var isPreparingReadAloud: Bool {
        readAloudPreparationState == .preparing
    }

    public var readAloudErrorMessage: String? {
        guard case let .failed(message) = readAloudPreparationState else { return nil }
        return message
    }

    public var playbackErrorMessage: String? {
        playbackFailure?.message
    }

    @MainActor
    public func beginReadAloudPreparation() -> UUID? {
        guard !isPreparingReadAloud else { return nil }
        let id = UUID()
        readAloudPreparationID = id
        readAloudPreparationState = .preparing
        return id
    }

    public func isCurrentReadAloudPreparation(_ id: UUID) -> Bool {
        readAloudPreparationID == id && isPreparingReadAloud
    }

    @MainActor
    public func completeReadAloudPreparation(_ id: UUID) {
        guard readAloudPreparationID == id else { return }
        readAloudPreparationID = nil
        readAloudPreparationState = .idle
    }

    @MainActor
    public func failReadAloudPreparation(_ id: UUID, message: String) {
        guard readAloudPreparationID == id else { return }
        readAloudPreparationID = nil
        readAloudPreparationState = .failed(message)
    }

    @MainActor
    public func cancelReadAloudPreparation() {
        readAloudPreparationID = nil
        readAloudPreparationState = .idle
    }

    @MainActor
    public func dismissReadAloudError() {
        guard readAloudErrorMessage != nil else { return }
        readAloudPreparationState = .idle
    }

    @MainActor
    public func reportPlaybackFailure(_ failure: ReaderPlaybackFailure) {
        playbackFailure = failure
    }

    @MainActor
    public func reportPlaybackError(_ message: String) {
        playbackFailure = playbackSource == .aiTextToSpeech
            ? .readAloudContinuation(message)
            : .recordedAudio(message)
    }

    @MainActor
    public func dismissPlaybackError() {
        playbackFailure = nil
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
        if !newState.pageURL.isNativeReaderView, newState.pageURL.host != nil, !newState.pageURL.isFileURL {
            if voiceAudioURLs != audioURLs {
                audioURLs = voiceAudioURLs
            }
            if !voiceAudioURLs.isEmpty && content.autoOpenMediaPlayer {
#if DEBUG
                if !isMediaPlayerPresented {
                }
#endif
                isMediaPlayerPresented = true
            } else if playbackSource == .recordedAudio, isMediaPlayerPresented {
                cancelAutoplayRequest(reason: "navigation.noRecordedAudio")
                isMediaPlayerPresented = false
            }
        } else if newState.pageURL.isNativeReaderView {
            Task { @MainActor [weak self] in
                try Task.checkCancellation()
                guard let self = self else { return }
                if self.isMediaPlayerPresented {
                    self.isMediaPlayerPresented = false
                }
                if voiceAudioURLs != audioURLs {
                    audioURLs = voiceAudioURLs
                }
                self.stopAITTSPlayback(clearQueue: true)
            }
        }
    }

    @MainActor
    public func requestAutoplay() {
        let token = UUID()
        autoplayRequestToken = token
        mediaDebugPrint(
            "# READALOUD autoplay.request",
            "source=\(playbackSource.rawValue)",
            "token=\(token.uuidString)"
        )
    }

    @MainActor
    public func cancelAutoplayRequest(reason: String) {
        guard let token = autoplayRequestToken else { return }
        autoplayRequestToken = nil
        mediaDebugPrint(
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
        mediaDebugPrint(
            "# READALOUD autoplay.consume",
            "source=\(playbackSource.rawValue)",
            "token=\(token.uuidString)",
            "didMatch=\(didMatch)"
        )
        return didMatch
    }

    @MainActor
    public func presentRecordedAudio(autoplay: Bool) {
        mediaDebugPrint(
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
    public func transitionToRecordedAudioPresentation(reason: String) {
        if autoplayRequestToken != nil {
            cancelAutoplayRequest(reason: "recordedTransition.\(reason)")
        }
        if playbackSource != .recordedAudio {
            stopAITTSIfNeeded()
        }
        playbackSource = .recordedAudio
        isMediaPlayerPresented = true
        mediaDebugPrint(
            "# READALOUD present.recorded.transition",
            "reason=\(reason)",
            "hasRecordedAudio=\(hasRecordedAudio)",
            "hasPreparedAITTS=\(hasPreparedAITTS)"
        )
    }

    @MainActor
    public func transitionToReadAloudPresentation() {
        cancelAutoplayRequest(reason: "readAloudTransition")
        playbackSource = .aiTextToSpeech
        isMediaPlayerPresented = true
        playbackFailure = nil
    }

    @MainActor
    public func closePlaybackPresentation() {
        cancelAutoplayRequest(reason: "closePlaybackPresentation")
        if playbackSource == .aiTextToSpeech {
            stopAITTSIfNeeded()
        }
        isPlaying = false
        isMediaPlayerPresented = false
    }

    @MainActor
    public func pauseReadAloudForBackgroundIfNeeded() {
        shouldResumeAITTSAfterAudioInterruption = false
        guard playbackSource == .aiTextToSpeech else { return }
        if isPlaying || readAloudController.isSpeaking {
            pauseAITTS()
        }
        isPlaying = false
    }

    @MainActor
    public func persistAutoOpenMediaPlayerIfNeeded() {
        guard let currentContentURL else { return }
        Task { @RealmBackgroundActor in
            do {
                try await ReaderContentLoader.updateContent(url: currentContentURL) { object in
                    guard !object.autoOpenMediaPlayer else { return false }
                    object.autoOpenMediaPlayer = true
                    return true
                }
            } catch {
            }
        }
    }

    @MainActor
    @discardableResult
    public func presentAITTS(
        utterances: [ReaderTTSUtterance],
        preferredLanguage: String = "ja-JP",
        ebookSectionIndex: Int? = nil,
        autoplay: Bool
    ) -> Bool {
        mediaDebugPrint(
            "# READALOUD present.ai",
            "incomingUtteranceCount=\(utterances.count)",
            "preferredLanguage=\(preferredLanguage)",
            "autoplay=\(autoplay)"
        )
        guard configureAITTSQueue(utterances: utterances, preferredLanguage: preferredLanguage) else {
            mediaDebugPrint("# READALOUD present.ai.rejected", "reason=queueConfigurationFailed")
            return false
        }
        transitionToReadAloudPresentation()
        ttsPreparedEbookSectionIndex = ebookSectionIndex
        restoreReadAloudPositionIfAvailable()
        if autoplay {
            mediaDebugPrint("# LISTEN ai.autoplay.direct")
            playAITTS()
        }
        mediaDebugPrint(
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
            mediaDebugPrint(
                "# READALOUD ai.queue.invalid",
                "incomingUtteranceCount=\(utterances.count)",
                "normalizedUtteranceCount=\(normalized.count)"
            )
            stopAITTSPlayback(clearQueue: true)
            return false
        }
        stopAITTSPlayback(clearQueue: true)
        ttsQueueGeneration &+= 1
        didPublishCompletionForCurrentQueue = false
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
        mediaDebugPrint(
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
              preparedSectionIndex != sectionIndex
        else { return }
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
            mediaDebugPrint("# READALOUD ai.play.skip", "reason=queueNotPrepared")
            return
        }
        guard !ttsUtterances.isEmpty else {
            mediaDebugPrint("# READALOUD ai.play.skip", "reason=emptyQueue")
            return
        }
        if readAloudController.isPaused {
            activateReadAloudAudioSession()
            guard readAloudController.continueSpeaking() else {
                deactivateReadAloudAudioSession()
                mediaDebugPrint("# READALOUD ai.play.resumeFailed")
                return
            }
            isPlaying = true
            registerPlaybackStart(contentKey: currentContentKey)
            mediaDebugPrint("# READALOUD ai.play.resumed")
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
            mediaDebugPrint("# READALOUD ai.play.restartFromBeginning", "upperBound=\(upperBound)")
        }
        mediaDebugPrint(
            "# READALOUD ai.play.begin",
            "startIndex=\(ttsCurrentUtteranceIndex)",
            "queueCount=\(ttsUtterances.count)"
        )
        beginSpeakingFromCurrentUtterance()
    }

    @MainActor
    public func pauseAITTS() {
        guard readAloudController.isSpeaking else {
            mediaDebugPrint("# READALOUD ai.pause.skip", "reason=notSpeaking")
            return
        }
        guard readAloudController.pauseSpeaking(at: .immediate) else {
            mediaDebugPrint("# READALOUD ai.pause.failed")
            return
        }
        isPlaying = false
        persistReadAloudPosition()
        deactivateReadAloudAudioSession()
        mediaDebugPrint("# READALOUD ai.pause")
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
        persistReadAloudPosition()

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
        clearPersistedReadAloudPosition()
    }

    @MainActor
    private func beginSpeakingFromCurrentUtterance() {
        guard !ttsUtterances.isEmpty else { return }
        let startIndex = min(max(ttsCurrentUtteranceIndex, 0), ttsUtterances.count - 1)
        ttsCurrentUtteranceIndex = startIndex
        ttsCurrentCharacterRange = nil
        ttsUtteranceObjectIdentifierToIndex.removeAll(keepingCapacity: true)

        stopAITTSSynthesizerForQueueSwap()
        activateReadAloudAudioSession()

        guard shouldEnqueueSpeechSynthesizerUtterances else {
            isPlaying = true
            registerPlaybackStart(contentKey: currentContentKey)
            updateAITTSProgress()
            mediaDebugPrint(
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
        let hasMissingVoice = configuredReadAloudVoice() == nil
        fillAITTSQueueWindow()

        isPlaying = true
        registerPlaybackStart(contentKey: currentContentKey)
        updateAITTSProgress()
        persistReadAloudPosition()
        mediaDebugPrint(
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
            didPublishCompletionForCurrentQueue = false
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
            // AVSpeechSynthesizer reports NSRange values in UTF-16 code units.
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

    private var readAloudPositionStorageKey: String? {
        guard let currentContentKey else { return nil }
        let sectionComponent = ttsPreparedEbookSectionIndex.map(String.init) ?? "article"
        return "\(currentContentKey)|\(sectionComponent)"
    }

    private func persistReadAloudPosition() {
        guard let storageKey = readAloudPositionStorageKey, hasPreparedAITTS else { return }
        var positions = UserDefaults.standard.dictionary(forKey: Self.readAloudPositionsKey) ?? [:]
        positions[storageKey] = ttsProgressValue
        UserDefaults.standard.set(positions, forKey: Self.readAloudPositionsKey)
    }

    private func restoreReadAloudPositionIfAvailable() {
        guard let storageKey = readAloudPositionStorageKey,
              let number = UserDefaults.standard.dictionary(forKey: Self.readAloudPositionsKey)?[storageKey] as? NSNumber,
              !ttsUtterances.isEmpty
        else { return }
        let index = min(max(Int(floor(number.doubleValue)), 0), ttsUtterances.count - 1)
        ttsCurrentUtteranceIndex = index
        ttsCurrentCharacterRange = nil
        ttsCurrentSentenceIdentifier = ttsUtterances[index].sentenceIdentifier
        ttsCurrentSentenceText = ttsUtterances[index].text
        updateAITTSProgress()
    }

    private func clearPersistedReadAloudPosition() {
        guard let storageKey = readAloudPositionStorageKey else { return }
        var positions = UserDefaults.standard.dictionary(forKey: Self.readAloudPositionsKey) ?? [:]
        positions.removeValue(forKey: storageKey)
        UserDefaults.standard.set(positions, forKey: Self.readAloudPositionsKey)
    }

    @MainActor
    private func stopAITTSSynthesizerForQueueSwap() {
        ignoresCancellationCallbacksForQueueSwap = readAloudController.stopSpeaking(at: .immediate)
    }

    @MainActor
    private func fillAITTSQueueWindow() {
        while ttsUtteranceObjectIdentifierToIndex.count < aittsQueueWindowSize,
              nextAITTSUtteranceIndexToEnqueue < ttsUtterances.count {
            let index = nextAITTSUtteranceIndexToEnqueue
            nextAITTSUtteranceIndexToEnqueue += 1
            let item = ttsUtterances[index]
            let speechUtterance = AVSpeechUtterance(string: item.text)
            speechUtterance.voice = configuredReadAloudVoice()
            speechUtterance.rate = configuredReadAloudRate()
            ttsUtteranceObjectIdentifierToIndex[ObjectIdentifier(speechUtterance)] = index
            readAloudController.speak(speechUtterance)
        }
    }

    private func configuredReadAloudVoice() -> AVSpeechSynthesisVoice? {
        let selectedIdentifier = UserDefaults.standard.string(
            forKey: ReaderReadAloudSettings.voiceIdentifierKey
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let languageCode = ttsVoiceLanguage.split(separator: "-").first?.lowercased() ?? ""
        if !selectedIdentifier.isEmpty,
           let selectedVoice = AVSpeechSynthesisVoice(identifier: selectedIdentifier),
           selectedVoice.language.split(separator: "-").first?.lowercased() == languageCode {
            return selectedVoice
        }
        if let exactVoice = AVSpeechSynthesisVoice(language: ttsVoiceLanguage) {
            return exactVoice
        }
        return AVSpeechSynthesisVoice.speechVoices().first { voice in
            voice.language.split(separator: "-").first?.lowercased() == languageCode
        }
    }

    private func configuredReadAloudRate() -> Float {
        let defaults = UserDefaults.standard
        let storedRate = defaults.object(forKey: ReaderReadAloudSettings.rateKey) == nil
            ? ReaderReadAloudSettings.defaultRate
            : defaults.double(forKey: ReaderReadAloudSettings.rateKey)
        return Float(min(
            max(storedRate, ReaderReadAloudSettings.supportedRateRange.lowerBound),
            ReaderReadAloudSettings.supportedRateRange.upperBound
        ))
    }

    private func activateReadAloudAudioSession() {
#if os(iOS)
        guard readAloudAudioSessionLease == nil else { return }
        do {
            readAloudAudioSessionLease = try ManabiSpokenAudioSession.acquire(.readAloud)
        } catch {
            mediaDebugPrint("# READALOUD audioSession.activate.failed", error.localizedDescription)
        }
#endif
    }

    private func deactivateReadAloudAudioSession() {
#if os(iOS)
        do {
            try readAloudAudioSessionLease?.release()
            readAloudAudioSessionLease = nil
        } catch {
            mediaDebugPrint("# READALOUD audioSession.deactivate.failed", error.localizedDescription)
        }
#endif
    }

#if os(iOS)
    @objc nonisolated private func handleAudioSessionInterruption(_ notification: Notification) {
        let typeRawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        let optionsRawValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        Task { @MainActor [weak self] in
            guard let self, self.playbackSource == .aiTextToSpeech,
                  let typeRawValue,
                  let type = AVAudioSession.InterruptionType(rawValue: typeRawValue)
            else { return }
            switch type {
            case .began:
                self.shouldResumeAITTSAfterAudioInterruption = self.isPlaying
                self.pauseAITTS()
                self.isPlaying = false
            case .ended:
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRawValue).contains(.shouldResume)
                    && self.shouldResumeAITTSAfterAudioInterruption
                self.shouldResumeAITTSAfterAudioInterruption = false
                if shouldResume {
                    self.playAITTS()
                }
            @unknown default:
                self.shouldResumeAITTSAfterAudioInterruption = false
            }
        }
    }

    @objc nonisolated private func handleAudioSessionRouteChange(_ notification: Notification) {
        let reasonRawValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        Task { @MainActor [weak self] in
            guard let self, self.playbackSource == .aiTextToSpeech,
                  let reasonRawValue,
                  AVAudioSession.RouteChangeReason(rawValue: reasonRawValue) == .oldDeviceUnavailable
            else { return }
            self.pauseAITTS()
            self.isPlaying = false
        }
    }
#endif

    @MainActor
    private func resetPlaybackStateForIncomingContent() {
        hasStartedPlaybackForCurrentContent = false
        isTemporarilySuspendedForLoading = false
        playbackFailure = nil
        playbackSource = .recordedAudio
        autoplayRequestToken = nil
        cancelReadAloudPreparation()
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
        persistReadAloudPosition()
        mediaDebugPrint(
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
        mediaDebugPrint("# READALOUD ai.delegate.didPause")
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        guard ttsUtteranceObjectIdentifierToIndex[ObjectIdentifier(utterance)] != nil else { return }
        isPlaying = true
        registerPlaybackStart(contentKey: currentContentKey)
        mediaDebugPrint("# READALOUD ai.delegate.didContinue")
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        guard let index = ttsUtteranceObjectIdentifierToIndex[key] else { return }
        ttsUtteranceObjectIdentifierToIndex.removeValue(forKey: key)
        fillAITTSQueueWindow()
        if index >= (ttsUtterances.count - 1) {
            ttsCurrentUtteranceIndex = max(ttsUtterances.count - 1, 0)
            ttsCurrentCharacterRange = NSRange(location: utterance.speechString.count, length: 0)
            updateAITTSProgress(forceEndOfUtterance: true)
            isPlaying = false
            deactivateReadAloudAudioSession()
            if !didPublishCompletionForCurrentQueue {
                clearPersistedReadAloudPosition()
                didPublishCompletionForCurrentQueue = true
                ttsPlaybackCompletionGeneration &+= 1
            }
        } else {
            ttsCurrentUtteranceIndex = index + 1
            ttsCurrentCharacterRange = nil
            updateAITTSProgress()
        }
        mediaDebugPrint(
            "# READALOUD ai.delegate.didFinish",
            "index=\(index)",
            "remainingQueued=\(ttsUtteranceObjectIdentifierToIndex.count)",
            "isSpeaking=\(synthesizer.isSpeaking)"
        )
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        guard ttsUtteranceObjectIdentifierToIndex[key] != nil else {
            return
        }
        ttsUtteranceObjectIdentifierToIndex.removeValue(forKey: key)
        if ignoresCancellationCallbacksForQueueSwap {
            ignoresCancellationCallbacksForQueueSwap = false
            mediaDebugPrint("# READALOUD ai.delegate.didCancel", "reason=queueSwap")
            return
        }
        if !synthesizer.isSpeaking && !synthesizer.isPaused {
            isPlaying = false
        }
        mediaDebugPrint(
            "# READALOUD ai.delegate.didCancel",
            "remainingQueued=\(ttsUtteranceObjectIdentifierToIndex.count)",
            "isSpeaking=\(synthesizer.isSpeaking)"
        )
    }
}
