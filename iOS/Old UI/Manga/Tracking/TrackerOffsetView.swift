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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(NSLocalizedString("CHAPTER_OFFSET", comment: ""))
                    .font(.title2.bold())
                Spacer()
                Button(NSLocalizedString("DONE", comment: "")) {
                    dismiss()
                }
            }
            Text(NSLocalizedString("CHAPTER_OFFSET_INFO", comment: ""))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(NSLocalizedString("OFFSET", comment: ""))
                Spacer()
                Text(offset > 0 ? "+\(offset)" : "\(offset)")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                Stepper("", value: $offset, in: -999...999)
                    .labelsHidden()
            }
            .padding(14)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            Spacer()
        }
        .padding()
        .onDisappear {
            onCommit(offset)
        }
    }
}
