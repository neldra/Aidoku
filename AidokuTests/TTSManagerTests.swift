import AVFoundation
import UIKit
import Testing
@testable import Aidoku

@MainActor
private final class MockSynth: SpeechSynthesizing {
    var speechDelegate: AVSpeechSynthesizerDelegate?
    var isSpeaking = false
    var isPaused = false
    private(set) var spoken: [String] = []
    private(set) var utterances: [AVSpeechUtterance] = []

    func speakUtterance(_ utterance: AVSpeechUtterance) {
        isSpeaking = true
        isPaused = false
        spoken.append(utterance.speechString)
        utterances.append(utterance)
    }
    func stopSpeakingNow() -> Bool { isSpeaking = false; isPaused = false; return true }
    func pauseSpeakingNow() -> Bool { isSpeaking = false; isPaused = true; return true }
    func continueSpeakingNow() -> Bool { isPaused = false; return true }
    func finish(_ utterance: AVSpeechUtterance) {
        speechDelegate?.speechSynthesizer?(AVSpeechSynthesizer(), didFinish: utterance)
    }
    func start(_ utterance: AVSpeechUtterance) {
        speechDelegate?.speechSynthesizer?(AVSpeechSynthesizer(), didStart: utterance)
    }
}

@MainActor
private final class StubProvider: TTSChapterProvider {
    var ttsNovelTitle = "Novel"
    func ttsChapterTitle(forKey key: String) -> String { key }
    var ttsArtwork: UIImage? { nil }
    var nextChapter: (chapterKey: String, text: String)?
    var previousChapter: (chapterKey: String, text: String)?
    var nextChapterDelay: UInt64 = 0
    var previousChapterDelay: UInt64 = 0
    private(set) var activated: [Int] = []

    func ttsLoadNextChapter() async -> (chapterKey: String, text: String)? {
        if nextChapterDelay > 0 {
            try? await Task.sleep(nanoseconds: nextChapterDelay)
        }
        defer { nextChapter = nil }
        return nextChapter
    }
    func ttsLoadPreviousChapter() async -> (chapterKey: String, text: String)? {
        if previousChapterDelay > 0 {
            try? await Task.sleep(nanoseconds: previousChapterDelay)
        }
        defer { previousChapter = nil }
        return previousChapter
    }
    func ttsDidActivateParagraph(localIndex: Int, chapterKey: String) {
        activated.append(localIndex)
    }
}

