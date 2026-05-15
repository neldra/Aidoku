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

    @Test func fractionalChapterPreserved() {
        #expect(TrackerManager.applyChapterOffset(12.5, offset: -2, totalChapters: 100) == 10.5)
    }

    @Test func landsExactlyOnUpperBound() {
        #expect(TrackerManager.applyChapterOffset(98, offset: 2, totalChapters: 100) == 100)
    }

    @Test func landsExactlyOnZero() {
        #expect(TrackerManager.applyChapterOffset(2, offset: -2, totalChapters: nil) == 0)
    }

    @Test func backupDecodesMissingOffsetAsZero() throws {
        // legacy backup payload without the "offset" key
        let legacy = #"{"id":"a","trackerId":"al","mangaId":"m","sourceId":"s","title":"T"}"#
        let decoded = try JSONDecoder().decode(BackupTrackItem.self, from: Data(legacy.utf8))
        #expect(decoded.offset == 0)
    }

    @Test func backupRoundTripsOffset() throws {
        let item = BackupTrackItem(
            id: "a", trackerId: "al", mangaId: "m", sourceId: "s", title: "T", offset: -3
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(BackupTrackItem.self, from: data)
        #expect(decoded.offset == -3)
    }
}
