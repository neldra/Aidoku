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
    /// The reader should highlight (and, if enabled, scroll to) this paragraph.
    /// `localIndex` is 0-based *within `chapterKey`* (the reader renders one
    /// chapter at a time, numbered from 0).
    func ttsDidActivateParagraph(localIndex: Int, chapterKey: String)
}

@MainActor
final class TTSManager: NSObject, ObservableObject {
    static let shared = TTSManager()

    @Published private(set) var isActive = false
    @Published private(set) var isPlaying = false
    /// Global index across the whole loaded queue (drives `progress`).
    @Published private(set) var currentParagraphIndex = 0
    /// Index within the current chapter (drives reader highlight).
    @Published private(set) var currentLocalIndex = 0
    @Published private(set) var paragraphCount = 0
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

    private let synthesizer: SpeechSynthesizing
    private var queue = TTSQueue(paragraphs: [])
    private weak var provider: TTSChapterProvider?
    private var loadingNext = false

    var progress: Double { queue.progress }
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
        self.provider = provider
        let paragraphs = TTSText.paragraphs(chapterKey: chapterKey, text: text)
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
        synthesizer.pauseSpeakingNow()
        isPlaying = false
        updateNowPlaying()
    }

    func skipForward() {
        guard queue.advance() != nil else { return }
        speakCurrent()
    }

    func skipBackward() {
        guard queue.rewind() != nil else { return }
        speakCurrent()
    }

    func seek(toProgress fraction: Double) {
        guard queue.count > 0 else { return }
        queue.seek(to: Int((fraction * Double(queue.count - 1)).rounded()))
        speakCurrent()
    }

    /// Restart the current chapter from its first paragraph.
    func resetChapter() {
        queue.seek(to: 0)
        speakCurrent()
    }

    func stop() {
        synthesizer.stopSpeakingNow()
        isPlaying = false
        isActive = false
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

        center.playCommand.addTarget { [weak self] _ in
            self?.play(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause(); return .success
        }
        center.skipForwardCommand.preferredIntervals = [1]
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.skipForward(); return .success
        }
        center.skipBackwardCommand.preferredIntervals = [1]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skipBackward(); return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.handleUtteranceFinished() // jump to next chapter boundary
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.resetChapter(); return .success
        }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle:
                provider?.ttsChapterTitle(forKey: currentChapterKey ?? "") ?? "",
            MPMediaItemPropertyArtist: provider?.ttsNovelTitle ?? "",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPMediaItemPropertyPlaybackDuration: Double(max(queue.count - 1, 1)),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(queue.index)
        ]
        if let art = provider?.ttsArtwork {
            info[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: art.size) { _ in art }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func restartCurrent() {
        guard isActive, synthesizer.isSpeaking || synthesizer.isPaused else { return }
        speakCurrent()
    }

    private func speakCurrent() {
        guard let paragraph = queue.current else { return }
        synthesizer.stopSpeakingNow()
        let utterance = AVSpeechUtterance(string: paragraph.spokenText)
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
        synthesizer.speakUtterance(utterance)
        updateNowPlaying()
    }

    /// Called when an utterance finishes naturally: advance, or load next chapter.
    fileprivate func handleUtteranceFinished() {
        if queue.advance() != nil {
            speakCurrent()
            return
        }
        guard !loadingNext else { return }
        loadingNext = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.loadingNext = false }
            guard let next = await self.provider?.ttsLoadNextChapter() else {
                self.isPlaying = false
                return
            }
            let more = TTSText.paragraphs(chapterKey: next.chapterKey, text: next.text)
            guard !more.isEmpty else { self.isPlaying = false; return }
            self.queue.appendChapter(more)
            self.paragraphCount = self.queue.count
            if self.queue.advance() != nil {
                self.speakCurrent()
            } else {
                self.isPlaying = false
            }
        }
    }
}

extension TTSManager: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.handleUtteranceFinished() }
    }
}
