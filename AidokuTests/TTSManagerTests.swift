import UIKit
import Testing
@testable import Aidoku

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
    /// Every range the provider has seen, in arrival order. Useful for
    /// asserting the multi-paragraph highlight fans out across the merged
    /// span; the bare-lowerBound `activated` array stays for tests that
    /// only care about the cursor's position.
    private(set) var activatedRanges: [Range<Int>] = []

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
    func ttsDidActivateParagraphs(localDisplayRange: Range<Int>, chapterKey: String) {
        // `activated` records the range's lower bound so assertions can stay
        // shaped as `[Int]`. Test fixtures use pre-terminated paragraphs so
        // each synthesis paragraph maps to a single-index display range; the
        // lowerBound carries the same value the old localIndex did. Tests
        // that exercise the merged case (multiple display paragraphs in one
        // synthesis utterance) read `activatedRanges` instead.
        activated.append(localDisplayRange.lowerBound)
        activatedRanges.append(localDisplayRange)
    }
}

@MainActor
@Suite struct TTSManagerTests {
    @Test("start speaks the start paragraph and reports it active")
    func startSpeaks() {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        let provider = StubProvider()
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A.\n\nB.\n\nC.", startIndex: 1)
        #expect(backend.spoken == ["B."])
        #expect(manager.currentParagraphIndexForTesting == 1)
        #expect(provider.activated == [1])
        #expect(provider.activatedRanges == [1..<2])
        #expect(manager.isActive && manager.isPlaying)
    }

    @Test("active display range spans every block a merged paragraph covers")
    func mergedParagraphHighlightSpansFullRange() {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        let provider = StubProvider()
        // Three unterminated display paragraphs merge into one synthesis
        // paragraph. The fourth display paragraph (terminated) is a second
        // synthesis paragraph standing on its own.
        manager.start(
            provider: provider,
            chapterKey: "c1",
            text: "Sunny glanced\n\nat the\n\nwarrior\n\nand smiled.\n\nNext sentence.",
            startIndex: 0
        )
        // First utterance covers display paragraphs 0..3 (the merge); the
        // reader can light all four rows up from a single range.
        #expect(provider.activatedRanges == [0..<4])
        #expect(manager.currentLocalDisplayRange == 0..<4)
        // Advancing moves to the standalone synthesis paragraph at display
        // index 4 — the single-block range looks identical to the
        // unmerged case.
        manager.handleUtteranceFinishedForTesting()
        #expect(provider.activatedRanges == [0..<4, 4..<5])
        #expect(manager.currentLocalDisplayRange == 4..<5)
    }

    @Test("start with no narratable paragraphs stays inactive")
    func startEmptyStops() {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        manager.start(provider: StubProvider(), chapterKey: "c1",
                      text: " \n\n\t", startIndex: 0)
        #expect(backend.spoken.isEmpty)
        #expect(manager.isActive == false)
        #expect(manager.isPlaying == false)
    }

    @Test("finishing advances through paragraphs then stops at end")
    func advanceOnFinish() async {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        let provider = StubProvider()
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A.\n\nB.", startIndex: 0)
        manager.handleUtteranceFinishedForTesting()   // A -> B
        #expect(backend.spoken == ["A.", "B."])
        manager.handleUtteranceFinishedForTesting()   // no next chapter
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(manager.isPlaying == false)
        #expect(manager.isActive == false)
    }

    @Test("auto-advances into the next chapter when provided")
    func crossChapter() async {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        let provider = StubProvider()
        provider.nextChapter = (chapterKey: "c2", text: "X.\n\nY.")
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A", startIndex: 0)
        manager.handleUtteranceFinishedForTesting()
        try? await Task.sleep(nanoseconds: 50_000_000)
        // Single-paragraph "A" doesn't merge (nothing to merge with), so it
        // stays without a terminator; the multi-paragraph next chapter does
        // need to be terminated to keep its synthesis paragraphs separate.
        #expect(backend.spoken == ["A", "X."])
        #expect(manager.currentChapterKey == "c2")
    }

