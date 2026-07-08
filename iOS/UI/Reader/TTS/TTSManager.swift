//
//  TTSManager.swift
//  Aidoku
//

import AVFoundation
import MediaPlayer
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Supplies chapter metadata, artwork, the next chapter, and receives
/// active-paragraph callbacks. Implemented by the reader layer.
@MainActor
protocol TTSChapterProvider: AnyObject {
    var ttsNovelTitle: String { get }
    func ttsChapterTitle(forKey key: String) -> String
    var ttsArtwork: UIImage? { get }
    /// Load the next *text* chapter's paragraphs, or nil if none / not text.
    func ttsLoadNextChapter() async -> (chapterKey: String, text: String)?
    /// Load the previous *text* chapter's paragraphs, or nil if none / not text.
    func ttsLoadPreviousChapter() async -> (chapterKey: String, text: String)?
    /// The reader should highlight every display paragraph in
    /// `localDisplayRange` (and, if enabled, scroll to the first one).
    /// Indices are 0-based within `chapterKey` — the reader renders one
    /// chapter at a time, numbered from 0. The range spans multiple display
    /// paragraphs when the active synthesis paragraph merged width-wrapped
    /// fragments, and is a single-index span otherwise.
    func ttsDidActivateParagraphs(localDisplayRange: Range<Int>, chapterKey: String)
}

@MainActor
final class TTSManager: NSObject, ObservableObject {
    static let shared: TTSManager = {
        let manager = TTSManager(registry: SpeechBackendRegistry())
        manager.announceChapterTitles =
            UserDefaults.standard.object(forKey: announceChapterKey) as? Bool ?? true
        return manager
    }()

    @Published private(set) var isActive = false
    @Published private(set) var isPlaying = false
    /// Display-paragraph range the active utterance covers, chapter-local.
    /// Drives the reader's highlight (every index in the range lights up)
    /// and its auto-scroll target (the range's lower bound). `nil` when no
    /// utterance is active. A merged synthesis paragraph produces a multi-
    /// index range; an un-merged one produces a single-index span.
    @Published private(set) var currentLocalDisplayRange: Range<Int>?
    @Published var artwork: UIImage?
    /// Chapter-local playback progress 0...1, for the mini-player scrub/
    /// hairline. Paragraph-boundary granularity, plus a 1 s wall-clock tick
    /// while `beginFineProgressUpdates()` observers exist.
    @Published private(set) var chapterProgress: Double = 0
    /// Estimated seconds left in the current chapter, or nil when no
    /// normalized chapter/estimate is available (mini-player shows "—:—").
    @Published private(set) var timeRemaining: TimeInterval?
    /// Sleep-timer setting for the mini-player. `.minutes` stops the session
    /// when its wall-clock deadline passes; `.endOfChapter` stops at the
    /// next chapter boundary instead of rolling into the following chapter.
    enum SleepTimer: Equatable {
        case off
        case minutes(Int)
        case endOfChapter
    }

    @Published private(set) var sleepTimer: SleepTimer = .off
    private var sleepDeadline: Date?
    private var sleepTask: Task<Void, Never>?
    private var novelTitle = ""
    private var currentChapterTitle = ""
    /// When true, the chapter title is spoken before the first paragraph of
    /// every chapter the narration enters.
    @Published var announceChapterTitles = false {
        didSet {
            UserDefaults.standard.set(announceChapterTitles, forKey: Self.announceChapterKey)
        }
    }
    @Published var voiceIdentifier: String {
        didSet {
            guard oldValue != voiceIdentifier else { return }
            UserDefaults.standard.set(
                voiceIdentifier,
                forKey: Self.voiceKey(forBackendID: currentBackendID)
            )
            // Speculatively load any backing assets for the new voice (Kokoro
            // pulls a ~500 KB pack on first use). Overlaps download with the
            // user's next action so the first paragraph after a voice change
            // doesn't stall on the network.
            if !voiceIdentifier.isEmpty {
                backend.prepareVoice(voiceIdentifier)
            }
            applyConfigChange(resetCalibration: true)
        }
    }
    @Published var rate: Float {
        didSet {
            guard oldValue != rate else { return }
            UserDefaults.standard.set(rate, forKey: Self.rateKey)
            applyConfigChange(resetCalibration: false)
        }
    }

    /// Legacy global voice key — migrated into the per-backend `.system` key
    /// by `migrateVoicePreferenceIfNeeded()`. Kept only as the migration source.
    static let legacyVoiceKey = "Reader.ttsVoiceIdentifier"
    static let rateKey = "Reader.ttsRateMultiplier"
    static let highlightKey = "Reader.ttsHighlight"
    static let announceChapterKey = "Reader.ttsAnnounceChapter"
    /// Selected backend id ("system" | "kokoro").
    static let backendKey = "Reader.ttsBackend"

    /// Per-backend voice preference key, e.g. "Reader.ttsVoice.system".
    static func voiceKey(forBackendID id: String) -> String {
        "Reader.ttsVoice.\(id)"
    }

    /// One-time migration: copy the legacy global voice into the per-backend
    /// `.system` key. Idempotent — runs only while the new key is absent.
    static func migrateVoicePreferenceIfNeeded() {
        let defaults = UserDefaults.standard
        let systemKey = voiceKey(forBackendID: "system")
        guard defaults.string(forKey: systemKey) == nil,
              let legacy = defaults.string(forKey: legacyVoiceKey)
        else { return }
        defaults.set(legacy, forKey: systemKey)
    }

    private var backend: any SpeechSynthesisBackend
    /// Non-nil when constructed via `init(registry:)` (the production path).
    /// Tests use `init(backend:)` and leave this nil — backend switching is
    /// then a no-op.
    private let registry: SpeechBackendRegistry?
    /// Selected backend id, persisted to `backendKey`. Drives the settings
    /// engine picker.
    @Published var currentBackendID: String {
        didSet {
            guard oldValue != currentBackendID else { return }
            UserDefaults.standard.set(currentBackendID, forKey: Self.backendKey)
            switchBackend(toID: currentBackendID)
        }
    }
    /// Monotonic counter; each `speak` mints the next id.
    private var utteranceCounter = 0
    /// Clock used for utterance-duration sampling. Injectable so tests can
    /// drive deterministic WPM observations without real-time sleeps.
    private let now: () -> Date
    private var queue = TTSQueue(paragraphs: [])
    private weak var provider: TTSChapterProvider?
    private var loadingNext = false
    private var loadingChapterNav = false
    /// id of the utterance currently in flight, or nil when none is. Replaces
    /// AVSpeechUtterance object-identity tracking; stale backend callbacks are
    /// matched against this.
    private var currentUtteranceID: Int?
    /// Wall-clock timestamp of the active utterance's `didStart` callback.
    /// Cleared whenever the utterance is interrupted, replaced, or stopped so
    /// only natural finishes flow into `calibrator.recordSample`.
    private var currentUtteranceStartedAt: Date?
    /// Word count of the spoken string (post chapter-title prefix, post
    /// mid-paragraph substring) for the active utterance.
    private var currentUtteranceWordCount: Int = 0
    private var sessionRevision = 0
    /// Chapter the title was last spoken for; used to announce the title
    /// exactly once per chapter the narration enters.
    private var lastAnnouncedChapterKey: String?

