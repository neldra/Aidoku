import Testing
@testable import Aidoku

@Suite struct KokoroTextChunkerTests {
    @Test("a short paragraph is a single chunk")
    func shortIsSingle() {
        let chunks = KokoroTextChunker.chunk("The cat sat. The dog ran.")
        #expect(chunks.count == 2)
        for chunk in chunks {
            #expect(chunk.count <= KokoroTextChunker.maxChunkCharacters)
        }
    }

    @Test("empty or whitespace input yields no chunks")
    func emptyYieldsNothing() {
        #expect(KokoroTextChunker.chunk("").isEmpty)
        #expect(KokoroTextChunker.chunk("   \n  ").isEmpty)
    }

    @Test("multiple sentences split one chunk per sentence")
    func multiSentence() {
        let chunks = KokoroTextChunker.chunk("One. Two. Three.")
        #expect(chunks.count == 3)
    }

    @Test("a sentence longer than the cap is sub-split, each piece within the cap")
    func longSentenceSubSplit() {
        let long = Array(repeating: "word", count: 400).joined(separator: " ")
        let chunks = KokoroTextChunker.chunk(long)
        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(chunk.count <= KokoroTextChunker.maxChunkCharacters)
        }
    }

    @Test("chunks never exceed the cap even for clause-heavy text")
    func clauseHeavyWithinCap() {
        let clauses = Array(repeating: "a clause here", count: 60).joined(separator: ", ")
        for chunk in KokoroTextChunker.chunk(clauses) {
            #expect(chunk.count <= KokoroTextChunker.maxChunkCharacters)
        }
    }

    @Test("a token longer than the cap does not exceed the cap")
    func singleOversizedTokenSubSplit() {
        let oversized = String(repeating: "a", count: 400)
        let chunks = KokoroTextChunker.chunk(oversized)
        #expect(chunks.isEmpty == false)
        for chunk in chunks {
            #expect(chunk.count <= KokoroTextChunker.maxChunkCharacters)
        }
    }
}