    @Test("pending next chapter load is ignored after stop")
    func pendingNextIgnoredAfterStop() async {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        let provider = StubProvider()
        provider.nextChapter = (chapterKey: "c2", text: "X.\n\nY.")
        provider.nextChapterDelay = 50_000_000
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A", startIndex: 0)

        manager.handleUtteranceFinishedForTesting()
        manager.stop()
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(backend.spoken == ["A"])
        #expect(manager.isActive == false)
        #expect(manager.isPlaying == false)
    }

    @Test("pending next chapter load cannot override user navigation")
    func pendingNextIgnoredAfterUserNavigation() async {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        let provider = StubProvider()
        provider.nextChapter = (chapterKey: "c2", text: "X.\n\nY.")
        provider.nextChapterDelay = 50_000_000
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A", startIndex: 0)

        manager.handleUtteranceFinishedForTesting()
        manager.userDidNavigate(toChapterKey: "c5", text: "M.\n\nN.")
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(manager.currentChapterKey == "c5")
        #expect(manager.currentParagraphIndexForTesting == 0)
        #expect(manager.currentLocalDisplayRange?.lowerBound == 0)
        #expect(backend.spoken == ["A", "M."])
        #expect(provider.activated == [0, 0])
    }

    @Test("skip forward/backward move one paragraph")
    func skip() {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        manager.start(provider: StubProvider(), chapterKey: "c1",
                      text: "A.\n\nB.\n\nC.", startIndex: 0)
        manager.skipForward()
        #expect(manager.currentParagraphIndexForTesting == 1)
        manager.skipBackward()
        #expect(manager.currentParagraphIndexForTesting == 0)
    }

    @Test("controls are no-ops when inactive")
    func inactiveControlsNoop() {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        let provider = StubProvider()
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A.\n\nB.\n\nC.", startIndex: 1)
        manager.stop()

        manager.pause()
        manager.skipForward()
        manager.skipBackward()
        manager.resetChapter()
        manager.seek(toProgress: 1)
        manager.play()

        #expect(manager.isActive == false)
        #expect(manager.isPlaying == false)
        #expect(manager.currentParagraphIndexForTesting == 1)
        #expect(backend.spoken == ["B."])
        #expect(provider.activated == [1])
    }

    @Test("paragraph controls while paused move the cursor without resuming")
    func pausedParagraphControlsDoNotResume() {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        let provider = StubProvider()
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A.\n\nB.\n\nC.", startIndex: 0)
        manager.pause()

        manager.skipForward()
        #expect(manager.currentParagraphIndexForTesting == 1)
        #expect(manager.currentLocalDisplayRange?.lowerBound == 1)
        #expect(manager.isPlaying == false)
        #expect(backend.spoken == ["A."])
        #expect(provider.activated == [0, 1])

        manager.skipBackward()
        #expect(manager.currentParagraphIndexForTesting == 0)
        #expect(manager.currentLocalDisplayRange?.lowerBound == 0)
        #expect(manager.isPlaying == false)
        #expect(backend.spoken == ["A."])
        #expect(provider.activated == [0, 1, 0])
    }

    @Test("play after paused paragraph navigation speaks the selected paragraph")
    func playAfterPausedParagraphNavigation() {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        manager.start(provider: StubProvider(), chapterKey: "c1",
                      text: "A.\n\nB.\n\nC.", startIndex: 0)
        manager.pause()
        manager.skipForward()

        manager.play()

        #expect(manager.currentParagraphIndexForTesting == 1)
        #expect(manager.currentLocalDisplayRange?.lowerBound == 1)
        #expect(backend.spoken == ["A.", "B."])
        #expect(manager.isPlaying)
    }

    @Test("rate changes while playing restart the same paragraph only")
    func rateChangeKeepsCursor() {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        let provider = StubProvider()
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A.\n\nB.\n\nC.", startIndex: 1)

        manager.rate = manager.rate == 1.5 ? 1.0 : 1.5

        #expect(manager.currentParagraphIndexForTesting == 1)
        #expect(manager.currentLocalDisplayRange?.lowerBound == 1)
        #expect(backend.spoken == ["B.", "B."])
        #expect(provider.activated == [1, 1])
        #expect(manager.isPlaying)
    }

