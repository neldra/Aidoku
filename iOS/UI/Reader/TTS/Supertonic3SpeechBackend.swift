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

    /// Pre-synthesized PCM buffers, keyed by `cacheKey(text:voiceID:)`. The
    /// TTSManager lookahead populates this for paragraph N+1 while N plays;
    /// `speak()` consumes (and removes) the entry when its `text` matches.
    private var prefetchedSamples: [String: [Float]] = [:]
    /// In-flight prefetch synthesis tasks, keyed the same way. `speak()`
    /// awaits a matching in-flight task instead of starting a new one.
    private var prefetchTasks: [String: Task<[Float]?, Never>] = [:]

    /// Voice ID for the single bundled `M1` preset. The voice style JSON ships
    /// inside the app bundle as `Supertonic3_M1.json` (~290 KB).
    private static let defaultVoice = "m1"

    private static func cacheKey(text: String, voiceID: String?) -> String {
        "\(voiceID ?? "")::\(text)"
    }

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

    var supportsLiveRateChange: Bool { true }

    func setLiveRate(_ rate: Float) {
        player.rate = rate
    }

    func prefetch(text: String, voiceID: String?) {
        let resolvedVoice = voiceID ?? Self.defaultVoice
        let key = Self.cacheKey(text: text, voiceID: resolvedVoice)
        guard prefetchedSamples[key] == nil, prefetchTasks[key] == nil else { return }
        // Single-task design: synthesize, store result, AND remove from
        // prefetchTasks all in the same task body, with no intermediate
        // await. Guarantees that when the task completes,
        // `prefetchedSamples[key]` is populated atomically from the main
        // actor's perspective — no window where neither map has the key.
        let task: Task<[Float]?, Never> = Task { [weak self] in
            guard let self else { return nil }
            do {
                let engine = try await self.ensureEngine()
                let style = try await self.loadVoiceStyleOnMain()
                try Task.checkCancellation()
                let result = try await engine.synthesize(
                    text: text, language: "en", style: style, speed: 1.0
                )
                try Task.checkCancellation()
                self.prefetchedSamples[key] = result.samples
                self.prefetchTasks.removeValue(forKey: key)
                return result.samples
            } catch is CancellationError {
                self.prefetchTasks.removeValue(forKey: key)
                return nil
            } catch {
                self.prefetchTasks.removeValue(forKey: key)
                return nil
            }
        }
        prefetchTasks[key] = task
    }

    func cancelPrefetch(text: String, voiceID: String?) {
        let resolvedVoice = voiceID ?? Self.defaultVoice
        let key = Self.cacheKey(text: text, voiceID: resolvedVoice)
        prefetchTasks[key]?.cancel()
        prefetchTasks.removeValue(forKey: key)
        prefetchedSamples.removeValue(forKey: key)
    }

    func cancelAllPrefetches() {
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll()
        prefetchedSamples.removeAll()
    }

    func speak(text: String, voiceID: String?, rate: Float, utteranceID: Int) {
        synthesisTask?.cancel()
        player.stop()
        // Synthesize at 1.0x; let the player time-stretch live (see
        // NeuralAudioPlayer's pitchUnit). Decoupling rate from synthesis lets
        // the rate slider work mid-playback without re-issuing the paragraph.
        player.rate = rate
        currentUtteranceID = utteranceID
        isSpeaking = true
        isPaused = false
        guard !text.isEmpty else {
            isSpeaking = false
            delegate?.backendDidFinish(utteranceID: utteranceID)
            return
        }
        let resolvedVoice = voiceID ?? Self.defaultVoice
        let key = Self.cacheKey(text: text, voiceID: resolvedVoice)
        // Three-way dispatch:
        // 1. Cached samples ready → schedule immediately, no synth wait.
        // 2. Prefetch in flight → await its result, then schedule.
        // 3. Cold path → synthesize from scratch.
        // On prefetch failure we always fall through to cold synth rather than
        // failing the utterance, so a transient prefetch error doesn't
        // cascade-skip paragraphs.
        if let cached = prefetchedSamples.removeValue(forKey: key) {
            playFromSamples(cached, utteranceID: utteranceID)
            return
        }
        if let inflight = prefetchTasks.removeValue(forKey: key) {
            synthesisTask = Task { [weak self] in
                guard let self else { return }
                self.delegate?.backendDidStart(utteranceID: utteranceID)
                let samples = await inflight.value
                guard self.currentUtteranceID == utteranceID else { return }
                if let samples {
                    self.scheduleAndFinish(samples: samples, utteranceID: utteranceID)
                } else {
                    // Prefetch synthesis failed; do cold synth instead of bailing.
                    await self.runColdSynth(text: text, utteranceID: utteranceID, alreadyStarted: true)
                }
            }
            return
        }
        synthesisTask = Task { [weak self] in
            guard let self else { return }
            await self.runColdSynth(text: text, utteranceID: utteranceID, alreadyStarted: false)
        }
    }

    /// Synthesize from scratch. `alreadyStarted` skips a redundant
    /// `backendDidStart` when the in-flight path already fired it before
    /// falling back here.
    private func runColdSynth(text: String, utteranceID: Int, alreadyStarted: Bool) async {
        do {
            let engine = try await ensureEngine()
            let style = try loadVoiceStyle()
            try Task.checkCancellation()
            guard currentUtteranceID == utteranceID else { return }
            if !alreadyStarted {
                delegate?.backendDidStart(utteranceID: utteranceID)
            }
            let result = try await engine.synthesize(
                text: text, language: "en", style: style, speed: 1.0
            )
            try Task.checkCancellation()
            guard currentUtteranceID == utteranceID else { return }
            scheduleAndFinish(samples: result.samples, utteranceID: utteranceID)
        } catch is CancellationError {
            // Superseded or stopped.
        } catch {
            guard currentUtteranceID == utteranceID else { return }
            isSpeaking = false
            delegate?.backendDidFail(utteranceID: utteranceID, error: error)
        }
    }

    /// Cache-hit fast path: skip the synth await, schedule cached PCM, signal start.
    private func playFromSamples(_ samples: [Float], utteranceID: Int) {
        delegate?.backendDidStart(utteranceID: utteranceID)
        scheduleAndFinish(samples: samples, utteranceID: utteranceID)
    }

    /// Hand a finished sample buffer to the player and wire end-of-stream.
    private func scheduleAndFinish(samples: [Float], utteranceID: Int) {
        if let buffer = NeuralAudioPlayer.makeBuffer(samples: samples, sampleRate: 44_100) {
            player.schedule(buffer)
            if !isPaused { player.play() }
        }
        player.markEndOfStream { [weak self] in
            guard let self, self.currentUtteranceID == utteranceID else { return }
            self.isSpeaking = false
            self.delegate?.backendDidFinish(utteranceID: utteranceID)
        }
    }

    /// Wrapper to load the voice style on the main actor from inside a
    /// Sendable Task body (prefetch synthesis runs detached). `loadVoiceStyle`
    /// itself is @MainActor-isolated by the actor's class isolation.
    @MainActor
    private func loadVoiceStyleOnMain() async throws -> Supertonic3VoiceStyle {
        try loadVoiceStyle()
    }

    func stop() {
        synthesisTask?.cancel()
        synthesisTask = nil
        player.stop()
        currentUtteranceID = nil
        isSpeaking = false
        isPaused = false
        // NOTE: deliberately does NOT clear the prefetch cache. `stop()` is
        // called from `TTSManager.speakCurrent` before every new paragraph to
        // interrupt the previous one — clearing here would invalidate the
        // very prefetch we're about to consume. Full-session cancellation
        // goes through TTSManager.stop() → cancelAllPrefetches() explicitly.
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
