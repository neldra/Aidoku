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
        // Off by default for the test-facing initializer (keeps the spoken
        // assertions stable); the real session honors the user's setting.
        manager.announceChapterTitles =
            UserDefaults.standard.object(forKey: announceChapterKey) as? Bool ?? true
        return manager
    }()

    @Published private(set) var isActive = false
    @Published private(set) var isPlaying = false
    /// Global index across the whole loaded queue (drives `progress`).
    @Published private(set) var currentParagraphIndex = 0
    /// Index within the current chapter (drives reader highlight).
    @Published private(set) var currentLocalIndex = 0
    @Published private(set) var paragraphCount = 0
    /// Observable session metadata so the player UIs reflect the *live*
    /// session instead of values snapshotted at presentation time.
    @Published private(set) var novelTitle = ""
    @Published private(set) var currentChapterTitle = ""
    @Published var artwork: UIImage?
    /// When true, the chapter title is spoken before the first paragraph of
    /// every chapter the narration enters. Defaults off here so unit tests
    /// see pure paragraph text; `shared` enables it from `UserDefaults`.
    @Published var announceChapterTitles = false {
        didSet {
            UserDefaults.standard.set(announceChapterTitles, forKey: Self.announceChapterKey)
        }
    }
    @Published var voiceIdentifier: String {
        didSet {
            UserDefaults.standard.set(voiceIdentifier, forKey: Self.voiceKey)
            if oldValue != voiceIdentifier {
                // Voice change invalidates the WPM observation history —
                // the next utterance's pacing belongs to a different voice.
                calibrator.reset(forVoice: voiceIdentifier)
                restartCurrent()
            }
        }
    }
    @Published var rate: Float {
        didSet {
            UserDefaults.standard.set(rate, forKey: Self.rateKey)
            if oldValue != rate { restartCurrent() }
        }
    }

    static let voiceKey = "Reader.ttsVoiceIdentifier"
    static let rateKey = "Reader.ttsRate"
    static let highlightKey = "Reader.ttsHighlight"
    static let announceChapterKey = "Reader.ttsAnnounceChapter"

    private let synthesizer: SpeechSynthesizing
    private var queue = TTSQueue(paragraphs: [])
    private weak var provider: TTSChapterProvider?
    private var loadingNext = false
    private var loadingChapterNav = false
    private var currentUtterance: AVSpeechUtterance?
    private var sessionRevision = 0
    /// Chapter the title was last spoken for; used to announce the title
    /// exactly once per chapter the narration enters (not per paragraph).
    private var lastAnnouncedChapterKey: String?

    /// Normalized view of the chapter the cursor is currently in, lazily
    /// rebuilt whenever `queue.current?.chapterKey` changes. Feeds the time
    /// estimator + scrub/skip handlers; an `id` mismatch is the sole rebuild
    /// trigger so per-paragraph advances don't pay the rebuild cost.
    private var currentNormalizedChapter: NormalizedTextChapter?
    /// Per-voice WPM estimate; reset on voice change. Seeded with the
    /// baseline until enough utterance timing samples arrive (the recording
    /// path itself ships in a follow-up step).
    private var calibrator = WPMCalibrator()

    /// Chapter-local (0...1); resets to 0 each time the active chapter
    /// changes so the player/mini-player progress bar restarts per chapter
    /// instead of accumulating across the appended multi-chapter queue.
    var progress: Double { queue.chapterProgress }
    var currentChapterKey: String? { queue.current?.chapterKey }

    /// Position of the narration cursor inside `currentNormalizedChapter`.
    /// `charOffsetInParagraph` is always 0 until `willSpeakRangeOfSpeechString`
    /// is wired — paragraph-granular is the best precision available today.
    var currentPosition: TextChapterPosition {
        TextChapterPosition(
            paragraphIndex: queue.localIndexInCurrentChapter,
            charOffsetInParagraph: 0
        )
    }

    init(synthesizer: SpeechSynthesizing = AVSpeechSynthesizer()) {
        self.synthesizer = synthesizer
        let defaults = UserDefaults.standard
        self.voiceIdentifier = defaults.string(forKey: Self.voiceKey)
            ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())?.identifier
            ?? ""
        let storedRate = defaults.object(forKey: Self.rateKey) as? Float
        self.rate = storedRate ?? AVSpeechUtteranceDefaultSpeechRate
        super.init()
        self.synthesizer.speechDelegate = self
        self.calibrator.reset(forVoice: voiceIdentifier)
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
        paragraphCount = queue.count
        currentNormalizedChapter = nil
        refreshNormalizedChapterIfNeeded()
        isActive = true
        activateAudioSession()
        configureRemoteCommands()
        speakCurrent()
    }

    func togglePlayPause() { isPlaying ? pause() : play() }

    func play() {
        guard isActive else { return }
        if synthesizer.isPaused {
            synthesizer.continueSpeakingNow()
            isPlaying = true
        } else if !synthesizer.isSpeaking {
            speakCurrent()
        } else {
            isPlaying = true
        }
        updateNowPlaying()
    }

    func pause() {
        guard isActive else { return }
        sessionRevision &+= 1
        synthesizer.pauseSpeakingNow()
        isPlaying = false
        updateNowPlaying()
    }

    func skipForward() {
        guard isActive else { return }
        let shouldContinuePlaying = isPlaying
        guard queue.advance() != nil else { return }
        sessionRevision &+= 1
        activateCurrent(playing: shouldContinuePlaying)
    }

    func skipBackward() {
        guard isActive else { return }
        let shouldContinuePlaying = isPlaying
        guard queue.rewind() != nil else { return }
        sessionRevision &+= 1
        activateCurrent(playing: shouldContinuePlaying)
    }

    func seek(toProgress fraction: Double) {
        guard isActive, queue.count > 0 else { return }
        let shouldContinuePlaying = isPlaying
        sessionRevision &+= 1
        queue.seek(to: Int((fraction * Double(queue.count - 1)).rounded()))
        activateCurrent(playing: shouldContinuePlaying)
    }

    /// Restart the current chapter from its first paragraph.
    func resetChapter() {
        guard isActive else { return }
        let shouldContinuePlaying = isPlaying
        sessionRevision &+= 1
        queue.seek(to: queue.firstIndexOfCurrentChapter)
        activateCurrent(playing: shouldContinuePlaying)
    }

    func stop() {
        sessionRevision &+= 1
        synthesizer.stopSpeakingNow()
        currentUtterance = nil
        isPlaying = false
        isActive = false
        artwork = nil
        novelTitle = ""
        currentChapterTitle = ""
        lastAnnouncedChapterKey = nil
        deactivateAudioSession()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    #if DEBUG
    /// Test seam: simulate the synthesizer finishing the current utterance.
    func handleUtteranceFinishedForTesting() { handleUtteranceFinished() }
    #endif

    // MARK: - Internals

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        // Spec §5.5: enable scrub + ±15s using time-derived position math.
        // The earlier prototype disabled these because there was no time model;
        // TTSEstimator now lets us convert between elapsed seconds and position.
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

    /// Pull display metadata from the bound reader for the *current* chapter.
    /// Keeps the last known value if the provider is momentarily detached so
    /// the UI never flashes blank during a re-bind.
    private func refreshSessionMetadata() {
        if let provider {
            novelTitle = provider.ttsNovelTitle
            currentChapterTitle = provider.ttsChapterTitle(forKey: currentChapterKey ?? "")
        }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentChapterTitle,
            MPMediaItemPropertyArtist: novelTitle,
            // Classify as audio so the system surfaces this in Control Center's
            // audio routing UI and (on iPhone 14 Pro+/15+) the Dynamic Island.
            // Spec §7.2 — both properties exist for historical reasons; iOS
            // reads `MPNowPlayingInfoPropertyMediaType` and `MPMediaItem`'s
            // `MediaType` at different code paths.
            MPMediaItemPropertyMediaType: NSNumber(value: MPNowPlayingInfoMediaType.audio.rawValue),
            MPNowPlayingInfoPropertyMediaType: NSNumber(value: MPNowPlayingInfoMediaType.audio.rawValue),
            // Lockscreen "playback rate" is decoupled from speech rate: it's
            // the wall-clock multiplier iOS uses to interpolate elapsed time
            // between updates. Our `chapterElapsedSec` already encodes speech
            // rate, so report 1.0 when playing, 0.0 when paused.
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Speech rate as a multiplier of "normal" pace, where 0.5
    /// (`AVSpeechUtteranceDefaultSpeechRate`) maps to 1.0× and the slider's
    /// 1.5× position maps to 1.5×. The mapping is approximate — AVSpeech's
    /// internal rate-to-WPM curve is non-linear — but the calibrator absorbs
    /// the residual error over a few samples.
    private var rateMultiplier: Double {
        let defaultRate = Double(AVSpeechUtteranceDefaultSpeechRate)
        guard defaultRate > 0 else { return 1.0 }
        return Double(rate) / defaultRate
    }

    /// Project the current cursor into a time estimate. Returns an all-nil
    /// estimate when no chapter is cached (start path, inactive session).
    private func currentEstimate() -> TTSEstimate {
        guard let chapter = currentNormalizedChapter else { return TTSEstimate() }
        return TTSEstimator.estimate(
            position: currentPosition,
            in: chapter,
            rate: rateMultiplier,
            calibratedWPM: calibrator.currentWPM
        )
    }

    /// Rebuild `currentNormalizedChapter` when the cursor crosses into a
    /// chapter different from the cached one. The queue can hold paragraphs
    /// from multiple appended chapters; the estimator only ever needs the
    /// *current* one (chapter-local time math).
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

    /// Move the cursor to the paragraph at `position` within the current
    /// chapter, mirroring the play/paused semantics of `skipForward`/`skipBackward`.
    /// `charOffsetInParagraph` is ignored until mid-paragraph seek is wired —
    /// AVSpeechSynthesizer can't restart inside an utterance natively.
    func seek(to position: TextChapterPosition) {
        guard isActive, queue.count > 0 else { return }
        let first = queue.firstIndexOfCurrentChapter
        let last = queue.lastIndexOfCurrentChapter
        let absolute = min(max(first, first + position.paragraphIndex), last)
        let shouldContinuePlaying = isPlaying
        sessionRevision &+= 1
        queue.seek(to: absolute)
        activateCurrent(playing: shouldContinuePlaying)
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
            rate: rateMultiplier,
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
            rate: rateMultiplier,
            calibratedWPM: calibrator.currentWPM
        )
        seek(to: position)
    }

    /// Apply a rate or voice change to the current paragraph.
    /// AVSpeechUtterance bakes rate/voice in at construction, so the only way
    /// to "change" them mid-paragraph is to stop the current utterance and
    /// start a new one. Handles both states:
    /// - speaking: restart the paragraph immediately at the new rate/voice
    /// - paused: drop the paused utterance so `play()` builds a fresh one
    ///   with the current rate/voice on resume (instead of `continueSpeakingNow`
    ///   on the stale utterance, which retains the old rate)
    /// Inactive / between-utterance states need no action — the next
    /// `speakCurrent()` reads the current rate/voice naturally.
    private func restartCurrent() {
        guard isActive else { return }
        if synthesizer.isPaused {
            synthesizer.stopSpeakingNow()
            currentUtterance = nil
        } else if isPlaying, synthesizer.isSpeaking {
            speakCurrent()
        }
    }

    private func activateCurrent(playing shouldPlay: Bool) {
        if shouldPlay {
            speakCurrent()
        } else {
            synthesizer.stopSpeakingNow()
            currentUtterance = nil
            isPlaying = false
            syncReaderToCursor()
            updateNowPlaying()
        }
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
        currentParagraphIndex = queue.index
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
        synthesizer.stopSpeakingNow()
        currentUtterance = nil
        var textToSpeak = paragraph.spokenText
        // Only announce on natural entry at a chapter's start. Mid-chapter
        // starts (user tapped headphones at paragraph N) skip the announce:
        // the user already has context. Auto-advance / userDidNavigate /
        // loadPreviousChapter all land at localIndex 0 so they still announce.
        if announceChapterTitles,
           paragraph.chapterKey != lastAnnouncedChapterKey,
           queue.localIndexInCurrentChapter == 0 {
            let title = provider?.ttsChapterTitle(forKey: paragraph.chapterKey) ?? ""
            if !title.isEmpty {
                textToSpeak = "\(title). \(textToSpeak)"
            }
        }
        lastAnnouncedChapterKey = paragraph.chapterKey
        let utterance = AVSpeechUtterance(string: textToSpeak)
        if let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        }
        utterance.rate = rate
        currentParagraphIndex = queue.index
        currentLocalIndex = queue.localIndexInCurrentChapter
        provider?.ttsDidActivateParagraph(
            localIndex: queue.localIndexInCurrentChapter,
            chapterKey: paragraph.chapterKey
        )
        isPlaying = true
        currentUtterance = utterance
        synthesizer.speakUtterance(utterance)
        refreshSessionMetadata()
        updateNowPlaying()
    }

    private func handleFinishedUtterance(_ utterance: AVSpeechUtterance) {
        guard isActive, isPlaying, currentUtterance === utterance else { return }
        currentUtterance = nil
        handleUtteranceFinished()
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
            self.paragraphCount = self.queue.count
            if self.queue.advance() != nil {
                self.activateCurrent(playing: shouldContinuePlaying)
            } else {
                self.stop()
            }
        }
    }

    /// Lock-screen / remote "next track" = jump to the next chapter boundary.
    func skipToNextChapter() {
        guard isActive else { return }
        let shouldContinuePlaying = isPlaying
        sessionRevision &+= 1
        // Reuse the natural end-of-chapter path: jump to the last paragraph
        // of the current chapter, then let finish-handling load and roll
        // into the next chapter.
        queue.seek(to: queue.lastIndexOfCurrentChapter)
        handleUtteranceFinished(continuePlaying: shouldContinuePlaying)
    }

    /// Lock-screen / remote "previous track" = restart current chapter, or
    /// (if already at the chapter's first paragraph) load the previous one.
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
            self.paragraphCount = self.queue.count
            self.currentNormalizedChapter = nil
            self.refreshNormalizedChapterIfNeeded()
            self.activateCurrent(playing: shouldContinuePlaying)
            self.updateNowPlaying()
        }
    }

    /// User-driven reader navigation is authoritative. When the visible
    /// reader moves to a new text chapter during a live session, rebuild the
    /// queue and narrate that chapter from the top.
    func userDidNavigate(toChapterKey chapterKey: String, text: String) {
        guard isActive else { return }
        let paragraphs = TTSText.paragraphs(chapterKey: chapterKey, text: text)
        guard !paragraphs.isEmpty else {
            stop()
            return
        }
        sessionRevision &+= 1
        queue = TTSQueue(paragraphs: paragraphs, startIndex: 0)
        paragraphCount = queue.count
        currentNormalizedChapter = nil
        refreshNormalizedChapterIfNeeded()
        activateCurrent(playing: isPlaying)
    }
}

extension TTSManager: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.handleFinishedUtterance(utterance) }
    }
}
