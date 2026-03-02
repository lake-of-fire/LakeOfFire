import SwiftUI
import SwiftUIWebView
import SwiftSoup
import RealmSwift
import Combine
import RealmSwiftGaps
import WebKit
import AVFoundation
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent

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

@MainActor
public class ReaderMediaPlayerViewModel: NSObject, ObservableObject {
    @Published public var isMediaPlayerPresented = false
    @Published public var audioURLs = [URL]()
    @Published public var isPlaying = false
    @Published public private(set) var hasStartedPlaybackForCurrentContent = false
    @Published public var isTemporarilySuspendedForLoading = false
    @Published public var playbackSource: ReaderPlaybackSource = .recordedAudio
    @Published public var autoplayRequestToken: UUID?
    @Published public private(set) var ttsProgressValue: Double = 0
    @Published public private(set) var ttsProgressUpperBound: Double = 1
    @Published public private(set) var ttsCurrentSentenceIdentifier: String?
    @Published public private(set) var ttsCurrentSentenceText: String?
    @Published public private(set) var ttsUtteranceCount: Int = 0
    @Published public private(set) var hasPreparedAITTS = false
    @Published public private(set) var ttsQueueGeneration: Int = 0

    private let speechSynthesizer = AVSpeechSynthesizer()
    private var currentContentKey: String?
    private var ttsUtterances = [ReaderTTSUtterance]()
    private var ttsSentenceIdentifierToIndex = [String: Int]()
    private var ttsUtteranceObjectIdentifierToIndex = [ObjectIdentifier: Int]()
    private var ttsCurrentUtteranceIndex: Int = 0
    private var ttsCurrentCharacterRange: NSRange?
    private var ttsVoiceLanguage = "ja-JP"
    private var ignoresCancellationCallbacksForQueueSwap = false

    public override init() {
        super.init()
        speechSynthesizer.delegate = self
    }

    public var hasAnyPlayableMedia: Bool {
        !audioURLs.isEmpty || hasPreparedAITTS
    }

    public var hasRecordedAudio: Bool {
        !audioURLs.isEmpty
    }

