//
//  SpeechSynthesizing.swift
//  Aidoku
//

import AVFoundation

/// Thin seam over AVSpeechSynthesizer so TTSManager navigation is testable
/// without producing real audio.
@MainActor
protocol SpeechSynthesizing: AnyObject {
    var speechDelegate: AVSpeechSynthesizerDelegate? { get set }
    var isSpeaking: Bool { get }
    var isPaused: Bool { get }
    func speakUtterance(_ utterance: AVSpeechUtterance)
    @discardableResult func stopSpeakingNow() -> Bool
    @discardableResult func pauseSpeakingNow() -> Bool
    @discardableResult func continueSpeakingNow() -> Bool
}

extension AVSpeechSynthesizer: SpeechSynthesizing {
    var speechDelegate: AVSpeechSynthesizerDelegate? {
        get { delegate }
        set { delegate = newValue }
    }
    func speakUtterance(_ utterance: AVSpeechUtterance) { speak(utterance) }
    @discardableResult func stopSpeakingNow() -> Bool { stopSpeaking(at: .immediate) }
    @discardableResult func pauseSpeakingNow() -> Bool { pauseSpeaking(at: .immediate) }
    @discardableResult func continueSpeakingNow() -> Bool { continueSpeaking() }
}
