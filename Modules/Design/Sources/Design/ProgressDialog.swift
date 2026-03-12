import SwiftUI

/// A native-looking progress dialog for file operations.
/// Observes an `NSProgress` object to display a progress bar, title, and current item name.
public struct ProgressDialog: View {
    public var progress: Progress
    
    public init(progress: Progress) {
        self.progress = progress
    }
    
    public var body: some View {
        // We use a local state to trigger refreshes since Progress isn't an ObservableObject
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(progress.localizedDescription ?? "Processing...")
                        .font(.headline)
                    Spacer()
                    Button(action: {
                        progress.cancel()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                
                ProgressView(progress)
                    .progressViewStyle(.linear)
                
                if let additional = progress.localizedAdditionalDescription, !additional.isEmpty {
                    Text(additional)
                        .font(.caption)
                        .foregroundColor(.secondary)
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
}
