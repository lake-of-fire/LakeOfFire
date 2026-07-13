import Foundation
import AVFoundation
import LakeOfFireCore

public enum ReaderPlaybackSource: String, Sendable {
    case recordedAudio
    case aiTextToSpeech
}

public enum ReaderPlaybackFailure: Equatable, Identifiable, Sendable {
    case readAloudPreparation(String)
    case readAloudContinuation(String)
    case recordedAudio(String)

    public var id: String {
        switch self {
        case .readAloudPreparation: return "readAloudPreparation"
        case .readAloudContinuation: return "readAloudContinuation"
        case .recordedAudio: return "recordedAudio"
        }
    }

    public var message: String {
        switch self {
        case .readAloudPreparation(let message),
             .readAloudContinuation(let message),
             .recordedAudio(let message):
            return message
        }
    }
}

public enum ReaderReadAloudPreparationState: Equatable, Sendable {
    case idle
    case preparing
    case failed(String)
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
        if let boolResult = rawResult as? Bool { return boolResult }
        if let numberResult = rawResult as? NSNumber { return numberResult.boolValue }
        return false
    }
}

public enum ReaderTTSProgressEvaluator {
    public static func fraction(text: String, spokenRange: NSRange?) -> Double {
        guard let spokenRange else { return 0 }
        let textLength = max(text.utf16.count, 1)
        let spokenEnd = min(max(spokenRange.location + spokenRange.length, 0), textLength)
        return min(max(Double(spokenEnd) / Double(textLength), 0), 1)
    }
}

public enum ReaderReadAloudSettings {
    public static let rateKey = "readAloudSpeechRate"
    public static let voiceIdentifierKey = "readAloudVoiceIdentifier"
    public static let defaultRate = Double(AVSpeechUtteranceDefaultSpeechRate)
    public static let supportedRateRange = 0.35...0.65
}

public enum ReaderReadAloudAvailability {
    public static func isAvailable(
        contentURL: URL?,
        pageURL: URL,
        isReaderModeContent: Bool
    ) -> Bool {
        if pageURL.isEBookURL { return true }
        let resolvedURL = contentURL ?? pageURL
        return !resolvedURL.isNativeReaderView && isReaderModeContent
    }
}

public struct ReaderAudioAvailabilitySnapshot: Equatable, Sendable {
    public let hasRecordedAudio: Bool
    public let canReadAloud: Bool

    public var hasAnyPlayableAudio: Bool { hasRecordedAudio || canReadAloud }

    public init(
        contentURL: URL?,
        pageURL: URL,
        isReaderModeContent: Bool,
        recordedAudioURLs: [URL],
        hasLoadedRecordedMedia: Bool = false,
        currentRecordedMediaURL: URL? = nil
    ) {
        hasRecordedAudio = hasLoadedRecordedMedia
            || currentRecordedMediaURL != nil
            || !recordedAudioURLs.isEmpty
        canReadAloud = ReaderReadAloudAvailability.isAvailable(
            contentURL: contentURL,
            pageURL: pageURL,
            isReaderModeContent: isReaderModeContent
        )
    }
}