    @Test("stale finish after rate restart does not advance the queue")
    func staleFinishAfterRateRestartDoesNotAdvance() async {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        let provider = StubProvider()
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A.\n\nB.\n\nC.", startIndex: 1)
        let stoppedID = backend.utteranceIDs[0]

        manager.rate = manager.rate == 1.5 ? 1.0 : 1.5

        backend.simulateFinish(utteranceID: stoppedID)
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(manager.currentParagraphIndexForTesting == 1)
        #expect(manager.currentLocalDisplayRange?.lowerBound == 1)
        #expect(backend.spoken == ["B.", "B."])
        #expect(provider.activated == [1, 1])

        backend.simulateFinish(utteranceID: backend.utteranceIDs[1])
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(manager.currentParagraphIndexForTesting == 2)
        #expect(manager.currentLocalDisplayRange?.lowerBound == 2)
        #expect(backend.spoken == ["B.", "B.", "C."])
        #expect(provider.activated == [1, 1, 2])
    }

    @Test("rate changes while paused keep the cursor and paused state")
    func rateChangeWhilePausedDoesNotResume() {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        let provider = StubProvider()
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A.\n\nB.\n\nC.", startIndex: 1)
        manager.pause()

        manager.rate = manager.rate == 1.5 ? 1.0 : 1.5

        #expect(manager.currentParagraphIndexForTesting == 1)
        #expect(manager.currentLocalDisplayRange?.lowerBound == 1)
        #expect(backend.spoken == ["B."])
        #expect(provider.activated == [1])
        #expect(manager.isPlaying == false)
    }

    @Test("reattach re-points provider and re-emits the active paragraph")
    func reattachReSyncs() {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        let first = StubProvider()
        manager.start(provider: first, chapterKey: "c1",
                      text: "A.\n\nB.\n\nC.", startIndex: 0)
        manager.skipForward()
        let second = StubProvider()
        manager.reattach(provider: second)
        #expect(second.activated == [1])
        #expect(manager.isActive)
    }

    @Test("reattach is a no-op when no session is active")
    func reattachInactive() {
        let manager = TTSManager(backend: MockBackend())
        let provider = StubProvider()
        manager.reattach(provider: provider)
        #expect(provider.activated.isEmpty)
        #expect(manager.isActive == false)
    }

    @Test("detach unbinds only the matching provider")
    func detachIdentity() {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        let first = StubProvider()
        manager.start(provider: first, chapterKey: "c1",
                      text: "A.\n\nB.\n\nC.\n\nD.", startIndex: 0)
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
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        let provider = StubProvider()
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A.\n\nB.\n\nC.", startIndex: 2)
        #expect(backend.spoken == ["C."])
        manager.userDidNavigate(toChapterKey: "c5", text: "X.\n\nY.")
        #expect(manager.currentChapterKey == "c5")
        #expect(manager.currentParagraphIndexForTesting == 0)
        #expect(backend.spoken == ["C.", "X."])
        #expect(provider.activated == [2, 0])
    }

    @Test("userDidNavigate while paused retargets without resuming")
    func navWhilePausedDoesNotResume() {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        let provider = StubProvider()
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A.\n\nB.\n\nC.", startIndex: 2)
        manager.pause()

        manager.userDidNavigate(toChapterKey: "c5", text: "X.\n\nY.")

        #expect(manager.currentChapterKey == "c5")
        #expect(manager.currentParagraphIndexForTesting == 0)
        #expect(manager.currentLocalDisplayRange?.lowerBound == 0)
        #expect(backend.spoken == ["C."])
        #expect(provider.activated == [2, 0])
        #expect(manager.isPlaying == false)
    }

    @Test("userDidNavigate is a no-op when no session is active")
    func navInactive() {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        manager.userDidNavigate(toChapterKey: "c5", text: "X.\n\nY.")
        #expect(backend.spoken.isEmpty)
        #expect(manager.isActive == false)
    }

