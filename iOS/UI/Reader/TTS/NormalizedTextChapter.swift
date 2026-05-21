//
//  NormalizedTextChapter.swift
//  Aidoku
//

import Foundation

/// Source-agnostic representation of a chapter's narratable text. Markdown,
/// HTML fragments, and wall-of-text input all collapse into the same shape
/// so the rest of the TTS pipeline sees a single type.
struct NormalizedTextChapter: Equatable {
    let id: String
    let title: String
    /// Always non-empty for narratable chapters (an empty chapter normalizes to `[]`).
    /// Each element is plain spoken text — markdown/HTML already stripped.
    let paragraphs: [String]
    /// ISO 639-1 code; defaults to "en" when undetectable.
    let language: String

    /// Word count per paragraph. Index-aligned with `paragraphs`.
    let paragraphWordCounts: [Int]
    /// Sum of `paragraphWordCounts`.
    let estimatedWordCount: Int
    /// Sum of `paragraphs[i].count`.
    let estimatedCharCount: Int

    init(id: String, title: String, paragraphs: [String], language: String = "en") {
        self.id = id
        self.title = title
        self.paragraphs = paragraphs
        self.language = language
        let counts = paragraphs.map { Self.wordCount($0) }
        self.paragraphWordCounts = counts
        self.estimatedWordCount = counts.reduce(0, +)
        self.estimatedCharCount = paragraphs.reduce(0) { $0 + $1.count }
    }

    /// Whether the chapter has any narratable content.
    var isEmpty: Bool { paragraphs.isEmpty || estimatedWordCount == 0 }

    /// Number of words still ahead of (and including the remainder of) `position`.
    /// The current paragraph's remaining words are estimated by linearly
    /// interpolating `charOffsetInParagraph` across its character count.
    func wordsRemaining(from position: TextChapterPosition) -> Double {
        guard !paragraphs.isEmpty else { return 0 }
        let clamped = position.clamped(to: self)
        let pIdx = clamped.paragraphIndex

        // Full words from paragraphs strictly after the current one.
        var remaining = 0.0
        if pIdx + 1 < paragraphWordCounts.count {
            for i in (pIdx + 1)..<paragraphWordCounts.count {
                remaining += Double(paragraphWordCounts[i])
            }
        }

        // Partial words still ahead in the current paragraph.
        let pLen = paragraphs[pIdx].count
        let pWords = paragraphWordCounts[pIdx]
        if pLen > 0 {
            let consumed = min(max(0, clamped.charOffsetInParagraph), pLen)
            let fractionLeft = 1.0 - Double(consumed) / Double(pLen)
            remaining += Double(pWords) * fractionLeft
        }

        return remaining
    }

    /// Number of words consumed up to (but not including the remainder of) `position`.
    func wordsConsumed(upTo position: TextChapterPosition) -> Double {
        Double(estimatedWordCount) - wordsRemaining(from: position)
    }

    /// Locate the position that corresponds to `wordsConsumed` words from
    /// the chapter start. Inverse of `wordsConsumed(upTo:)` up to the
    /// linear-interpolation precision; clamped into the chapter.
    func position(atWordsConsumed wordsConsumed: Double) -> TextChapterPosition {
        guard !paragraphs.isEmpty else { return .start }
        if wordsConsumed <= 0 { return .start }
        if wordsConsumed >= Double(estimatedWordCount) { return .end(of: self) }

        // At a paragraph boundary, canonical form is the start of the *next*
        // paragraph (matches how playback advances). Use strict `<` so the
        // seam at exactly `next` words consumed lands in the following
        // iteration rather than terminating in the current one.
        var running = 0.0
        for (idx, words) in paragraphWordCounts.enumerated() {
            let next = running + Double(words)
            if wordsConsumed < next {
                let wordsIntoParagraph = wordsConsumed - running
                let pLen = paragraphs[idx].count
                let fraction: Double
                if words > 0 {
                    fraction = min(1.0, max(0.0, wordsIntoParagraph / Double(words)))
                } else {
                    fraction = 0
                }
                let charOffset = Int((Double(pLen) * fraction).rounded())
                return TextChapterPosition(
                    paragraphIndex: idx,
                    charOffsetInParagraph: min(charOffset, pLen)
                )
            }
            running = next
        }
        return .end(of: self)
    }

    // MARK: - Word counting

    /// Count contiguous non-whitespace runs.
    static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if inWord { count += 1; inWord = false }
            } else {
                inWord = true
            }
        }
        if inWord { count += 1 }
        return count
    }
}
