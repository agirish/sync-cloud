import SwiftUI

/// A native-looking progress dialog for file operations.
/// Shows a single title, progress bar, count (e.g. "3,336 of 7,363"), optional current item, and Cancel.
public struct ProgressDialog: View {
    public var progress: Progress

    public init(progress: Progress) {
        self.progress = progress
    }

    public var body: some View {
        // Refresh periodically since Progress isn't ObservableObject
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let completed = progress.completedUnitCount
            let total = progress.totalUnitCount
            let totalDouble = total > 0 ? Double(total) : 1.0

            VStack(alignment: .leading, spacing: 14) {
                // Single title row: description + close
                HStack {
                    Text(progress.localizedDescription ?? "Processing…")
                        .font(.headline)
                    Spacer()
                    Button(action: { progress.cancel() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                // Progress bar (value-based to avoid duplicate labels). Clamped to 0...1:
                // completed can drift past total during cancel, and out-of-range values make
                // ProgressView log runtime warnings and pin oddly.
                ProgressView(value: total > 0 ? min(1.0, max(0.0, Double(completed) / totalDouble)) : nil, total: 1.0)
                    .progressViewStyle(.linear)

                // Single count line, e.g. "3,336 of 7,363"
                Text(formattedCount(completed: completed, total: total))
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                // Optional: current file name when set
                if let additional = progress.localizedAdditionalDescription, !additional.isEmpty {
                    Text(additional)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack {
                    Spacer()
                    Button("Cancel") {
                        progress.cancel()
                    }
                    .controlSize(.small)
                }
            }
            .padding(20)
            .frame(width: 360)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous))
            .shadow(
                color: LiquidGlass.cardShadow.color,
                radius: LiquidGlass.cardShadow.radius,
                x: LiquidGlass.cardShadow.x,
                y: LiquidGlass.cardShadow.y
            )
        }
    }

    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private func formattedCount(completed: Int64, total: Int64) -> String {
        let c = Self.countFormatter.string(from: NSNumber(value: completed)) ?? "\(completed)"
        let t = Self.countFormatter.string(from: NSNumber(value: total)) ?? "\(total)"
        return "\(c) of \(t)"
    }
}
