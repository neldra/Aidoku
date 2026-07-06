import Testing
@testable import Aidoku

/// One-shot gate: `wait()` suspends until `signal()` is called (or returns
/// immediately if already signalled). Lets a test hold an async disk check
/// open while another operation runs, making an otherwise-timing-dependent
/// race deterministic.
@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var signalled = false
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func signal() {
        signalled = true
        continuation?.resume()
        continuation = nil
    }
}

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

    @Test("refreshInstalledState does not clobber a download that completed during its disk check")
    func refreshDoesNotClobberConcurrentDownload() async {
        let gate = Gate()
        let manager = KokoroModelManager(
            performDownload: { $0(1.0) },
            // Simulates a disk check that started before the download finished
            // writing files — it resolves to `false` only after the download
            // has already flipped the state to `.ready`.
            checkInstalled: { await gate.wait(); return false }
        )

        manager.refreshInstalledState()   // suspends inside checkInstalled at the gate
        manager.startDownload()           // runs to completion: state -> .ready
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(manager.state == .ready)

        gate.signal()                     // let the stale disk check return false
        try? await Task.sleep(nanoseconds: 50_000_000)

        // The completed download's result is authoritative; the stale read
        // must not knock the state back to .notInstalled.
        #expect(manager.state == .ready)
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
