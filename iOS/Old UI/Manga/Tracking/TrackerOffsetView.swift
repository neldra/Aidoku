//
//  TrackerOffsetView.swift
//  Aidoku (iOS)
//
//  Created by neldra on 5/15/26.
//

import SwiftUI

struct TrackerOffsetView: View {
    @Binding var offset: Int
    let onCommit: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(NSLocalizedString("CHAPTER_OFFSET", comment: ""))
                    .font(.headline)
                Spacer()
                Button(NSLocalizedString("DONE", comment: "")) {
                    dismiss()
                }
                .font(.body.weight(.semibold))
            }
            Text(NSLocalizedString("CHAPTER_OFFSET_INFO", comment: ""))
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Text(NSLocalizedString("OFFSET", comment: ""))
                Spacer()
                Text(offset > 0 ? "+\(offset)" : "\(offset)")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                Stepper("", value: $offset, in: -999...999)
                    .labelsHidden()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(20)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { contentHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { newHeight in
                        contentHeight = newHeight
                    }
            }
        )
        .modifier(FittedSheetDetent(height: contentHeight))
        .onDisappear {
            onCommit(offset)
        }
    }
}

/// Sizes the sheet to its content (iOS 16+). On iOS 15 the sheet keeps the
/// system default — matching how the rest of the app degrades detents.
private struct FittedSheetDetent: ViewModifier {
    let height: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 16.0, *), height > 0 {
            content
                .presentationDetents([.height(height)])
                .presentationDragIndicator(.visible)
        } else {
            content
        }
    }
}
