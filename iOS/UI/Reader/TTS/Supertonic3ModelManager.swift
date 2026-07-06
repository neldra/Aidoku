//
//  Supertonic3ModelManager.swift
//  Aidoku
//

import Foundation
import FluidAudio
import Network

/// Owns the Supertonic-3 model download and the availability state machine
/// that `Supertonic3SpeechBackend.availability` projects. iOS 16+ — neural
/// TTS never runs on iOS 15. Mirror of `KokoroModelManager`; download/check
/// operations are injectable for testing.
@available(iOS 16, *)
@MainActor
final class Supertonic3ModelManager: ObservableObject {
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
    static let wifiOnlyKey = "Reader.ttsSupertonic3WifiOnly"

    private var downloadTask: Task<Void, Never>?
    /// Bumped whenever a download settles (success, failure, or cancel). A
    /// `refreshInstalledState` disk check captures this before its `await`;
    /// if it changed by the time the check resolves, a download intervened and
    /// owns the state — the (possibly stale) read is discarded.
    private var downloadGeneration = 0

    private let performDownload: (@escaping @Sendable (Double) -> Void) async throws -> Void
    private let checkInstalled: () async -> Bool
    private let checkInstalledSync: @MainActor () -> Bool

    init(
        performDownload: @escaping (@escaping @Sendable (Double) -> Void) async throws -> Void
            = Supertonic3ModelManager.realDownload,
        checkInstalled: @escaping () async -> Bool
            = Supertonic3ModelManager.realCheckInstalled,
        checkInstalledSync: @escaping @MainActor () -> Bool
            = Supertonic3ModelManager.realCheckInstalledSync
    ) {
        self.performDownload = performDownload
        self.checkInstalled = checkInstalled
        self.checkInstalledSync = checkInstalledSync
    }

    var availability: BackendAvailability {
        switch state {
        case .notInstalled: return .needsDownload
        case .downloading(let progress): return .downloading(progress: progress)
        case .ready: return .ready
        case .failed(let reason): return .unavailable(reason: reason)
        }
    }

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

    private static func isOnWifi() async -> Bool {
        final class OnceFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var finished = false
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

    /// Download the four Supertonic-3 CoreML stages + companion JSON files to
    /// FluidAudio's default cache. The voice style preset (M1) is bundled in
    /// the app, not downloaded.
    private static func realDownload(
        _ progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let wifiOnly = UserDefaults.standard.object(forKey: wifiOnlyKey) as? Bool ?? true
        if wifiOnly, await isOnWifi() == false {
            throw NSError(
                domain: "Supertonic3ModelManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("TTS_SUPERTONIC3_NEEDS_WIFI", comment: "")]
            )
        }
        try await Supertonic3ResourceDownloader.ensureModels(
            directory: nil,
            progressHandler: { downloadProgress in
                progress(downloadProgress.fractionCompleted)
            }
        )
        progress(1.0)
    }

    private static func realCheckInstalled() async -> Bool {
        Supertonic3ResourceDownloader.modelsArePresent()
    }

    private static func realCheckInstalledSync() -> Bool {
        Supertonic3ResourceDownloader.modelsArePresent()
    }
}
