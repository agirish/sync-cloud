import SwiftUI
import Sync
import Design

/// A single-row proportional treemap of `[TreemapNode]`: rounded tiles whose widths track each
/// area's rolled-up bytes, largest first. A purely visual summary of where space concentrates —
/// it triggers no action and mutates nothing.
struct TreemapView: View {
    let nodes: [TreemapNode]

    /// A rotating palette drawn from the Design module's hues so the tiles feel of a piece with the
    /// rest of the app. "Other" always reads as neutral gray.
    private static let palette: [Color] = [
        LiquidGlassHue.blue, .teal, .purple, .amber, .coral, .green, .indigo, .rose, .cyan, .slate
    ].map { $0.accentColor }

    private func color(for index: Int, node: TreemapNode) -> Color {
        node.name == "Other" ? Color.secondary : Self.palette[index % Self.palette.count]
    }

    var body: some View {
        let total = max(1, nodes.reduce(0) { $0 + $1.bytes })
        GeometryReader { geo in
            let spacing: CGFloat = 3
            let available = max(0, geo.size.width - spacing * CGFloat(max(0, nodes.count - 1)))
            HStack(spacing: spacing) {
                ForEach(Array(nodes.enumerated()), id: \.offset) { idx, node in
                    let width = available * CGFloat(node.bytes) / CGFloat(total)
                    tile(node, color: color(for: idx, node: node), width: width)
                }
            }
        }
        .frame(height: 88)
    }

    @ViewBuilder
    private func tile(_ node: TreemapNode, color: Color, width: CGFloat) -> some View {
        // Never let a real (nonzero) area collapse to nothing — a hairline still shows it exists.
        let clamped = max(width, 3)
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(color.gradient)
            .frame(width: clamped)
            .overlay(alignment: .topLeading) {
                if clamped >= 46 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.name)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if clamped >= 68 {
                            Text(FileSyncManager.formatBytes(node.bytes))
                                .font(.system(size: 10, weight: .medium))
                                .opacity(0.92)
                        }
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
                }
            }
            .help("\(node.name) — \(FileSyncManager.formatBytes(node.bytes))")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(node.name), \(FileSyncManager.formatBytes(node.bytes))")
    }
}