    @Test("userDidNavigate to empty text stops the live session")
    func navEmptyStops() {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        manager.start(provider: StubProvider(), chapterKey: "c1",
                      text: "A.\n\nB.", startIndex: 0)
        manager.userDidNavigate(toChapterKey: "empty", text: " \n\n ")
        #expect(backend.spoken == ["A."])
        #expect(manager.isActive == false)
        #expect(manager.isPlaying == false)
    }

    @Test("remote next chapter while paused retargets without resuming")
    func remoteNextWhilePausedDoesNotResume() async {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        let provider = StubProvider()
        provider.nextChapter = (chapterKey: "c2", text: "X.\n\nY.")
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A", startIndex: 0)
        manager.pause()

        manager.skipToNextChapter()
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(manager.currentChapterKey == "c2")
        #expect(manager.currentParagraphIndexForTesting == 1)
        #expect(manager.currentLocalDisplayRange?.lowerBound == 0)
        #expect(backend.spoken == ["A"])
        #expect(provider.activated == [0, 0])
        #expect(manager.isPlaying == false)
    }

    @Test("remote previous chapter while paused retargets without resuming")
    func remotePreviousWhilePausedDoesNotResume() async {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        let provider = StubProvider()
        provider.previousChapter = (chapterKey: "c0", text: "X.\n\nY.")
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A.\n\nB.", startIndex: 0)
        manager.pause()

        manager.skipToPreviousChapter()
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(manager.currentChapterKey == "c0")
        #expect(manager.currentParagraphIndexForTesting == 0)
        #expect(manager.currentLocalDisplayRange?.lowerBound == 0)
        #expect(backend.spoken == ["A."])
        #expect(provider.activated == [0, 0])
        #expect(manager.isPlaying == false)
    }

    @Test("session exposes observable novel & chapter titles that follow navigation")
    func sessionTitlesFollowNavigation() {
        let manager = TTSManager(backend: MockBackend())
        let provider = StubProvider()
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A.\n\nB.", startIndex: 0)
        #expect(manager.novelTitleForTesting == "Novel")
        #expect(manager.currentChapterTitleForTesting == "c1")
        manager.userDidNavigate(toChapterKey: "c2", text: "X.\n\nY.")
        #expect(manager.currentChapterTitleForTesting == "c2")
    }

    @Test("progress is chapter-local and resets when the chapter changes")
    func progressIsChapterLocal() {
        let manager = TTSManager(backend: MockBackend())
        manager.start(provider: StubProvider(), chapterKey: "c1",
                      text: "A.\n\nB.\n\nC.", startIndex: 2)
        #expect(manager.chapterProgressForTesting == 1)             // last paragraph of c1
        manager.userDidNavigate(toChapterKey: "c2", text: "X.\n\nY.\n\nZ.")
        #expect(manager.chapterProgressForTesting == 0)             // reset at the top of c2
    }

    @Test("announces the chapter title once when entering each chapter")
    func announcesChapterTitleOnChange() {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        manager.announceChapterTitles = true
        let provider = StubProvider()              // ttsChapterTitle returns the key
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A.\n\nB.", startIndex: 0)
        #expect(backend.spoken == ["c1. A."])         // title precedes the first paragraph
        manager.skipForward()
        #expect(backend.spoken == ["c1. A.", "B."])    // no re-announce within the chapter
        manager.userDidNavigate(toChapterKey: "c2", text: "X.\n\nY.")
        #expect(backend.spoken == ["c1. A.", "B.", "c2. X."])  // announced on chapter change
    }

    @Test("chapter announcement is off by default for the test initializer")
    func announcementOffByDefault() {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        manager.start(provider: StubProvider(), chapterKey: "c1",
                      text: "A.\n\nB.", startIndex: 0)
        #expect(backend.spoken == ["A."])
    }

