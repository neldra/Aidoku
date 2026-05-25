//
//  KokoroTextChunker.swift
//  Aidoku
//

import NaturalLanguage

/// Splits a paragraph into synthesis-sized chunks for Kokoro. Kokoro caps a
/// single call at 510 IPA phonemes / 2000 acoustic frames; a long paragraph
/// must be broken up. Chunking is by sentence (`NLTokenizer`); a sentence
/// longer than `maxChunkCharacters` is sub-split on clause punctuation, then on
/// word boundaries as a last resort. Character count is a conservative proxy
/// for the phoneme cap — English rarely exceeds ~1 phoneme per character, so
/// the threshold leaves ample headroom. Pure and deterministic.
enum KokoroTextChunker {
    /// Conservative character proxy for Kokoro's 510-phoneme cap.
    static let maxChunkCharacters = 300

    static func chunk(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var chunks: [String] = []
        for sentence in sentences(of: trimmed) {
            if sentence.count <= maxChunkCharacters {
                chunks.append(sentence)
            } else {
                chunks.append(contentsOf: splitLong(sentence))
            }
        }
        return chunks
    }

    private static func sentences(of text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { result.append(sentence) }
            return true
        }
        return result.isEmpty ? [text] : result
    }

    /// Sub-split an over-long sentence: first on clause punctuation, then any
    /// still-too-long piece on word boundaries.
    private static func splitLong(_ sentence: String) -> [String] {
        var pieces: [String] = []
        for clause in sentence.split(whereSeparator: { ",;:".contains($0) }) {
            let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.count <= maxChunkCharacters {
                pieces.append(trimmed)
            } else {
                pieces.append(contentsOf: splitOnWords(trimmed))
            }
        }
        return pieces.isEmpty ? splitOnWords(sentence) : pieces
    }

    private static func splitOnWords(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            let w = String(word)
            // A single token longer than the cap can't be joined — flush
            // current, then hard-slice the oversized token rather than
            // emitting it whole.
            if w.count > maxChunkCharacters {
                if !current.isEmpty { pieces.append(current); current = "" }
                var remaining = w
                while remaining.count > maxChunkCharacters {
                    let idx = remaining.index(remaining.startIndex, offsetBy: maxChunkCharacters)
                    pieces.append(String(remaining[..<idx]))
                    remaining = String(remaining[idx...])
                }
                if !remaining.isEmpty { current = remaining }
            } else if current.isEmpty {
                current = w
            } else if current.count + 1 + w.count <= maxChunkCharacters {
                current += " " + w
            } else {
                pieces.append(current)
                current = w
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
