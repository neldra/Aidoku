//
//  ReaderTextView.swift
//  Aidoku
//
//  Created by skitty on 3/16/26.
//

import AidokuRunner
import SwiftUI
import ZIPFoundation

struct TTSParagraphFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] { [:] }
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct ReaderTextView: View {
    let source: AidokuRunner.Source?
    let text: String?
    let chapterKey: String
    let fontFamily: String
    let fontSize: Double
    let lineSpacing: Double
    let horizontalPadding: Double
    var onParagraphFrames: (([Int: CGRect]) -> Void)?

    @ObservedObject private var tts = TTSManager.shared
    @Environment(\.colorScheme) private var colorScheme

    init(
        source: AidokuRunner.Source?,
        page: Page?,
        fontFamily: String,
        fontSize: Double,
        lineSpacing: Double,
        horizontalPadding: Double,
        onParagraphFrames: (([Int: CGRect]) -> Void)? = nil
    ) {
        self.source = source
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.horizontalPadding = horizontalPadding
        self.chapterKey = page?.chapterId ?? ""
        self.onParagraphFrames = onParagraphFrames

        self.text = page?.resolvedText()
    }

    private var paragraphs: [TTSParagraph] {
        guard let text else { return [] }
        return TTSText.paragraphs(chapterKey: chapterKey, text: text)
    }

    /// 16% accent reads cleanly on a near-white background; on a near-black
    /// one it barely lifts. Roughly double the opacity in dark mode so the
    /// active paragraph has comparable contrast against either surface.
    private var highlightFill: Color {
        Color.accentColor.opacity(colorScheme == .dark ? 0.32 : 0.16)
    }

    /// `paragraph.id` is the 0-based chapter-local display index (built with
    /// the default `startIndex: 0`). When the engine's active utterance
    /// merged several display paragraphs together, every index in the
    /// synthesis paragraph's `currentLocalDisplayRange` lights up so the
    /// visible row of text matches what's being spoken.
    private func isHighlighted(_ paragraph: TTSParagraph) -> Bool {
        guard
            tts.isActive,
            tts.currentChapterKey == chapterKey,
            let range = tts.currentLocalDisplayRange
        else { return false }
        return range.contains(paragraph.id)
    }

    var body: some View {
        if text != nil {
            VStack(alignment: .leading, spacing: lineSpacing * 1.5) {
                ForEach(paragraphs) { paragraph in
                    MarkdownView(
                        paragraph.displayMarkdown,
                        fontFamily: fontFamily,
                        fontSize: fontSize,
                        lineSpacing: lineSpacing,
                        horizontalPadding: 0
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isHighlighted(paragraph) ? highlightFill : Color.clear)
                    )
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: TTSParagraphFramesKey.self,
                                value: [paragraph.id: geo.frame(in: .named("ttsReaderContent"))]
                            )
                        }
                    )
                    .animation(.easeInOut(duration: 0.2), value: isHighlighted(paragraph))
                }
            }
            .onPreferenceChange(TTSParagraphFramesKey.self) { onParagraphFrames?($0) }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ignoresSafeArea()
            .coordinateSpace(name: "ttsReaderContent")
        }
    }
}
