//
//  Supertonic3SpeechBackend.swift
//  Aidoku
//

import Foundation
import FluidAudio

/// `SpeechSynthesisBackend` backed by FluidAudio's Supertonic-3 multilingual
/// TTS (Apache 2.0). Gated to iOS 16+. Produces 44.1 kHz mono Float32 audio.
///
/// Unlike Kokoro, Supertonic-3 chunks input text internally — we don't pre-
/// split paragraphs. We hand the entire utterance to the engine and feed the
/// returned PCM into `NeuralAudioPlayer` as a single buffer.
@available(iOS 16, *)
@MainActor
final class Supertonic3SpeechBackend: SpeechSynthesisBackend {
    let id = "supertonic3"
    var displayName: String {
        NSLocalizedString("TTS_BACKEND_SUPERTONIC3", comment: "Supertonic-3 neural TTS engine")
    }
    var availability: BackendAvailability { modelManager.availability }
    weak var delegate: SpeechBackendDelegate?

    private(set) var isSpeaking = false
    private(set) var isPaused = false

    private let modelManager: Supertonic3ModelManager
    private let player: NeuralAudioPlayer
    private var engine: Supertonic3Manager?
    private var engineInitTask: Task<Supertonic3Manager, Error>?
    private var voiceStyleCache: Supertonic3VoiceStyle?
    private var synthesisTask: Task<Void, Never>?
    private var currentUtteranceID: Int?

    /// Voice ID for the single bundled `M1` preset. The voice style JSON ships
    /// inside the app bundle as `Supertonic3_M1.json` (~290 KB).
    private static let defaultVoice = "m1"

    init(modelManager: Supertonic3ModelManager) {
        self.modelManager = modelManager
        self.player = NeuralAudioPlayer()
    }

    init(modelManager: Supertonic3ModelManager, player: NeuralAudioPlayer) {
        self.modelManager = modelManager
        self.player = player
    }

    var defaultVoiceID: String? { Self.defaultVoice }

    /// v1 ships only the `M1` preset (the single voice FluidInference mirrored
    /// to `voice_styles/M1.json`). A curated multi-voice catalog is a fast-
    /// follow once the upstream Supertone v1.7.3 voice library is repackaged
    /// for FluidInference's CoreML repo.
    func availableVoices() -> [SpeechVoice] {
        [SpeechVoice(
            id: Self.defaultVoice,
            displayName: NSLocalizedString("TTS_SUPERTONIC3_VOICE_DEFAULT", comment: "Supertonic-3 default voice"),
            language: "en-US",
            quality: .premium
        )]
    }

    func prepare() async {
        _ = try? await ensureEngine()
    }

    func speak(text: String, voiceID: String?, rate: Float, utteranceID: Int) {
        synthesisTask?.cancel()
        player.stop()
        currentUtteranceID = utteranceID
        isSpeaking = true
        isPaused = false
        guard !text.isEmpty else {
            isSpeaking = false
            delegate?.backendDidFinish(utteranceID: utteranceID)
            return
        }
        synthesisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let engine = try await self.ensureEngine()
                let style = try self.loadVoiceStyle()
                try Task.checkCancellation()
                guard self.currentUtteranceID == utteranceID else { return }
                self.delegate?.backendDidStart(utteranceID: utteranceID)
                let result = try await engine.synthesize(
                    text: text,
                    language: "en",
                    style: style,
                    speed: rate
                )
                try Task.checkCancellation()
                guard self.currentUtteranceID == utteranceID else { return }
                if let buffer = NeuralAudioPlayer.makeBuffer(
                    samples: result.samples,
                    sampleRate: 44_100
                ) {
                    self.player.schedule(buffer)
                    if !self.isPaused {
                        self.player.play()
                    }
                }
                self.player.markEndOfStream { [weak self] in
                    guard let self, self.currentUtteranceID == utteranceID else { return }
                    self.isSpeaking = false
                    self.delegate?.backendDidFinish(utteranceID: utteranceID)
                }
            } catch is CancellationError {
                // Superseded or stopped.
            } catch {
                guard self.currentUtteranceID == utteranceID else { return }
                self.isSpeaking = false
                self.delegate?.backendDidFail(utteranceID: utteranceID, error: error)
            }
        }
    }

    func stop() {
        synthesisTask?.cancel()
        synthesisTask = nil
        player.stop()
        currentUtteranceID = nil
        isSpeaking = false
        isPaused = false
    }

    func pause() {
        player.pause()
        isPaused = true
    }

    func resume() {
        player.play()
        isPaused = false
    }

    /// Lazily build and initialize the Supertonic-3 engine; cached after first
    /// use. Concurrent callers share a single in-flight initialization.
    private func ensureEngine() async throws -> Supertonic3Manager {
        if let engine { return engine }
        if let engineInitTask { return try await engineInitTask.value }
        let task = Task { () throws -> Supertonic3Manager in
            let manager = Supertonic3Manager()
            try await manager.initialize()
            return manager
        }
        engineInitTask = task
        do {
            let manager = try await task.value
            engine = manager
            engineInitTask = nil
            return manager
        } catch {
            engineInitTask = nil
            throw error
        }
    }

    /// Load (and cache) the bundled M1 voice style preset.
    private func loadVoiceStyle() throws -> Supertonic3VoiceStyle {
        if let voiceStyleCache { return voiceStyleCache }
        guard let url = Bundle.main.url(forResource: "Supertonic3_M1", withExtension: "json") else {
            throw NSError(
                domain: "Supertonic3SpeechBackend",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Supertonic3_M1.json is missing from the app bundle"]
            )
        }
        let style = try Supertonic3VoiceStyle.load(from: url)
        voiceStyleCache = style
        return style
    }
}
