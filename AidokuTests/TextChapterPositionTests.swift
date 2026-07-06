import Foundation
import Testing
@testable import Aidoku

@Suite struct TextChapterPositionTests {
    private func chapter(_ paragraphs: [String], lang: String = "en") -> NormalizedTextChapter {
        NormalizedTextChapter(id: "c1", title: "T", paragraphs: paragraphs, language: lang)
    }

    @Test("default char offset is zero")
    func defaultOffset() {
        let p = TextChapterPosition(paragraphIndex: 3)
        #expect(p.paragraphIndex == 3)
        #expect(p.charOffsetInParagraph == 0)
    }

    @Test("start is the (0, 0) sentinel")
    func startSentinel() {
        #expect(TextChapterPosition.start == TextChapterPosition(paragraphIndex: 0, charOffsetInParagraph: 0))
    }

    @Test("end points at the final paragraph's last character")
    func endPosition() {
        let ch = chapter(["One.", "Two two.", "Three three three."])
        let e = TextChapterPosition.end(of: ch)
        #expect(e.paragraphIndex == 2)
        #expect(e.charOffsetInParagraph == "Three three three.".count)
    }

    @Test("end of an empty chapter is start")
    func endEmpty() {
        let ch = chapter([])
        #expect(TextChapterPosition.end(of: ch) == .start)
    }

    @Test("clamped pulls negative or overflowing values into bounds")
    func clampedBounds() {
        // Terminators keep the merge layer from collapsing these two
        // display paragraphs into a single synthesis paragraph (the unit
        // `clamped` measures against).
        let ch = chapter(["Hello.", "World."])
        let underflow = TextChapterPosition(paragraphIndex: -1, charOffsetInParagraph: -5)
        #expect(underflow.clamped(to: ch) == TextChapterPosition(paragraphIndex: 0, charOffsetInParagraph: 0))
        let overflow = TextChapterPosition(paragraphIndex: 10, charOffsetInParagraph: 999)
        #expect(overflow.clamped(to: ch) == TextChapterPosition(paragraphIndex: 1, charOffsetInParagraph: 6))
    }

    @Test("clamped against an empty chapter collapses to start")
    func clampedEmpty() {
        let ch = chapter([])
        let p = TextChapterPosition(paragraphIndex: 4, charOffsetInParagraph: 12)
        #expect(p.clamped(to: ch) == .start)
    }

    @Test("Codable round-trips paragraph index and char offset")
    func codableRoundTrip() throws {
        let original = TextChapterPosition(paragraphIndex: 7, charOffsetInParagraph: 42)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TextChapterPosition.self, from: data)
        #expect(decoded == original)
    }

    @Test("Hashable identity matches Equatable")
    func hashableMatchesEquatable() {
        let a = TextChapterPosition(paragraphIndex: 2, charOffsetInParagraph: 10)
        let b = TextChapterPosition(paragraphIndex: 2, charOffsetInParagraph: 10)
        var seen: Set<TextChapterPosition> = []
        seen.insert(a)
        #expect(seen.contains(b))
    }
}
