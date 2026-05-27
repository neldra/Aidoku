//
//  NormalizedTextChapter.swift
//  Aidoku
//

import Foundation

/// Source-agnostic representation of a chapter's narratable text. Markdown,
/// HTML fragments, and wall-of-text input all collapse into the same shape
/// so the rest of the TTS pipeline sees a single type.
///
/// Two-layer model:
///
/// - `displayParagraphs` reflects the source 1:1. The reader renders these
///   verbatim — every character that came from the source is here, including
///   any width-wrapped mid-sentence breaks the scraper introduced.
/// - `synthesisParagraphs` is the TTS-only view: adjacent display paragraphs
///   that don't end with a sentence terminator are merged so the synthesizer
///   sees complete utterances instead of mid-sentence fragments. No content
///   is dropped — every character in the source flows into one synthesis
///   paragraph.
///
/// `synthesisToDisplay` / `displayToSynthesis` round-trip positions between
/// the two coordinate systems so the highlight layer can light up the correct
/// display paragraph(s) when TTS is on a merged synthesis paragraph, and a
/// future tap-to-seek can drive the reverse path.
struct NormalizedTextChapter: Equatable {
    let id: String
    let title: String
    /// ISO 639-1 code; defaults to "en" when undetectable.
    let language: String

    /// Source paragraphs exactly as the reader sees them. Index-aligned with
    /// the reader's display so highlight markers can use these indices
    /// directly.
    let displayParagraphs: [String]
    /// TTS-side units. Adjacent display paragraphs that don't terminate are
    /// merged so the synthesizer sees complete utterances. Use the position-
    /// mapping methods to convert between display and synthesis coordinates.
    let synthesisParagraphs: [String]

    /// For each synthesis paragraph: the contiguous list of display
    /// paragraph slices that make up its content. Sorted by
    /// `synthesisStartOffset`. Used by `synthesisToDisplay`.
    private let synthesisToDisplayParts: [[DisplayPart]]
    /// For each display paragraph: the list of synthesis paragraph slices
    /// where this display paragraph's content appears. Sorted by
    /// `displayStartOffset`. Most display paragraphs have a single entry;
    /// straddlers produced by an over-cap comma split can have two.
    private let displayToSynthesisParts: [[SynthesisPart]]

    /// Word count per synthesis paragraph — the unit the TTS pipeline
    /// iterates and the calibrator times. Index-aligned with
    /// `synthesisParagraphs`.
    let paragraphWordCounts: [Int]
    /// Sum of `paragraphWordCounts`.
    let estimatedWordCount: Int

    /// Soft upper bound on a single synthesis paragraph. When a merge would
    /// exceed this, we look for a comma to split at; if none is available
    /// the paragraph is allowed to grow past the cap rather than splitting
    /// mid-word or losing content.
    static let softCapCharacters: Int = 1000

    /// Sentence-terminating punctuation. Em-dash is deliberately excluded —
    /// it's commonly used mid-narrative ("—she said—") and treating it as a
    /// terminator would split sentences in half.
    private static let terminators: Set<Character> =
        [".", "!", "?", "…", "。", "！", "？"]

    /// Punctuation that's allowed AFTER a terminator while still counting as
    /// a terminated paragraph: closing quotes (straight, curly single,
    /// curly double, single-low and double-low), parens / brackets / braces,
    /// asterisks (markdown emphasis), and right-pointing angle marks.
    private static let trailingClosers: Set<Character> = [
        "'", "\"",
        "\u{2018}", "\u{2019}",     // ' '
        "\u{201C}", "\u{201D}",     // " "
        "\u{201A}", "\u{201E}",     // ‚ „
        ")", "]", "}",
        "*", "_",
        "\u{203A}", "\u{00BB}",     // › »
    ]

