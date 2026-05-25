import Foundation
@testable import Aidoku

/// `SpeechSynthesisBackend` test double. Records what it was asked to speak
/// and lets tests drive lifecycle callbacks deterministically by utteranceID.
@MainActor
final class MockBackend: SpeechSynthesisBackend {
    let id: String
    let displayName: String

    init(id: String = "mock", displayName: String = "Mock") {
        self.id = id
        self.displayName = displayName
    }

    var availability: BackendAvailability = .ready
    weak var delegate: SpeechBackendDelegate?
    var isSpeaking = false
    var isPaused = false

    /// Text of every `speak` call, in order — mirrors the old MockSynth.spoken.
    private(set) var spoken: [String] = []
    /// utteranceID of every `speak` call, in order.
    private(set) var utteranceIDs: [Int] = []

    func speak(text: String, voiceID: String?, rate: Float, utteranceID: Int) {
        isSpeaking = true
        isPaused = false
        spoken.append(text)
        utteranceIDs.append(utteranceID)
    }

    func stop() { isSpeaking = false; isPaused = false }
    func pause() { isSpeaking = false; isPaused = true }
    func resume() { isPaused = false; isSpeaking = true }

    var defaultVoiceID: String? { nil }
    func availableVoices() -> [SpeechVoice] { [] }
    func prepare() async {}

    // MARK: - Test drivers

    /// Simulate the backend beginning playback of `utteranceID`.
    func simulateStart(utteranceID: Int) {
        delegate?.backendDidStart(utteranceID: utteranceID)
    }

    /// Simulate the backend finishing playback of `utteranceID`.
    func simulateFinish(utteranceID: Int) {
        isSpeaking = false
        delegate?.backendDidFinish(utteranceID: utteranceID)
    }

    /// Simulate a synthesis failure for `utteranceID`.
    func simulateFail(utteranceID: Int, error: Error) {
        delegate?.backendDidFail(utteranceID: utteranceID, error: error)
    }
}
