import Settings
import FileExplorer
import Events
import SwiftUI
import Sync

/// A top-level status bar displaying aggregated metrics across both source and destination trees.
public struct DashboardHeader: View {
    public let sourceCount: Int
    public let destinationCount: Int
    public let differences: [FileDifference]
    
    public init(sourceCount: Int, destinationCount: Int, differences: [FileDifference]) {
        self.sourceCount = sourceCount
        self.destinationCount = destinationCount
        self.differences = differences
    }
    
    public var body: some View {
        HStack {
            DashboardMetric(title: "Source Items", value: "\(sourceCount)", icon: "doc.on.doc", color: .blue)
            Divider().frame(height: 30)
            DashboardMetric(title: "Destination Items", value: "\(destinationCount)", icon: "arrow.down.doc", color: .purple)
            Divider().frame(height: 30)
            DashboardMetric(title: "Differences", value: "\(differences.count)", icon: "exclamationmark.triangle", color: differences.isEmpty ? .green : .orange)
        }
        .padding()
        .background(.ultraThinMaterial)
    }
}

/// A reusable atomic UI component that displays a single numerical metric with an icon and title.
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

/// A visual header sitting atop a file pane, indicating the targeted provider and the current absolute path on disk.
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
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if let provider = provider {
                    HStack {
                        Image(provider.imageName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                        Text(provider.displayName)
                    }
                    .font(.subheadline)
                }
            }
            HStack {
                Text(path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
    }
}
