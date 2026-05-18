import Testing
@testable import Aidoku

@Suite struct TTSTextTests {
    @Test("splits on blank lines, trims, drops empties")
    func splitParagraphs() {
        let input = "First para.\n\n  Second para.  \n\n\n\nThird.\n\n   "
        #expect(TTSText.splitParagraphs(input) == ["First para.", "Second para.", "Third."])
    }

    @Test("normalizes CRLF before splitting")
    func splitParagraphsCRLF() {
        let input = "A line.\r\n\r\nB line."
        #expect(TTSText.splitParagraphs(input) == ["A line.", "B line."])
    }

    @Test("strips markdown syntax for narration", arguments: [
        ("# Chapter One", "Chapter One"),
        ("> a quote line", "a quote line"),
        ("Some *bold* and _italic_ and `code`.", "Some bold and italic and code."),
        ("See [the docs](https://x.y) now.", "See the docs now."),
        ("![alt text](img.png) after", "alt text after"),
        ("Line one\nLine two", "Line one Line two")
    ])
    func markdownToPlain(input: String, expected: String) {
        #expect(TTSText.markdownToPlain(input) == expected)
    }

    @Test("paragraphs() builds contiguous ids from a start offset")
    func paragraphsBuild() {
        let ps = TTSText.paragraphs(chapterKey: "ch1", text: "*A*\n\nB", startIndex: 5)
        #expect(ps.map(\.id) == [5, 6])
        #expect(ps.map(\.chapterKey) == ["ch1", "ch1"])
        #expect(ps[0].displayMarkdown == "*A*")
        #expect(ps[0].spokenText == "A")
    }
}
