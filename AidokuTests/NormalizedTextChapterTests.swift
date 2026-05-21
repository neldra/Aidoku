import Testing
@testable import Aidoku

@Suite struct NormalizedTextChapterTests {
    private func chapter(_ paragraphs: [String]) -> NormalizedTextChapter {
        NormalizedTextChapter(id: "c1", title: "T", paragraphs: paragraphs)
    }

    @Test("word counter handles whitespace, punctuation, leading/trailing space")
    func wordCount() {
        #expect(NormalizedTextChapter.wordCount("") == 0)
        #expect(NormalizedTextChapter.wordCount("   ") == 0)
        #expect(NormalizedTextChapter.wordCount("one") == 1)
        #expect(NormalizedTextChapter.wordCount("one two three") == 3)
        #expect(NormalizedTextChapter.wordCount("  one   two  ") == 2)
        #expect(NormalizedTextChapter.wordCount("a\nb\tc") == 3)
        #expect(NormalizedTextChapter.wordCount("hello, world!") == 2)
    }

    @Test("paragraph word counts and totals are computed at init")
    func computedCounts() {
        let ch = chapter(["one two", "three", "four five six"])
        #expect(ch.paragraphWordCounts == [2, 1, 3])
        #expect(ch.estimatedWordCount == 6)
    }

    @Test("empty chapter is isEmpty and reports zero counts")
    func emptyChapter() {
        let ch = chapter([])
        #expect(ch.isEmpty)
        #expect(ch.estimatedWordCount == 0)
        #expect(ch.wordsRemaining(from: .start) == 0)
    }

    @Test("whitespace-only paragraphs count as empty narration")
    func whitespaceOnlyChapter() {
        let ch = chapter(["   ", "\t\n"])
        #expect(ch.isEmpty)
    }

    @Test("wordsRemaining from start equals total")
    func wordsRemainingFromStart() {
        let ch = chapter(["one two", "three", "four five six"])
        #expect(ch.wordsRemaining(from: .start) == 6)
    }

    @Test("wordsRemaining at end of chapter is zero")
    func wordsRemainingAtEnd() {
        let ch = chapter(["one two", "three", "four five six"])
        #expect(ch.wordsRemaining(from: .end(of: ch)) == 0)
    }

    @Test("wordsRemaining interpolates within the current paragraph")
    func wordsRemainingMidParagraph() {
        // "abcdefgh" = 1 word, 8 chars. Halfway through: 0.5 words remain in p0.
        let ch = chapter(["abcdefgh", "next"])
        let mid = TextChapterPosition(paragraphIndex: 0, charOffsetInParagraph: 4)
        // Remaining: 0.5 (half of p0's 1 word) + 1 (all of p1).
        #expect(ch.wordsRemaining(from: mid) == 1.5)
    }

    @Test("wordsRemaining handles a position past the last paragraph by clamping")
    func wordsRemainingClampOverflow() {
        let ch = chapter(["one two", "three"])
        let overflow = TextChapterPosition(paragraphIndex: 99, charOffsetInParagraph: 99)
        #expect(ch.wordsRemaining(from: overflow) == 0)
    }

    @Test("position(atWordsConsumed:) is monotonic and clamps")
    func positionFromWords() {
        let ch = chapter(["one two", "three four"])  // 4 words total
        #expect(ch.position(atWordsConsumed: -5) == .start)
        #expect(ch.position(atWordsConsumed: 0) == .start)
        // 2 words consumed → boundary between p0 and p1. Canonical form is
        // start of the next paragraph (that's where playback resumes), so (1, 0).
        let twoWords = ch.position(atWordsConsumed: 2)
        #expect(twoWords == TextChapterPosition(paragraphIndex: 1, charOffsetInParagraph: 0))
        // 4+ words → past end.
        #expect(ch.position(atWordsConsumed: 100) == .end(of: ch))
    }

    @Test("position(atWordsConsumed:) lands at the start of each paragraph boundary")
    func paragraphStartFromConsumedWords() {
        let ch = chapter(["one two three", "four five", "six seven eight nine"])
        // Cumulative word counts at the start of each paragraph: 0, 3, 5.
        var cumulative = 0
        for pIdx in 0..<ch.paragraphWordCounts.count {
            let landed = ch.position(atWordsConsumed: Double(cumulative))
            #expect(landed == TextChapterPosition(paragraphIndex: pIdx, charOffsetInParagraph: 0))
            cumulative += ch.paragraphWordCounts[pIdx]
        }
    }

    @Test("single very long paragraph: interpolation tracks linearly")
    func singleLongParagraph() {
        // 1000 words, 5000 chars (rough). Build a deterministic blob.
        let word = "word"
        let paragraph = Array(repeating: word, count: 1000).joined(separator: " ")
        let ch = chapter([paragraph])
        #expect(ch.estimatedWordCount == 1000)

        // Quarter through chars → roughly quarter through words.
        let quarter = TextChapterPosition(
            paragraphIndex: 0,
            charOffsetInParagraph: paragraph.count / 4
        )
        let remaining = ch.wordsRemaining(from: quarter)
        // Interpolation is linear on char count, so remaining ≈ 750 (within rounding).
        #expect(remaining >= 745 && remaining <= 755)
    }

    @Test("paragraph with zero-length text contributes zero words")
    func zeroLengthParagraph() {
        let ch = chapter(["", "real words here", ""])
        #expect(ch.estimatedWordCount == 3)
        #expect(ch.paragraphWordCounts == [0, 3, 0])
        // wordsRemaining from start should still be 3.
        #expect(ch.wordsRemaining(from: .start) == 3)
    }
}
