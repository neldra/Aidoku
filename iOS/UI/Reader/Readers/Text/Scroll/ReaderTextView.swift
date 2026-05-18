//
//  ReaderTextView.swift
//  Aidoku
//
//  Created by skitty on 3/16/26.
//

import AidokuRunner
import SwiftUI
import ZIPFoundation

struct ReaderTextView: View {
    let source: AidokuRunner.Source?
    let text: String?
    let chapterKey: String
    let fontFamily: String
    let fontSize: Double
    let lineSpacing: Double
    let horizontalPadding: Double

    @ObservedObject private var tts = TTSManager.shared

    init(
        source: AidokuRunner.Source?,
        page: Page?,
        fontFamily: String,
        fontSize: Double,
        lineSpacing: Double,
        horizontalPadding: Double
    ) {
        self.source = source
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.horizontalPadding = horizontalPadding
        self.chapterKey = page?.chapterId ?? ""

        self.text = page?.resolvedText()
    }

    private var paragraphs: [TTSParagraph] {
        guard let text else { return [] }
        return TTSText.paragraphs(chapterKey: chapterKey, text: text)
    }

    /// `paragraph.id` is the 0-based index within this chapter (this view
    /// builds paragraphs with the default `startIndex: 0`), so it compares
    /// directly against the manager's chapter-local index.
    private func isHighlighted(_ paragraph: TTSParagraph) -> Bool {
        tts.isActive
            && tts.currentChapterKey == chapterKey
            && paragraph.id == tts.currentLocalIndex
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
                            .fill(isHighlighted(paragraph)
                                  ? Color.accentColor.opacity(0.16)
                                  : Color.clear)
                    )
                    .animation(.easeInOut(duration: 0.2), value: isHighlighted(paragraph))
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ignoresSafeArea()
        }
    }
}
