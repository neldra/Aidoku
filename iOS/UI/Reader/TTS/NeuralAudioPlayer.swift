//
//  NeuralAudioPlayer.swift
//  Aidoku
//

import AVFoundation

/// Reusable PCM playback helper for neural TTS backends. Owns an
/// `AVAudioEngine` + `AVAudioPlayerNode`; buffers are scheduled as they are
/// synthesized and played back in order. Does NOT own the `AVAudioSession` —
/// that stays with `TTSManager`, which keeps one session for whichever backend
/// is active (only one backend plays at a time, so there is no contention).
@MainActor
final class NeuralAudioPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    /// Buffers handed to `schedule`, and buffers whose playback has completed.
    /// `onStreamEnd` fires once `endOfStream` is set and these are equal.
    private var scheduledCount = 0
    private var playedCount = 0
    private var endOfStream = false
    private var onStreamEnd: (() -> Void)?

    init() {
        engine.attach(playerNode)
    }

    /// Convert raw fp32 PCM into an `AVAudioPCMBuffer`. `samples` is mono,
    /// non-interleaved. Returns nil only if the format/buffer cannot be
    /// allocated, or `samples` is empty.
    static func makeBuffer(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(samples.count)
              )
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }

    /// Schedule a buffer for playback. The engine is started lazily and the
    /// player node connected at the first buffer's format (the mixer resamples
    /// to the hardware rate).
    func schedule(_ buffer: AVAudioPCMBuffer) {
        if !engine.isRunning {
            engine.connect(playerNode, to: engine.mainMixerNode, format: buffer.format)
            try? engine.start()
        }
        scheduledCount += 1
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.bufferDidFinish() }
        }
    }

    func play() {
        if !playerNode.isPlaying { playerNode.play() }
    }

    func pause() {
        playerNode.pause()
    }

    /// Stop playback, discard scheduled buffers, reset all counters. Safe to
    /// call when nothing is playing.
    func stop() {
        playerNode.stop()
        engine.stop()
        scheduledCount = 0
        playedCount = 0
        endOfStream = false
        onStreamEnd = nil
    }

    /// Signal that no further buffers will be scheduled for the current
    /// utterance. `completion` fires once every scheduled buffer has drained
    /// (immediately, if they already have).
    func markEndOfStream(completion: @escaping () -> Void) {
        onStreamEnd = completion
        endOfStream = true
        fireEndIfDrained()
    }

    private func bufferDidFinish() {
        playedCount += 1
        fireEndIfDrained()
    }

    private func fireEndIfDrained() {
        guard endOfStream, playedCount >= scheduledCount, let completion = onStreamEnd else { return }
        onStreamEnd = nil
        completion()
    }
}
