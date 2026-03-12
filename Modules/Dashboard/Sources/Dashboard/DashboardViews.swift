import Settings
import FileExplorer
import Events
import SwiftUI
import Sync

/// Status bar showing item counts for the left and right panes and the number of differences.
public struct DashboardHeader: View {
    public let leftCount: Int
    public let rightCount: Int
    public let differences: [FileDifference]
    
    public init(leftCount: Int, rightCount: Int, differences: [FileDifference]) {
        self.leftCount = leftCount
        self.rightCount = rightCount
        self.differences = differences
    }
    
    public var body: some View {
        HStack {
            DashboardMetric(title: "Left", value: "\(leftCount)", icon: "doc.on.doc", color: .blue)
            Divider().frame(height: 30)
            DashboardMetric(title: "Differences", value: "\(differences.count)", icon: "exclamationmark.triangle", color: differences.isEmpty ? .green : .orange)
            Divider().frame(height: 30)
            DashboardMetric(title: "Right", value: "\(rightCount)", icon: "arrow.down.doc", color: .purple)
        }
        .padding()
        .background(.ultraThinMaterial)
    }
}

/// One metric block in the dashboard header (e.g. "Left" count, "Differences" count).
struct DashboardMetric: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(color)
            
            VStack(alignment: .leading) {
                Text(value)
                    .font(.title2)
                    .fontWeight(.bold)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
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

    public init(title: String, provider: CloudProvider?, path: String) {
        self.title = title
        self.provider = provider
        self.path = path
    }

    public var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                if let provider = provider {
                    Image(provider.imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                    Text(provider.displayName)
                        .font(.headline)
                } else {
                    Image(systemName: "folder")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Text(path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
    }
}
