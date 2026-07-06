import Foundation
import Testing
@testable import Aidoku

@Suite struct TTSEstimatorTests {
    private func chapter(_ paragraphs: [String]) -> NormalizedTextChapter {
        NormalizedTextChapter(id: "c1", title: "T", paragraphs: paragraphs)
    }

    /// Build a chapter with a known exact word count for arithmetic tests.
    /// Each generated paragraph ends with a period so the synthesis-layer
    /// merge (which collapses unterminated fragments) leaves the paragraph
    /// count intact — the math tests rely on a specific paragraph layout.
    /// The terminator adds one character per paragraph but contributes no
    /// words, so `wordCount` stays the requested value.
    private func chapter(words wordCount: Int, perParagraph: Int = 10) -> NormalizedTextChapter {
        let paragraphCount = (wordCount + perParagraph - 1) / perParagraph
        var paragraphs: [String] = []
        var remaining = wordCount
        for _ in 0..<paragraphCount {
            let w = min(perParagraph, remaining)
            paragraphs.append(Array(repeating: "word", count: w).joined(separator: " ") + ".")
            remaining -= w
        }
        return chapter(paragraphs)
    }

    @Test("estimate at start returns full chapter duration as remaining")
    func estimateAtStart() {
        // 175 words at 175 WPM × 1.0 rate = 60s.
        let ch = chapter(words: 175)
        let est = TTSEstimator.estimate(
            position: .start,
            in: ch,
            rate: 1.0,
            calibratedWPM: 175,
            now: Date(timeIntervalSince1970: 1000)
        )
        #expect(est.chapterRemainingSec == 60)
        #expect(est.chapterElapsedSec == 0)
        #expect(est.chapterDurationSec == 60)
        #expect(est.finishAtTimestamp == Date(timeIntervalSince1970: 1060))
    }

    @Test("estimate at end has zero remaining and nil finish-at")
    func estimateAtEnd() {
        let ch = chapter(words: 175)
        let est = TTSEstimator.estimate(
            position: .end(of: ch),
            in: ch,
            rate: 1.0,
            calibratedWPM: 175
        )
        #expect(est.chapterRemainingSec == 0)
        #expect(est.chapterElapsedSec == 60)
        #expect(est.chapterDurationSec == 60)
        #expect(est.finishAtTimestamp == nil)
    }

    @Test("rate scales remaining time inversely")
    func rateScaling() {
        let ch = chapter(words: 175)
        let at1x = TTSEstimator.estimate(position: .start, in: ch, rate: 1.0, calibratedWPM: 175)
        let at2x = TTSEstimator.estimate(position: .start, in: ch, rate: 2.0, calibratedWPM: 175)
        let athalf = TTSEstimator.estimate(position: .start, in: ch, rate: 0.5, calibratedWPM: 175)
        #expect(at1x.chapterRemainingSec == 60)
        #expect(at2x.chapterRemainingSec == 30)
        #expect(athalf.chapterRemainingSec == 120)
    }

    @Test("calibratedWPM scales remaining time inversely")
    func calibrationScaling() {
        let ch = chapter(words: 175)
        let slow = TTSEstimator.estimate(position: .start, in: ch, rate: 1.0, calibratedWPM: 100)
        let fast = TTSEstimator.estimate(position: .start, in: ch, rate: 1.0, calibratedWPM: 350)
        #expect(slow.chapterRemainingSec ?? 0 > 60)   // ~105s
        #expect(fast.chapterRemainingSec ?? 0 < 60)   // ~30s
    }

    @Test("empty chapter produces all-nil estimate")
    func emptyChapter() {
        let ch = chapter([])
        let est = TTSEstimator.estimate(position: .start, in: ch, rate: 1.0)
        #expect(est.chapterRemainingSec == nil)
        #expect(est.chapterElapsedSec == nil)
        #expect(est.chapterDurationSec == nil)
        #expect(est.finishAtTimestamp == nil)
    }

    @Test("invalid rate falls back to 1.0")
    func invalidRate() {
        let ch = chapter(words: 175)
        let zero = TTSEstimator.estimate(position: .start, in: ch, rate: 0, calibratedWPM: 175)
        let negative = TTSEstimator.estimate(position: .start, in: ch, rate: -1, calibratedWPM: 175)
        let nan = TTSEstimator.estimate(position: .start, in: ch, rate: .nan, calibratedWPM: 175)
        let inf = TTSEstimator.estimate(position: .start, in: ch, rate: .infinity, calibratedWPM: 175)
        // All four should fall back to 1.0 rate → 60s remaining at 175 WPM.
        #expect(zero.chapterRemainingSec == 60)
        #expect(negative.chapterRemainingSec == 60)
        #expect(nan.chapterRemainingSec == 60)
        #expect(inf.chapterRemainingSec == 60)
    }

    @Test("invalid calibrated WPM falls back to baseline")
    func invalidCalibration() {
        let ch = chapter(words: 175)
        let est = TTSEstimator.estimate(position: .start, in: ch, rate: 1.0, calibratedWPM: -5)
        // Baseline is 175 → 60s remaining at 175 words.
        #expect(est.chapterRemainingSec == 60)
    }

    @Test("position → elapsed → position is a tight round trip")
    func positionRoundTrip() {
        let ch = chapter(words: 200, perParagraph: 10)
        // Pick a position clearly inside paragraph 10 (avoids paragraph-boundary
        // floating-point ambiguity). Compute its elapsed, convert back.
        let original = TextChapterPosition(
            paragraphIndex: 10,
            charOffsetInParagraph: ch.paragraphs[10].count / 2
        )
        let estimate = TTSEstimator.estimate(
            position: original, in: ch, rate: 1.0, calibratedWPM: 175
        )
        let elapsed = estimate.chapterElapsedSec ?? 0
        let derived = TTSEstimator.position(
            forElapsedSec: elapsed, in: ch, rate: 1.0, calibratedWPM: 175
        )
        #expect(derived.paragraphIndex == original.paragraphIndex)
        #expect(abs(derived.charOffsetInParagraph - original.charOffsetInParagraph) <= 1)
    }

    @Test("position(forElapsedSec:) clamps negative and overflow")
    func positionClampedElapsed() {
        let ch = chapter(words: 100)
        #expect(TTSEstimator.position(forElapsedSec: -10, in: ch, rate: 1, calibratedWPM: 175) == .start)
        let huge = TTSEstimator.position(forElapsedSec: 99_999, in: ch, rate: 1, calibratedWPM: 175)
        #expect(huge == .end(of: ch))
    }

    @Test("very long single paragraph: estimate scales with intra-paragraph progress")
    func longSingleParagraph() {
        // Make a 1000-word paragraph chapter. At 175 WPM × 1.0 = ~342.86s total.
        let ch = chapter(words: 1000, perParagraph: 1000)
        let start = TTSEstimator.estimate(position: .start, in: ch, rate: 1, calibratedWPM: 175)
        let halfPos = TextChapterPosition(
            paragraphIndex: 0,
            charOffsetInParagraph: ch.paragraphs[0].count / 2
        )
        let half = TTSEstimator.estimate(position: halfPos, in: ch, rate: 1, calibratedWPM: 175)

        let total = start.chapterRemainingSec ?? 0
        let remaining = half.chapterRemainingSec ?? 0
        // Halfway through chars ≈ halfway through estimated remaining time.
        // Allow modest tolerance for word/char alignment.
        let ratio = remaining / total
        #expect(ratio > 0.45 && ratio < 0.55)
    }
}
