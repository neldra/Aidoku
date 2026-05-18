//
//  Page.swift
//  Aidoku
//
//  Created by Skitty on 12/22/21.
//

import Foundation
import AidokuRunner
import ZIPFoundation

struct Page: Hashable {

    enum PageType: Int {
        case imagePage
        case prevInfoPage
        case nextInfoPage
    }

    var type: PageType = .imagePage
    var sourceId: String
    var chapterId: String
    var index: Int = 0
    var imageURL: String?
    var base64: String?
    var text: String?
    var image: PlatformImage?
    var zipURL: String?

    var context: PageContext?
    var hasDescription: Bool = false
    var description: String?

    var key: String {
        "\(chapterId)|\(index)"
    }

    var isTextPage: Bool {
        text != nil || (zipURL != nil && imageURL?.lowercased().hasSuffix(".txt") == true)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(chapterId)
        hasher.combine(index)
    }
}

extension Page {
    /// The page's text whether delivered inline (`text`) or as a `.txt`
    /// entry inside a downloaded chapter's zip (`zipURL` + `imageURL`).
    func resolvedText() -> String? {
        if let text { return text }
        guard
            let zipURL = zipURL.flatMap({ URL(string: $0) }),
            let filePath = imageURL
        else { return nil }
        do {
            var data = Data()
            let archive = try Archive(url: zipURL, accessMode: .read)
            guard let entry = archive[filePath] else { return nil }
            _ = try archive.extract(entry, consumer: { data.append($0) })
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }
}

extension Page {
    func toNew() -> AidokuRunner.Page {
        let content: AidokuRunner.PageContent = if let imageURL, let url = URL(string: imageURL) {
            .url(url: url, context: context)
        } else if let text {
            .text(text)
        } else if let image {
#if os(macOS)
            .image(AidokuRunner.PlatformImage(image))
#else
            .image(image)
#endif
        } else if let zipURL, let url = URL(string: zipURL), let imageURL {
            .zipFile(url: url, filePath: imageURL)
        } else {
            .text("Invalid URL")
        }
        return AidokuRunner.Page(
            content: content,
            hasDescription: hasDescription,
            description: description
        )
    }
}
