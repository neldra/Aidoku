//
//  TrackerOffsetTests.swift
//  Aidoku
//

import Foundation
import Testing

@testable import Aidoku

@Suite struct TrackerOffsetTests {
    @Test func zeroOffsetIsNoOp() {
        #expect(TrackerManager.applyChapterOffset(50, offset: 0, totalChapters: 100) == 50)
        #expect(TrackerManager.applyChapterOffset(50, offset: 0, totalChapters: nil) == 50)
    }

    @Test func positiveAndNegativeOffsetApplied() {
        #expect(TrackerManager.applyChapterOffset(50, offset: 3, totalChapters: 100) == 53)
        #expect(TrackerManager.applyChapterOffset(50, offset: -2, totalChapters: 100) == 48)
    }

    @Test func clampsToZeroLowerBound() {
        #expect(TrackerManager.applyChapterOffset(1, offset: -5, totalChapters: 100) == 0)
        #expect(TrackerManager.applyChapterOffset(1, offset: -5, totalChapters: nil) == 0)
    }

    @Test func clampsToTotalChaptersUpperBound() {
        #expect(TrackerManager.applyChapterOffset(99, offset: 5, totalChapters: 100) == 100)
    }

    @Test func noUpperClampWhenTotalUnknown() {
        #expect(TrackerManager.applyChapterOffset(99, offset: 5, totalChapters: nil) == 104)
    }
}
