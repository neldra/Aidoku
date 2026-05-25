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
}
