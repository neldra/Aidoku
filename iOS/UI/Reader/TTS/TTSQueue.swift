//
//  TTSQueue.swift
//  Aidoku
//

import Foundation

/// Pure paragraph cursor for narration. No audio, no UIKit — fully testable.
struct TTSQueue {
    private(set) var paragraphs: [TTSParagraph]
    private(set) var index: Int

    init(paragraphs: [TTSParagraph], startIndex: Int = 0) {
        self.paragraphs = paragraphs
        self.index = Self.clamp(startIndex, count: paragraphs.count)
    }

    var count: Int { paragraphs.count }
    var current: TTSParagraph? {
        paragraphs.indices.contains(index) ? paragraphs[index] : nil
    }
    var isAtEnd: Bool { index >= paragraphs.count - 1 }

    /// Index of the current paragraph *within its own chapter* (0-based).
    /// The reader renders one chapter at a time numbered from 0, so highlight
    /// matching must use this, not the global queue index.
    var localIndexInCurrentChapter: Int {
        guard let key = current?.chapterKey else { return 0 }
        let firstOfChapter = paragraphs.firstIndex { $0.chapterKey == key } ?? 0
        return index - firstOfChapter
    }
    var progress: Double {
        guard paragraphs.count > 1 else { return paragraphs.isEmpty ? 0 : 1 }
        return Double(index) / Double(paragraphs.count - 1)
    }

    @discardableResult
    mutating func advance() -> TTSParagraph? {
        guard index < paragraphs.count - 1 else { return nil }
        index += 1
        return paragraphs[index]
    }

    @discardableResult
    mutating func rewind() -> TTSParagraph? {
        guard index > 0 else { return nil }
        index -= 1
        return paragraphs[index]
    }

    mutating func seek(to newIndex: Int) {
        index = Self.clamp(newIndex, count: paragraphs.count)
    }

    /// Append a following chapter's paragraphs, renumbering ids to stay contiguous.
    mutating func appendChapter(_ next: [TTSParagraph]) {
        let base = paragraphs.count
        paragraphs.append(contentsOf: next.enumerated().map { offset, p in
            TTSParagraph(
                id: base + offset,
                chapterKey: p.chapterKey,
                displayMarkdown: p.displayMarkdown,
                spokenText: p.spokenText
            )
        })
    }

    private static func clamp(_ i: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(i, 0), count - 1)
    }
}
