import Settings
import FileExplorer
import Events
import SwiftUI
import Sync

private struct AdaptiveGlass: ViewModifier {
    let cornerRadius: CGFloat
    let intensity: Double
    let baseMaterial: Material
    
    func body(content: Content) -> some View {
        let t = max(0.0, min(1.0, intensity))
        if #available(macOS 26.0, *) {
            content
                .glassEffect(t > 0.33 ? .regular : .clear, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(baseMaterial.opacity(0.55 + 0.35 * t))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

/// Status bar showing item counts for the left and right panes and the number of differences.
public struct DashboardHeader: View {
    public let leftCount: Int
    public let rightCount: Int
    public let differences: [FileDifference]
    @AppStorage("liquidGlassIntensity") private var glassIntensity: Double = 0.65
    
    public init(leftCount: Int, rightCount: Int, differences: [FileDifference]) {
        self.leftCount = leftCount
        self.rightCount = rightCount
        self.differences = differences
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            DashboardMetric(title: "Left", value: "\(leftCount)", icon: "doc.on.doc", color: .blue)
            Rectangle()
                .fill(.quaternary)
                .frame(width: 1, height: 28)
                .padding(.vertical, 8)
            DashboardMetric(title: "Differences", value: "\(differences.count)", icon: "exclamationmark.triangle", color: differences.isEmpty ? .green : .orange)
            Rectangle()
                .fill(.quaternary)
                .frame(width: 1, height: 28)
                .padding(.vertical, 8)
            DashboardMetric(title: "Right", value: "\(rightCount)", icon: "arrow.down.doc", color: .purple)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .modifier(AdaptiveGlass(cornerRadius: 12, intensity: glassIntensity, baseMaterial: .regularMaterial))
    }
}

/// One metric block in the dashboard header (e.g. "Left" count, "Differences" count).
struct DashboardMetric: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(color)
                .symbolRenderingMode(.hierarchical)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title2.weight(.semibold))
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Header above each file tree pane: provider logo and name on the left, current path below.
public struct PaneHeader: View {
    public let title: String
    public let provider: CloudProvider?
    public let path: String
    @AppStorage("liquidGlassIntensity") private var glassIntensity: Double = 0.65

    public init(title: String, provider: CloudProvider?, path: String) {
        self.title = title
        self.provider = provider
        self.path = path
    }

    public var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                if let provider = provider {
                    Image(provider.imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                    Text(provider.displayName)
                        .font(.headline.weight(.semibold))
                } else {
                    Image(systemName: "folder")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .modifier(AdaptiveGlass(cornerRadius: 12, intensity: glassIntensity, baseMaterial: .ultraThinMaterial))
    }
}
