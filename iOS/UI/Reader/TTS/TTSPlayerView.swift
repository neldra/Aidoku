//
//  TTSPlayerView.swift
//  Aidoku
//

import AVFoundation
import SwiftUI

struct TTSPlayerView: View {
    @ObservedObject var tts = TTSManager.shared
    @Environment(\.dismiss) private var dismiss

    let novelTitle: String
    let chapterTitle: String
    let coverImage: UIImage?

    @AppStorage(TTSManager.highlightKey) private var highlightEnabled = true

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
                        Text(novelTitle).font(.title3.bold())
                        Text(chapterTitle).font(.subheadline).foregroundColor(.secondary)
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
            if let coverImage {
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
                    Text(String(format: "%.1fx", tts.rate / AVSpeechUtteranceDefaultSpeechRate))
                        .foregroundColor(.secondary)
                }
                Slider(
                    value: $tts.rate,
                    in: (AVSpeechUtteranceDefaultSpeechRate * 0.5)...(AVSpeechUtteranceDefaultSpeechRate * 2.0)
                )
                .tint(.accentColor)
            }
            Toggle("Highlight & auto-scroll", isOn: $highlightEnabled)
                .tint(.accentColor)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }
}
