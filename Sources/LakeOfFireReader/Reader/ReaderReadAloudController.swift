import AVFoundation

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

/// Owns the system speech dependency so read-aloud orchestration can be tested
/// independently from `AVSpeechSynthesizer` timing and installed voices.
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
