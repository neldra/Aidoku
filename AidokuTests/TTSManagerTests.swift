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
}
