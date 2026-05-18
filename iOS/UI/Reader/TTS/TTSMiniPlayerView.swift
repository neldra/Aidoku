//
//  TTSMiniPlayerView.swift
//  Aidoku
//

import SwiftUI

struct TTSMiniPlayerView: View {
    @ObservedObject var tts = TTSManager.shared
    let title: String
    let subtitle: String
    let onTapExpand: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: tts.togglePlayPause) {
                Image(systemName: tts.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.accentColor))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)

            Button(action: tts.skipForward) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(alignment: .bottom) {
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * tts.progress, height: 2)
            }
            .frame(height: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTapExpand)
        .padding(.horizontal, 12)
    }
}
