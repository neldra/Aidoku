import AVFoundation
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
private final class RecordingDelegate: SpeechBackendDelegate {
    private(set) var started: [Int] = []
    private(set) var finished: [Int] = []
    private(set) var failed: [Int] = []
    func backendDidStart(utteranceID: Int) { started.append(utteranceID) }
    func backendDidFinish(utteranceID: Int) { finished.append(utteranceID) }
    func backendDidFail(utteranceID: Int, error: Error) { failed.append(utteranceID) }
}

@MainActor
@Suite struct SystemSpeechBackendTests {
    @Test("identity and availability")
    func identity() {
        let backend = SystemSpeechBackend(synthesizer: MockSynth())
        #expect(backend.id == "system")
        #expect(backend.availability == .ready)
        #expect(backend.displayName.isEmpty == false)
    }

    @Test("speak forwards the text to the synthesizer")
    func speakForwards() {
        let synth = MockSynth()
        let backend = SystemSpeechBackend(synthesizer: synth)
        backend.speak(text: "Hello", voiceID: nil, rate: 1.0, utteranceID: 7)
        #expect(synth.spoken == ["Hello"])
        #expect(backend.isSpeaking)
    }

    @Test("didFinish forwards to the delegate with the same utteranceID")
    func finishForwardsID() async {
        let synth = MockSynth()
        let backend = SystemSpeechBackend(synthesizer: synth)
        let delegate = RecordingDelegate()
        backend.delegate = delegate
        backend.speak(text: "Hello", voiceID: nil, rate: 1.0, utteranceID: 42)
        synth.start(synth.utterances[0])
        synth.finish(synth.utterances[0])
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(delegate.started == [42])
        #expect(delegate.finished == [42])
    }

    @Test("a finish for a superseded utterance is ignored")
    func staleFinishIgnored() async {
        let synth = MockSynth()
        let backend = SystemSpeechBackend(synthesizer: synth)
        let delegate = RecordingDelegate()
        backend.delegate = delegate
        backend.speak(text: "First", voiceID: nil, rate: 1.0, utteranceID: 1)
        let stale = synth.utterances[0]
        backend.speak(text: "Second", voiceID: nil, rate: 1.0, utteranceID: 2)
        synth.finish(stale)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(delegate.finished.isEmpty)
    }

    @Test("voice catalog is non-empty and includes a default")
    func voices() {
        let backend = SystemSpeechBackend(synthesizer: MockSynth())
        #expect(backend.availableVoices().isEmpty == false)
        #expect(backend.defaultVoiceID != nil)
    }
}
