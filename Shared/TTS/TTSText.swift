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
}