    init(
        id: String,
        title: String,
        paragraphs: [String],
        language: String = "en"
    ) {
        self.id = id
        self.title = title
        self.language = language
        self.displayParagraphs = paragraphs

        let merged = Self.mergeBrokenParagraphs(paragraphs)
        self.synthesisParagraphs = merged.synthesisParagraphs
        self.synthesisToDisplayParts = merged.synthesisToDisplayParts
        self.displayToSynthesisParts = merged.displayToSynthesisParts

        // The position-math layer (estimator, TextChapterPosition, queue)
        // traverses synthesis units — that's the unit the engine actually
        // speaks, so the calibrator's words-per-second has to match. The
        // reader continues to render `displayParagraphs`; its highlight
        // fans out across the active synthesis paragraph's `displayRange`.
        let counts = merged.synthesisParagraphs.map { Self.wordCount($0) }
        self.paragraphWordCounts = counts
        self.estimatedWordCount = counts.reduce(0, +)
    }

    /// Alias for `synthesisParagraphs`. Estimator / position math / queue
    /// callers read `paragraphs` and operate in synthesis units so the
    /// calibrator's wpm matches what the synthesizer actually iterates.
    /// The reader does NOT use this alias — it renders `displayParagraphs`.
    var paragraphs: [String] { synthesisParagraphs }

    /// Whether the chapter has any narratable content.
    var isEmpty: Bool { paragraphs.isEmpty || estimatedWordCount == 0 }

    // MARK: - Position mapping

    /// Map a position in the synthesis coordinate system to a position in
    /// the display coordinate system. Returns `nil` if the synthesis
    /// paragraph index is out of range. Char offset is clamped to the
    /// containing display paragraph's length.
    func synthesisToDisplay(
        paragraphIndex: Int,
        charOffset: Int
    ) -> (displayIndex: Int, charOffsetInDisplay: Int)? {
        guard synthesisToDisplayParts.indices.contains(paragraphIndex) else {
            return nil
        }
        let parts = synthesisToDisplayParts[paragraphIndex]
        guard !parts.isEmpty else { return nil }

        // Pick the latest part whose synth-start is <= the queried offset.
        var found = parts[0]
        for part in parts.dropFirst() {
            if part.synthesisStartOffset <= charOffset {
                found = part
            } else {
                break
            }
        }
        let offsetWithinPart = max(0, charOffset - found.synthesisStartOffset)
        let clamped = min(
            displayParagraphs[found.displayIndex].count,
            found.displayStartOffset + offsetWithinPart
        )
        return (found.displayIndex, clamped)
    }

    /// Map a position in the display coordinate system to a position in the
    /// synthesis coordinate system. Returns `nil` if the display paragraph
    /// was skipped entirely (empty paragraph in the source) — in that case
    /// the highlight has nothing to seek to.
    func displayToSynthesis(
        paragraphIndex: Int,
        charOffset: Int
    ) -> (synthesisIndex: Int, charOffsetInSynthesis: Int)? {
        guard displayToSynthesisParts.indices.contains(paragraphIndex) else {
            return nil
        }
        let parts = displayToSynthesisParts[paragraphIndex]
        guard !parts.isEmpty else { return nil }

        var found = parts[0]
        for part in parts.dropFirst() {
            if part.displayStartOffset <= charOffset {
                found = part
            } else {
                break
            }
        }
        let offsetWithinPart = max(0, charOffset - found.displayStartOffset)
        let synthesisOffset = found.synthesisStartOffset + offsetWithinPart
        return (found.synthesisIndex, synthesisOffset)
    }

    /// Contiguous range of display paragraph indices that the given
    /// synthesis paragraph covers. The reader uses this to highlight every
    /// display paragraph that contributed to the active synthesis paragraph.
    /// Returns `nil` if `paragraphIndex` is out of range.
    func displayRange(forSynthesisParagraphIndex paragraphIndex: Int) -> Range<Int>? {
        guard synthesisToDisplayParts.indices.contains(paragraphIndex) else {
            return nil
        }
        let parts = synthesisToDisplayParts[paragraphIndex]
        guard
            let first = parts.first?.displayIndex,
            let last = parts.last?.displayIndex
        else { return nil }
        return first..<(last + 1)
    }

