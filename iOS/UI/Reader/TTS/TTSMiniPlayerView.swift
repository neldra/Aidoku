//
//  TTSMiniPlayerView.swift
//  Aidoku
//

import SwiftUI

/// Floating in-reader transport capsule for TTS (spec: 2026-07-07 mini-player).
/// Deliberately logic-free: every control calls a TTSManager method and every
/// rendered value is @Published on the manager — the unit-test boundary stays
/// on the manager side. Hosted by ReaderViewController as a sibling of the
/// auto-hiding reader chrome; visibility (isActive) is controlled by the host.
struct TTSMiniPlayerView: View {
    @ObservedObject private var tts = TTSManager.shared
    @State private var isExpanded = false
    /// Local echo of the scrub position while the finger is down, so the bar
    /// tracks the drag instead of the (paragraph-granular) published value.
    @State private var scrubFraction: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let rateCycle: [Float] = [0.8, 1.0, 1.2, 1.5, 2.0]

    var body: some View {
        Group {
            if isExpanded { expanded } else { collapsed }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        // Collapse whenever the reader chrome toggles (page tap) — the same
        // touch that shows/hides bars shouldn't leave the capsule expanded.
        .onReceive(NotificationCenter.default.publisher(for: .readerShowingBars)) { _ in collapse() }
        .onReceive(NotificationCenter.default.publisher(for: .readerHidingBars)) { _ in collapse() }
        .onChange(of: isExpanded) { expanded in
            if expanded { tts.beginFineProgressUpdates() } else { tts.endFineProgressUpdates() }
        }
        // Collapse when the session ends: the host hides (not unmounts) this
        // view on isActive = false, so onDisappear won't fire — without this,
        // an expanded capsule would keep its fine-progress task alive and
        // reappear expanded with stale state next session. No animation: the
        // view is already hidden at this point.
        .onChange(of: tts.isActive) { active in
            if !active { isExpanded = false }
        }
        .onDisappear {
            if isExpanded {
                tts.endFineProgressUpdates()
                isExpanded = false
            }
        }
    }

    private func collapse() {
        guard isExpanded else { return }
        if reduceMotion {
            isExpanded = false
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { isExpanded = false }
        }
    }

    private func expand() {
        if reduceMotion {
            isExpanded = true
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { isExpanded = true }
        }
    }

    // MARK: - Collapsed

    private var collapsed: some View {
        HStack(spacing: 11) {
            Button { tts.togglePlayPause() } label: {
                Image(systemName: tts.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 34, height: 34)
                    // Ink stays 34pt; inset extends the hit target to 44pt.
                    .contentShape(Rectangle().inset(by: -5))
            }
            .accessibilityLabel(tts.isPlaying ? NSLocalizedString("PAUSE") : NSLocalizedString("PLAY"))

            VStack(alignment: .leading, spacing: 1) {
                Text(tts.currentChapterTitle)
                    // Intentionally sub-scale (12/10.5pt vs the expanded 13/11.5/10pt
                    // scale) to keep the collapsed pill compact, per the rev-2 mockup.
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(timeLeftLabel)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundColor(Color.primary.opacity(0.65))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { expand() }

            Button { tts.stop() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.primary.opacity(0.45))
                    .frame(width: 34, height: 34)
                    // Ink stays 34pt; inset extends the hit target to 44pt.
                    .contentShape(Rectangle().inset(by: -5))
            }
            .accessibilityLabel(NSLocalizedString("TTS_STOP_LISTENING"))
        }
        .padding(EdgeInsets(top: 6, leading: 14, bottom: 8, trailing: 14))
        .overlay(alignment: .bottom) {
            GeometryReader { geo in
                Capsule().fill(Color.primary.opacity(0.10))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.accentColor)
                            .frame(width: max(0, geo.size.width * tts.chapterProgress))
                    }
            }
            .frame(height: 2)
            .padding(.horizontal, 16)
            .padding(.bottom, 5)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Expanded

    private var expanded: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(tts.currentChapterTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { collapse() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.primary.opacity(0.45))
                        .frame(width: 34, height: 34)
                        // Ink stays 34pt; inset extends the hit target to 44pt.
                        .contentShape(Rectangle().inset(by: -5))
                }
                .accessibilityLabel(NSLocalizedString("CLOSE"))
            }

            scrubBar

            HStack {
                transportButton("backward.end.fill", size: 15, opacity: 0.8,
                                label: "TTS_PREVIOUS_CHAPTER") { tts.skipToPreviousChapter() }
                Spacer()
                transportButton("gobackward.15", size: 20, opacity: 0.8,
                                label: "TTS_SKIP_BACK_15") { tts.skipBackward15() }
                Spacer()
                transportButton(tts.isPlaying ? "pause.fill" : "play.fill", size: 26, opacity: 1.0,
                                label: tts.isPlaying ? "PAUSE" : "PLAY") { tts.togglePlayPause() }
                Spacer()
                transportButton("goforward.15", size: 20, opacity: 0.8,
                                label: "TTS_SKIP_FORWARD_15") { tts.skipForward15() }
                Spacer()
                transportButton("forward.end.fill", size: 15, opacity: 0.8,
                                label: "TTS_NEXT_CHAPTER") { tts.skipToNextChapter() }
            }
            .padding(.horizontal, 10)

