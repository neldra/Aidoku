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

    @Test("voice catalog exposes the curated 12-voice English roster")
    func voiceCatalogSize() {
        let modelManager = KokoroModelManager(
            performDownload: { _ in }, checkInstalled: { false }
        )
        let backend = KokoroSpeechBackend(modelManager: modelManager)
        #expect(backend.availableVoices().count == 12)
    }

    @Test("voice catalog leads with af_heart and includes top-rated alternatives")
    func voiceCatalogIncludesKeyVoices() {
        let modelManager = KokoroModelManager(
            performDownload: { _ in }, checkInstalled: { false }
        )
        let backend = KokoroSpeechBackend(modelManager: modelManager)
        let ids = backend.availableVoices().map(\.id)
        #expect(ids.first == "af_heart")
        // The voices the previous turn called out as community favourites.
        #expect(ids.contains("af_bella"))
        #expect(ids.contains("am_fenrir"))
        #expect(ids.contains("bf_emma"))
        #expect(ids.contains("bm_george"))
    }

    @Test("voice catalog tags American voices en-US and British voices en-GB")
    func voiceCatalogLanguages() {
        let modelManager = KokoroModelManager(
            performDownload: { _ in }, checkInstalled: { false }
        )
        let backend = KokoroSpeechBackend(modelManager: modelManager)
        for voice in backend.availableVoices() {
            let expected = voice.id.hasPrefix("a") ? "en-US" : "en-GB"
            #expect(voice.language == expected, "\(voice.id) should be \(expected), got \(voice.language)")
        }
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
