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
    /// The reader should highlight (and, if enabled, scroll to) this paragraph.
    /// `localIndex` is 0-based *within `chapterKey`* (the reader renders one
    /// chapter at a time, numbered from 0).
    func ttsDidActivateParagraph(localIndex: Int, chapterKey: String)
}

@MainActor
final class TTSManager: NSObject, ObservableObject {
    static let shared: TTSManager = {
        let manager = TTSManager()
        manager.announceChapterTitles =
            UserDefaults.standard.object(forKey: announceChapterKey) as? Bool ?? true
        return manager
    }()

    @Published private(set) var isActive = false
    @Published private(set) var isPlaying = false
    /// Index within the current chapter (drives reader highlight).
    @Published private(set) var currentLocalIndex = 0
    @Published var artwork: UIImage?
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
            UserDefaults.standard.set(voiceIdentifier, forKey: Self.voiceKey)
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

    static let voiceKey = "Reader.ttsVoiceIdentifier"
    static let rateKey = "Reader.ttsRateMultiplier"
    static let highlightKey = "Reader.ttsHighlight"
    static let announceChapterKey = "Reader.ttsAnnounceChapter"

    private let backend: any SpeechSynthesisBackend
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
    private var calibrator = WPMCalibrator()
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

    init(
        backend: (any SpeechSynthesisBackend)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.backend = backend ?? SystemSpeechBackend()
        self.now = now
        let defaults = UserDefaults.standard
        self.voiceIdentifier = defaults.string(forKey: Self.voiceKey)
            ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())?.identifier
            ?? ""
        let storedRate = defaults.object(forKey: Self.rateKey) as? Float
        self.rate = storedRate ?? 1.0
        super.init()
        self.backend.delegate = self
        self.calibrator.reset(forVoice: voiceIdentifier)
        self.registerInterruptionObserver()
        self.registerRouteChangeObserver()
    }

    // MARK: - Lifecycle

    func start(
        provider: TTSChapterProvider,
        chapterKey: String,
        text: String,
        startIndex: Int
    ) {
        let paragraphs = TTSText.paragraphs(chapterKey: chapterKey, text: text)
        guard !paragraphs.isEmpty else {
            stop()
            return
        }
        sessionRevision &+= 1
        self.provider = provider
        queue = TTSQueue(paragraphs: paragraphs, startIndex: startIndex)
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
        // Re-issue the current paragraph rather than trusting the synthesizer's
        // state: a system interruption can leave AVSpeechSynthesizer
        // mid-utterance, and the interruption/route handlers deliberately never
        // command it (doing so deadlocks Apple's TextToSpeech framework — see
        // pauseForSystemAudioEvent). speakCurrent() stops the synth cleanly and
        // re-speaks, from this safe (non-interruption) context.
        speakCurrent()
    }

    /// User-initiated pause (toolbar button, lock-screen pauseCommand).
    func pause() {
        guard isActive else { return }
        sessionRevision &+= 1
        // Stop the synth and deactivate the audio session. While the session
        // is active, iOS dispatches pauseCommand for every play/pause gesture
        // regardless of MPNowPlayingInfoCenter.playbackState, and the
        // lock-screen icon stays on the pause glyph. Deactivating is the signal
        // iOS reads. Resume reactivates the session and re-issues the current
        // paragraph from activeCharOffset via speakCurrent. This is a
        // user-driven call (no interruption in flight), so commanding the synth
        // synchronously here is safe.
        backend.stop()
        pendingCharOffset = activeCharOffset
        currentUtteranceID = nil
        // Deactivate off the main thread (see audioSessionQueue). The session
        // still gets torn down — the lock-screen needs that — it just no
        // longer blocks the UI for ~580ms.
        audioSessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false)
        }
        pausedByUser = true
        // Drop the in-flight sample so a resume->finish doesn't bake the
        // paused wall-clock interval into the observed duration.
        clearUtteranceSample()
        isPlaying = false
        updateNowPlaying()
    }

    /// Logical pause for a system audio event — an interruption beginning, or
    /// the output route disappearing. Deliberately does NOT call into
    /// AVSpeechSynthesizer: issuing a synth control call synchronously from an
    /// AVAudioSession notification handler can deadlock inside Apple's
    /// TextToSpeech framework while it concurrently processes the same event
    /// (observed: the main thread wedged permanently in pauseSpeaking()). The
    /// system has already removed our audio output; the synthesizer is
    /// re-commanded only later, from a safe context — play() re-issues the
    /// current paragraph via speakCurrent().
    private func pauseForSystemAudioEvent(suppressAutoResume: Bool) {
        guard isActive, isPlaying else { return }
        sessionRevision &+= 1
        pendingCharOffset = activeCharOffset
        currentUtteranceID = nil
        clearUtteranceSample()
        if suppressAutoResume { pausedByUser = true }
        isPlaying = false
        updateNowPlaying()
    }

    func skipForward()  { performQueueMutation { queue.advance() != nil } }
    func skipBackward() { performQueueMutation { queue.rewind() != nil } }

    func seek(toProgress fraction: Double) {
        performQueueMutation {
            guard queue.count > 0 else { return false }
            queue.seek(to: Int((fraction * Double(queue.count - 1)).rounded()))
            return true
        }
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
        deactivateAudioSession()
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    #if DEBUG
    /// Test seam: simulate the backend finishing the current utterance.
    func handleUtteranceFinishedForTesting() { handleUtteranceFinished() }
    /// Test inspection: number of post-filter calibration samples observed.
    var calibratorSampleCountForTesting: Int { calibrator.sampleCount }
    /// Test inspection: current calibrated WPM (baseline until first valid sample).
    var calibratorCurrentWPMForTesting: Double { calibrator.currentWPM }
    /// Test inspection: global queue index across the whole (possibly multi-chapter)
    /// queue. Production reads `currentLocalIndex`; tests need the global value
    /// to verify cross-chapter ordering after `queue.appendChapter`.
    var currentParagraphIndexForTesting: Int { queue.index }
    /// Test inspection: chapter-local progress (0..1) that resets per chapter.
    /// Production reads it indirectly via `currentEstimate` for the lockscreen.
    var chapterProgressForTesting: Double { queue.chapterProgress }
    /// Test inspection: novel/chapter titles cached from the provider; production
    /// reads them internally for Now Playing metadata.
    var novelTitleForTesting: String { novelTitle }
    var currentChapterTitleForTesting: String { currentChapterTitle }
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
            // Logical-only pause via the system-event path: the route change
            // arrives as an AVAudioSession notification, and commanding the
            // synth synchronously from here can deadlock the TextToSpeech
            // framework. Suppress auto-resume — a pulled-headphone pause should
            // not resume on its own.
            pauseForSystemAudioEvent(suppressAutoResume: true)
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

    /// Rebuild `currentNormalizedChapter` when the cursor crosses into a
    /// different chapter than the cached one.
    private func refreshNormalizedChapterIfNeeded() {
        guard let key = queue.current?.chapterKey else {
            currentNormalizedChapter = nil
            return
        }
        if currentNormalizedChapter?.id == key { return }
        let paragraphs = queue.paragraphs
            .filter { $0.chapterKey == key }
            .map(\.spokenText)
        let title = provider?.ttsChapterTitle(forKey: key) ?? ""
        currentNormalizedChapter = NormalizedTextChapter(
            id: key,
            title: title,
            paragraphs: paragraphs
        )
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

    /// Handler for `MPRemoteCommandCenter.changePlaybackPositionCommand`.
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
        guard mutate() else { return }
        sessionRevision &+= 1
        activateCurrent(playing: shouldContinuePlaying)
    }

    /// Apply a voice or rate change: optionally reset per-voice calibration,
    /// restart the current utterance, and refresh Now Playing so the
    /// lockscreen scrub bar reflects the new pacing even while paused.
    /// AVSpeechUtterance bakes rate/voice in at construction, so the only
    /// way to apply them mid-paragraph is to issue a fresh utterance.
    private func applyConfigChange(resetCalibration: Bool) {
        if resetCalibration { calibrator.reset(forVoice: voiceIdentifier) }
        restartCurrent()
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
        currentLocalIndex = queue.localIndexInCurrentChapter
        provider?.ttsDidActivateParagraph(
            localIndex: queue.localIndexInCurrentChapter,
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
        currentLocalIndex = queue.localIndexInCurrentChapter
        provider?.ttsDidActivateParagraph(
            localIndex: queue.localIndexInCurrentChapter,
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
        guard isActive, isPlaying, currentUtteranceID == utteranceID else { return }
        currentUtteranceID = nil
        recordCalibrationSampleIfAvailable()
        handleUtteranceFinished()
    }

    /// A backend reported a synthesis failure for `utteranceID`. v1 policy:
    /// drop the in-flight sample and advance past the failed paragraph so the
    /// session keeps moving rather than stalling.
    private func handleFailedUtterance(utteranceID: Int, error: Error) {
        guard isActive, currentUtteranceID == utteranceID else { return }
        currentUtteranceID = nil
        clearUtteranceSample()
        handleUtteranceFinished()
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
            durationSec: durationSec
        )
        clearUtteranceSample()
    }

    private func handleStartedUtterance(utteranceID: Int) {
        guard isActive, currentUtteranceID == utteranceID else { return }
        currentUtteranceStartedAt = now()
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
            let more = TTSText.paragraphs(chapterKey: next.chapterKey, text: next.text)
            guard !more.isEmpty else {
                self.stop()
                return
            }
            self.queue.appendChapter(more)
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
            let paras = TTSText.paragraphs(chapterKey: prev.chapterKey, text: prev.text)
            guard !paras.isEmpty else { return }
            self.queue = TTSQueue(paragraphs: paras, startIndex: 0)
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
        let paragraphs = TTSText.paragraphs(chapterKey: chapterKey, text: text)
        guard !paragraphs.isEmpty else {
            stop()
            return
        }
        sessionRevision &+= 1
        queue = TTSQueue(paragraphs: paragraphs, startIndex: 0)
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
