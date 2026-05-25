//
//  KokoroSpeechBackend.swift
//  Aidoku
//

import Foundation
import FluidAudio

/// `SpeechSynthesisBackend` backed by FluidAudio's Kokoro neural TTS. Gated to
/// iOS 16+ — the vendored FluidAudio fork's Kokoro path uses iOS-16 CoreML
/// APIs. Synthesizes a paragraph chunk-by-chunk off the main actor and feeds
/// rendered PCM to a `NeuralAudioPlayer`. One `TTSParagraph` is one logical
/// utterance: `backendDidStart` fires on the first chunk, `backendDidFinish`
/// when the last buffer drains.
@available(iOS 16, *)
@MainActor
final class KokoroSpeechBackend: SpeechSynthesisBackend {
    let id = "kokoro"
    var displayName: String {
        NSLocalizedString("TTS_BACKEND_KOKORO", comment: "Kokoro neural TTS engine")
    }
    var availability: BackendAvailability { modelManager.availability }
    weak var delegate: SpeechBackendDelegate?

    private(set) var isSpeaking = false
    private(set) var isPaused = false

    private let modelManager: KokoroModelManager
    private let player: NeuralAudioPlayer
    private var engine: KokoroAneManager?
    private var engineInitTask: Task<KokoroAneManager, Error>?
    private var synthesisTask: Task<Void, Never>?
    private var currentUtteranceID: Int?

    init(modelManager: KokoroModelManager) {
        self.modelManager = modelManager
        self.player = NeuralAudioPlayer()
    }

    /// Designated initializer used by tests to inject a custom player.
    init(modelManager: KokoroModelManager, player: NeuralAudioPlayer) {
        self.modelManager = modelManager
        self.player = player
    }

    var defaultVoiceID: String? { KokoroAneVariant.english.defaultVoice }

    /// v1 ships only the default voice (`af_heart`), which the model download
    /// bundles — no extra voice-pack fetch. A curated multi-voice catalog
    /// backed by `KokoroAneResourceDownloader.ensureVoicePack` is a fast-follow.
    func availableVoices() -> [SpeechVoice] {
        [SpeechVoice(
            id: KokoroAneVariant.english.defaultVoice,
            displayName: NSLocalizedString("TTS_KOKORO_VOICE_DEFAULT", comment: "Kokoro default voice"),
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
        let voice = voiceID ?? defaultVoiceID ?? KokoroAneVariant.english.defaultVoice
        let chunks = KokoroTextChunker.chunk(text)
        guard !chunks.isEmpty else {
            isSpeaking = false
            delegate?.backendDidFinish(utteranceID: utteranceID)
            return
        }
        synthesisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let engine = try await self.ensureEngine()
                try Task.checkCancellation()
                guard self.currentUtteranceID == utteranceID else { return }
                self.delegate?.backendDidStart(utteranceID: utteranceID)
                for chunk in chunks {
                    try Task.checkCancellation()
                    let result = try await engine.synthesizeDetailed(
                        text: chunk, voice: voice, speed: rate
                    )
                    try Task.checkCancellation()
                    guard self.currentUtteranceID == utteranceID else { return }
                    if let buffer = NeuralAudioPlayer.makeBuffer(
                        samples: result.samples,
                        sampleRate: Double(result.sampleRate)
                    ) {
                        self.player.schedule(buffer)
                        if !self.isPaused {
                            self.player.play()
                        }
                    }
                }
                self.player.markEndOfStream { [weak self] in
                    guard let self, self.currentUtteranceID == utteranceID else { return }
                    self.isSpeaking = false
                    self.delegate?.backendDidFinish(utteranceID: utteranceID)
                }
            } catch is CancellationError {
                // Superseded or stopped — the replacing call already reset state.
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

    /// Lazily build and initialize the Kokoro engine; cached after first use.
    /// Concurrent callers share a single in-flight initialization.
    private func ensureEngine() async throws -> KokoroAneManager {
        if let engine { return engine }
        if let engineInitTask { return try await engineInitTask.value }
        let task = Task { () throws -> KokoroAneManager in
            let manager = KokoroAneManager(
                variant: .english,
                defaultVoice: KokoroAneVariant.english.defaultVoice
            )
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
            engineInitTask = nil  // allow a later retry after a failed init
            throw error
        }
    }
}