    /// Normalized view of the chapter the cursor is currently in, rebuilt
    /// whenever `queue.current?.chapterKey` changes. Feeds the time estimator
    /// and scrub/skip handlers.
    private var currentNormalizedChapter: NormalizedTextChapter?
    /// Cached normalized chapters keyed by chapterKey. Populated at every
    /// queue ingestion path (start / userDidNavigate / loadNext / loadPrev)
    /// where we have the original chapter text. `refreshNormalizedChapterIfNeeded`
    /// looks the current key up instead of rebuilding from the queue's
    /// already-merged synthesis spokenText (which would re-feed pre-merged
    /// output back into the merge layer).
    private var normalizedChapterCache: [String: NormalizedTextChapter] = [:]
    private var calibrator = WPMCalibrator()
    /// Count of live fine-progress observers (expanded mini-players). The
    /// 1 s tick Task exists only while this is > 0.
    private var fineProgressObservers = 0
    private var fineProgressTask: Task<Void, Never>?
    /// Character offset into the next paragraph utterance — set by
    /// mid-paragraph seeks (lockscreen scrub / ±15s) and consumed once by
    /// `speakCurrent`. Without it the backend would restart the paragraph
    /// from the top instead of at the requested offset.
    private var pendingCharOffset: Int = 0
    /// Character offset at which the current utterance started, surfaced via
    /// `currentPosition` so the lockscreen scrub bar reports the real
    /// position after a mid-paragraph seek. Set when `speakCurrent` consumes
    /// `pendingCharOffset`; reset to 0 on the next utterance (which always
    /// begins from offset 0 unless another seek lands first).
    private var activeCharOffset: Int = 0
    /// True when the current paused state came from a user-initiated action
    /// (toggle command, AirPod removed, lockscreen pause) rather than an
    /// audio-session interruption. Auto-resume on interruption .ended is
    /// gated on this being false, matching HIG and most iOS audio apps:
    /// Siri/calls auto-resume; user-initiated pauses stay paused.
    private var pausedByUser: Bool = false
    /// AVAudioSession interruption observer (phone call, Siri, AirPods press
    /// in some routings). Kept alive for the singleton's lifetime.
    private var interruptionObserver: NSObjectProtocol?
    /// AVAudioSession route-change observer (headphone/AirPods/Bluetooth
    /// disconnect). Kept alive for the singleton's lifetime.
    private var routeChangeObserver: NSObjectProtocol?
    /// `UIApplication.willResignActiveNotification` observer. Deferring
    /// session deactivation to backgrounding (instead of doing it inline on
    /// `pause()`) follows Apple's guidance: deactivating mid-foreground is
    /// known to cause resume-playback issues, so we keep the session active
    /// while the app is foreground (engine just pauses in place) and only
    /// release it when the app backgrounds, which is also when iOS reads
    /// the session state to update the lockscreen icon.
    private var willResignActiveObserver: NSObjectProtocol?
    /// Serial queue for AVAudioSession activation/deactivation. `setActive` is
    /// a synchronous, blocking call — deactivation measures ~580ms — so it must
    /// not run on the main thread (it froze the reader's play/pause UI). Serial
    /// keeps a deactivate and a following reactivate correctly ordered.
    private let audioSessionQueue = DispatchQueue(label: "app.aidoku.tts.audioSession")

    var currentChapterKey: String? { queue.current?.chapterKey }

    /// Position of the narration cursor inside `currentNormalizedChapter`.
    /// `charOffsetInParagraph` reflects the start of the active utterance, so
    /// a mid-paragraph seek shows up immediately in elapsed/duration. Within
    /// a single utterance the offset doesn't tick — `willSpeakRangeOfSpeechString`
    /// would be needed for word-by-word precision.
    private var currentPosition: TextChapterPosition {
        TextChapterPosition(
            paragraphIndex: queue.localIndexInCurrentChapter,
            charOffsetInParagraph: activeCharOffset
        )
    }

