//
//  TTSText.swift
//  Aidoku
//

import Foundation

/// One narratable paragraph: original markdown for display, stripped text for speech.
struct TTSParagraph: Identifiable, Equatable {
    let id: Int
    let chapterKey: String
    let displayMarkdown: String
    let spokenText: String
}

enum TTSText {
    /// Split chapter markdown into paragraph blocks on blank-line boundaries.
    static func splitParagraphs(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Strip common markdown so the synthesizer does not read symbols.
    static func markdownToPlain(_ markdown: String) -> String {
        var s = markdown
        func replace(_ pattern: String, _ template: String) {
            s = s.replacingOccurrences(
                of: pattern, with: template, options: .regularExpression
            )
        }
        replace(#"!\[([^\]]*)\]\([^\)]*\)"#, "$1")   // images ![alt](url) -> alt
        replace(#"\[([^\]]+)\]\([^\)]*\)"#, "$1")     // links [text](url) -> text
        replace(#"(?m)^\s{0,3}#{1,6}\s+"#, "")         // headings
        replace(#"(?m)^\s{0,3}>\s?"#, "")              // blockquote markers
        replace(#"[*_`~]"#, "")                        // emphasis / code ticks
        replace(#"\s+"#, " ")                          // collapse whitespace
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build the paragraph queue for one chapter's text.
    static func paragraphs(
        chapterKey: String,
        text: String,
        startIndex: Int = 0
    ) -> [TTSParagraph] {
        splitParagraphs(text).enumerated().map { offset, block in
            TTSParagraph(
                id: startIndex + offset,
                chapterKey: chapterKey,
                displayMarkdown: block,
                spokenText: markdownToPlain(block)
            )
        }
    }
}