    // MARK: - Word-position math (operates on synthesis paragraphs)

    /// Number of words still ahead of (and including the remainder of)
    /// `position`. Operates on the synthesis layer: `position`'s
    /// `paragraphIndex` is a synthesis paragraph index — the unit the queue
    /// and the engine's cursor both use.
    func wordsRemaining(from position: TextChapterPosition) -> Double {
        guard !paragraphs.isEmpty else { return 0 }
        let clamped = position.clamped(to: self)
        let pIdx = clamped.paragraphIndex

        var remaining = 0.0
        if pIdx + 1 < paragraphWordCounts.count {
            for i in (pIdx + 1)..<paragraphWordCounts.count {
                remaining += Double(paragraphWordCounts[i])
            }
        }

        let pLen = paragraphs[pIdx].count
        let pWords = paragraphWordCounts[pIdx]
        if pLen > 0 {
            let consumed = min(max(0, clamped.charOffsetInParagraph), pLen)
            let fractionLeft = 1.0 - Double(consumed) / Double(pLen)
            remaining += Double(pWords) * fractionLeft
        }
        return remaining
    }

    /// Inverse of `wordsRemaining`. Returned position's `paragraphIndex` is
    /// a synthesis paragraph index — match the unit the cursor consumes.
    func position(atWordsConsumed wordsConsumed: Double) -> TextChapterPosition {
        guard !paragraphs.isEmpty else { return .start }
        if wordsConsumed <= 0 { return .start }
        if wordsConsumed >= Double(estimatedWordCount) { return .end(of: self) }

        var running = 0.0
        for (idx, words) in paragraphWordCounts.enumerated() {
            let next = running + Double(words)
            if wordsConsumed < next {
                let wordsIntoParagraph = wordsConsumed - running
                let pLen = paragraphs[idx].count
                let fraction: Double
                if words > 0 {
                    fraction = min(1.0, max(0.0, wordsIntoParagraph / Double(words)))
                } else {
                    fraction = 0
                }
                let charOffset = Int((Double(pLen) * fraction).rounded())
                return TextChapterPosition(
                    paragraphIndex: idx,
                    charOffsetInParagraph: min(charOffset, pLen)
                )
            }
            running = next
        }
        return .end(of: self)
    }

    // MARK: - Word counting

