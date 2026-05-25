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

    public init(phonemes: String, coverage: Double) {
        self.phonemes = phonemes
        self.coverage = coverage
    }
}

@available(iOS 16, *)
public protocol KokoroG2PProvider: Sendable {
    func phonemize(_ text: String) async throws -> KokoroG2PResult
}
