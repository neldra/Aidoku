//
//  TTSText.swift
//  Aidoku
//

import Foundation

/// One narratable paragraph: original markdown for display, stripped text for speech.
///
/// `displayRange` is the contiguous range of *display-layer* paragraph indices
/// (chapter-local) this entry covers. For display-aligned paragraphs (the
/// reader's source) the range is a single index `id..<id+1`. For synthesis-
/// aligned paragraphs (the engine queue's units) it can span multiple display
/// indices when the merge layer collapsed mid-sentence fragments together.
struct TTSParagraph: Identifiable, Equatable {
    let id: Int
    let chapterKey: String
    let displayMarkdown: String
    let spokenText: String
    let displayRange: Range<Int>

    /// Production synthesis paragraphs come from `TTSText.chapterBundle`
    /// which always passes an explicit `displayRange`. The default — a
    /// single-index span derived from `id` — exists for test fixtures and
    /// for legacy display-aligned construction, where the chapter-local
    /// range and the absolute id happen to coincide.
    init(
        id: Int,
        chapterKey: String,
        displayMarkdown: String,
        spokenText: String,
        displayRange: Range<Int>? = nil
    ) {
        self.id = id
        self.chapterKey = chapterKey
        self.displayMarkdown = displayMarkdown
        self.spokenText = spokenText
        self.displayRange = displayRange ?? (id..<(id + 1))
    }
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

    /// Display-aligned paragraph list. One entry per blank-line-separated
    /// block of the source — the reader renders these verbatim. Each entry's
    /// `displayRange` is the single-index range `id..<id+1` so callers that
    /// need to fan a highlight out across display paragraphs (the merged-
    /// synthesis case) get a uniform shape.
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
                spokenText: markdownToPlain(block),
                displayRange: offset..<(offset + 1)
            )
        }
    }

    /// Synthesis-aligned paragraph list — the unit the TTS engine actually
    /// iterates. Adjacent display paragraphs that don't end with a sentence
    /// terminator are merged by `NormalizedTextChapter` so the synthesizer
    /// sees complete utterances instead of mid-sentence width-wrap fragments.
    /// Each entry's `displayRange` is the contiguous span of display indices
    /// it covers; the reader's highlight layer uses that range to fan out the
    /// active-paragraph marker across every visible block the merge consumed.
    static func synthesisParagraphs(
        chapterKey: String,
        text: String,
        startIndex: Int = 0
    ) -> [TTSParagraph] {
        let bundle = chapterBundle(chapterKey: chapterKey, text: text, synthesisStartIndex: startIndex)
        return bundle.synthesisParagraphs
    }

    /// Bundle the synthesis-aligned queue paragraphs and the underlying
    /// normalized chapter (which carries the position-math and display↔︎
    /// synthesis mappings) so the engine can build both at the same time
    /// without re-splitting the chapter twice.
    static func chapterBundle(
        chapterKey: String,
        text: String,
        chapterTitle: String = "",
        language: String = "en",
        synthesisStartIndex: Int = 0
    ) -> ChapterBundle {
        let displayBlocks = splitParagraphs(text)
        let displaySpoken = displayBlocks.map(markdownToPlain)
        let chapter = NormalizedTextChapter(
            id: chapterKey,
            title: chapterTitle,
            paragraphs: displaySpoken,
            language: language
        )
        let synthesisParagraphs = chapter.synthesisParagraphs.enumerated().map { offset, spoken in
            let range = chapter.displayRange(forSynthesisParagraphIndex: offset)
                ?? offset..<(offset + 1)
            let clampedRange = range.clamped(to: 0..<displayBlocks.count)
            let mergedMarkdown = clampedRange
                .map { displayBlocks[$0] }
                .joined(separator: "\n\n")
            return TTSParagraph(
                id: synthesisStartIndex + offset,
                chapterKey: chapterKey,
                displayMarkdown: mergedMarkdown,
                spokenText: spoken,
                displayRange: range
            )
        }
        return ChapterBundle(
            synthesisParagraphs: synthesisParagraphs,
            normalizedChapter: chapter
        )
    }

    /// Output of `chapterBundle`: the engine reads `synthesisParagraphs` for
    /// the queue and `normalizedChapter` for the position-math layer
    /// (`currentNormalizedChapter`). The two are derived from the same
    /// underlying split so a single chapter's text is only parsed once.
    struct ChapterBundle {
        let synthesisParagraphs: [TTSParagraph]
        let normalizedChapter: NormalizedTextChapter
    }
}

private extension Range where Bound == Int {
    /// Intersect with `bounds`. Empty ranges (lowerBound ≥ upperBound) get
    /// collapsed to `bounds.lowerBound..<bounds.lowerBound`.
    func clamped(to bounds: Range<Int>) -> Range<Int> {
        let lower = Swift.max(lowerBound, bounds.lowerBound)
        let upper = Swift.min(upperBound, bounds.upperBound)
        guard lower < upper else { return bounds.lowerBound..<bounds.lowerBound }
        return lower..<upper
    }
}