    public func hasPlayableMediaForCurrentSource(
        contentVoiceAudioURL: URL?,
        hasLoadedRecordedMedia: Bool,
        currentRecordedMediaURL: URL?
    ) -> Bool {
        switch playbackSource {
        case .recordedAudio:
            return hasLoadedRecordedMedia
                || currentRecordedMediaURL != nil
                || hasRecordedAudio
                || contentVoiceAudioURL != nil
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
        let voiceAudioURLs = content.voiceAudioURL.map { [$0] } ?? []
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
            if !voiceAudioURLs.isEmpty {
#if DEBUG
                if !isMediaPlayerPresented {
                    debugPrint("# AUDIO ReaderMediaPlayerViewModel.presentingNowPlaying reason=navigation voiceCount=\(voiceAudioURLs.count)")
                }
#endif
                isMediaPlayerPresented = true
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
        autoplayRequestToken = UUID()
    }

    @MainActor
    @discardableResult
    public func consumeAutoplayRequestIfMatches(_ token: UUID) -> Bool {
        guard autoplayRequestToken == token else { return false }
        autoplayRequestToken = nil
        return true
    }

    @MainActor
    public func presentRecordedAudio(autoplay: Bool) {
        playbackSource = .recordedAudio
        isMediaPlayerPresented = true
        if autoplay {
            requestAutoplay()
        }
    }

    @MainActor
    @discardableResult
    public func presentAITTS(
        utterances: [ReaderTTSUtterance],
        preferredLanguage: String = "ja-JP",
        autoplay: Bool
    ) -> Bool {
        guard configureAITTSQueue(utterances: utterances, preferredLanguage: preferredLanguage) else {
            return false
        }
        playbackSource = .aiTextToSpeech
        isMediaPlayerPresented = true
        if autoplay {
            requestAutoplay()
        }
        return true
    }

    @MainActor
    @discardableResult
    public func configureAITTSQueue(
        utterances: [ReaderTTSUtterance],
        preferredLanguage: String = "ja-JP"
    ) -> Bool {
        let normalized = utterances.compactMap { utterance -> ReaderTTSUtterance? in
            let trimmedIdentifier = utterance.sentenceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedText = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedIdentifier.isEmpty, !trimmedText.isEmpty else { return nil }
            return ReaderTTSUtterance(sentenceIdentifier: trimmedIdentifier, text: trimmedText)
        }
        guard !normalized.isEmpty else {
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
        return true
    }

    @MainActor
    public func clearAITTSPlaybackQueue() {
        stopAITTSPlayback(clearQueue: true)
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
        guard hasPreparedAITTS else { return }
        guard !ttsUtterances.isEmpty else { return }
        if speechSynthesizer.isPaused {
            guard speechSynthesizer.continueSpeaking() else { return }
            isPlaying = true
            registerPlaybackStart(contentKey: currentContentKey)
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
        }
        beginSpeakingFromCurrentUtterance()
    }

    @MainActor
    public func pauseAITTS() {
        guard speechSynthesizer.isSpeaking else { return }
        guard speechSynthesizer.pauseSpeaking(at: .word) else { return }
        isPlaying = false
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

        if speechSynthesizer.isSpeaking || speechSynthesizer.isPaused {
            ignoresCancellationCallbacksForQueueSwap = true
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        if shouldPlay {
            beginSpeakingFromCurrentUtterance()
        } else {
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
        ttsCurrentCharacterRange = NSRange(location: utterance.text.count, length: 0)
        if speechSynthesizer.isSpeaking || speechSynthesizer.isPaused {
            ignoresCancellationCallbacksForQueueSwap = true
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
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

        if speechSynthesizer.isSpeaking || speechSynthesizer.isPaused {
            ignoresCancellationCallbacksForQueueSwap = true
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        for index in startIndex..<ttsUtterances.count {
            let item = ttsUtterances[index]
            let speechUtterance = AVSpeechUtterance(string: item.text)
            speechUtterance.voice = AVSpeechSynthesisVoice(language: ttsVoiceLanguage)
            ttsUtteranceObjectIdentifierToIndex[ObjectIdentifier(speechUtterance)] = index
            speechSynthesizer.speak(speechUtterance)
        }

        isPlaying = true
        registerPlaybackStart(contentKey: currentContentKey)
        updateAITTSProgress()
    }

    @MainActor
    private func stopAITTSPlayback(clearQueue: Bool) {
        if speechSynthesizer.isSpeaking || speechSynthesizer.isPaused {
            ignoresCancellationCallbacksForQueueSwap = true
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        isPlaying = false
        ttsUtteranceObjectIdentifierToIndex.removeAll(keepingCapacity: false)

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
        } else if let ttsCurrentCharacterRange {
            let textLength = max(currentText.count, 1)
            let spokenEnd = min(max(ttsCurrentCharacterRange.location + ttsCurrentCharacterRange.length, 0), textLength)
            locationFraction = min(max(Double(spokenEnd) / Double(textLength), 0), 1)
        } else {
            locationFraction = 0
        }
        let absoluteProgress = min(Double(boundedIndex) + locationFraction, upperBound)
        ttsProgressValue = absoluteProgress
        ttsCurrentSentenceIdentifier = ttsUtterances[boundedIndex].sentenceIdentifier
        ttsCurrentSentenceText = ttsUtterances[boundedIndex].text
    }

    @MainActor
    private func resetPlaybackStateForIncomingContent() {
        hasStartedPlaybackForCurrentContent = false
        isTemporarilySuspendedForLoading = false
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
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        guard ttsUtteranceObjectIdentifierToIndex[ObjectIdentifier(utterance)] != nil else { return }
        isPlaying = true
        registerPlaybackStart(contentKey: currentContentKey)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        guard let index = ttsUtteranceObjectIdentifierToIndex[key] else { return }
        ttsUtteranceObjectIdentifierToIndex.removeValue(forKey: key)
        if index >= (ttsUtterances.count - 1) {
            ttsCurrentUtteranceIndex = max(ttsUtterances.count - 1, 0)
            ttsCurrentCharacterRange = NSRange(location: utterance.speechString.count, length: 0)
            updateAITTSProgress(forceEndOfUtterance: true)
            if !synthesizer.isSpeaking && !synthesizer.isPaused {
                isPlaying = false
            }
        } else {
            ttsCurrentUtteranceIndex = index + 1
            ttsCurrentCharacterRange = nil
            updateAITTSProgress()
        }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        guard ttsUtteranceObjectIdentifierToIndex[key] != nil else {
            return
        }
        ttsUtteranceObjectIdentifierToIndex.removeValue(forKey: key)
        if ignoresCancellationCallbacksForQueueSwap {
            ignoresCancellationCallbacksForQueueSwap = false
            return
        }
        if !synthesizer.isSpeaking && !synthesizer.isPaused {
            isPlaying = false
        }
    }
}