@MainActor
@Suite struct TTSManagerTests {
    @Test("start speaks the start paragraph and reports it active")
    func startSpeaks() {
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth)
        let provider = StubProvider()
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A\n\nB\n\nC", startIndex: 1)
        #expect(synth.spoken == ["B"])
        #expect(manager.currentParagraphIndex == 1)
        #expect(provider.activated == [1])
        #expect(manager.isActive && manager.isPlaying)
    }

    @Test("start with no narratable paragraphs stays inactive")
    func startEmptyStops() {
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth)
        manager.start(provider: StubProvider(), chapterKey: "c1",
                      text: " \n\n\t", startIndex: 0)
        #expect(synth.spoken.isEmpty)
        #expect(manager.isActive == false)
        #expect(manager.isPlaying == false)
    }

    @Test("finishing advances through paragraphs then stops at end")
    func advanceOnFinish() async {
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth)
        let provider = StubProvider()
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A\n\nB", startIndex: 0)
        manager.handleUtteranceFinishedForTesting()   // A -> B
        #expect(synth.spoken == ["A", "B"])
        manager.handleUtteranceFinishedForTesting()   // no next chapter
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(manager.isPlaying == false)
        #expect(manager.isActive == false)
    }

    @Test("auto-advances into the next chapter when provided")
    func crossChapter() async {
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth)
        let provider = StubProvider()
        provider.nextChapter = (chapterKey: "c2", text: "X\n\nY")
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A", startIndex: 0)
        manager.handleUtteranceFinishedForTesting()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(synth.spoken == ["A", "X"])
        #expect(manager.currentChapterKey == "c2")
    }

    @Test("pending next chapter load is ignored after stop")
    func pendingNextIgnoredAfterStop() async {
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth)
        let provider = StubProvider()
        provider.nextChapter = (chapterKey: "c2", text: "X\n\nY")
        provider.nextChapterDelay = 50_000_000
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A", startIndex: 0)

        manager.handleUtteranceFinishedForTesting()
        manager.stop()
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(synth.spoken == ["A"])
        #expect(manager.isActive == false)
        #expect(manager.isPlaying == false)
    }

    @Test("pending next chapter load cannot override user navigation")
    func pendingNextIgnoredAfterUserNavigation() async {
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth)
        let provider = StubProvider()
        provider.nextChapter = (chapterKey: "c2", text: "X\n\nY")
        provider.nextChapterDelay = 50_000_000
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A", startIndex: 0)

        manager.handleUtteranceFinishedForTesting()
        manager.userDidNavigate(toChapterKey: "c5", text: "M\n\nN")
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(manager.currentChapterKey == "c5")
        #expect(manager.currentParagraphIndex == 0)
        #expect(manager.currentLocalIndex == 0)
        #expect(synth.spoken == ["A", "M"])
        #expect(provider.activated == [0, 0])
    }

    @Test("skip forward/backward move one paragraph")
    func skip() {
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth)
        manager.start(provider: StubProvider(), chapterKey: "c1",
                      text: "A\n\nB\n\nC", startIndex: 0)
        manager.skipForward()
        #expect(manager.currentParagraphIndex == 1)
        manager.skipBackward()
        #expect(manager.currentParagraphIndex == 0)
    }

    @Test("controls are no-ops when inactive")
    func inactiveControlsNoop() {
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth)
        let provider = StubProvider()
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A\n\nB\n\nC", startIndex: 1)
        manager.stop()

        manager.pause()
        manager.skipForward()
        manager.skipBackward()
        manager.resetChapter()
        manager.seek(toProgress: 1)
        manager.play()

        #expect(manager.isActive == false)
        #expect(manager.isPlaying == false)
        #expect(manager.currentParagraphIndex == 1)
        #expect(synth.spoken == ["B"])
        #expect(provider.activated == [1])
    }

    @Test("paragraph controls while paused move the cursor without resuming")
    func pausedParagraphControlsDoNotResume() {
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth)
        let provider = StubProvider()
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A\n\nB\n\nC", startIndex: 0)
        manager.pause()

        manager.skipForward()
        #expect(manager.currentParagraphIndex == 1)
        #expect(manager.currentLocalIndex == 1)
        #expect(manager.isPlaying == false)
        #expect(synth.spoken == ["A"])
        #expect(provider.activated == [0, 1])

        manager.skipBackward()
        #expect(manager.currentParagraphIndex == 0)
        #expect(manager.currentLocalIndex == 0)
        #expect(manager.isPlaying == false)
        #expect(synth.spoken == ["A"])
        #expect(provider.activated == [0, 1, 0])
    }

    @Test("play after paused paragraph navigation speaks the selected paragraph")
    func playAfterPausedParagraphNavigation() {
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth)
        manager.start(provider: StubProvider(), chapterKey: "c1",
                      text: "A\n\nB\n\nC", startIndex: 0)
        manager.pause()
        manager.skipForward()

        manager.play()

        #expect(manager.currentParagraphIndex == 1)
        #expect(manager.currentLocalIndex == 1)
        #expect(synth.spoken == ["A", "B"])
        #expect(manager.isPlaying)
    }

    @Test("rate changes while playing restart the same paragraph only")
    func rateChangeKeepsCursor() {
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth)
        let provider = StubProvider()
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A\n\nB\n\nC", startIndex: 1)

        manager.rate = manager.rate == AVSpeechUtteranceDefaultSpeechRate * 1.5
            ? AVSpeechUtteranceDefaultSpeechRate
            : AVSpeechUtteranceDefaultSpeechRate * 1.5

        #expect(manager.currentParagraphIndex == 1)
        #expect(manager.currentLocalIndex == 1)
        #expect(synth.spoken == ["B", "B"])
        #expect(provider.activated == [1, 1])
        #expect(manager.isPlaying)
    }

    @Test("stale finish after rate restart does not advance the queue")
    func staleFinishAfterRateRestartDoesNotAdvance() async {
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth)
        let provider = StubProvider()
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A\n\nB\n\nC", startIndex: 1)
        let stoppedUtterance = synth.utterances[0]

        manager.rate = manager.rate == AVSpeechUtteranceDefaultSpeechRate * 1.5
            ? AVSpeechUtteranceDefaultSpeechRate
            : AVSpeechUtteranceDefaultSpeechRate * 1.5

        synth.finish(stoppedUtterance)
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(manager.currentParagraphIndex == 1)
        #expect(manager.currentLocalIndex == 1)
        #expect(synth.spoken == ["B", "B"])
        #expect(provider.activated == [1, 1])

        synth.finish(synth.utterances[1])
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(manager.currentParagraphIndex == 2)
        #expect(manager.currentLocalIndex == 2)
        #expect(synth.spoken == ["B", "B", "C"])
        #expect(provider.activated == [1, 1, 2])
    }

    @Test("rate changes while paused keep the cursor and paused state")
    func rateChangeWhilePausedDoesNotResume() {
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth)
        let provider = StubProvider()
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A\n\nB\n\nC", startIndex: 1)
        manager.pause()

        manager.rate = manager.rate == AVSpeechUtteranceDefaultSpeechRate * 1.5
            ? AVSpeechUtteranceDefaultSpeechRate
            : AVSpeechUtteranceDefaultSpeechRate * 1.5

        #expect(manager.currentParagraphIndex == 1)
        #expect(manager.currentLocalIndex == 1)
        #expect(synth.spoken == ["B"])
        #expect(provider.activated == [1])
        #expect(manager.isPlaying == false)
    }

    @Test("reattach re-points provider and re-emits the active paragraph")
    func reattachReSyncs() {
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth)
        let first = StubProvider()
        manager.start(provider: first, chapterKey: "c1",
                      text: "A\n\nB\n\nC", startIndex: 0)
        manager.skipForward()
        let second = StubProvider()
        manager.reattach(provider: second)
        #expect(second.activated == [1])
        #expect(manager.isActive)
    }

    @Test("reattach is a no-op when no session is active")
    func reattachInactive() {
        let manager = TTSManager(synthesizer: MockSynth())
        let provider = StubProvider()
        manager.reattach(provider: provider)
        #expect(provider.activated.isEmpty)
        #expect(manager.isActive == false)
    }

    @Test("detach unbinds only the matching provider")
    func detachIdentity() {
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth)
        let first = StubProvider()
        manager.start(provider: first, chapterKey: "c1",
                      text: "A\n\nB\n\nC\n\nD", startIndex: 0)
        manager.skipForward()
        let other = StubProvider()
        manager.detach(provider: other)
        manager.skipForward()
        #expect(first.activated == [0, 1, 2])
        manager.detach(provider: first)
        manager.skipForward()
        #expect(first.activated == [0, 1, 2])
    }

    @Test("userDidNavigate retargets the queue to the new chapter from the top")
    func navRetargets() {
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth)
        let provider = StubProvider()
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A\n\nB\n\nC", startIndex: 2)
        #expect(synth.spoken == ["C"])
        manager.userDidNavigate(toChapterKey: "c5", text: "X\n\nY")
        #expect(manager.currentChapterKey == "c5")
        #expect(manager.currentParagraphIndex == 0)
        #expect(synth.spoken == ["C", "X"])
        #expect(provider.activated == [2, 0])
    }

    @Test("userDidNavigate while paused retargets without resuming")
    func navWhilePausedDoesNotResume() {
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth)
        let provider = StubProvider()
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A\n\nB\n\nC", startIndex: 2)
        manager.pause()

        manager.userDidNavigate(toChapterKey: "c5", text: "X\n\nY")

        #expect(manager.currentChapterKey == "c5")
        #expect(manager.currentParagraphIndex == 0)
        #expect(manager.currentLocalIndex == 0)
        #expect(synth.spoken == ["C"])
        #expect(provider.activated == [2, 0])
        #expect(manager.isPlaying == false)
    }

    @Test("userDidNavigate is a no-op when no session is active")
    func navInactive() {
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth)
        manager.userDidNavigate(toChapterKey: "c5", text: "X\n\nY")
        #expect(synth.spoken.isEmpty)
        #expect(manager.isActive == false)
    }

    @Test("userDidNavigate to empty text stops the live session")
    func navEmptyStops() {
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth)
        manager.start(provider: StubProvider(), chapterKey: "c1",
                      text: "A\n\nB", startIndex: 0)
        manager.userDidNavigate(toChapterKey: "empty", text: " \n\n ")
        #expect(synth.spoken == ["A"])
        #expect(manager.isActive == false)
        #expect(manager.isPlaying == false)
    }

    @Test("remote next chapter while paused retargets without resuming")
    func remoteNextWhilePausedDoesNotResume() async {
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth)
        let provider = StubProvider()
        provider.nextChapter = (chapterKey: "c2", text: "X\n\nY")
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A", startIndex: 0)
        manager.pause()

        manager.skipToNextChapter()
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(manager.currentChapterKey == "c2")
        #expect(manager.currentParagraphIndex == 1)
        #expect(manager.currentLocalIndex == 0)
        #expect(synth.spoken == ["A"])
        #expect(provider.activated == [0, 0])
        #expect(manager.isPlaying == false)
    }

    @Test("remote previous chapter while paused retargets without resuming")
    func remotePreviousWhilePausedDoesNotResume() async {
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth)
        let provider = StubProvider()
        provider.previousChapter = (chapterKey: "c0", text: "X\n\nY")
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A\n\nB", startIndex: 0)
        manager.pause()

        manager.skipToPreviousChapter()
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(manager.currentChapterKey == "c0")
        #expect(manager.currentParagraphIndex == 0)
        #expect(manager.currentLocalIndex == 0)
        #expect(synth.spoken == ["A"])
        #expect(provider.activated == [0, 0])
        #expect(manager.isPlaying == false)
    }

    @Test("session exposes observable novel & chapter titles that follow navigation")
    func sessionTitlesFollowNavigation() {
        let manager = TTSManager(synthesizer: MockSynth())
        let provider = StubProvider()
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A\n\nB", startIndex: 0)
        #expect(manager.novelTitle == "Novel")
        #expect(manager.currentChapterTitle == "c1")
        manager.userDidNavigate(toChapterKey: "c2", text: "X\n\nY")
        #expect(manager.currentChapterTitle == "c2")
    }

    @Test("progress is chapter-local and resets when the chapter changes")
    func progressIsChapterLocal() {
        let manager = TTSManager(synthesizer: MockSynth())
        manager.start(provider: StubProvider(), chapterKey: "c1",
                      text: "A\n\nB\n\nC", startIndex: 2)
        #expect(manager.progress == 1)             // last paragraph of c1
        manager.userDidNavigate(toChapterKey: "c2", text: "X\n\nY\n\nZ")
        #expect(manager.progress == 0)             // reset at the top of c2
    }

    @Test("announces the chapter title once when entering each chapter")
    func announcesChapterTitleOnChange() {
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth)
        manager.announceChapterTitles = true
        let provider = StubProvider()              // ttsChapterTitle returns the key
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A\n\nB", startIndex: 0)
        #expect(synth.spoken == ["c1. A"])         // title precedes the first paragraph
        manager.skipForward()
        #expect(synth.spoken == ["c1. A", "B"])    // no re-announce within the chapter
        manager.userDidNavigate(toChapterKey: "c2", text: "X\n\nY")
        #expect(synth.spoken == ["c1. A", "B", "c2. X"])  // announced on chapter change
    }

    @Test("chapter announcement is off by default for the test initializer")
    func announcementOffByDefault() {
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth)
        manager.start(provider: StubProvider(), chapterKey: "c1",
                      text: "A\n\nB", startIndex: 0)
        #expect(synth.spoken == ["A"])
    }

    @Test("calibrator records a sample after didStart -> didFinish on the same utterance")
    func calibratorRecordsSampleOnNaturalFinish() async {
        // Inject a deterministic clock that advances by 60s between didStart
        // and didFinish so the observed WPM lands inside the filter window.
        var ticks = 0
        let times: [Date] = [
            Date(timeIntervalSince1970: 0),       // didStart
            Date(timeIntervalSince1970: 60),      // didFinish -> 60s duration
        ]
        let clock: () -> Date = {
            defer { ticks = min(ticks + 1, times.count - 1) }
            return times[ticks]
        }
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth, now: clock)
        let provider = StubProvider()
        // 60 words: at 60s that is 60 WPM, comfortably inside [50, 500].
        let words = Array(repeating: "alpha", count: 60).joined(separator: " ")
        manager.start(provider: provider, chapterKey: "c1",
                      text: words, startIndex: 0)
        #expect(manager.calibratorSampleCountForTesting == 0)

        let utterance = synth.utterances[0]
        synth.start(utterance)
        await Task.yield()
        synth.finish(utterance)
        await Task.yield()
        // Allow the @MainActor delegate hop tasks to drain.
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(manager.calibratorSampleCountForTesting == 1)
        #expect(abs(manager.calibratorCurrentWPMForTesting - 60.0) < 0.0001)
    }

    @Test("interrupted utterance does not feed the calibrator")
    func calibratorIgnoresInterruptedUtterance() async {
        var ticks = 0
        let times: [Date] = [
            Date(timeIntervalSince1970: 0),    // didStart on first utterance
            Date(timeIntervalSince1970: 60),   // (unused after pause clears sample)
        ]
        let clock: () -> Date = {
            defer { ticks = min(ticks + 1, times.count - 1) }
            return times[ticks]
        }
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth, now: clock)
        let provider = StubProvider()
        let words = Array(repeating: "alpha", count: 60).joined(separator: " ")
        manager.start(provider: provider, chapterKey: "c1",
                      text: words, startIndex: 0)

        let utterance = synth.utterances[0]
        synth.start(utterance)
        await Task.yield()
        // Pause clears the in-flight sample; the synthesizer's late didFinish
        // (which mirrors AVSpeech's behaviour after stopSpeakingNow) must not
        // be misread as a natural completion.
        manager.pause()
        synth.finish(utterance)
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(manager.calibratorSampleCountForTesting == 0)
    }
}
