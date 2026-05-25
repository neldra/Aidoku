import Testing
@testable import Aidoku

@MainActor
@Suite struct SpeechBackendRegistryTests {
    private func makeMock(id: String, availability: BackendAvailability) -> MockBackend {
        let backend = MockBackend(id: id)
        backend.availability = availability
        return backend
    }

    @Test("currentBackend returns the preferred backend when ready")
    func preferredWhenReady() {
        let system = makeMock(id: "system", availability: .ready)
        let kokoro = makeMock(id: "kokoro", availability: .ready)
        let registry = SpeechBackendRegistry(backends: [system, kokoro], systemBackend: system)
        #expect(registry.currentBackend(preferredID: "kokoro").id == "kokoro")
    }

    @Test("currentBackend falls back to system when the preferred is unavailable")
    func fallbackWhenUnavailable() {
        let system = makeMock(id: "system", availability: .ready)
        let kokoro = makeMock(id: "kokoro", availability: .needsDownload)
        let registry = SpeechBackendRegistry(backends: [system, kokoro], systemBackend: system)
        #expect(registry.currentBackend(preferredID: "kokoro").id == "system")
    }

    @Test("currentBackend falls back to system for a nil or unknown id")
    func fallbackForUnknown() {
        let system = makeMock(id: "system", availability: .ready)
        let registry = SpeechBackendRegistry(backends: [system], systemBackend: system)
        #expect(registry.currentBackend(preferredID: nil).id == "system")
        #expect(registry.currentBackend(preferredID: "ghost").id == "system")
    }

    @Test("selectableBackends lists every backend")
    func selectableLists() {
        let system = makeMock(id: "system", availability: .ready)
        let kokoro = makeMock(id: "kokoro", availability: .ready)
        let registry = SpeechBackendRegistry(backends: [system, kokoro], systemBackend: system)
        #expect(registry.selectableBackends().map(\.id) == ["system", "kokoro"])
    }

    @Test("currentBackend falls back to system for downloading and unavailable backends")
    func fallbackForOtherNonReadyStates() {
        let system = makeMock(id: "system", availability: .ready)

        let downloading = makeMock(id: "kokoro", availability: .downloading(progress: 0.5))
        let r1 = SpeechBackendRegistry(backends: [system, downloading], systemBackend: system)
        #expect(r1.currentBackend(preferredID: "kokoro").id == "system")

        let unavailable = makeMock(id: "kokoro", availability: .unavailable(reason: "missing"))
        let r2 = SpeechBackendRegistry(backends: [system, unavailable], systemBackend: system)
        #expect(r2.currentBackend(preferredID: "kokoro").id == "system")
    }
}