    @Test("calibrator records a sample after didStart -> didFinish on the same utterance")
    func calibratorRecordsSampleOnNaturalFinish() async {
        var ticks = 0
        let times: [Date] = [
            Date(timeIntervalSince1970: 0),
            Date(timeIntervalSince1970: 60),
        ]
        let clock: () -> Date = {
            defer { ticks = min(ticks + 1, times.count - 1) }
            return times[ticks]
        }
        let backend = MockBackend()
        let manager = TTSManager(backend: backend, now: clock)
        // Pin the rate so the rate-normalization step in `recordSample` is
        // deterministic; otherwise UserDefaults pollution from a sibling
        // test that touched `Reader.ttsRateMultiplier` can make the observed
        // WPM divide out to a different value.
        manager.rate = 1.0
        let provider = StubProvider()
        let words = Array(repeating: "alpha", count: 60).joined(separator: " ")
        manager.start(provider: provider, chapterKey: "c1",
                      text: words, startIndex: 0)
        #expect(manager.calibratorSampleCountForTesting == 0)

        let id = backend.utteranceIDs[0]
        backend.simulateStart(utteranceID: id)
        await Task.yield()
        backend.simulateFinish(utteranceID: id)
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(manager.calibratorSampleCountForTesting == 1)
        #expect(abs(manager.calibratorCurrentWPMForTesting - 60.0) < 0.0001)
    }

    @Test("switching backend mid-playback restarts the paragraph on the new backend")
    func switchBackendRestartsOnNewBackend() {
        let system = MockBackend(id: "system")
        let kokoro = MockBackend(id: "kokoro")
        let registry = SpeechBackendRegistry(backends: [system, kokoro], systemBackend: system)
        let manager = TTSManager(backend: system, registry: registry, now: Date.init)
        let provider = StubProvider()
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A.\n\nB.\n\nC.", startIndex: 0)
        #expect(system.spoken == ["A."])

        manager.currentBackendID = "kokoro"

        // The current paragraph restarts on the new backend, exactly once.
        #expect(kokoro.spoken == ["A."])
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
        let backend = MockBackend()
        let manager = TTSManager(backend: backend, now: clock)
        let provider = StubProvider()
        let words = Array(repeating: "alpha", count: 60).joined(separator: " ")
        manager.start(provider: provider, chapterKey: "c1",
                      text: words, startIndex: 0)

        let id = backend.utteranceIDs[0]
        backend.simulateStart(utteranceID: id)
        await Task.yield()
        // Pause clears the in-flight sample; the backend's late finish
        // (which mirrors AVSpeech's behaviour after stopSpeakingNow) must not
        // be misread as a natural completion.
        manager.pause()
        backend.simulateFinish(utteranceID: id)
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(manager.calibratorSampleCountForTesting == 0)
    }

    @Test("changing voiceIdentifier asks the active backend to prepare the new voice")
    func voiceChangeTriggersPrepareVoice() {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        // Pin a known baseline first: voiceIdentifier persists to the shared
        // UserDefaults, so without this the manager could init already holding
        // "freshly_picked_voice" (from a prior run) and the assignment below
        // would no-op. Reset the prepare log *after* the baseline so only the
        // real change under test is recorded.
        manager.voiceIdentifier = "baseline_voice"
        backend.resetPreparedVoices()
        manager.voiceIdentifier = "freshly_picked_voice"
        #expect(backend.preparedVoices == ["freshly_picked_voice"])
    }

    @Test("re-setting voiceIdentifier to the current value does not re-prepare")
    func voiceUnchangedNoPrepare() {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        manager.voiceIdentifier = "pinned_voice"
        backend.resetPreparedVoices()
        manager.voiceIdentifier = "pinned_voice"
        #expect(backend.preparedVoices.isEmpty)
    }

    // MARK: - System audio events

    @Test("losing the output route stops a backend that can't pause in place")
    func outputRouteLossStopsNonPausableBackend() {
        // MockBackend reports supportsInterruptPause == false (the protocol
        // default), like AVSpeechSynthesizer. On a route change the session
        // stays active and reroutes to the speaker, so the synth must be
        // actively stopped or it keeps reading aloud.
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        manager.start(provider: StubProvider(), chapterKey: "c1",
                      text: "A.\n\nB.", startIndex: 0)
        #expect(backend.isSpeaking)
        let stopsBefore = backend.stopCount

        manager.simulateOutputRouteLostForTesting()

        #expect(manager.isPlaying == false)
        #expect(backend.isSpeaking == false)
        #expect(backend.stopCount == stopsBefore + 1)
    }

