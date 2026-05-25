import Testing
@testable import Aidoku

@MainActor
@Suite struct KokoroModelManagerTests {
    @Test("a successful download drives notInstalled -> downloading -> ready")
    func successfulDownload() async {
        let manager = KokoroModelManager(
            performDownload: { progress in
                progress(0.5)
                progress(1.0)
            },
            checkInstalled: { false }
        )
        #expect(manager.state == .notInstalled)
        manager.startDownload()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(manager.state == .ready)
    }

    @Test("a failing download lands in .failed")
    func failingDownload() async {
        struct Boom: Error {}
        let manager = KokoroModelManager(
            performDownload: { _ in throw Boom() },
            checkInstalled: { false }
        )
        manager.startDownload()
        try? await Task.sleep(nanoseconds: 50_000_000)
        if case .failed = manager.state {} else {
            Issue.record("expected .failed, got \(manager.state)")
        }
    }

    @Test("refreshInstalledState reflects an already-installed model")
    func refreshDetectsInstalled() async {
        let manager = KokoroModelManager(
            performDownload: { _ in },
            checkInstalled: { true }
        )
        manager.refreshInstalledState()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(manager.state == .ready)
    }

    @Test("availability projects the state")
    func availabilityProjection() {
        let manager = KokoroModelManager(
            performDownload: { _ in }, checkInstalled: { false }
        )
        #expect(manager.availability == .needsDownload)
    }

    @Test("refreshInstalledStateSync flips to .ready synchronously when models are present")
    func refreshSyncDetectsInstalled() {
        let manager = KokoroModelManager(
            performDownload: { _ in },
            checkInstalled: { false },  // async path unused here
            checkInstalledSync: { true }
        )
        #expect(manager.state == .notInstalled)
        manager.refreshInstalledStateSync()
        // No await — the launch path depends on this being synchronous.
        #expect(manager.state == .ready)
    }

    @Test("refreshInstalledStateSync flips back to .notInstalled when the cache is gone")
    func refreshSyncDetectsAbsent() {
        let manager = KokoroModelManager(
            performDownload: { _ in },
            checkInstalled: { true },
            checkInstalledSync: { false }
        )
        manager.refreshInstalledStateSync()
        #expect(manager.state == .notInstalled)
    }

    @Test("retry after a failed download reaches ready")
    func retryAfterFailure() async {
        struct Boom: Error {}
        var attempts = 0
        let manager = KokoroModelManager(
            performDownload: { _ in
                attempts += 1
                if attempts == 1 { throw Boom() }
            },
            checkInstalled: { false }
        )
        manager.startDownload()
        try? await Task.sleep(nanoseconds: 50_000_000)
        if case .failed = manager.state {} else {
            Issue.record("expected .failed after first attempt, got \(manager.state)")
        }
        manager.retry()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(manager.state == .ready)
    }
}
