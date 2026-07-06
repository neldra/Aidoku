//
//  MisakiKokoroG2PProvider.swift
//  Aidoku
//

import Foundation
import FluidAudio
@preconcurrency import MisakiSwiftLite

/// Lexicon-first English G2P:
///   1. Try MisakiSwiftLite for each token (Apple `NaturalLanguage` POS +
///      Misaki `us_gold` / `us_silver` lexicon).
///   2. For tokens MisakiSwiftLite cannot resolve (OOV — proper nouns,
///      rare words), fall back to FluidAudio's BART G2P per word.
///
/// Output: concatenated IPA string suitable for
/// `KokoroAneManager.synthesizeFromPhonemesDetailed(phonemes:)`, plus a
/// `coverage` ratio so callers can detect mostly-OOV input and route it
/// through FluidAudio's built-in whole-text G2P instead.
@available(iOS 16, *)
extension KokoroAneManager: KokoroWordPhonemizing {}

@available(iOS 16, *)
public final class MisakiKokoroG2PProvider: KokoroG2PProvider {
    private let g2p: EnglishG2P
    private let fluidAudio: KokoroWordPhonemizing

    public init(fluidAudio: KokoroWordPhonemizing, british: Bool = false) {
        self.g2p = EnglishG2P(british: british)
        self.fluidAudio = fluidAudio
    }

    public func phonemize(_ text: String) async throws -> KokoroG2PResult {
        let (lexiconIPA, tokens) = g2p.phonemize(text: text)
        var lexiconHits = 0
        var contentTokens = 0
        var needsFallback = false

        for token in tokens {
            let isContent = token.text.contains(where: \.isLetter)
            guard isContent else { continue }
            contentTokens += 1
            if token.phonemes != nil {
                lexiconHits += 1
            } else {
                needsFallback = true
            }
        }

        let phonemes: String
        var hasUnresolvedTokens = false
        if needsFallback {
            var pieces: [String] = []
            pieces.reserveCapacity(tokens.count)
            for token in tokens {
                if let ipa = token.phonemes {
                    pieces.append(ipa)
                    pieces.append(token.whitespace)
                } else if token.text.contains(where: \.isLetter) {
                    if let fallback = try await fluidAudio.phonemizeWord(token.text) {
                        pieces.append(fallback)
                        pieces.append(token.whitespace)
                    } else {
                        // Neither the lexicon nor per-word BART G2P could resolve
                        // this word. Dropping it from `pieces` would speak a
                        // silent hole, so flag the whole chunk for whole-text
                        // G2P instead (see KokoroSpeechBackend.synthesize).
                        hasUnresolvedTokens = true
                    }
                } else {
                    pieces.append(token.text)
                    pieces.append(token.whitespace)
                }
            }
            phonemes = pieces.joined()
        } else {
            phonemes = lexiconIPA
        }

        let coverage = contentTokens > 0 ? Double(lexiconHits) / Double(contentTokens) : 1.0
        return KokoroG2PResult(
            phonemes: phonemes,
            coverage: coverage,
            hasUnresolvedTokens: hasUnresolvedTokens
        )
    }
}