    /// Count contiguous non-whitespace runs.
    static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if inWord { count += 1; inWord = false }
            } else {
                inWord = true
            }
        }
        if inWord { count += 1 }
        return count
    }

    // MARK: - Merge algorithm

    /// One slice of a display paragraph's content inside a synthesis
    /// paragraph: where it starts in the synthesis string, and where it
    /// starts within its display paragraph (non-zero only for the second
    /// half of a straddler produced by a comma-split).
    private struct DisplayPart: Equatable {
        let displayIndex: Int
        let synthesisStartOffset: Int
        let displayStartOffset: Int
    }

    /// One slice of a display paragraph in the *other* direction: where in
    /// the synthesis chapter to find content for this display offset.
    private struct SynthesisPart: Equatable {
        let synthesisIndex: Int
        let displayStartOffset: Int
        let synthesisStartOffset: Int
    }

    /// Output bundle from `mergeBrokenParagraphs` so the init can wire up
    /// all three fields atomically.
    private struct MergeResult {
        let synthesisParagraphs: [String]
        let synthesisToDisplayParts: [[DisplayPart]]
        let displayToSynthesisParts: [[SynthesisPart]]
    }

    /// Merge adjacent display paragraphs that don't end with a sentence
    /// terminator. Rules:
    ///
    /// - Empty paragraphs flush the in-progress merge and are not merged
    ///   through (an explicit blank line in the source means "stop here").
    /// - The first non-empty paragraph is preserved standalone if it's
    ///   title-like (short, no terminator, starts with a digit) — captures
    ///   the "2285 Legion of Death" chapter-number prefix pattern.
    /// - Trailing quotes / brackets / asterisks / underscores are tolerated
    ///   when checking for a terminator, so `."` and `.")` and `.*` all
    ///   still count as terminated.
    /// - When the accumulator exceeds `softCapCharacters`, we look for the
    ///   last comma and split there as a soft break. If no comma is
    ///   available the paragraph grows past the cap rather than splitting
    ///   mid-word.
    /// - Em-dash (—) is NOT a terminator; mid-narrative em-dashes are
    ///   common and treating them as breaks fragments dialogue.
    private static func mergeBrokenParagraphs(
        _ paragraphs: [String]
    ) -> MergeResult {
        var synthesis: [String] = []
        var synthMap: [[DisplayPart]] = []
        var displayMap: [[SynthesisPart]] = Array(
            repeating: [],
            count: paragraphs.count
        )

        var accumulator = ""
        var accumulatorParts: [DisplayPart] = []

        func flush() {
            guard !accumulator.isEmpty else { return }
            let synthIdx = synthesis.count
            synthesis.append(accumulator)
            synthMap.append(accumulatorParts)
            for part in accumulatorParts {
                displayMap[part.displayIndex].append(SynthesisPart(
                    synthesisIndex: synthIdx,
                    displayStartOffset: part.displayStartOffset,
                    synthesisStartOffset: part.synthesisStartOffset
                ))
            }
            accumulator = ""
            accumulatorParts = []
        }

        for (displayIdx, raw) in paragraphs.enumerated() {
            // An "empty" paragraph here means no narratable content. Pure
            // whitespace also counts — the source might emit "   " between
            // sections and we treat it the same as a true blank line.
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flush()
                continue
            }

            // Title detection only fires for the very first non-empty
            // paragraph of the chapter. Once anything else has landed we
            // never re-enter title mode.
            if synthesis.isEmpty, accumulator.isEmpty, isTitleLike(raw) {
                let synthIdx = synthesis.count
                synthesis.append(raw)
                synthMap.append([
                    DisplayPart(
                        displayIndex: displayIdx,
                        synthesisStartOffset: 0,
                        displayStartOffset: 0
                    )
                ])
                displayMap[displayIdx].append(SynthesisPart(
                    synthesisIndex: synthIdx,
                    displayStartOffset: 0,
                    synthesisStartOffset: 0
                ))
                continue
            }

            // Join with a single space; that's the only character we add
            // anywhere in this pipeline, and it's a no-op for word counting
            // and for any speech synthesizer.
            let separator = accumulator.isEmpty ? "" : " "
            let startOffsetInAccumulator = accumulator.count + separator.count
            accumulatorParts.append(DisplayPart(
                displayIndex: displayIdx,
                synthesisStartOffset: startOffsetInAccumulator,
                displayStartOffset: 0
            ))
            accumulator += separator + raw

            if endsWithTerminator(accumulator) {
                flush()
                continue
            }

            // Soft cap: if we've grown past the limit and a comma is
            // available, split at the last comma and let the remainder
            // continue accumulating. Straddling display paragraphs get
            // split with their content distributed across two synthesis
            // paragraphs.
            if accumulator.count > softCapCharacters {
                if let split = splitAccumulatorAtLastComma(
                    accumulator,
                    parts: accumulatorParts
                ) {
                    let synthIdx = synthesis.count
                    synthesis.append(split.head)
                    synthMap.append(split.headParts)
                    for part in split.headParts {
                        displayMap[part.displayIndex].append(SynthesisPart(
                            synthesisIndex: synthIdx,
                            displayStartOffset: part.displayStartOffset,
                            synthesisStartOffset: part.synthesisStartOffset
                        ))
                    }
                    accumulator = split.tail
                    accumulatorParts = split.tailParts
                }
                // If no usable comma, just let the paragraph grow past
                // the cap rather than splitting mid-word or losing content.
            }
        }

        flush()

        return MergeResult(
            synthesisParagraphs: synthesis,
            synthesisToDisplayParts: synthMap,
            displayToSynthesisParts: displayMap
        )
    }

    /// Is the text a chapter-number-style title — short, no terminator,
    /// starts with a digit? Captures patterns like "2285 Legion of Death"
    /// or "Chapter 1" (though "Chapter" doesn't start with a digit so the
    /// latter falls through and just merges with the following paragraph,
    /// which is the right behaviour).
    private static func isTitleLike(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return false }
        guard !endsWithTerminator(trimmed) else { return false }
        return trimmed.first?.isNumber == true
    }

    /// Does the accumulator end in a sentence-final terminator, allowing
    /// trailing whitespace and trailing closers (quotes, brackets, etc.)?
    private static func endsWithTerminator(_ text: String) -> Bool {
        var idx = text.endIndex
        while idx > text.startIndex {
            let prev = text.index(before: idx)
            let ch = text[prev]
            if ch.isWhitespace || trailingClosers.contains(ch) {
                idx = prev
                continue
            }
            return terminators.contains(ch)
        }
        return false
    }

    private struct AccumulatorSplit {
        let head: String
        let headParts: [DisplayPart]
        let tail: String
        let tailParts: [DisplayPart]
    }

    /// Find the last comma in `accumulator` and return the (head, tail)
    /// split, with display parts redistributed. Returns nil when no usable
    /// comma exists or when the resulting head would be too short to be
    /// worth flushing (< 25% of the soft cap).
    private static func splitAccumulatorAtLastComma(
        _ accumulator: String,
        parts: [DisplayPart]
    ) -> AccumulatorSplit? {
        // Walk by character (Swift indexes) so the offsets we hand out
        // match `.count` in the rest of the file.
        let chars = Array(accumulator)
        var commaPosition: Int? = nil
        for i in stride(from: chars.count - 1, through: 0, by: -1) {
            if chars[i] == "," {
                commaPosition = i
                break
            }
        }
        guard let commaIdx = commaPosition else { return nil }
        let splitPos = commaIdx + 1  // include the comma in the head

        let minHead = softCapCharacters / 4
        guard splitPos >= minHead else { return nil }

        let head = String(chars[..<splitPos])
        let tail = String(chars[splitPos...])

        // Redistribute parts. For each part, compute its [start, end) in
        // the accumulator. Parts fully before splitPos → head. Fully after
        // → tail (with shifted offset). Straddlers → head keeps the part
        // intact (its content is cut at splitPos), tail gets a continuation
        // entry whose displayStartOffset reflects how much of that display
        // paragraph the head already consumed.
        var headParts: [DisplayPart] = []
        var tailParts: [DisplayPart] = []
        for (i, part) in parts.enumerated() {
            let partStart = part.synthesisStartOffset
            let partEnd = (i + 1 < parts.count)
                ? parts[i + 1].synthesisStartOffset
                : accumulator.count
            if partEnd <= splitPos {
                headParts.append(part)
            } else if partStart >= splitPos {
                tailParts.append(DisplayPart(
                    displayIndex: part.displayIndex,
                    synthesisStartOffset: partStart - splitPos,
                    displayStartOffset: part.displayStartOffset
                ))
            } else {
                // Straddler: the comma falls inside this display paragraph's
                // content. Head keeps the entry as-is. Tail gets a follow-on.
                headParts.append(part)
                let consumedInDisplay = splitPos - partStart
                let remainingLength = partEnd - splitPos
                if remainingLength > 0 {
                    tailParts.append(DisplayPart(
                        displayIndex: part.displayIndex,
                        synthesisStartOffset: 0,
                        displayStartOffset: part.displayStartOffset
                            + consumedInDisplay
                    ))
                }
            }
        }

        return AccumulatorSplit(
            head: head,
            headParts: headParts,
            tail: tail,
            tailParts: tailParts
        )
    }
}
