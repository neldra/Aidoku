import Testing
@testable import Aidoku

@MainActor
private final class RecordingBackendDelegate: SpeechBackendDelegate {
    private(set) var started: [Int] = []
    private(set) var finished: [Int] = []
    private(set) var failed: [Int] = []
    func backendDidStart(utteranceID: Int) { started.append(utteranceID) }
    func backendDidFinish(utteranceID: Int) { finished.append(utteranceID) }
    func backendDidFail(utteranceID: Int, error: Error) { failed.append(utteranceID) }
}

@MainActor
@Suite struct KokoroSpeechBackendTests {
    @Test("identity")
    func identity() {
        let modelManager = KokoroModelManager(
            performDownload: { _ in }, checkInstalled: { false }
        )
        let backend = KokoroSpeechBackend(modelManager: modelManager)
        #expect(backend.id == "kokoro")
        #expect(backend.displayName.isEmpty == false)
    }

    @Test("availability tracks the model manager")
    func availabilityTracksModelManager() {
        let modelManager = KokoroModelManager(
            performDownload: { _ in }, checkInstalled: { false }
        )
        let backend = KokoroSpeechBackend(modelManager: modelManager)
        #expect(backend.availability == .needsDownload)
    }

    @Test("voice catalog is non-empty with a default")
    func voices() {
        let modelManager = KokoroModelManager(
            performDownload: { _ in }, checkInstalled: { false }
        )
        let backend = KokoroSpeechBackend(modelManager: modelManager)
        #expect(backend.availableVoices().isEmpty == false)
        #expect(backend.defaultVoiceID != nil)
    }

    @Test("speak with whitespace-only text finishes immediately without speaking")
    func emptyTextFinishesImmediately() {
        let modelManager = KokoroModelManager(
            performDownload: { _ in }, checkInstalled: { false }
        )
        let backend = KokoroSpeechBackend(modelManager: modelManager)
        let delegate = RecordingBackendDelegate()
        backend.delegate = delegate
        backend.speak(text: "   \n  ", voiceID: nil, rate: 1.0, utteranceID: 99)
        #expect(delegate.finished == [99])
        #expect(delegate.started.isEmpty)
        #expect(backend.isSpeaking == false)
    }
}
