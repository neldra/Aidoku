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

    func speakUtterance(_ utterance: AVSpeechUtterance) {
        isSpeaking = true
        isPaused = false
        spoken.append(utterance.speechString)
    }
    func stopSpeakingNow() -> Bool { isSpeaking = false; return true }
    func pauseSpeakingNow() -> Bool { isPaused = true; return true }
    func continueSpeakingNow() -> Bool { isPaused = false; return true }
}

@MainActor
private final class StubProvider: TTSChapterProvider {
    var ttsNovelTitle = "Novel"
    func ttsChapterTitle(forKey key: String) -> String { key }
    var ttsArtwork: UIImage? { nil }
    var nextChapter: (chapterKey: String, text: String)?
    private(set) var activated: [Int] = []

    func ttsLoadNextChapter() async -> (chapterKey: String, text: String)? {
        defer { nextChapter = nil }
        return nextChapter
    }
    func ttsLoadPreviousChapter() async -> (chapterKey: String, text: String)? { nil }
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

    @Test("userDidNavigate is a no-op when no session is active")
    func navInactive() {
        let synth = MockSynth()
        let manager = TTSManager(synthesizer: synth)
        manager.userDidNavigate(toChapterKey: "c5", text: "X\n\nY")
        #expect(synth.spoken.isEmpty)
        #expect(manager.isActive == false)
    }
}
