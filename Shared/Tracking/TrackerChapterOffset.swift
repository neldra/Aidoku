//
//  TrackerChapterOffset.swift
//  Aidoku
//

import Foundation

extension TrackerManager {
    /// Applies a per-title chapter offset and clamps the result.
    ///
    /// Used only by the auto-update-after-reading path. The manual edit path
    /// must never call this.
    static func applyChapterOffset(_ chapter: Float, offset: Int, totalChapters: Int?) -> Float {
        let adjusted = chapter + Float(offset)
        if let totalChapters {
            return min(max(adjusted, 0), Float(totalChapters))
        } else {
            return max(adjusted, 0)
        }
    }
}
