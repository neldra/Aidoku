//
//  SpeechSynthesisBackend.swift
//  Aidoku
//

import Foundation

/// Quality tier of a synthesis voice, for display and sorting.
enum SpeechVoiceQuality: Int, Comparable {
    case standard
    case enhanced
    case premium

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A voice offered by a specific backend. Backend-scoped: a voice from one
/// backend is not usable by another. The `id` is opaque to consumers and
/// only meaningful to the backend that produced it.
struct SpeechVoice: Identifiable, Hashable {
    let id: String
    let displayName: String
    /// BCP-47 language tag, e.g. "en-US".
    let language: String
    let quality: SpeechVoiceQuality
}

/// Whether a backend can synthesize right now.
enum BackendAvailability: Equatable {
    case ready
    case needsDownload
    case downloading(progress: Double)
    case unavailable(reason: String)
}

/// Receives utterance lifecycle callbacks from a backend. Implemented by
/// `TTSManager`. `utteranceID` echoes the value passed to `speak` so a stale
/// callback (from an utterance that was stopped and replaced) can be ignored.
/// Always delivered on the main actor.
@MainActor
protocol SpeechBackendDelegate: AnyObject {
    func backendDidStart(utteranceID: Int)
    func backendDidFinish(utteranceID: Int)
    func backendDidFail(utteranceID: Int, error: Error)
}

/// A pluggable text-to-speech engine. Each conformer owns its own audio
/// playback. The control surface is called from the main actor; any async
/// work is spawned internally and its callbacks hop back to the main actor.
@MainActor
protocol SpeechSynthesisBackend: AnyObject {
    /// Stable identifier persisted in preferences, e.g. "system".
    var id: String { get }
    /// Human-readable name for settings UI.
    var displayName: String { get }
    /// Whether the backend can synthesize right now.
    var availability: BackendAvailability { get }
    /// Lifecycle callback sink. Set by `TTSManager`.
    var delegate: SpeechBackendDelegate? { get set }

    var isSpeaking: Bool { get }
    var isPaused: Bool { get }

    /// Speak `text` using the voice identified by `voiceID` (nil = the
    /// backend's default voice) at `rate` (1.0 = normal pace). `utteranceID`
    /// is echoed back in delegate callbacks for staleness checks.
    func speak(text: String, voiceID: String?, rate: Float, utteranceID: Int)
    func stop()
    func pause()
    func resume()

    /// Identifier of the backend's default voice, or nil if it has none.
    var defaultVoiceID: String? { get }
    /// Full voice catalog for settings UI.
    func availableVoices() -> [SpeechVoice]

    /// Warm-up hook. No-op for backends that need none.
    func prepare() async

    /// `true` if the backend can apply rate changes to audio that's already
    /// in flight (or already synthesized). When `false` (the default), the
    /// caller restarts the current utterance to make the new rate take effect.
    var supportsLiveRateChange: Bool { get }

    /// Apply a new playback rate to the in-flight audio. Default
    /// implementation is a no-op — backends that report
    /// `supportsLiveRateChange == true` must implement this.
    func setLiveRate(_ rate: Float)

    /// Speculatively synthesize `text` and cache the result so a later
    /// `speak(text:..., voiceID:...)` with the same arguments plays
    /// immediately. Default no-op; backends with batch synthesis
    /// (Supertonic-3) override to overlap synth of N+1 with playback of N.
    func prefetch(text: String, voiceID: String?)

    /// Drop one specific cached prefetch (used when a paragraph is skipped or
    /// the voice changes). Default no-op.
    func cancelPrefetch(text: String, voiceID: String?)

    /// Drop everything cached. Called from `TTSManager.stop` and on voice
    /// changes. Default no-op.
    func cancelAllPrefetches()
}

extension SpeechSynthesisBackend {
    var supportsLiveRateChange: Bool { false }
    func setLiveRate(_ rate: Float) {}

    func prefetch(text: String, voiceID: String?) {}
    func cancelPrefetch(text: String, voiceID: String?) {}
    func cancelAllPrefetches() {}
}
