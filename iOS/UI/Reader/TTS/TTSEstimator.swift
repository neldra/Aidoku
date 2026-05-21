//
//  TTSEstimator.swift
//  Aidoku
//

import Foundation

/// Result of a TTS time estimate. All values are seconds remaining (not minutes
/// like Readest's `timeinfo`); UI converts to clock format at the display layer.
///
/// `nil` values mean an estimate could not be produced (empty chapter, position
/// past the end, invalid rate). Mirrors Readest's nullable-fields convention so
/// the lockscreen scrub bar / display chips can render placeholders cleanly.
/// See `docs/SPEC.md` §3.4 and `notes/readest-investigation.md`.
struct TTSEstimate: Equatable {
    /// Seconds left in the current chapter from `position`.
    var chapterRemainingSec: TimeInterval?
    /// Seconds elapsed in the current chapter from start → `position`.
    var chapterElapsedSec: TimeInterval?
    /// Estimated total chapter duration (elapsed + remaining).
    var chapterDurationSec: TimeInterval?
    /// `Date()` at which the chapter is expected to finish, given current rate
    /// and calibrated WPM. `nil` when remaining is `nil` or non-positive.
    var finishAtTimestamp: Date?
}

/// Pure time-from-position math. No playback state, no observers — `estimate()`
/// is a static function so it can be called from anywhere (lockscreen update,
/// reader UI, unit tests).
///
/// Baseline: WPM scaled by user-selected rate, optionally adjusted by a
/// per-voice `calibratedWPM` from `WPMCalibrator`. See spec §3.4 for the
/// rationale on WPM (not CPS) and on self-calibration.
enum TTSEstimator {
    /// Conventional pace of a US English premium voice at `AVSpeechUtteranceDefaultSpeechRate`.
    /// This is the seed value `WPMCalibrator` starts from before any measurements arrive.
    static let baselineWPM: Double = 175

    /// Compute a remaining/elapsed/finish-at estimate.
    ///
    /// - Parameters:
    ///   - position: Current cursor in the chapter.
    ///   - chapter: Normalized chapter (word counts already baked in at init).
    ///   - rate: User's TTS rate. Treated as a multiplier — 1.0 = normal pace.
    ///   - calibratedWPM: Self-calibrated WPM from `WPMCalibrator`, or the
    ///     baseline when no samples exist yet.
    ///   - now: Clock reference for `finishAtTimestamp`. Defaults to `Date()`;
    ///     injectable for deterministic tests.
    static func estimate(
        position: TextChapterPosition,
        in chapter: NormalizedTextChapter,
        rate: Double,
        calibratedWPM: Double = baselineWPM,
        now: Date = Date()
    ) -> TTSEstimate {
        // Guard: chapter has nothing to say, or our pace inputs are nonsense.
        guard !chapter.isEmpty else { return TTSEstimate() }
        let effectiveRate = (rate.isFinite && rate > 0) ? rate : 1.0
        let effectiveWPM = (calibratedWPM.isFinite && calibratedWPM > 0) ? calibratedWPM : baselineWPM

        // Words per second at the effective pace.
        let wps = effectiveWPM * effectiveRate / 60.0
        guard wps > 0 else { return TTSEstimate() }

        let wordsRemaining = chapter.wordsRemaining(from: position)
        let wordsElapsed = max(0, Double(chapter.estimatedWordCount) - wordsRemaining)

        let remaining = wordsRemaining / wps
        let elapsed = wordsElapsed / wps
        let duration = elapsed + remaining

        let finishAt: Date? = remaining > 0
            ? now.addingTimeInterval(remaining)
            : nil

        return TTSEstimate(
            chapterRemainingSec: remaining,
            chapterElapsedSec: elapsed,
            chapterDurationSec: duration,
            finishAtTimestamp: finishAt
        )
    }

    /// Inverse: which position corresponds to `elapsed` seconds of playback?
    /// Used by `MPRemoteCommandCenter.changePlaybackPositionCommand` and ±15s skip.
    static func position(
        forElapsedSec elapsed: TimeInterval,
        in chapter: NormalizedTextChapter,
        rate: Double,
        calibratedWPM: Double = baselineWPM
    ) -> TextChapterPosition {
        guard !chapter.isEmpty else { return .start }
        let effectiveRate = (rate.isFinite && rate > 0) ? rate : 1.0
        let effectiveWPM = (calibratedWPM.isFinite && calibratedWPM > 0) ? calibratedWPM : baselineWPM
        let wps = effectiveWPM * effectiveRate / 60.0
        guard wps > 0 else { return .start }

        let wordsConsumed = max(0, elapsed) * wps
        return chapter.position(atWordsConsumed: wordsConsumed)
    }
}
