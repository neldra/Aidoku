//
//  SpeechBackendRegistry.swift
//  Aidoku
//

import Foundation

/// Owns the available TTS backends and resolves the active one. On iOS 15 it
/// holds only `SystemSpeechBackend`; the neural backends (Kokoro,
/// Supertonic-3) are constructed only inside `if #available(iOS 16, *)`, so
/// iOS 15 users never see them.
@MainActor
final class SpeechBackendRegistry {
    private let backends: [any SpeechSynthesisBackend]
    let systemBackend: any SpeechSynthesisBackend

    /// Neural model managers, stored type-erased so this non-gated class can
    /// hold `@available(iOS 16, *)` types. Reach them via
    /// `kokoroModelManager` / `supertonic3ModelManager`.
    private let kokoroModelManagerBox: AnyObject?
    private let supertonic3ModelManagerBox: AnyObject?

    /// Designated init — injectable for tests.
    init(
        backends: [any SpeechSynthesisBackend],
        systemBackend: any SpeechSynthesisBackend,
        kokoroModelManagerBox: AnyObject? = nil,
        supertonic3ModelManagerBox: AnyObject? = nil
    ) {
        self.backends = backends
        self.systemBackend = systemBackend
        self.kokoroModelManagerBox = kokoroModelManagerBox
        self.supertonic3ModelManagerBox = supertonic3ModelManagerBox
    }

    /// Production init — builds the real backends. Supertonic-3 is listed
    /// before Kokoro so the engine picker presents the better-quality choice
    /// first; the default-resolution logic in `currentBackend` also prefers
    /// the first ready neural backend when the user hasn't pinned one.
    convenience init() {
        let system = SystemSpeechBackend()
        if #available(iOS 16, *) {
            let kokoroManager = KokoroModelManager()
            let supertonic3Manager = Supertonic3ModelManager()
            let kokoro = KokoroSpeechBackend(modelManager: kokoroManager)
            let supertonic3 = Supertonic3SpeechBackend(modelManager: supertonic3Manager)
            self.init(
                backends: [system, supertonic3, kokoro],
                systemBackend: system,
                kokoroModelManagerBox: kokoroManager,
                supertonic3ModelManagerBox: supertonic3Manager
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

    /// The Supertonic-3 model manager — non-nil only on iOS 16+. Drives the
    /// settings download row.
    @available(iOS 16, *)
    var supertonic3ModelManager: Supertonic3ModelManager? {
        supertonic3ModelManagerBox as? Supertonic3ModelManager
    }
}