    // MARK: - Chapter navigation during an in-flight load

    @Test("next-track during an end-of-chapter load still advances to the next chapter")
    func nextTrackDuringEndOfChapterLoadAdvances() async {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        let provider = StubProvider()
        provider.nextChapter = (chapterKey: "c2", text: "X.\n\nY.")
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A", startIndex: 0)

        // Chapter ends naturally: kicks off the async next-chapter load. The
        // load Task is enqueued but cannot run until this synchronous chain
        // suspends, so `loadingNext` is still true when next-track fires.
        manager.handleUtteranceFinishedForTesting()
        // User taps Next Track on the lockscreen while that load is in flight.
        manager.skipToNextChapter()
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(manager.currentChapterKey == "c2")
        #expect(backend.spoken == ["A", "X."])
        #expect(manager.isActive)
    }

    // MARK: - Pending seek offset across queue moves

    @Test("a paused mid-paragraph seek offset does not leak onto a skipped-to paragraph")
    func pausedSeekOffsetDoesNotLeakAcrossSkip() {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        manager.start(provider: StubProvider(), chapterKey: "c1",
                      text: "First one two three.\n\nSecond four five six.", startIndex: 0)
        manager.pause()

        // Scrub into the middle of paragraph 0 while paused — the offset is
        // stashed but not consumed (paused paths don't re-speak).
        manager.seek(to: TextChapterPosition(paragraphIndex: 0, charOffsetInParagraph: 6))
        // Move to a different paragraph, then resume.
        manager.skipForward()
        manager.play()

        // Paragraph 1 must be spoken in full — the stale offset belonged to
        // paragraph 0 and must not clip paragraph 1's opening words.
        #expect(manager.currentParagraphIndexForTesting == 1)
        #expect(backend.spoken.last == "Second four five six.")
    }

    @Test("a mid-paragraph seek while playing still starts at the requested offset")
    func playingSeekAppliesOffset() {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        manager.start(provider: StubProvider(), chapterKey: "c1",
                      text: "Alpha beta gamma.", startIndex: 0)

        // Seek into the paragraph while playing: the offset is consumed
        // immediately, so the utterance restarts from the requested word.
        manager.seek(to: TextChapterPosition(paragraphIndex: 0, charOffsetInParagraph: 6))

        #expect(backend.spoken.last == "gamma.")
        #expect(manager.isPlaying)
    }

    // MARK: - seek(toProgress:)

    @Test("seek(toProgress:) is chapter-local after a next chapter is appended")
    func seekToProgressIsChapterLocal() async {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        let provider = StubProvider()
        provider.nextChapter = (chapterKey: "c2", text: "X.\n\nY.\n\nZ.")
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A.\n\nB.\n\nC.", startIndex: 0)
        // Roll into c2 so the queue holds both chapters (6 paragraphs total).
        manager.skipToNextChapter()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(manager.currentChapterKey == "c2")

        // Scrub to the start of the chapter: must land on c2's first paragraph
        // (global index 3), NOT the queue's first paragraph (global index 0).
        manager.seek(toProgress: 0.0)
        #expect(manager.currentChapterKey == "c2")
        #expect(manager.currentParagraphIndexForTesting == 3)

        // Scrub to the end: c2's last paragraph (global 5), not past it.
        manager.seek(toProgress: 1.0)
        #expect(manager.currentChapterKey == "c2")
        #expect(manager.currentParagraphIndexForTesting == 5)
    }

    @Test("seek(toProgress:) still works on a single-chapter queue")
    func seekToProgressSingleChapter() {
        let backend = MockBackend()
        let manager = TTSManager(backend: backend)
        let provider = StubProvider()
        manager.start(provider: provider, chapterKey: "c1",
                      text: "A.\n\nB.\n\nC.\n\nD.", startIndex: 0)
        manager.seek(toProgress: 1.0)
        #expect(manager.currentParagraphIndexForTesting == 3)
        manager.seek(toProgress: 0.0)
        #expect(manager.currentParagraphIndexForTesting == 0)
    }
}