    /// Designated initializer. `backend` is the initially-active backend;
    /// `registry`, when present, enables backend switching.
    init(
        backend: any SpeechSynthesisBackend,
        registry: SpeechBackendRegistry?,
        now: @escaping () -> Date
    ) {
        Self.migrateVoicePreferenceIfNeeded()
        self.backend = backend
        self.registry = registry
        self.now = now
        let defaults = UserDefaults.standard
        self.currentBackendID = backend.id
        self.voiceIdentifier = defaults.string(forKey: Self.voiceKey(forBackendID: backend.id))
            ?? backend.defaultVoiceID
            ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())?.identifier
            ?? ""
        let storedRate = defaults.object(forKey: Self.rateKey) as? Float
        self.rate = storedRate ?? 1.0
        super.init()
        self.backend.delegate = self
        self.calibrator.reset(forVoice: voiceIdentifier)
        // Neural backends pay a one-time anecompilerservice cold-start when
        // their CoreML stages first load (≈16–20s for Supertonic-3, ≈10–20s
        // for Kokoro on M-series). Warm them up off the main path before the
        // user hits play.
        prewarmActiveBackendIfNeeded()
        self.registerInterruptionObserver()
        self.registerRouteChangeObserver()
        self.registerWillResignActiveObserver()
    }

    /// Test seam: drive the manager with an explicit backend, no registry.
    convenience init(
        backend: (any SpeechSynthesisBackend)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.init(backend: backend ?? SystemSpeechBackend(), registry: nil, now: now)
    }

    /// Production path: resolve the active backend from the registry.
    convenience init(
        registry: SpeechBackendRegistry,
        now: @escaping () -> Date = Date.init
    ) {
        let preferred = UserDefaults.standard.string(forKey: Self.backendKey)
        // Refresh Kokoro's installed state synchronously before resolving —
        // otherwise on every relaunch the models on disk are not yet detected
        // (`refreshInstalledState()` only runs from the settings download row's
        // `.onAppear`), the registry falls back to the system backend, and the
        // user's saved Kokoro preference is silently lost until they open
        // Reader Settings.
        if #available(iOS 16, *) {
            registry.kokoroModelManager?.refreshInstalledStateSync()
            registry.supertonic3ModelManager?.refreshInstalledStateSync()
        }
        let active = registry.currentBackend(preferredID: preferred)
        self.init(backend: active, registry: registry, now: now)
    }

    deinit {
        // Dropping a Task handle doesn't cancel it; without this a
        // deallocated manager (tests) leaves a zombie tick for up to 1 s.
        fineProgressTask?.cancel()
        sleepTask?.cancel()
    }

    // MARK: - Settings surface

    /// Backends the settings engine picker can offer. Empty when there is no
    /// registry (the test seam) — the picker then stays hidden.
    func selectableBackends() -> [any SpeechSynthesisBackend] {
        registry?.selectableBackends() ?? []
    }

    /// Voice catalog of the currently-active backend, for the settings picker.
    func activeBackendVoices() -> [SpeechVoice] {
        backend.availableVoices()
    }

    /// The backend matching `currentBackendID` (the user's preference),
    /// regardless of whether it's currently `.ready`. Differs from the active
    /// `backend` when the preference has resolved to a fallback (e.g. Kokoro
    /// selected but mid-download).
    private var selectedBackend: (any SpeechSynthesisBackend)? {
        registry?.backend(forID: currentBackendID)
    }

    /// Voices offered by the *selected* (preferred) backend, regardless of
    /// whether it's currently ready. The settings voice picker uses these so
    /// it follows the engine picker rather than the resolved fallback — paired
    /// with `selectedBackendIsReady` driving the picker's `.disabled` state.
    func selectedBackendVoices() -> [SpeechVoice] {
        selectedBackend?.availableVoices() ?? []
    }

    /// Whether the selected (preferred) backend is `.ready`. Drives the
    /// settings voice picker's `.disabled` state — picking a voice for a
    /// backend that can't yet play wouldn't take effect.
    var selectedBackendIsReady: Bool {
        selectedBackend?.availability == .ready
    }

    /// Voice picker selection bound by the settings sheet. When the selected
    /// backend equals the active backend (the usual case, picker enabled),
    /// this is the live `voiceIdentifier`. When they differ — the selected
    /// backend hasn't yet resolved to active (Kokoro mid-download, etc.) — it
    /// reports the per-backend stored voice so the picker still shows the
    /// correct selection. The picker is `.disabled` in that case, so the
    /// setter normally only fires through the equal-backends branch.
    var selectedBackendVoiceID: String {
        get {
            if currentBackendID == backend.id {
                return voiceIdentifier
            }
            return UserDefaults.standard.string(
                forKey: Self.voiceKey(forBackendID: currentBackendID)
            ) ?? selectedBackend?.defaultVoiceID ?? ""
        }
        set {
            if currentBackendID == backend.id {
                // Selected == active: route through `voiceIdentifier`'s didSet
                // for persistence + calibration reset + restart-on-change.
                voiceIdentifier = newValue
            } else {
                // Disabled-picker fallback. Persist anyway for symmetry.
                UserDefaults.standard.set(
                    newValue,
                    forKey: Self.voiceKey(forBackendID: currentBackendID)
                )
            }
        }
    }

    /// The Kokoro model manager (iOS 16+), for the settings download row.
    @available(iOS 16, *)
    var kokoroModelManager: KokoroModelManager? {
        registry?.kokoroModelManager
    }

    /// The Supertonic-3 model manager (iOS 16+), for the settings download row.
    @available(iOS 16, *)
    var supertonic3ModelManager: Supertonic3ModelManager? {
        registry?.supertonic3ModelManager
    }

    /// Re-resolve the active backend against the current `currentBackendID`
    /// preference. Call after a backend that was previously unavailable (e.g.
    /// Kokoro mid-download) becomes ready, so the user's selection takes effect
    /// without an app restart. A no-op if the resolved backend is already active.
    func reapplyBackendPreference() {
        switchBackend(toID: currentBackendID)
    }

    // MARK: - Lifecycle

    func start(
        provider: TTSChapterProvider,
        chapterKey: String,
        text: String,
        startIndex: Int
    ) {
        let bundle = TTSText.chapterBundle(
            chapterKey: chapterKey,
            text: text,
            chapterTitle: provider.ttsChapterTitle(forKey: chapterKey)
        )
        guard !bundle.synthesisParagraphs.isEmpty else {
            stop()
            return
        }
        sessionRevision &+= 1
        self.provider = provider
        queue = TTSQueue(paragraphs: bundle.synthesisParagraphs, startIndex: startIndex)
        normalizedChapterCache = [chapterKey: bundle.normalizedChapter]
        currentNormalizedChapter = nil
        refreshNormalizedChapterIfNeeded()
        isActive = true
        activateAudioSession()
        configureRemoteCommands()
        speakCurrent()
    }

    func togglePlayPause() { isPlaying ? pause() : play() }

    func play() {
        guard isActive, !isPlaying else { return }
        pausedByUser = false
        // Reactivate the audio session in case a pause deactivated it.
        // Safe to call when already active.
        activateAudioSession()
        if backend.supportsInterruptPause, backend.isPaused {
            // Neural backend was paused mid-utterance by pauseForSystemAudioEvent.
            // Resume in place — no re-synth, audio picks up at the exact sample
            // where Siri cut in.
            backend.resume()
            isPlaying = true
            updateNowPlaying()
            return
        }
        // System backend (or any backend that doesn't preserve interrupt
        // state): re-issue the current paragraph. speakCurrent() stops the
        // synth cleanly and re-speaks from this safe (non-interruption) context.
        speakCurrent()
    }

    /// User-initiated pause (toolbar button, lock-screen pauseCommand).
    ///
    /// Two-axis behaviour:
    ///
    /// - **Backend state**: for backends that support in-place pause (neural
    ///   ones backed by `AVAudioEngine`), call `backend.pause()` so the
    ///   utterance keeps its position and `play()` can `backend.resume()`
    ///   instantly. For backends that don't (`AVSpeechSynthesizer`), tear
    ///   down via `backend.stop()` — resume on those re-issues the paragraph
    ///   from `activeCharOffset` via `speakCurrent()`.
    ///
    /// - **Audio-session lifecycle**: per Apple's documented pattern, iOS
    ///   reads the session's active state (not `MPNowPlayingInfoCenter
    ///   .playbackState`, which is macOS-only) to drive the lockscreen
    ///   play/pause icon. But deactivating mid-foreground causes
    ///   resume-playback issues. So: if the app is foreground we keep the
    ///   session active and defer deactivation to
    ///   `handleAppWillResignActive`. If the app is already backgrounded
    ///   (e.g. lockscreen pauseCommand), deactivate inline so the lockscreen
    ///   icon flips right away.
    ///
    /// Drops the in-flight calibration sample either way — the paused
    /// interval would otherwise be baked into the observed paragraph
    /// duration.
    func pause() {
        guard isActive else { return }
        sessionRevision &+= 1
        clearUtteranceSample()
        if backend.supportsInterruptPause {
            backend.pause()
        } else {
            backend.stop()
            pendingCharOffset = activeCharOffset
            currentUtteranceID = nil
        }
        pausedByUser = true
        isPlaying = false
        if UIApplication.shared.applicationState != .active {
            // Backgrounded already — lockscreen needs the session-inactive
            // signal now to flip its icon to "play".
            audioSessionQueue.async {
                try? AVAudioSession.sharedInstance().setActive(false)
            }
        }
        updateNowPlaying()
    }

    /// Pause for a system audio event — an interruption beginning, or the
    /// output route disappearing. Two paths:
    ///
    /// - **Neural backends** (`supportsInterruptPause == true`): call
    ///   `backend.pause()`, which pauses the `AVAudioPlayerNode` in place.
    ///   `play()` later calls `backend.resume()` and audio picks up where
    ///   the system cut in. The utterance and its `currentUtteranceID` stay
    ///   live so the eventual natural `didFinish` still flows through.
    /// - **System backend** (`AVSpeechSynthesizer`): logical-only state
    ///   change; `pauseSpeaking()` from inside this notification handler
    ///   deadlocks Apple's TextToSpeech framework (observed: main thread
    ///   wedged permanently). `play()` re-issues the paragraph from
    ///   `activeCharOffset` via `speakCurrent()` instead.
    ///
    /// Either way the in-flight calibration sample is dropped — the paused
    /// interval would otherwise be baked into the observed duration.
    ///
    /// `stopOutput` distinguishes the two triggers for a non-pausable backend:
    /// an interruption (`.began`) arrives with the session already silenced by
    /// iOS, so a logical-only pause suffices. A route change
    /// (`.oldDeviceUnavailable`) leaves the session active and reroutes output
    /// to the built-in speaker, so the synth must be actively torn down or it
    /// keeps reading aloud. `stopSpeaking(at:.immediate)` (backend.stop) is
    /// safe here — only `pauseSpeaking`/`continueSpeaking` deadlock the
    /// TextToSpeech framework mid-interruption.
    private func pauseForSystemAudioEvent(suppressAutoResume: Bool, stopOutput: Bool = false) {
        guard isActive, isPlaying else { return }
        sessionRevision &+= 1
        clearUtteranceSample()
        if backend.supportsInterruptPause {
            backend.pause()
        } else {
            if stopOutput { backend.stop() }
            pendingCharOffset = activeCharOffset
            currentUtteranceID = nil
        }
        if suppressAutoResume { pausedByUser = true }
        isPlaying = false
        updateNowPlaying()
    }

    func skipForward()  { performQueueMutation { queue.advance() != nil } }
    func skipBackward() { performQueueMutation { queue.rewind() != nil } }

    /// Scrub to a 0...1 fraction of the CURRENT CHAPTER (chapter-local, the
    /// same basis the lockscreen scrubber uses — not the whole multi-chapter
    /// queue). Time-based via the estimator when a normalized chapter is
    /// available (char-level precision, honoring merged paragraphs);
    /// paragraph-span fallback otherwise.
    func seek(toProgress fraction: Double) {
        guard isActive else { return }
        let f = min(1.0, max(0.0, fraction))
        if let duration = currentEstimate().chapterDurationSec, duration > 0 {
            seekToElapsed(f * duration)
            return
        }
        performQueueMutation {
            guard queue.count > 0 else { return false }
            let first = queue.firstIndexOfCurrentChapter
            let last = queue.lastIndexOfCurrentChapter
            queue.seek(to: first + Int((f * Double(last - first)).rounded()))
            return true
        }
    }

    /// The mini-player calls this when its expanded state appears; while any
    /// observer is registered a 1 s tick re-publishes `chapterProgress`/
    /// `timeRemaining` so the scrub bar moves between paragraph boundaries
    /// while playing. Balanced with `endFineProgressUpdates()`; idempotent
    /// per observer.
    func beginFineProgressUpdates() {
        fineProgressObservers += 1
        guard fineProgressTask == nil else { return }
        fineProgressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.isActive, self.isPlaying { self.publishProgress() }
            }
        }
    }

    func endFineProgressUpdates() {
        fineProgressObservers = max(0, fineProgressObservers - 1)
        if fineProgressObservers == 0 {
            fineProgressTask?.cancel()
            fineProgressTask = nil
        }
    }

    /// Set/replace/cancel the sleep timer. Only meaningful during an active
    /// session; stop() from any source resets to `.off`. Pause deliberately
    /// does NOT cancel (Books semantics — the countdown is wall-clock).
    func setSleepTimer(_ timer: SleepTimer) {
        guard isActive else { return }
        sleepTask?.cancel()
        sleepTask = nil
        sleepDeadline = nil
        sleepTimer = timer
        guard case .minutes(let minutes) = timer else { return }
        let deadline = now().addingTimeInterval(TimeInterval(minutes) * 60)
        sleepDeadline = deadline
        // The Task only schedules the fire; sleepTimerDidFire re-validates
        // against the injected clock, so tests drive it directly.
        sleepTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.sleepTimerDidFire()
        }
    }

    /// Deadline check + stop. Internal (not private) so tests can invoke the
    /// fire path directly with a manipulated `now` — the scheduling Task
    /// above is deliberately not unit-tested.
    func sleepTimerDidFire() {
        guard isActive,
              case .minutes = sleepTimer,
              let deadline = sleepDeadline,
              now() >= deadline else { return }
        stop()
    }

    /// Restart the current chapter from its first paragraph.
    func resetChapter() {
        performQueueMutation {
            queue.seek(to: queue.firstIndexOfCurrentChapter)
            return true
        }
    }

    func stop() {
        sessionRevision &+= 1
        backend.stop()
        // Full-session stop also discards any prefetched audio (backend.stop
        // deliberately doesn't, because it's called between paragraphs to
        // make way for the next speak — we want the cache to survive there).
        backend.cancelAllPrefetches()
        currentUtteranceID = nil
        currentUtteranceStartedAt = nil
        currentUtteranceWordCount = 0
        isPlaying = false
        isActive = false
        pausedByUser = false
        artwork = nil
        novelTitle = ""
        currentChapterTitle = ""
        lastAnnouncedChapterKey = nil
        pendingCharOffset = 0
        activeCharOffset = 0
        currentNormalizedChapter = nil
        normalizedChapterCache.removeAll()
        currentLocalDisplayRange = nil
        chapterProgress = 0
        timeRemaining = nil
        sleepTask?.cancel()
        sleepTask = nil
        sleepDeadline = nil
        sleepTimer = .off
        deactivateAudioSession()
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    #if DEBUG
    /// Test seam: simulate the backend finishing the current utterance.
    func handleUtteranceFinishedForTesting() { handleUtteranceFinished() }
    /// Test seam: simulate the active output route disappearing (headphones
    /// unplugged / AirPods disconnected) so route-change handling is unit
    /// testable without a live `AVAudioSession`.
    func simulateOutputRouteLostForTesting() {
        handleRouteChange(Notification(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            ]
        ))
    }
    /// Test inspection: number of post-filter calibration samples observed.
    var calibratorSampleCountForTesting: Int { calibrator.sampleCount }
    /// Test inspection: current calibrated WPM (baseline until first valid sample).
    var calibratorCurrentWPMForTesting: Double { calibrator.currentWPM }
    /// Test inspection: global queue index across the whole (possibly multi-
    /// chapter) queue. Production reads `currentLocalDisplayRange`; tests need
    /// the global value to verify cross-chapter ordering after `queue.appendChapter`.
    var currentParagraphIndexForTesting: Int { queue.index }
    /// Test inspection: the queue's paragraph-count chapter progress (0..1)
    /// that resets per chapter. Distinct from the published time-based
    /// `chapterProgress`. Production reads it indirectly via `currentEstimate`
    /// for the lockscreen.
    var queueChapterProgressForTesting: Double { queue.chapterProgress }
    /// Test seam: re-derive the published progress pair on demand. The
    /// production trigger for between-boundary updates is the 1 s
    /// fine-progress tick (added with the mini-player UI).
    func publishProgressForTesting() { publishProgress() }
    /// Test inspection: whether the fine-progress tick Task is alive.
    var fineProgressActiveForTesting: Bool { fineProgressTask != nil }
    /// Test inspection: novel/chapter titles cached from the provider; production
    /// reads them internally for Now Playing metadata.
    var novelTitleForTesting: String { novelTitle }
    var currentChapterTitleForTesting: String { currentChapterTitle }
    /// Test seam: drop the normalized-chapter state so tests can force
    /// seek(toProgress:)'s paragraph-span fallback path.
    func clearNormalizedChapterForTesting() {
        currentNormalizedChapter = nil
        normalizedChapterCache.removeAll()
    }
    #endif

    // MARK: - Internals

    private func activateAudioSession() {
        audioSessionQueue.async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .spokenAudio)
            try? session.setActive(true)
        }
    }

    private func deactivateAudioSession() {
        audioSessionQueue.async {
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Register once for the lifetime of the singleton. The handler is a
    /// no-op when no session is active.
    private func registerInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.handleInterruption(note)
            }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard isActive,
              let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        switch type {
        case .began:
            // System-driven pause; leave `pausedByUser` alone so a prior
            // user-initiated pause still suppresses auto-resume on .ended.
            // Logical-only — never command the synth from here (deadlocks
            // the TextToSpeech framework mid-interruption).
            pauseForSystemAudioEvent(suppressAutoResume: false)
        case .ended:
            // Auto-resume only when the system asks AND we didn't pause by
            // user intent. Matches most iOS audio apps: Siri/calls resume,
            // but a user-toggled pause (or an AirPod pulled out) stays
            // paused even if the system later signals shouldResume.
            guard !pausedByUser,
                  let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) else {
                return
            }
            play()
        @unknown default:
            break
        }
    }

    /// Register once for the lifetime of the singleton. The handler is a
    /// no-op when no session is active.
    private func registerRouteChangeObserver() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.handleRouteChange(note)
            }
        }
    }

    /// Register once for the lifetime of the singleton. Fires when the app
    /// resigns active (lock, switch to another app, system sheet on top).
    private func registerWillResignActiveObserver() {
        willResignActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAppWillResignActive()
            }
        }
    }

    /// Deferred session deactivation per Apple's MPRemoteCommandCenter +
    /// AVAudioSession pattern: when the app backgrounds while we're paused,
    /// release the session so iOS flips the lockscreen icon to "play".
    /// While playing, keep the session active — the `audio` background mode
    /// requires it to keep producing audio on a locked device.
    private func handleAppWillResignActive() {
        guard isActive, !isPlaying else { return }
        audioSessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false)
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard isActive,
              let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        // `.oldDeviceUnavailable` is the canonical "active output route was
        // lost" signal: headphone unplug, AirPods disconnect, Bluetooth
        // speaker off. Per Apple's HIG, do NOT auto-resume on
        // `.newDeviceAvailable` (headphone plug-in).
        if reason == .oldDeviceUnavailable {
            // Unlike an interruption, a route change does not silence the
            // session — iOS reroutes output to the built-in speaker. A
            // non-pausable backend (AVSpeechSynthesizer) would keep reading
            // aloud, so `stopOutput` tears the utterance down. Suppress
            // auto-resume — a pulled-headphone pause should not resume on its
            // own.
            pauseForSystemAudioEvent(suppressAutoResume: true, stopOutput: true)
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        // AirPods single-press fires this directly; iOS's auto-routing of
        // toggle → play/pause based on playbackRate is unreliable across
        // versions. Owning the dispatch keeps our state in sync.
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: 15)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: 15)]
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        center.playCommand.addTarget { [weak self] _ in
            self?.play(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause(); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause(); return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.skipToNextChapter(); return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.skipToPreviousChapter(); return .success
        }
        center.skipForwardCommand.addTarget { [weak self] event in
            guard let self,
                  let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            self.skipBy(seconds: event.interval)
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] event in
            guard let self,
                  let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            self.skipBy(seconds: -event.interval)
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.seekToElapsed(event.positionTime)
            return .success
        }
    }

    /// Pull display metadata from the bound reader. Keeps the last known
    /// value when the provider is momentarily detached so the UI doesn't
    /// flash blank during a re-bind.
    private func refreshSessionMetadata() {
        if let provider {
            novelTitle = provider.ttsNovelTitle
            currentChapterTitle = provider.ttsChapterTitle(forKey: currentChapterKey ?? "")
        }
    }

    private func updateNowPlaying() {
        publishProgress()
        guard isActive else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentChapterTitle,
            MPMediaItemPropertyArtist: novelTitle,
            // Classify as audio so the system surfaces this in Control Center's
            // audio routing UI and the Dynamic Island. Both keys are set
            // because iOS reads them on different code paths.
            MPMediaItemPropertyMediaType: NSNumber(value: MPNowPlayingInfoMediaType.audio.rawValue),
            MPNowPlayingInfoPropertyMediaType: NSNumber(value: MPNowPlayingInfoMediaType.audio.rawValue),
            // Lockscreen playback rate is the wall-clock multiplier iOS uses
            // to interpolate elapsed time between updates, not the speech
            // rate. `chapterElapsedSec` already encodes speech rate.
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let art = artwork {
            info[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: art.size) { _ in art }
        }
        let estimate = currentEstimate()
        if let duration = estimate.chapterDurationSec, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let elapsed = estimate.chapterElapsedSec {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        // Explicit state signal — iOS otherwise infers from playbackRate and
        // often skips redrawing the lockscreen scrub/metadata when rate is
        // already 0, so paused-state skips don't visibly move the cursor
        // until the user resumes.
        center.playbackState = isPlaying ? .playing : .paused
    }

    /// Project the current cursor into a time estimate, or an all-nil
    /// estimate when no chapter is cached.
    private func currentEstimate() -> TTSEstimate {
        guard let chapter = currentNormalizedChapter else { return TTSEstimate() }
        return TTSEstimator.estimate(
            position: currentPosition,
            in: chapter,
            rate: Double(rate),
            calibratedWPM: calibrator.currentWPM
        )
    }

    /// Re-derive the published progress pair from the estimator. Called from
    /// `updateNowPlaying()` (which every cursor/state transition already
    /// funnels through) and from the fine-progress tick.
    private func publishProgress() {
        let estimate = currentEstimate()
        guard let duration = estimate.chapterDurationSec, duration > 0,
              var elapsed = estimate.chapterElapsedSec else {
            chapterProgress = 0
            timeRemaining = nil
            return
        }
        // Between paragraph boundaries the estimator's elapsed is static;
        // while playing, add the in-utterance wall time so the 1 s tick
        // moves smoothly. Capped at the next paragraph boundary's elapsed
        // (chapter end for the final paragraph) so an utterance that runs
        // longer than its estimated share can't sweep past the boundary —
        // the cursor advancing would then snap progress backward.
        if isPlaying, let startedAt = currentUtteranceStartedAt,
           let chapter = currentNormalizedChapter {
            var cap = duration
            let nextIndex = currentPosition.paragraphIndex + 1
            if nextIndex < chapter.paragraphs.count {
                let boundary = TTSEstimator.estimate(
                    position: TextChapterPosition(paragraphIndex: nextIndex),
                    in: chapter,
                    rate: Double(rate),
                    calibratedWPM: calibrator.currentWPM
                )
                if let boundaryElapsed = boundary.chapterElapsedSec {
                    cap = min(cap, boundaryElapsed)
                }
            }
            elapsed = min(cap, elapsed + now().timeIntervalSince(startedAt))
        }
        chapterProgress = min(1.0, max(0.0, elapsed / duration))
        timeRemaining = max(0, duration - elapsed)
    }

    /// Swap `currentNormalizedChapter` to the entry the cursor is now in.
    /// The chapter was populated into `normalizedChapterCache` at the queue-
    /// ingestion call site that owned the source text (start / userDidNavigate
    /// / loadNext / loadPrev) — rebuilding here from the queue's already-
    /// merged synthesis spokenText would re-feed pre-merged output into the
    /// merge layer and corrupt the position math.
    private func refreshNormalizedChapterIfNeeded() {
        guard let key = queue.current?.chapterKey else {
            currentNormalizedChapter = nil
            return
        }
        if currentNormalizedChapter?.id == key { return }
        currentNormalizedChapter = normalizedChapterCache[key]
    }

    /// Move the cursor to `position` within the current chapter, mirroring
    /// the play/paused semantics of `skipForward`/`skipBackward`.
    /// `charOffsetInParagraph` is honored via `pendingCharOffset` — the next
    /// `speakCurrent` constructs a substring utterance starting at (or just
    /// past) that offset, snapped to a word boundary. AVSpeechSynthesizer
    /// cannot restart inside an existing utterance, so we stop and re-issue
    /// with the remaining substring.
    func seek(to position: TextChapterPosition) {
        performQueueMutation {
            guard queue.count > 0 else { return false }
            let first = queue.firstIndexOfCurrentChapter
            let last = queue.lastIndexOfCurrentChapter
            queue.seek(to: min(max(first, first + position.paragraphIndex), last))
            pendingCharOffset = max(0, position.charOffsetInParagraph)
            return true
        }
    }

    /// Apply a ±N-second offset to the current elapsed time and seek to the
    /// resulting position. Backed by `TTSEstimator` so it stays consistent
    /// with the lockscreen scrub bar's reading of "elapsed".
    private func skipBy(seconds delta: TimeInterval) {
        guard isActive, let chapter = currentNormalizedChapter else { return }
        let estimate = currentEstimate()
        let currentElapsed = estimate.chapterElapsedSec ?? 0
        let target = max(0, currentElapsed + delta)
        let newPosition = TTSEstimator.position(
            forElapsedSec: target,
            in: chapter,
            rate: Double(rate),
            calibratedWPM: calibrator.currentWPM
        )
        seek(to: newPosition)
    }

    /// Seek to an absolute elapsed time within the current chapter. Handler
    /// for `MPRemoteCommandCenter.changePlaybackPositionCommand` (lockscreen
    /// scrubber) and the time-based path of `seek(toProgress:)`.
    private func seekToElapsed(_ elapsed: TimeInterval) {
        guard isActive, let chapter = currentNormalizedChapter else { return }
        let position = TTSEstimator.position(
            forElapsedSec: elapsed,
            in: chapter,
            rate: Double(rate),
            calibratedWPM: calibrator.currentWPM
        )
        seek(to: position)
    }

    /// Run a queue mutation inside the standard "snapshot play-state →
    /// mutate → bump session revision → activate" envelope. The mutation
    /// closure returns false to abort (e.g. advancing past the end of the
    /// queue or seeking on an empty queue).
    private func performQueueMutation(_ mutate: () -> Bool) {
        guard isActive else { return }
        let shouldContinuePlaying = isPlaying
        // Drop any pending mid-paragraph seek offset: it belonged to the
        // paragraph current *before* this mutation. `seek(to:)` re-sets it
        // inside `mutate` below, so its own offset survives; every other
        // mutation (skip/reset/seek-to-progress) clears it so a paused,
        // unconsumed offset can't clip the paragraph we land on.
        pendingCharOffset = 0
        guard mutate() else { return }
        sessionRevision &+= 1
        // Any prefetched buffer was speculative against the old cursor — drop
        // it. The next handleStartedUtterance repopulates based on the new
        // position.
        backend.cancelAllPrefetches()
        activateCurrent(playing: shouldContinuePlaying)
    }

    /// Apply a voice or rate change. Voice changes always restart the current
    /// utterance (the synthesized audio carries the voice character — no live
    /// swap). Rate changes go through the backend's live path when supported
    /// (neural backends time-stretch in flight via AVAudioUnitTimePitch); for
    /// backends without a live path (AVSpeechSynthesizer bakes rate into the
    /// utterance) we fall back to restart.
    private func applyConfigChange(resetCalibration: Bool) {
        if resetCalibration {
            calibrator.reset(forVoice: voiceIdentifier)
            // Voice change invalidates any voice-keyed prefetch cache.
            backend.cancelAllPrefetches()
        }
        backend.setLiveRate(rate)
        if resetCalibration || !backend.supportsLiveRateChange {
            restartCurrent()
        }
        updateNowPlaying()
    }

    private func restartCurrent() {
        guard isActive else { return }
        if backend.isPaused {
            backend.stop()
            currentUtteranceID = nil
            clearUtteranceSample()
        } else if isPlaying, backend.isSpeaking {
            speakCurrent()
        }
    }

    /// Switch the active synthesis backend. Resolves the new backend from the
    /// registry (preferred-if-ready, else the system backend), swaps it in,
    /// adopts its saved per-backend voice, and — if TTS was playing — restarts
    /// the current paragraph on the new backend. A no-op without a registry
    /// (the test seam) or when the resolved backend is already active.
    ///
    /// `currentBackendID` records the user's *preferred* backend; it may differ
    /// from the active `backend` when the preference resolves to a fallback
    /// (e.g. Kokoro is selected but not yet downloaded).
    private func switchBackend(toID id: String) {
        guard let registry else { return }
        let resolved = registry.currentBackend(preferredID: id)
        guard resolved.id != backend.id else { return }
        let wasPlaying = isPlaying
        currentUtteranceID = nil
        backend.stop()
        backend.delegate = nil
        backend = resolved
        backend.delegate = self
        clearUtteranceSample()
        // Adopt the new backend's saved voice. The didSet persists the value
        // and resets calibration; the didSet's restartCurrent is a no-op here
        // (the freshly swapped-in backend is not speaking), so playback is
        // driven explicitly below.
        let stored = UserDefaults.standard.string(forKey: Self.voiceKey(forBackendID: resolved.id))
        voiceIdentifier = stored ?? resolved.defaultVoiceID ?? ""
        if wasPlaying {
            activateAudioSession()
            speakCurrent()
        }
        updateNowPlaying()
        prewarmActiveBackendIfNeeded()
    }

    /// Fire-and-forget `prepare()` on the active backend so the first
    /// `speak()` doesn't pay the anecompilerservice cold-start. Idempotent;
    /// safe to call repeatedly. A no-op for the system backend whose
    /// `prepare()` returns immediately.
    private func prewarmActiveBackendIfNeeded() {
        guard backend.availability == .ready else { return }
        let target = backend
        Task { await target.prepare() }
    }

    private func activateCurrent(playing shouldPlay: Bool) {
        if shouldPlay {
            speakCurrent()
        } else {
            backend.stop()
            currentUtteranceID = nil
            clearUtteranceSample()
            isPlaying = false
            syncReaderToCursor()
            updateNowPlaying()
        }
    }

    /// Drop the in-flight sample so a late `didFinish` (e.g. after stop/pause
    /// flushes through the synth) can't be mistaken for a natural completion.
    private func clearUtteranceSample() {
        currentUtteranceStartedAt = nil
        currentUtteranceWordCount = 0
    }

    // MARK: - Reader session binding

    /// Re-point a live session at a reader instance and immediately re-emit
    /// the active paragraph so highlight/scroll catches up after recreation.
    func reattach(provider: TTSChapterProvider) {
        guard isActive else { return }
        self.provider = provider
        syncReaderToCursor()
    }

    /// Unbind only the provider that is currently attached. This prevents a
    /// stale reader teardown from detaching a newer reader instance.
    func detach(provider: TTSChapterProvider) {
        if self.provider === provider {
            self.provider = nil
        }
    }

    /// Re-emit the active paragraph callback for the queue's current cursor.
    func syncReaderToCursor() {
        guard isActive, let paragraph = queue.current else { return }
        refreshNormalizedChapterIfNeeded()
        currentLocalDisplayRange = paragraph.displayRange
        provider?.ttsDidActivateParagraphs(
            localDisplayRange: paragraph.displayRange,
            chapterKey: paragraph.chapterKey
        )
        refreshSessionMetadata()
    }

    private func speakCurrent() {
        guard let paragraph = queue.current else { return }
        refreshNormalizedChapterIfNeeded()
        backend.stop()
        currentUtteranceID = nil
        clearUtteranceSample()
        // Honor a pending mid-paragraph seek by taking the substring from
        // the requested offset (snapped to a word boundary); consume the
        // offset so subsequent paragraphs start at 0.
        let fullText = paragraph.spokenText
        let offset = pendingCharOffset
        pendingCharOffset = 0
        activeCharOffset = (offset > 0 && offset < fullText.count) ? offset : 0
        var textToSpeak = (offset > 0 && offset < fullText.count)
            ? Self.substring(of: fullText, fromOffsetSnappedToWordBoundary: offset)
            : fullText
        // Announce only on natural entry at a chapter's start. Mid-chapter
        // starts and mid-paragraph seeks (offset > 0) skip the announce.
        if announceChapterTitles,
           paragraph.chapterKey != lastAnnouncedChapterKey,
           queue.localIndexInCurrentChapter == 0,
           offset == 0 {
            let title = provider?.ttsChapterTitle(forKey: paragraph.chapterKey) ?? ""
            if !title.isEmpty {
                textToSpeak = "\(title). \(textToSpeak)"
            }
        }
        lastAnnouncedChapterKey = paragraph.chapterKey
        currentLocalDisplayRange = paragraph.displayRange
        provider?.ttsDidActivateParagraphs(
            localDisplayRange: paragraph.displayRange,
            chapterKey: paragraph.chapterKey
        )
        isPlaying = true
        utteranceCounter &+= 1
        currentUtteranceID = utteranceCounter
        // Word count is captured here (from the exact spoken string) because
        // the backend callbacks no longer carry the utterance text.
        currentUtteranceWordCount = NormalizedTextChapter.wordCount(textToSpeak)
        backend.speak(
            text: textToSpeak,
            voiceID: voiceIdentifier.isEmpty ? nil : voiceIdentifier,
            rate: rate,
            utteranceID: utteranceCounter
        )
        refreshSessionMetadata()
        updateNowPlaying()
    }

    private func handleFinishedUtterance(utteranceID: Int) {
        // Don't gate on `isPlaying`: the new in-place pause path keeps the
        // utterance live on the backend, so a buffer finishing the last
        // sample at the same moment the user pauses still arrives here with
        // a matching id. Advance the cursor regardless, but pass `isPlaying`
        // through as the continue-playing flag so paused users don't
        // suddenly hear the next paragraph start.
        guard isActive, currentUtteranceID == utteranceID else { return }
        currentUtteranceID = nil
        recordCalibrationSampleIfAvailable()
        handleUtteranceFinished(continuePlaying: isPlaying)
    }

    /// A backend reported a synthesis failure for `utteranceID`. v1 policy:
    /// drop the in-flight sample and advance past the failed paragraph so the
    /// session keeps moving rather than stalling. Same `isPlaying`-as-flag
    /// pattern as `handleFinishedUtterance` so a failure post-pause doesn't
    /// resume audio against the user's intent.
    private func handleFailedUtterance(utteranceID: Int, error: Error) {
        guard isActive, currentUtteranceID == utteranceID else { return }
        currentUtteranceID = nil
        clearUtteranceSample()
        handleUtteranceFinished(continuePlaying: isPlaying)
    }

    /// Feed the calibrator with the just-completed utterance's observed pace.
    /// Only the natural-finish path calls this; stop/pause/restart paths run
    /// `clearUtteranceSample()` first so a late delegate callback can't fire it.
    private func recordCalibrationSampleIfAvailable() {
        guard let startedAt = currentUtteranceStartedAt,
              currentUtteranceWordCount > 0 else {
            return
        }
        let durationSec = now().timeIntervalSince(startedAt)
        calibrator.recordSample(
            words: currentUtteranceWordCount,
            durationSec: durationSec,
            observedAtRate: Double(rate)
        )
        clearUtteranceSample()
    }

    private func handleStartedUtterance(utteranceID: Int) {
        guard isActive, currentUtteranceID == utteranceID else { return }
        currentUtteranceStartedAt = now()
        // Kick off speculative synthesis of paragraph N+1 while N plays. For
        // backends without a real prefetch impl (system, Kokoro currently),
        // this is a no-op via the protocol's default. For Supertonic-3 it
        // overlaps the N+1 synth with the N playback, eliminating the
        // inter-paragraph gap.
        schedulePrefetchForNextParagraph()
    }

    /// Look one paragraph ahead in the queue and tell the backend to start
    /// synthesizing it now. Within-chapter only — cross-chapter lookahead
    /// would need the async `ttsLoadNextChapter` path and isn't worth it for
    /// v1 (the chapter boundary is also a natural pause point).
    private func schedulePrefetchForNextParagraph() {
        let nextAbs = queue.index + 1
        guard nextAbs < queue.count else { return }
        let nextParagraph = queue.paragraphs[nextAbs]
        let voiceID = voiceIdentifier.isEmpty ? nil : voiceIdentifier
        backend.prefetch(text: nextParagraph.spokenText, voiceID: voiceID)
    }

    /// Called when an utterance finishes naturally: advance, or load next chapter.
    fileprivate func handleUtteranceFinished(continuePlaying shouldContinuePlaying: Bool = true) {
        if queue.advance() != nil {
            activateCurrent(playing: shouldContinuePlaying)
            return
        }
        guard !loadingNext else { return }
        loadingNext = true
        let revision = sessionRevision
        let finishedChapterKey = currentChapterKey
        Task { [weak self] in
            guard let self else { return }
            defer { self.loadingNext = false }
            guard let next = await self.provider?.ttsLoadNextChapter() else {
                guard self.isActive, self.sessionRevision == revision else { return }
                self.stop()
                return
            }
            guard self.isActive,
                  self.sessionRevision == revision,
                  self.currentChapterKey == finishedChapterKey else { return }
            let bundle = TTSText.chapterBundle(
                chapterKey: next.chapterKey,
                text: next.text,
                chapterTitle: self.provider?.ttsChapterTitle(forKey: next.chapterKey) ?? ""
            )
            guard !bundle.synthesisParagraphs.isEmpty else {
                self.stop()
                return
            }
            self.normalizedChapterCache[next.chapterKey] = bundle.normalizedChapter
            self.queue.appendChapter(bundle.synthesisParagraphs)
            if self.queue.advance() != nil {
                self.activateCurrent(playing: shouldContinuePlaying)
            } else {
                self.stop()
            }
        }
    }

    /// Lock-screen / remote "next track": jump to the next chapter boundary.
    func skipToNextChapter() {
        guard isActive else { return }
        // A next-chapter load is already in flight (natural end-of-chapter
        // rolled into it). That load lands exactly where next-track wants to
        // go, so let it complete. Bumping `sessionRevision` here would cancel
        // it via its staleness guard while `guard !loadingNext` blocks this
        // call from starting a replacement — leaving playback wedged.
        guard !loadingNext else { return }
        let shouldContinuePlaying = isPlaying
        sessionRevision &+= 1
        // Reuse the natural end-of-chapter path: jump to the last paragraph
        // of the current chapter and let finish-handling roll into the next.
        queue.seek(to: queue.lastIndexOfCurrentChapter)
        handleUtteranceFinished(continuePlaying: shouldContinuePlaying)
    }

    /// Lock-screen / remote "previous track": restart the current chapter,
    /// or load the previous one if already at the chapter's first paragraph.
    func skipToPreviousChapter() {
        guard isActive else { return }
        if queue.localIndexInCurrentChapter == 0 {
            sessionRevision &+= 1
            loadPreviousChapter(continuePlaying: isPlaying)
        } else {
            resetChapter()
            updateNowPlaying()
        }
    }

    private func loadPreviousChapter(continuePlaying shouldContinuePlaying: Bool = true) {
        guard !loadingChapterNav else { return }
        loadingChapterNav = true
        let revision = sessionRevision
        Task { [weak self] in
            guard let self else { return }
            defer { self.loadingChapterNav = false }
            guard let prev = await self.provider?.ttsLoadPreviousChapter() else { return }
            guard self.isActive, self.sessionRevision == revision else { return }
            let bundle = TTSText.chapterBundle(
                chapterKey: prev.chapterKey,
                text: prev.text,
                chapterTitle: self.provider?.ttsChapterTitle(forKey: prev.chapterKey) ?? ""
            )
            guard !bundle.synthesisParagraphs.isEmpty else { return }
            self.queue = TTSQueue(paragraphs: bundle.synthesisParagraphs, startIndex: 0)
            self.normalizedChapterCache = [prev.chapterKey: bundle.normalizedChapter]
            self.currentNormalizedChapter = nil
            self.refreshNormalizedChapterIfNeeded()
            self.activateCurrent(playing: shouldContinuePlaying)
            self.updateNowPlaying()
        }
    }

    /// Return the suffix of `text` starting at the next word boundary at or
    /// after `offset`: walk past any in-progress word, then past whitespace,
    /// landing on a clean word start. Used by mid-paragraph seeks so an
    /// utterance never starts mid-word.
    private static func substring(
        of text: String,
        fromOffsetSnappedToWordBoundary offset: Int
    ) -> String {
        let chars = Array(text)
        var i = min(max(0, offset), chars.count)
        while i < chars.count, !chars[i].isWhitespace { i += 1 }
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        if i >= chars.count { return "" }
        return String(chars[i...])
    }

    /// Rebuild the queue against `chapterKey` and narrate it from the top.
    /// Called when the visible reader scrolls into a new text chapter
    /// during a live session — user navigation is authoritative.
    func userDidNavigate(toChapterKey chapterKey: String, text: String) {
        guard isActive else { return }
        let bundle = TTSText.chapterBundle(
            chapterKey: chapterKey,
            text: text,
            chapterTitle: provider?.ttsChapterTitle(forKey: chapterKey) ?? ""
        )
        guard !bundle.synthesisParagraphs.isEmpty else {
            stop()
            return
        }
        sessionRevision &+= 1
        queue = TTSQueue(paragraphs: bundle.synthesisParagraphs, startIndex: 0)
        normalizedChapterCache = [chapterKey: bundle.normalizedChapter]
        currentNormalizedChapter = nil
        pendingCharOffset = 0
        refreshNormalizedChapterIfNeeded()
        activateCurrent(playing: isPlaying)
    }
}

extension TTSManager: SpeechBackendDelegate {
    func backendDidStart(utteranceID: Int) {
        handleStartedUtterance(utteranceID: utteranceID)
    }

    func backendDidFinish(utteranceID: Int) {
        handleFinishedUtterance(utteranceID: utteranceID)
    }

    func backendDidFail(utteranceID: Int, error: Error) {
        handleFailedUtterance(utteranceID: utteranceID, error: error)
    }
}
