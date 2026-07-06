//
//  KokoroModelManager.swift
//  Aidoku
//

import Foundation
import FluidAudio
import Network

/// Owns the Kokoro model download and the availability state machine that
/// `KokoroSpeechBackend.availability` projects. iOS 16+ — Kokoro never runs on
/// iOS 15. Download/check operations are injectable for testing.
@available(iOS 16, *)
@MainActor
final class KokoroModelManager: ObservableObject {
    enum State: Equatable {
        case notInstalled
        case downloading(progress: Double)
        case ready
        case failed(reason: String)
    }

    @Published private(set) var state: State = .notInstalled

    /// Persisted "download over Wi-Fi only" preference (defaults on).
    var wifiOnly: Bool {
        get { UserDefaults.standard.object(forKey: Self.wifiOnlyKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.wifiOnlyKey) }
    }
    static let wifiOnlyKey = "Reader.ttsKokoroWifiOnly"

    private var downloadTask: Task<Void, Never>?
    /// Bumped whenever a download settles (success, failure, or cancel). A
    /// `refreshInstalledState` disk check captures this before its `await`;
    /// if it changed by the time the check resolves, a download intervened and
    /// owns the state — the (possibly stale) read is discarded.
    private var downloadGeneration = 0

    /// Injectable seams. `performDownload` reports 0...1 progress and throws on
    /// failure; `checkInstalled` answers whether the model chain is on disk
    /// (async); `checkInstalledSync` is the synchronous flavor used at launch,
    /// where we can't await before the backend has to resolve.
    private let performDownload: (@escaping @Sendable (Double) -> Void) async throws -> Void
    private let checkInstalled: () async -> Bool
    private let checkInstalledSync: @MainActor () -> Bool

    init(
        performDownload: @escaping (@escaping @Sendable (Double) -> Void) async throws -> Void
            = KokoroModelManager.realDownload,
        checkInstalled: @escaping () async -> Bool
            = KokoroModelManager.realCheckInstalled,
        checkInstalledSync: @escaping @MainActor () -> Bool
            = KokoroModelManager.realCheckInstalledSync
    ) {
        self.performDownload = performDownload
        self.checkInstalled = checkInstalled
        self.checkInstalledSync = checkInstalledSync
    }

    /// Projection consumed by `KokoroSpeechBackend.availability`.
    var availability: BackendAvailability {
        switch state {
        case .notInstalled: return .needsDownload
        case .downloading(let progress): return .downloading(progress: progress)
        case .ready: return .ready
        case .failed(let reason): return .unavailable(reason: reason)
        }
    }

    /// Call at launch / settings appearance. The model cache lives in the
    /// purgeable caches directory, so a previously-`ready` install can vanish.
    func refreshInstalledState() {
        if downloadTask != nil { return }
        if case .downloading = state { return }
        let generation = downloadGeneration
        Task {
            let installed = await checkInstalled()
            // A download that started or completed during the check now owns
            // the state; its result is authoritative over a disk read that may
            // have raced the file writes.
            guard downloadTask == nil, downloadGeneration == generation else { return }
            state = installed ? .ready : .notInstalled
        }
    }

    /// Synchronous variant of `refreshInstalledState`. Used during `TTSManager`
    /// launch where we have to resolve the active backend before any `await`
    /// would complete — otherwise the user's saved Kokoro preference falls back
    /// to the system backend on every relaunch. The underlying `modelsArePresent`
    /// is a filesystem-only check; no I/O wait. A no-op while a download is in
    /// flight.
    func refreshInstalledStateSync() {
        if case .downloading = state { return }
        state = checkInstalledSync() ? .ready : .notInstalled
    }

    func startDownload() {
        guard downloadTask == nil else { return }
        state = .downloading(progress: 0)
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.performDownload { progress in
                    Task { @MainActor in
                        if case .downloading = self.state {
                            self.state = .downloading(progress: progress)
                        }
                    }
                }
                self.state = .ready
            } catch is CancellationError {
                self.state = .notInstalled
            } catch {
                self.state = .failed(reason: error.localizedDescription)
            }
            self.downloadGeneration &+= 1
            self.downloadTask = nil
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    func retry() {
        guard downloadTask == nil else { return }
        startDownload()
    }

    // MARK: - Real implementations

    /// One-shot check of whether the current network path uses Wi-Fi.
    /// Used to honor the `wifiOnly` download preference.
    private static func isOnWifi() async -> Bool {
        /// Thread-safe once-flag: the NSLock protects the `finished` Bool so
        /// that only the first NWPathMonitor callback resumes the continuation.
        final class OnceFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var finished = false
            /// Returns true only on the first call; false thereafter.
            func testAndSet() -> Bool {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return false }
                finished = true
                return true
            }
        }
        return await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let flag = OnceFlag()
            monitor.pathUpdateHandler = { path in
                guard flag.testAndSet() else { return }
                monitor.cancel()
                continuation.resume(returning: path.usesInterfaceType(.wifi))
            }
            monitor.start(queue: DispatchQueue.global(qos: .utility))
        }
    }

    /// Downloads the Kokoro English model chain (+ bundled `af_heart` voice)
    /// and the shared English G2P assets to FluidAudio's default cache.
    ///
    /// NOTE: `DownloadUtils.ProgressHandler` is `@Sendable (DownloadProgress) -> Void`
    /// (not `(Double) -> Void`). The plan assumed a plain Double; the actual type
    /// carries a `DownloadProgress` struct with `fractionCompleted: Double` and
    /// `phase: DownloadPhase`. We extract `.fractionCompleted` and forward it.
    private static func realDownload(
        _ progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let wifiOnly = UserDefaults.standard.object(forKey: wifiOnlyKey) as? Bool ?? true
        if wifiOnly, await isOnWifi() == false {
            throw NSError(
                domain: "KokoroModelManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("TTS_KOKORO_NEEDS_WIFI", comment: "")]
            )
        }
        try await KokoroAneResourceDownloader.ensureModels(
            variant: .english,
            directory: nil,
            progressHandler: { downloadProgress in progress(downloadProgress.fractionCompleted * 0.9) }
        )
        try await KokoroAneResourceDownloader.ensureG2PAssets(
            directory: nil,
            progressHandler: { downloadProgress in progress(0.9 + downloadProgress.fractionCompleted * 0.1) }
        )
        progress(1.0)
    }

    /// Detects whether the model chain is already on disk via a no-network
    /// filesystem presence check (mirrors the cache-hit logic in
    /// `KokoroAneResourceDownloader.ensureModels`).
    private static func realCheckInstalled() async -> Bool {
        KokoroAneResourceDownloader.modelsArePresent(variant: .english)
    }

    /// Synchronous flavor of `realCheckInstalled` — the underlying
    /// `modelsArePresent` is a sync filesystem check, no async required.
    private static func realCheckInstalledSync() -> Bool {
        KokoroAneResourceDownloader.modelsArePresent(variant: .english)
    }
}
