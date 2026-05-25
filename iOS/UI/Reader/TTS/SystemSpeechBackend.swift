//
//  SystemSpeechBackend.swift
//  Aidoku
//

import AVFoundation

/// `SpeechSynthesisBackend` backed by `AVSpeechSynthesizer`. Always available,
/// no download. Wraps the `SpeechSynthesizing` seam so it stays unit-testable
/// without producing real audio.
@MainActor
final class SystemSpeechBackend: NSObject, SpeechSynthesisBackend {
    let id = "system"
    var displayName: String {
        NSLocalizedString("TTS_BACKEND_SYSTEM", comment: "Apple/system TTS voices")
    }
    var availability: BackendAvailability { .ready }
    weak var delegate: SpeechBackendDelegate?

    private let synthesizer: SpeechSynthesizing
    /// The utterance currently owned by this backend, and its id. Delegate
    /// callbacks are matched on object identity so a late callback from a
    /// stopped-and-replaced utterance is dropped.
    private var currentUtterance: AVSpeechUtterance?
    private var currentUtteranceID = 0

    var isSpeaking: Bool { synthesizer.isSpeaking }
    var isPaused: Bool { synthesizer.isPaused }

    init(synthesizer: SpeechSynthesizing = AVSpeechSynthesizer()) {
        self.synthesizer = synthesizer
        super.init()
        self.synthesizer.speechDelegate = self
    }

    func speak(text: String, voiceID: String?, rate: Float, utteranceID: Int) {
        synthesizer.stopSpeakingNow()
        let utterance = AVSpeechUtterance(string: text)
        if let voiceID, let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
            utterance.voice = voice
        }
        utterance.rate = Self.avRate(forMultiplier: rate)
        currentUtterance = utterance
        currentUtteranceID = utteranceID
        synthesizer.speakUtterance(utterance)
    }

    func stop() {
        currentUtterance = nil
        synthesizer.stopSpeakingNow()
    }

    func pause() { synthesizer.pauseSpeakingNow() }
    func resume() { synthesizer.continueSpeakingNow() }

    var defaultVoiceID: String? {
        AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())?
            .identifier
            ?? AVSpeechSynthesisVoice.speechVoices().first?.identifier
    }

    func availableVoices() -> [SpeechVoice] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            SpeechVoice(
                id: voice.identifier,
                displayName: voice.name,
                language: voice.language,
                quality: Self.quality(for: voice.quality)
            )
        }
    }

    func prepare() async {}

    /// Map a normalized multiplier (1.0 = normal) onto `AVSpeechUtterance.rate`.
    /// AVSpeech's rate curve is non-linear; this linear approximation is good
    /// enough because `WPMCalibrator` absorbs the residual error. Clamped to
    /// the framework's supported range.
    static func avRate(forMultiplier multiplier: Float) -> Float {
        let raw = AVSpeechUtteranceDefaultSpeechRate * multiplier
        return min(
            max(raw, AVSpeechUtteranceMinimumSpeechRate),
            AVSpeechUtteranceMaximumSpeechRate
        )
    }

    private static func quality(
        for quality: AVSpeechSynthesisVoiceQuality
    ) -> SpeechVoiceQuality {
        switch quality {
        case .premium: return .premium
        case .enhanced: return .enhanced
        default: return .standard
        }
    }
}

extension SystemSpeechBackend: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            guard utterance === self.currentUtterance else { return }
            self.delegate?.backendDidStart(utteranceID: self.currentUtteranceID)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            guard utterance === self.currentUtterance else { return }
            let id = self.currentUtteranceID
            self.currentUtterance = nil
            self.delegate?.backendDidFinish(utteranceID: id)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            if utterance === self.currentUtterance { self.currentUtterance = nil }
        }
    }
}
