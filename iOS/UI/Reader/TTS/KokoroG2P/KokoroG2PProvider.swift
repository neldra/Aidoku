//
//  KokoroG2PProvider.swift
//  Aidoku
//

import Foundation

@available(iOS 16, *)
public struct KokoroG2PResult: Sendable {
    public let phonemes: String
    /// Lexicon-hit ratio over content tokens (0…1). Callers may use this to
    /// decide whether to route to FluidAudio's built-in whole-text G2P when
    /// coverage is too low to trust the overlay output.
    public let coverage: Double
    /// `true` when at least one content word could be resolved by neither the
    /// Misaki lexicon nor the per-word BART fallback. Such a word is absent
    /// from `phonemes`; callers must route the whole chunk through FluidAudio's
    /// whole-text G2P rather than speak the resulting hole.
    public let hasUnresolvedTokens: Bool

    public init(phonemes: String, coverage: Double, hasUnresolvedTokens: Bool = false) {
        self.phonemes = phonemes
        self.coverage = coverage
        self.hasUnresolvedTokens = hasUnresolvedTokens
    }
}

@available(iOS 16, *)
public protocol KokoroG2PProvider: Sendable {
    func phonemize(_ text: String) async throws -> KokoroG2PResult
}

/// Narrow seam over FluidAudio's per-word BART G2P so
/// `MisakiKokoroG2PProvider`'s OOV-fallback logic is unit-testable without a
/// live Kokoro model. `KokoroAneManager` conforms via extension.
@available(iOS 16, *)
public protocol KokoroWordPhonemizing: Sendable {
    func phonemizeWord(_ word: String) async throws -> String?
}
