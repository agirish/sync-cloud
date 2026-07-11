import SwiftUI

/// A compact count chip for the differences header: an SF Symbol, the count, and a short
/// label, with the whole capsule tinted so the actionable number stands out.
struct StatPill: View {
    let count: Int
    let label: String
    let color: Color
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
            Text(count.formatted())
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(color.opacity(0.14))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(color.opacity(0.45), lineWidth: 0.5)
        )
        .fixedSize()
        // One element, not icon + two texts: VoiceOver reads "7 Differences".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count.formatted()) \(label)")
    }
}
