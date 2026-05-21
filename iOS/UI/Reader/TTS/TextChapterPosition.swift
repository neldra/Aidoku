//
//  TextChapterPosition.swift
//  Aidoku
//

import Foundation

/// Unified position cursor shared by the text reader and the TTS engine.
/// The reader writes this when scroll settles; the engine writes it when an
/// utterance boundary fires. Time is derived from this, never stored.
struct TextChapterPosition: Codable, Equatable, Hashable {
    /// Paragraph index within the chapter's normalized paragraph array (0-based).
    var paragraphIndex: Int
    /// Character offset into the paragraph's spoken text. Clamped to [0, paragraph.count].
    var charOffsetInParagraph: Int

    init(paragraphIndex: Int, charOffsetInParagraph: Int = 0) {
        self.paragraphIndex = paragraphIndex
        self.charOffsetInParagraph = charOffsetInParagraph
    }

    /// Position at the very start of the chapter.
    static let start = TextChapterPosition(paragraphIndex: 0, charOffsetInParagraph: 0)

    /// Position pointing one past the last paragraph of `chapter`, used as the
    /// upper bound for duration calculations.
    static func end(of chapter: NormalizedTextChapter) -> TextChapterPosition {
        guard let last = chapter.paragraphs.last else {
            return .start
        }
        return TextChapterPosition(
            paragraphIndex: max(0, chapter.paragraphs.count - 1),
            charOffsetInParagraph: last.count
        )
    }

    /// Clamp into the bounds of `chapter`. Out-of-range paragraph indices collapse
    /// to the nearest valid paragraph; char offsets clamp to [0, paragraph.count].
    func clamped(to chapter: NormalizedTextChapter) -> TextChapterPosition {
        guard !chapter.paragraphs.isEmpty else {
            return .start
        }
        let pIndex = min(max(0, paragraphIndex), chapter.paragraphs.count - 1)
        let pLen = chapter.paragraphs[pIndex].count
        let cOff = min(max(0, charOffsetInParagraph), pLen)
        return TextChapterPosition(paragraphIndex: pIndex, charOffsetInParagraph: cOff)
    }
}
