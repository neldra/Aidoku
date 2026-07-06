//
//  SpeechBackendRegistry.swift
//  Aidoku
//

import Foundation

/// Owns the available TTS backends and resolves the active one. On iOS 15 it
/// holds only `SystemSpeechBackend`; the neural backend (Kokoro) is
/// constructed only inside `if #available(iOS 16, *)`, so iOS 15 users never
/// see it.
@MainActor
final class SpeechBackendRegistry {
    private let backends: [any SpeechSynthesisBackend]
    let systemBackend: any SpeechSynthesisBackend

    /// Neural model manager, stored type-erased so this non-gated class can
    /// hold `@available(iOS 16, *)` types. Reach it via `kokoroModelManager`.
    private let kokoroModelManagerBox: AnyObject?

    /// Designated init — injectable for tests.
    init(
        backends: [any SpeechSynthesisBackend],
        systemBackend: any SpeechSynthesisBackend,
        kokoroModelManagerBox: AnyObject? = nil
    ) {
        self.backends = backends
        self.systemBackend = systemBackend
        self.kokoroModelManagerBox = kokoroModelManagerBox
    }

    /// Production init — builds the real backends.
    convenience init() {
        let system = SystemSpeechBackend()
        if #available(iOS 16, *) {
            let kokoroManager = KokoroModelManager()
            let kokoro = KokoroSpeechBackend(modelManager: kokoroManager)
            self.init(
                backends: [system, kokoro],
                systemBackend: system,
                kokoroModelManagerBox: kokoroManager
            )
        } else {
            self.init(backends: [system], systemBackend: system)
        }
    }

    /// All backends, for the settings engine picker. The UI hides the picker
    /// when this has only one entry — so iOS 15 sees exactly today's UI.
    func selectableBackends() -> [any SpeechSynthesisBackend] { backends }

    func backend(forID id: String) -> (any SpeechSynthesisBackend)? {
        backends.first { $0.id == id }
    }

    /// The backend to synthesize with: the preferred backend if it exists and
    /// is `.ready`, otherwise the always-ready system backend.
    func currentBackend(preferredID: String?) -> any SpeechSynthesisBackend {
        guard let preferredID,
              let preferred = backend(forID: preferredID),
              preferred.availability == .ready
        else { return systemBackend }
        return preferred
    }

    /// The Kokoro model manager — non-nil only on iOS 16+. Drives the settings
    /// download row.
    @available(iOS 16, *)
    var kokoroModelManager: KokoroModelManager? {
        kokoroModelManagerBox as? KokoroModelManager
    }
}
