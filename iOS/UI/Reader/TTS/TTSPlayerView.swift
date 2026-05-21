//
//  TTSPlayerView.swift
//  Aidoku
//

import AVFoundation
import SwiftUI

struct TTSPlayerView: View {
    @ObservedObject var tts = TTSManager.shared
    @Environment(\.dismiss) private var dismiss

    @AppStorage(TTSManager.highlightKey) private var highlightEnabled = true
    @State private var draftRate: Float?

    private var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    coverArt
                    VStack(spacing: 4) {
                        Text(tts.novelTitle).font(.title3.bold())
                        Text(tts.currentChapterTitle).font(.subheadline).foregroundColor(.secondary)
                    }

                    HStack(spacing: 36) {
                        controlButton("backward.fill", action: tts.skipBackward)
                        Button(action: tts.togglePlayPause) {
                            Image(systemName: tts.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 64, height: 64)
                                .background(Circle().fill(Color.accentColor))
                        }
                        .buttonStyle(.plain)
                        controlButton("forward.fill", action: tts.skipForward)
                    }

                    ProgressView(value: tts.progress)
                        .tint(.accentColor)
                        .padding(.horizontal)

                    Button {
                        tts.resetChapter()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)

                    settingsCard
                }
                .padding()
            }
            .navigationTitle("Text-to-Speech")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var coverArt: some View {
        Group {
            if let coverImage = tts.artwork {
                Image(uiImage: coverImage).resizable().scaledToFill()
            } else {
                Color(uiColor: .secondarySystemBackground)
            }
        }
        .frame(width: 150, height: 214)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func controlButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 20)).foregroundColor(.primary)
        }
        .buttonStyle(.plain)
    }

    private var settingsCard: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Voice")
                Spacer()
                Picker("Voice", selection: $tts.voiceIdentifier) {
                    ForEach(voices, id: \.identifier) { v in
                        Text("\(v.name) (\(v.language))").tag(v.identifier)
                    }
                }
                .labelsHidden()
            }
            VStack(alignment: .leading) {
                HStack {
                    Text("Speed")
                    Spacer()
                    Text(String(format: "%.1fx",
                                (draftRate ?? tts.rate) / AVSpeechUtteranceDefaultSpeechRate))
                        .foregroundColor(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { draftRate ?? tts.rate },
                        set: { draftRate = $0 }
                    ),
                    in: (AVSpeechUtteranceDefaultSpeechRate * 0.5)...(AVSpeechUtteranceDefaultSpeechRate * 2.0),
                    onEditingChanged: { editing in
                        if !editing {
                            if let rate = draftRate {
                                tts.rate = rate
                            }
                            draftRate = nil
                        }
                    }
                )
                .tint(.accentColor)
            }
            Toggle("Highlight & auto-scroll", isOn: $highlightEnabled)
                .tint(.accentColor)
            Toggle("Announce chapter titles", isOn: $tts.announceChapterTitles)
                .tint(.accentColor)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }
}