            HStack {
                Button { cycleRate() } label: {
                    Text(String(format: "%.1f×", tts.rate))
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundColor(Color.primary.opacity(0.65))
                        .frame(minWidth: 44, minHeight: 32)
                        // Ink stays 32pt tall; inset extends the hit target to 44pt.
                        .contentShape(Rectangle().inset(by: -6))
                }
                .accessibilityLabel(NSLocalizedString("TTS_SPEECH_RATE"))
                .accessibilityValue(Text(String(format: "%.1f×", tts.rate)))
                Spacer()
                HStack(spacing: 12) {
                    sleepMenu
                    Button { tts.syncReaderToCursor() } label: {
                        Image(systemName: "scope")
                            .font(.system(size: 13))
                            .foregroundColor(Color.primary.opacity(0.45))
                            .frame(width: 34, height: 34)
                            // Ink stays 34pt; inset extends the hit target to 44pt.
                            .contentShape(Rectangle().inset(by: -5))
                    }
                    .accessibilityLabel(NSLocalizedString("TTS_JUMP_TO_CURRENT"))
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(EdgeInsets(top: 15, leading: 18, bottom: 13, trailing: 18))
        .gesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.height > 30 { collapse() }
            }
        )
    }

    private var scrubBar: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let fraction = scrubFraction ?? tts.chapterProgress
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(0, geo.size.width * fraction))
                }
                .contentShape(Rectangle().inset(by: -12))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            scrubFraction = min(1, max(0, value.location.x / geo.size.width))
                        }
                        .onEnded { value in
                            let fraction = min(1, max(0, value.location.x / geo.size.width))
                            tts.seek(toProgress: fraction)
                            scrubFraction = nil
                        }
                )
            }
            .frame(height: 4)
            .accessibilityElement()
            .accessibilityLabel(Text(tts.currentChapterTitle))
            .accessibilityValue(Text(timeLeftLabel))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: tts.skipForward15()
                case .decrement: tts.skipBackward15()
                @unknown default: break
                }
            }

            HStack {
                Text(tts.timeRemaining == nil ? "—:—" : Self.timeString(elapsedSeconds))
                Spacer()
                Text(tts.timeRemaining.map { "−" + Self.timeString($0) } ?? "—:—")
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundColor(Color.primary.opacity(0.45))
        }
    }

    private var sleepMenu: some View {
        Menu {
            // Picker-in-Menu renders native checkmarks on the armed option.
            Picker(
                NSLocalizedString("TTS_SLEEP_TIMER"),
                selection: Binding(
                    get: { tts.sleepTimer },
                    set: { tts.setSleepTimer($0) }
                )
            ) {
                Text(NSLocalizedString("TTS_SLEEP_OFF")).tag(TTSManager.SleepTimer.off)
                Text(NSLocalizedString("TTS_SLEEP_15_MIN")).tag(TTSManager.SleepTimer.minutes(15))
                Text(NSLocalizedString("TTS_SLEEP_30_MIN")).tag(TTSManager.SleepTimer.minutes(30))
                Text(NSLocalizedString("TTS_SLEEP_60_MIN")).tag(TTSManager.SleepTimer.minutes(60))
                Text(NSLocalizedString("TTS_SLEEP_END_OF_CHAPTER")).tag(TTSManager.SleepTimer.endOfChapter)
            }
        } label: {
            Image(systemName: tts.sleepTimer == .off ? "moon.zzz" : "moon.zzz.fill")
                .font(.system(size: 13))
                .foregroundColor(tts.sleepTimer == .off ? Color.primary.opacity(0.45) : Color.primary.opacity(0.8))
                .frame(width: 34, height: 34)
                // Ink stays 34pt; inset extends the hit target to 44pt.
                .contentShape(Rectangle().inset(by: -5))
        }
        .accessibilityLabel(NSLocalizedString("TTS_SLEEP_TIMER"))
        .accessibilityValue(Text(sleepTimerValueLabel))
    }

    /// Localized description of the current sleep-timer setting, for the
    /// sleep menu's accessibility value.
    private var sleepTimerValueLabel: String {
        switch tts.sleepTimer {
        case .off: return NSLocalizedString("TTS_SLEEP_OFF")
        case .minutes(15): return NSLocalizedString("TTS_SLEEP_15_MIN")
        case .minutes(30): return NSLocalizedString("TTS_SLEEP_30_MIN")
        case .minutes(60): return NSLocalizedString("TTS_SLEEP_60_MIN")
        case .minutes(let minutes): return "\(minutes) min"
        case .endOfChapter: return NSLocalizedString("TTS_SLEEP_END_OF_CHAPTER")
        }
    }

    // MARK: - Helpers

    private func transportButton(
        _ symbol: String, size: CGFloat, opacity: Double,
        label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(Color.primary.opacity(opacity))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(NSLocalizedString(label))
    }

    private func cycleRate() {
        let current = tts.rate
        let next = Self.rateCycle.first { $0 > current + 0.05 } ?? Self.rateCycle[0]
        tts.rate = next
    }

    private var elapsedSeconds: TimeInterval {
        guard let remaining = tts.timeRemaining, tts.chapterProgress > 0,
              tts.chapterProgress < 1 else { return 0 }
        let duration = remaining / (1 - tts.chapterProgress)
        return max(0, duration - remaining)
    }

    private var timeLeftLabel: String {
        guard let remaining = tts.timeRemaining else { return "—:—" }
        return String(format: NSLocalizedString("TTS_TIME_LEFT"), Self.timeString(remaining))
    }

    private static func timeString(_ time: TimeInterval) -> String {
        let total = Int(time.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
