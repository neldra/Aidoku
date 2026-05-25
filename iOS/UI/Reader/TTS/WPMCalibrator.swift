//
//  WPMCalibrator.swift
//  Aidoku
//

import Foundation

/// Self-tuning WPM estimator: feed it observed utterance durations and it
/// returns a running estimate of how fast the active voice actually speaks
/// at the user's current rate. Strategy is an exponentially-weighted moving
/// average; resettable on voice change. Short utterances are filtered as
/// noise (single-word paragraphs, pauses).
struct WPMCalibrator {
    /// Weight applied to a new sample (old value keeps `1 - alpha`). The
    /// default 0.3 gives a ~3-sample warmup before observations dominate.
    let alpha: Double
    /// Utterances shorter than this are discarded as noise.
    let minSampleDurationSec: TimeInterval
    /// Clamp observed WPM into this range so a one-off glitch can't push
    /// the running value out of bounds.
    let minObservedWPM: Double
    let maxObservedWPM: Double
    /// Seed value used when no samples have been recorded.
    let baselineWPM: Double

    /// Current running estimate. `baselineWPM` until the first valid sample lands.
    private(set) var currentWPM: Double
    /// Number of samples that have contributed (post-filter).
    private(set) var sampleCount: Int = 0
    /// Voice identifier the running estimate is calibrated against; changing
    /// voice resets the running value back to the baseline.
    private(set) var voiceIdentifier: String?

    init(
        baselineWPM: Double = TTSEstimator.baselineWPM,
        alpha: Double = 0.3,
        minSampleDurationSec: TimeInterval = 2.0,
        minObservedWPM: Double = 50,
        maxObservedWPM: Double = 500
    ) {
        self.baselineWPM = baselineWPM
        self.alpha = alpha
        self.minSampleDurationSec = minSampleDurationSec
        self.minObservedWPM = minObservedWPM
        self.maxObservedWPM = maxObservedWPM
        self.currentWPM = baselineWPM
    }

    /// Reset the running estimate. Call when the user picks a different
    /// voice — `calibratedWPM` is per-voice, not per-rate.
    mutating func reset(forVoice newVoice: String?) {
        currentWPM = baselineWPM
        sampleCount = 0
        voiceIdentifier = newVoice
    }

    /// Record a finished utterance. Discards samples that are too short to be
    /// reliable, or that would produce out-of-bounds WPM observations.
    ///
    /// - Returns: `true` if the sample was accepted and the running value updated;
    ///   `false` if it was filtered out (informational, for tests/logs).
    @discardableResult
    mutating func recordSample(words: Int, durationSec: TimeInterval) -> Bool {
        guard words > 0, durationSec.isFinite, durationSec >= minSampleDurationSec else {
            return false
        }
        let observed = Double(words) / (durationSec / 60.0)
        guard observed.isFinite, observed >= minObservedWPM, observed <= maxObservedWPM else {
            return false
        }
        if sampleCount == 0 {
            // First valid sample replaces the seed outright.
            currentWPM = observed
        } else {
            currentWPM = (1 - alpha) * currentWPM + alpha * observed
        }
        sampleCount += 1
        return true
    }
}
