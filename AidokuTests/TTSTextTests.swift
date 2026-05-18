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
}
