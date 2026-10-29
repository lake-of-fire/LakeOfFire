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
    private let synthesizerFactory: () -> any ReaderSpeechSynthesizing
    // Idle playback bookkeeping must not initialize the system speech runtime.
    // Once created (or explicitly injected), keep the same synthesizer.
    private var synthesizer: (any ReaderSpeechSynthesizing)?
    private weak var pendingDelegate: (any AVSpeechSynthesizerDelegate)?

    init(synthesizerFactory: @escaping () -> any ReaderSpeechSynthesizing = { AVSpeechSynthesizer() }) {
        self.synthesizerFactory = synthesizerFactory
    }

    init(synthesizer: any ReaderSpeechSynthesizing) {
        self.synthesizerFactory = { synthesizer }
        self.synthesizer = synthesizer
    }

    var delegate: (any AVSpeechSynthesizerDelegate)? {
        get {
            if let synthesizer { return synthesizer.delegate }
            return pendingDelegate
        }
        set {
            pendingDelegate = newValue
            synthesizer?.delegate = newValue
        }
    }

    var isSpeaking: Bool { synthesizer?.isSpeaking ?? false }
    var isPaused: Bool { synthesizer?.isPaused ?? false }

    func speak(_ utterance: AVSpeechUtterance) {
        if let synthesizer {
            synthesizer.speak(utterance)
        } else {
            let synthesizer = synthesizerFactory()
            synthesizer.delegate = pendingDelegate
            self.synthesizer = synthesizer
            synthesizer.speak(utterance)
        }
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        synthesizer?.stopSpeaking(at: boundary) ?? false
    }

    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        synthesizer?.pauseSpeaking(at: boundary) ?? false
    }

    func continueSpeaking() -> Bool {
        synthesizer?.continueSpeaking() ?? false
    }
}
