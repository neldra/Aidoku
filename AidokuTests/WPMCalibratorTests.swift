import Testing
@testable import Aidoku

@Suite struct WPMCalibratorTests {
    @Test("seed value equals baseline before any samples")
    func seedValue() {
        let cal = WPMCalibrator(baselineWPM: 175)
        #expect(cal.currentWPM == 175)
        #expect(cal.sampleCount == 0)
    }

    @Test("first valid sample replaces the seed (no smoothing)")
    func firstSampleReplacesSeed() {
        var cal = WPMCalibrator(baselineWPM: 175, alpha: 0.3)
        // 200 words in 60s = 200 WPM.
        let accepted = cal.recordSample(words: 200, durationSec: 60)
        #expect(accepted)
        #expect(cal.currentWPM == 200)
        #expect(cal.sampleCount == 1)
    }

    @Test("subsequent samples smooth with the configured alpha")
    func subsequentSamplesSmooth() {
        var cal = WPMCalibrator(baselineWPM: 175, alpha: 0.3)
        _ = cal.recordSample(words: 200, durationSec: 60)  // observed = 200, running = 200
        _ = cal.recordSample(words: 100, durationSec: 60)  // observed = 100, running = 0.7*200 + 0.3*100 = 170
        #expect(abs(cal.currentWPM - 170) < 0.0001)
        #expect(cal.sampleCount == 2)
    }

    @Test("samples shorter than the threshold are filtered out")
    func filterShortSamples() {
        var cal = WPMCalibrator(baselineWPM: 175, minSampleDurationSec: 2.0)
        let accepted = cal.recordSample(words: 5, durationSec: 1.5)
        #expect(accepted == false)
        #expect(cal.currentWPM == 175)
        #expect(cal.sampleCount == 0)
    }

    @Test("samples with zero or negative words are rejected")
    func rejectZeroWords() {
        var cal = WPMCalibrator(baselineWPM: 175)
        #expect(cal.recordSample(words: 0, durationSec: 60) == false)
        #expect(cal.recordSample(words: -3, durationSec: 60) == false)
        #expect(cal.currentWPM == 175)
    }

    @Test("samples outside the WPM bounds are filtered out")
    func filterOutOfBoundsWPM() {
        var cal = WPMCalibrator(baselineWPM: 175, minObservedWPM: 50, maxObservedWPM: 500)
        // 10 words in 60s = 10 WPM, below floor.
        #expect(cal.recordSample(words: 10, durationSec: 60) == false)
        // 1000 words in 60s = 1000 WPM, above ceiling.
        #expect(cal.recordSample(words: 1000, durationSec: 60) == false)
        #expect(cal.currentWPM == 175)
        #expect(cal.sampleCount == 0)
    }

    @Test("reset for new voice clears samples and returns to baseline")
    func resetClearsState() {
        var cal = WPMCalibrator(baselineWPM: 175)
        _ = cal.recordSample(words: 200, durationSec: 60)
        _ = cal.recordSample(words: 220, durationSec: 60)
        #expect(cal.sampleCount == 2)
        cal.reset(forVoice: "com.apple.voice.premium.en-US.Ava")
        #expect(cal.currentWPM == 175)
        #expect(cal.sampleCount == 0)
        #expect(cal.voiceIdentifier == "com.apple.voice.premium.en-US.Ava")
    }

    @Test("running estimate converges toward observed rate after several samples")
    func convergesAfterSeveralSamples() {
        var cal = WPMCalibrator(baselineWPM: 175, alpha: 0.3)
        // Feed in 10 samples all at exactly 220 WPM.
        for _ in 0..<10 {
            _ = cal.recordSample(words: 220, durationSec: 60)
        }
        // Converged to the observation.
        #expect(abs(cal.currentWPM - 220) < 0.01)
        #expect(cal.sampleCount == 10)
    }

    @Test("samples normalize to 1.0x reference by dividing out observed rate")
    func ratesNormalize() {
        var cal = WPMCalibrator(baselineWPM: 175, alpha: 0.3)
        // 300 words in 60s observed at 1.5x rate. Raw observed = 300 WPM;
        // normalized to the 1.0x baseline = 300 / 1.5 = 200 WPM. The
        // estimator multiplies by current rate to project back.
        let accepted = cal.recordSample(words: 300, durationSec: 60, observedAtRate: 1.5)
        #expect(accepted)
        #expect(abs(cal.currentWPM - 200) < 0.0001)
        #expect(cal.sampleCount == 1)
    }

    @Test("zero or non-finite observedAtRate is rejected")
    func invalidRateRejected() {
        var cal = WPMCalibrator(baselineWPM: 175)
        #expect(cal.recordSample(words: 200, durationSec: 60, observedAtRate: 0) == false)
        #expect(cal.recordSample(words: 200, durationSec: 60, observedAtRate: -1) == false)
        #expect(cal.recordSample(words: 200, durationSec: 60, observedAtRate: .nan) == false)
        #expect(cal.recordSample(words: 200, durationSec: 60, observedAtRate: .infinity) == false)
        #expect(cal.sampleCount == 0)
        #expect(cal.currentWPM == 175)
    }

    @Test("rate-bound nonsense inputs do not poison the running value")
    func nonsenseInputsDoNotPoison() {
        var cal = WPMCalibrator(baselineWPM: 175)
        _ = cal.recordSample(words: 200, durationSec: 60)  // running = 200
        // NaN duration: filtered.
        #expect(cal.recordSample(words: 100, durationSec: .nan) == false)
        // Infinite duration: filtered.
        #expect(cal.recordSample(words: 100, durationSec: .infinity) == false)
        #expect(cal.currentWPM == 200)
    }
}
