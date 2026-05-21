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
            if oldValue != voiceIdentifier { restartCurrent() }
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

    /// Chapter-local (0...1); resets to 0 each time the active chapter
    /// changes so the player/mini-player progress bar restarts per chapter
    /// instead of accumulating across the appended multi-chapter queue.
    var progress: Double { queue.chapterProgress }
    var currentChapterKey: String? { queue.current?.chapterKey }

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
        // Eyes-free surface: only play/pause + whole-chapter prev/next.
        // Paragraph skip is a reading-context action (in-app only); the
        // ±-second skip glyphs misrepresent it, so disable them.
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true

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
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let art = artwork {
            info[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: art.size) { _ in art }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func restartCurrent() {
        guard isActive, isPlaying, synthesizer.isSpeaking, !synthesizer.isPaused else { return }
        speakCurrent()
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
        synthesizer.stopSpeakingNow()
        currentUtterance = nil
        var textToSpeak = paragraph.spokenText
        if announceChapterTitles, paragraph.chapterKey != lastAnnouncedChapterKey {
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
