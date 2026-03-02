import SwiftUI

struct DashboardHeader: View {
    let sourceCount: Int
    let destinationCount: Int
    let differences: [FileDifference]
    
    var body: some View {
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

struct PaneHeader: View {
    let title: String
    let provider: CloudProvider?
    let path: String
    
    var body: some View {
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
