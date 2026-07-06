import AVFoundation
import Testing
@testable import Aidoku

@MainActor
@Suite struct NeuralAudioPlayerTests {
    @Test("makeBuffer copies samples into a mono float buffer")
    func makeBufferCopiesSamples() {
        let samples: [Float] = [0.0, 0.25, -0.5, 0.75, -1.0]
        let buffer = NeuralAudioPlayer.makeBuffer(samples: samples, sampleRate: 24_000)
        #expect(buffer != nil)
        #expect(buffer?.frameLength == AVAudioFrameCount(samples.count))
        #expect(buffer?.format.sampleRate == 24_000)
        #expect(buffer?.format.channelCount == 1)
        let channel = buffer?.floatChannelData?[0]
        #expect(channel != nil)
        for (index, expected) in samples.enumerated() {
            #expect(channel?[index] == expected)
        }
    }

    @Test("makeBuffer returns nil for empty input")
    func makeBufferRejectsEmpty() {
        #expect(NeuralAudioPlayer.makeBuffer(samples: [], sampleRate: 24_000) == nil)
    }
}
