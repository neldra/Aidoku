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
    /// Time-pitch unit between player and mixer. Lets us change the playback
    /// rate mid-stream without re-synthesizing, and keeps pitch stable so
    /// 1.5x doesn't sound like a chipmunk. Rate range is 1/32...32 (Apple);
    /// we clamp to the same 0.5...2.0 window the settings slider exposes.
    private let pitchUnit = AVAudioUnitTimePitch()

    /// Buffers handed to `schedule`, and buffers whose playback has completed.
    /// `onStreamEnd` fires once `endOfStream` is set and these are equal.
    private var scheduledCount = 0
    private var playedCount = 0
    private var endOfStream = false
    private var onStreamEnd: (() -> Void)?
    /// Bumped on every `stop()`. Each scheduled buffer's completion callback
    /// captures the epoch at schedule time; `bufferDidFinish` drops the count
    /// when the captured epoch no longer matches. Apple may fire
    /// `.dataPlayedBack` for a partially-rendered buffer when `playerNode.stop()`
    /// clears it (e.g. on the resume path after a Siri interruption), which
    /// would otherwise leave `playedCount` one ahead of the next utterance's
    /// `scheduledCount` and trip `fireEndIfDrained` before the new audio plays.
    private var epoch: Int = 0

    /// Playback rate. Applied live — changes take effect immediately on the
    /// currently-playing buffer with no re-synthesis. Defaults to 1.0.
    var rate: Float = 1.0 {
        didSet { pitchUnit.rate = max(0.5, min(2.0, rate)) }
    }

    init() {
        engine.attach(playerNode)
        engine.attach(pitchUnit)
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
            // Chain: player → pitch → mixer. The pitch unit time-stretches at
            // the player's input format and emits at the same rate; the mixer
            // resamples to the hardware rate.
            engine.connect(playerNode, to: pitchUnit, format: buffer.format)
            engine.connect(pitchUnit, to: engine.mainMixerNode, format: buffer.format)
            pitchUnit.rate = max(0.5, min(2.0, rate))
            try? engine.start()
        }
        scheduledCount += 1
        let bufferEpoch = epoch
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.bufferDidFinish(epoch: bufferEpoch) }
        }
    }

    func play() {
        if !playerNode.isPlaying { playerNode.play() }
    }

    func pause() {
        playerNode.pause()
    }

    /// Stop playback, discard scheduled buffers, reset all counters. Safe to
    /// call when nothing is playing. Deliberately does NOT call `engine.stop()`
    /// because the iOS `audio` background mode requires the engine to be
    /// continuously running to keep the app alive on a locked device — even a
    /// brief engine.stop() → start() cycle between paragraphs lets iOS suspend
    /// the app, which freezes pending CoreML synthesis on the next paragraph.
    /// The engine keeps running (outputting silence) for the player's
    /// lifetime; it's released when the backend deallocates.
    func stop() {
        epoch &+= 1
        playerNode.stop()
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

    private func bufferDidFinish(epoch bufferEpoch: Int) {
        guard bufferEpoch == epoch else { return }
        playedCount += 1
        fireEndIfDrained()
    }

    private func fireEndIfDrained() {
        guard endOfStream, playedCount >= scheduledCount, let completion = onStreamEnd else { return }
        onStreamEnd = nil
        completion()
    }
}
