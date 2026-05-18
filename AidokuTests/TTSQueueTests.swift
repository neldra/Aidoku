import Testing
@testable import Aidoku

@Suite struct TTSQueueTests {
    private func make(_ n: Int, key: String = "c", start: Int = 0) -> TTSQueue {
        let ps = (0..<n).map {
            TTSParagraph(id: $0, chapterKey: key, displayMarkdown: "p\($0)", spokenText: "p\($0)")
        }
        return TTSQueue(paragraphs: ps, startIndex: start)
    }

    @Test("start index is clamped into range")
    func clampStart() {
        #expect(make(3, start: 9).index == 2)
        #expect(make(3, start: -4).index == 0)
        #expect(make(0, start: 2).index == 0)
    }

    @Test("advance stops at the last paragraph")
    func advance() {
        var q = make(3)
        #expect(q.advance()?.id == 1)
        #expect(q.advance()?.id == 2)
        #expect(q.advance() == nil)
        #expect(q.index == 2)
        #expect(q.isAtEnd)
    }

    @Test("rewind stops at the first paragraph")
    func rewind() {
        var q = make(3, start: 2)
        #expect(q.rewind()?.id == 1)
        #expect(q.rewind()?.id == 0)
        #expect(q.rewind() == nil)
        #expect(q.index == 0)
    }

    @Test("seek clamps and progress is fractional")
    func seekProgress() {
        var q = make(5)
        q.seek(to: 2)
        #expect(q.index == 2)
        #expect(q.progress == 0.5)
        q.seek(to: 99)
        #expect(q.index == 4)
        #expect(q.progress == 1.0)
    }

    @Test("appendChapter renumbers ids contiguously and keeps position")
    func appendChapter() {
        var q = make(2, key: "c1", start: 1)
        let next = [
            TTSParagraph(id: 0, chapterKey: "c2", displayMarkdown: "x", spokenText: "x"),
            TTSParagraph(id: 1, chapterKey: "c2", displayMarkdown: "y", spokenText: "y")
        ]
        q.appendChapter(next)
        #expect(q.count == 4)
        #expect(q.paragraphs.map(\.id) == [0, 1, 2, 3])
        #expect(q.paragraphs[3].chapterKey == "c2")
        #expect(q.index == 1)            // position unchanged by append
        #expect(q.advance()?.id == 2)    // can now cross into appended chapter
    }

    @Test("localIndexInCurrentChapter resets per chapter")
    func localIndex() {
        var q = make(2, key: "c1")
        #expect(q.localIndexInCurrentChapter == 0)
        q.advance()
        #expect(q.localIndexInCurrentChapter == 1)
        q.appendChapter([
            TTSParagraph(id: 0, chapterKey: "c2", displayMarkdown: "x", spokenText: "x"),
            TTSParagraph(id: 0, chapterKey: "c2", displayMarkdown: "y", spokenText: "y")
        ])
        q.advance()                       // global index 2 -> first of c2
        #expect(q.current?.chapterKey == "c2")
        #expect(q.localIndexInCurrentChapter == 0)
        q.advance()
        #expect(q.localIndexInCurrentChapter == 1)
    }

    @Test("rewind is the exact inverse of advance across paragraphs and stays in bounds")
    func rewindInverseOfAdvance() {
        var q = TTSQueue(
            paragraphs: TTSText.paragraphs(chapterKey: "c1", text: "A\n\nB\n\nC\n\nD"),
            startIndex: 0
        )
        #expect(q.index == 0)
        _ = q.advance(); _ = q.advance()      // 0 -> 1 -> 2
        #expect(q.index == 2)
        _ = q.rewind()                        // 2 -> 1  (must go DOWN)
        #expect(q.index == 1)
        _ = q.rewind()                        // 1 -> 0
        #expect(q.index == 0)
        #expect(q.rewind() == nil)            // clamped at start, no underflow
        #expect(q.index == 0)
        _ = q.advance(); _ = q.advance(); _ = q.advance() // 0 ->1->2->3 (last)
        #expect(q.index == 3)
        #expect(q.advance() == nil)           // clamped at end, no overflow
        #expect(q.index == 3)
    }
}
