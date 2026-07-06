//
//  SpeechBackendRegistry.swift
//  Aidoku
//

import Foundation

/// Owns the available TTS backends and resolves the active one. This foundation
/// layer holds only `SystemSpeechBackend`; neural backends are added by later
/// layers, which construct them behind `if #available(iOS 16, *)`.
@MainActor
final class SpeechBackendRegistry {
    private let backends: [any SpeechSynthesisBackend]
    let systemBackend: any SpeechSynthesisBackend

    /// Designated init — injectable for tests.
    init(
        backends: [any SpeechSynthesisBackend],
        systemBackend: any SpeechSynthesisBackend
    ) {
        self.backends = backends
        self.systemBackend = systemBackend
    }

    /// Production init — builds the real backends.
    convenience init() {
        let system = SystemSpeechBackend()
        self.init(backends: [system], systemBackend: system)
    }

    /// All backends, for the settings engine picker. The UI hides the picker
    /// when this has only one entry — so today's single-engine UI is unchanged.
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
}
