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
    private var g2pProvider: KokoroG2PProvider?

    /// Minimum lexicon coverage at which the Misaki overlay is trusted to
    /// dictate the whole sentence. Below this, we fall back to FluidAudio's
    /// built-in whole-text G2P for that chunk (still gives us correct
    /// pronunciation for OOV-heavy sentences via the existing BART path).
    private static let misakiCoverageThreshold: Double = 0.5

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

    var supportsInterruptPause: Bool { true }
    var supportsLiveRateChange: Bool { true }

    func setLiveRate(_ rate: Float) {
        player.rate = rate
    }

    func speak(text: String, voiceID: String?, rate: Float, utteranceID: Int) {
        synthesisTask?.cancel()
        player.stop()
        // Synthesize at 1.0x and let the player's time-pitch unit handle the
        // live rate. Decouples synthesis cost from the user's rate slider and
        // lets mid-utterance changes take effect without re-synthesis.
        player.rate = rate
        currentUtteranceID = utteranceID
        isSpeaking = true
        isPaused = false
        let voice = voiceID ?? defaultVoiceID ?? KokoroAneVariant.english.defaultVoice
        let chunks = KokoroTextChunker.chunk(Self.normalizeForKokoro(text))
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
                let provider = self.resolveG2PProvider(for: engine)
                self.delegate?.backendDidStart(utteranceID: utteranceID)
                for chunk in chunks {
                    try Task.checkCancellation()
                    let result = try await Self.synthesize(
                        chunk: chunk,
                        engine: engine,
                        provider: provider,
                        voice: voice
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

    /// Rewrites that paper over two classes of Kokoro/Misaki text-handling
    /// gaps before chunking. Apply additively when a new class shows up:
    ///
    /// 1. **Repeated punctuation.** Kokoro's prosody stage emits artifacts
    ///    on runs of identical sentence-terminator tokens ("...", "!!!",
    ///    "??", "——") because they aren't in the training distribution.
    ///    Two of the runs get *substituted* into distinct vocab tokens
    ///    that the model has seen — ASCII `...` → `…` (id 10), `--` →
    ///    `—` (id 9). Everything else collapses to a single instance.
    ///
    /// 2. **Currency.** Misaki's retokenize requires NLTagger to classify
    ///    `$` as `.otherWord` (matching its spaCy upstream), but
    ///    NLTagger tags it as `.punctuation`, so the currency branch
    ///    never fires and the whole `$N.MM` token is silently dropped.
    ///    Expand to plain English here.
    private static func normalizeForKokoro(_ text: String) -> String {
        return text
            // Currency: longer (with cents) first so the shorter match
            // doesn't eat the dollar amount before the cents arrive.
            .replacingOccurrences(
                of: #"\$(\d+(?:,\d{3})*)\.(\d{2})\b"#,
                with: "$1 dollars and $2 cents",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\$(\d+(?:,\d{3})*)\b"#,
                with: "$1 dollars",
                options: .regularExpression
            )
            // Semantic substitution for ASCII ellipsis / dash runs.
            .replacingOccurrences(of: #"\.{3,}"#, with: "…", options: .regularExpression)
            .replacingOccurrences(of: #"-{2,}"#,  with: "—", options: .regularExpression)
            // Defensive collapse of any remaining run of identical
            // sentence punctuation. Catches "!!!", "???", ",,", ";;",
            // and anything further that survives rules above.
            .replacingOccurrences(
                of: #"([!?,;:—…])\1+"#,
                with: "$1",
                options: .regularExpression
            )
    }

    private func resolveG2PProvider(for engine: KokoroAneManager) -> KokoroG2PProvider {
        if let existing = g2pProvider { return existing }
        let provider = MisakiKokoroG2PProvider(fluidAudio: engine)
        g2pProvider = provider
        return provider
    }

    private static func synthesize(
        chunk: String,
        engine: KokoroAneManager,
        provider: KokoroG2PProvider,
        voice: String
    ) async throws -> KokoroAneSynthesisResult {
        let g2p = try await provider.phonemize(chunk)
        if g2p.coverage >= misakiCoverageThreshold && !g2p.phonemes.isEmpty {
            return try await engine.synthesizeFromPhonemesDetailed(
                g2p.phonemes, voice: voice, speed: 1.0
            )
        }
        // Low coverage or empty Misaki output → FluidAudio's whole-text G2P.
        return try await engine.synthesizeDetailed(
            text: chunk, voice: voice, speed: 1.0
        )
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
            // FluidAudio's default puts prosody/noise/tail on `.all`
            // (CPU+GPU+ANE), letting the iOS scheduler pick. That works
            // when our app is foreground or in lock-screen background (ANE
            // is allocated to us). But when our app is backgrounded behind
            // another foreground app, ANE goes to whoever's in front and
            // iOS falls back to MPS Graph — which then crashes on
            // KokoroProsody:
            //   model.mil:148: error: 'mps.add' op requires the same
            //   element type for all operands and results
            //   MPSGraphUtilities.h:165: failed assertion `Type is
            //   unranked.` → SIGABRT.
            // Forcing `.aneOrAll` (= `.cpuAndNeuralEngine` on iOS 16+)
            // keeps MPS out of the candidate set: when ANE is unavailable,
            // fall back to CPU rather than to GPU/MPS.
            let computeUnits = KokoroAneComputeUnits(
                prosody: .aneOrAll,
                noise: .aneOrAll,
                tail: .aneOrAll
            )
            let manager = KokoroAneManager(
                variant: .english,
                defaultVoice: KokoroAneVariant.english.defaultVoice,
                computeUnits: computeUnits
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
