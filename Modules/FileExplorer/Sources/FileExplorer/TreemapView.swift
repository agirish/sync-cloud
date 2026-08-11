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

    /// Per-tile label colors, chosen by each palette entry's luminance: hardcoded white was
    /// ~2.1–2.7:1 on the light hues (amber, cyan, …), so those tiles get near-black text while
    /// the dark hues keep white. The palette is fixed sRGB values, so this is computed once.
    /// See `Color.onFillLabel(_:)` in Design for the rule.
    private static let labelPalette: [Color] = palette.map { Color.onFillLabel($0) }

    private func color(for index: Int, node: TreemapNode) -> Color {
        node.name == "Other" ? Color.secondary : Self.palette[index % Self.palette.count]
    }

    /// "Other" fills with `Color.secondary`, which tracks the appearance — `.primary` tracks it
    /// the same way (dark text on the light-mode gray, light text on the dark-mode gray), where a
    /// fixed choice would be wrong in one appearance.
    private func labelColor(for index: Int, node: TreemapNode) -> Color {
        node.name == "Other" ? .primary : Self.labelPalette[index % Self.labelPalette.count]
    }

    /// The width below which a tile draws no name — and, since the fold landed, the width below
    /// which it stops being its own tile at all.
    static let labelMinWidth: CGFloat = 46

    /// What the fold decided: the tiles that keep their identity, and the ones the tail absorbs.
    struct Fold: Equatable {
        var visible: [TreemapNode]
        var folded: [TreemapNode]
        var tailBytes: Int { folded.reduce(0) { $0 + $1.bytes } }
    }

    /// Folds the sub-label-width suffix into one tail (v4.0 polish P9). A part-of-whole picture
    /// that ends in anonymous slivers silently drops its smallest parts; the tail accounts for
    /// them in words — "+3 more · 6.2 MB" — and every byte stays on screen: visible + folded
    /// always sum to the input, which is what `TreemapFoldTests` pins.
    ///
    /// Two deliberate edges: a fold of ONE would relabel a tile "+1 more" in the same space its
    /// own name could use, so a single sub-threshold node keeps its identity (the view widens it
    /// to the label floor instead); and nodes are assumed largest-first, so the fold is a suffix.
    nonisolated static func fold(nodes: [TreemapNode], availableWidth: CGFloat,
                                 spacing: CGFloat = 3) -> Fold {
        guard nodes.count > 1, availableWidth > 0 else { return Fold(visible: nodes, folded: []) }
        let total = max(1, nodes.reduce(0) { $0 + $1.bytes })
        let available = max(0, availableWidth - spacing * CGFloat(nodes.count - 1))
        let firstFolded = nodes.firstIndex {
            available * CGFloat($0.bytes) / CGFloat(total) < labelMinWidth
        }
        guard let firstFolded, nodes.count - firstFolded >= 2 else {
            return Fold(visible: nodes, folded: [])
        }
        return Fold(visible: Array(nodes[..<firstFolded]), folded: Array(nodes[firstFolded...]))
    }

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 3
            let fold = Self.fold(nodes: nodes, availableWidth: geo.size.width, spacing: spacing)
            let total = max(1, nodes.reduce(0) { $0 + $1.bytes })
            let tileCount = fold.visible.count + (fold.folded.isEmpty ? 0 : 1)
            let available = max(0, geo.size.width - spacing * CGFloat(max(0, tileCount - 1)))
            // The tail never falls below the label floor — its whole job is to be readable —
            // and the visible tiles share what remains in their own proportions.
            let tailWidth = fold.folded.isEmpty ? 0
                : max(Self.labelMinWidth, available * CGFloat(fold.tailBytes) / CGFloat(total))
            let visibleBytes = max(1, total - fold.tailBytes)
            let visibleAvailable = max(0, available - tailWidth)
            HStack(spacing: spacing) {
                ForEach(Array(fold.visible.enumerated()), id: \.offset) { idx, node in
                    // A single sub-threshold straggler was left visible by the fold (a "+1 more"
                    // would use the space its own name could): hold it at the label floor too.
                    let proportional = visibleAvailable * CGFloat(node.bytes) / CGFloat(visibleBytes)
                    let width = idx == fold.visible.count - 1 && fold.folded.isEmpty
                        ? max(proportional, min(Self.labelMinWidth, visibleAvailable))
                        : proportional
                    tile(node, color: color(for: idx, node: node),
                         label: labelColor(for: idx, node: node), width: width)
                }
                if !fold.folded.isEmpty {
                    tailTile(fold, width: tailWidth)
                }
            }
        }
        .frame(height: 88)
    }

    /// The tail: neutral like "Other", labeled with what it absorbed, enumerating on hover.
    private func tailTile(_ fold: Fold, width: CGFloat) -> some View {
        let names = fold.folded.map(\.name).joined(separator: ", ")
        let bytes = FileSyncManager.formatBytes(fold.tailBytes)
        return RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.secondary.opacity(0.35))
            .frame(width: width)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("+\(fold.folded.count) more")
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(bytes)
                        .scaledFont(.system(size: 10, weight: .medium))
                        .opacity(0.92)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
            }
            .help("\(fold.folded.count) more area\(fold.folded.count == 1 ? "" : "s") — \(bytes): \(names)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(fold.folded.count) more areas, \(bytes): \(names)")
    }

    @ViewBuilder
    private func tile(_ node: TreemapNode, color: Color, label: Color, width: CGFloat) -> some View {
        // Never let a real (nonzero) area collapse to nothing — a hairline still shows it exists.
        let clamped = max(width, 3)
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(color.gradient)
            .frame(width: clamped)
            .overlay(alignment: .topLeading) {
                if clamped >= 46 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.name)
                            .scaledFont(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if clamped >= 68 {
                            Text(FileSyncManager.formatBytes(node.bytes))
                                .scaledFont(.system(size: 10, weight: .medium))
                                .opacity(0.92)
                        }
                    }
                    .foregroundStyle(label)
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
