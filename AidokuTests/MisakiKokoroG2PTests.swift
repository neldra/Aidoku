import Foundation
import Testing
@testable import Aidoku
import MisakiSwiftLite

/// Verifies the lexicon path that `MisakiKokoroG2PProvider` relies on.
/// The provider's FluidAudio OOV fallback requires the Kokoro model
/// download; that path is covered by the manual verification step.
@MainActor
@Suite struct MisakiKokoroG2PTests {

    @Test("function words hit the lexicon and produce non-letter-name IPA")
    func functionWordsHitLexicon() {
        let g2p = EnglishG2P(british: false)
        // These are the words that the broken FluidAudio BART G2P pronounced
        // as letter-names ("she" → "Shay", "a" → "Eh"). All should resolve
        // via the Misaki lexicon now.
        for word in ["the", "a", "she", "I", "of", "to", "and", "is"] {
            let (ipa, tokens) = g2p.phonemize(text: word)
            #expect(!ipa.isEmpty, "empty IPA for \(word)")
            let primary = tokens.first { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            #expect(primary?.phonemes != nil, "\(word) should be in lexicon")
        }
    }

    @Test("OOV words signal nil phonemes for caller handling")
    func oovReturnsNilPhonemes() {
        let g2p = EnglishG2P(british: false)
        let (_, tokens) = g2p.phonemize(text: "Rayquaza")
        let primary = tokens.first { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        #expect(primary != nil)
        #expect(primary?.phonemes == nil)
    }

    /// Stubs the per-word BART fallback so the OOV path is exercised without a
    /// live Kokoro model. Returning `nil` mimics a word BART can't resolve.
    private struct NilWordPhonemizer: KokoroWordPhonemizing {
        func phonemizeWord(_ word: String) async throws -> String? { nil }
    }

    @Test("an unresolvable word flags the result so the caller uses whole-text G2P")
    func unresolvableWordFlagsResult() async throws {
        let provider = MisakiKokoroG2PProvider(fluidAudio: NilWordPhonemizer())
        // "Rayquaza" misses the lexicon, and the stub fallback returns nil, so
        // it can be resolved by neither path.
        let result = try await provider.phonemize("Rayquaza")
        #expect(result.hasUnresolvedTokens)
    }

    @Test("fully-lexicalized input leaves the result unflagged")
    func lexicalizedInputNotFlagged() async throws {
        // Every word hits the Misaki lexicon, so the fallback (and the stub) is
        // never consulted and nothing is unresolved.
        let provider = MisakiKokoroG2PProvider(fluidAudio: NilWordPhonemizer())
        let result = try await provider.phonemize("the a she is")
        #expect(result.hasUnresolvedTokens == false)
        #expect(result.phonemes.isEmpty == false)
    }
}
