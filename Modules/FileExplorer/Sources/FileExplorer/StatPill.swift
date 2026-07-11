import SwiftUI

/// A compact count chip for the differences header: a colored dot (or SF Symbol), the count,
/// and a short label. `emphasized` tints the whole capsule and colors the text — used for the
/// differences count so the actionable number stands out from the Left/Right reference counts.
struct StatPill: View {
    let count: Int
    let label: String
    let color: Color
    var systemImage: String? = nil
    var emphasized: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .bold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(color)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
            Text(count.formatted())
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(emphasized ? color : Color.primary)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(emphasized ? color : Color.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(emphasized ? color.opacity(0.14) : Color.secondary.opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(emphasized ? color.opacity(0.45) : Color.secondary.opacity(0.22), lineWidth: 0.5)
        )
        .fixedSize()
        // One element, not dot + two texts: VoiceOver reads "7 Differences".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count.formatted()) \(label)")
    }
}
