import SwiftUI
import AppKit
import Sync
import Design

/// A single-row proportional treemap of `[TreemapNode]`: rounded tiles whose widths track each
/// area's rolled-up bytes, largest first. A purely visual summary of where space concentrates —
/// it triggers no action and mutates nothing.
struct TreemapView: View {
    let nodes: [TreemapNode]

    /// The hue the ramp is built from. Handed in rather than read from `@AppStorage`, so the view
    /// stays a pure function of its inputs.
    var hue: LiquidGlassHue = .blue

    /// One sequential ramp, deep to pale, ordered by size, so colour is the ranking and no legend
    /// is needed.
    ///
    /// Step 0 is the hue's own accent and each later step desaturates toward white, so luminance
    /// is strictly monotonic for every hue; `TreemapRampTests` pins it over all twelve. Why: HSB→RGB
    /// is `b · (1 − s·f)`, so falling `s` and rising `b` both raise every component. `max(0, …)`
    /// keeps `b` from falling for hues already at `b = 1.0`; those ramp on saturation alone.
    ///
    /// Not absolute endpoints: one luminance band for every hue turns amber brown at the deep end.
    nonisolated static func ramp(_ hue: LiquidGlassHue, count: Int) -> [Color] {
        // `.none` is the system accent, a dynamic color: sampling its components would freeze it
        // to the current appearance. Every other hue is static sRGB; blue is the app's default.
        let base = hue == .none ? LiquidGlassHue.blue : hue
        guard count > 0 else { return [] }
        guard let hsb = NSColor(base.accentColor).usingColorSpace(.sRGB) else {
            return Array(repeating: base.accentColor, count: count)
        }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        hsb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (0..<count).map { index in
            let t = count > 1 ? CGFloat(index) / CGFloat(count - 1) : 0
            return Color(nsColor: NSColor(colorSpace: .sRGB,
                                          hue: h,
                                          saturation: s * (1 - 0.62 * t),
                                          brightness: b + max(0, 0.97 - b) * t,
                                          alpha: 1))
        }
    }

    /// The fill for tile `index`, or neutral gray for the "Other" bucket the report itself emits.
    private func color(for index: Int, in ramp: [Color], node: TreemapNode) -> Color {
        guard node.name != "Other", ramp.indices.contains(index) else { return Color.secondary }
        return ramp[index]
    }

    /// The label color for the fill the tile actually took, from `Color.onFillLabel`, the app's
    /// one on-fill pairing rule. Needed even at the pale end: the fold floors the smallest visible
    /// tile at `labelMinWidth`, exactly where a tile starts drawing its name.
    private func labelColor(for index: Int, in ramp: [Color], node: TreemapNode) -> Color {
        node.name == "Other" ? .primary : Color.onFillLabel(color(for: index, in: ramp, node: node))
    }

    /// The width below which a tile draws no name, and below which the fold absorbs it.
    /// `nonisolated` so the pure `fold` and `visibleWidths` can read it without a main-actor hop.
    nonisolated static let labelMinWidth: CGFloat = 46

    /// What the fold decided: the tiles that keep their identity, and the ones the tail absorbs.
    struct Fold: Equatable {
        var visible: [TreemapNode]
        var folded: [TreemapNode]
        var tailBytes: Int { folded.reduce(0) { $0 + $1.bytes } }
    }

    /// Folds the sub-label-width suffix into one tail, "+3 more · 6.2 MB", so the picture doesn't
    /// end in anonymous slivers. Visible plus folded always sum to the input (`TreemapFoldTests`).
    ///
    /// A fold of one is refused: "+1 more" would use the space the tile's own name could, so a
    /// lone straggler keeps its identity and the view widens it to the floor. Nodes are assumed
    /// largest-first, so the fold is a suffix.
    ///
    /// Iterative, because the tail is clamped to the label floor and that width comes out of the
    /// visible tiles, which can push the smallest under the floor. So it re-measures after each
    /// fold until the last visible tile can carry a label.
    nonisolated static func fold(nodes: [TreemapNode], availableWidth: CGFloat,
                                 spacing: CGFloat = 3) -> Fold {
        guard nodes.count > 1, availableWidth > 0 else { return Fold(visible: nodes, folded: []) }
        let total = max(1, nodes.reduce(0) { $0 + $1.bytes })
        var visible = nodes
        var folded: [TreemapNode] = []
        while visible.count > 1 {
            let tileCount = visible.count + (folded.isEmpty ? 0 : 1)
            let available = max(0, availableWidth - spacing * CGFloat(max(0, tileCount - 1)))
            let tailBytes = folded.reduce(0) { $0 + $1.bytes }
            let tailWidth = folded.isEmpty ? 0
                : max(labelMinWidth, available * CGFloat(tailBytes) / CGFloat(total))
            let visibleBytes = max(1, total - tailBytes)
            let visibleAvailable = max(0, available - tailWidth)
            guard let last = visible.last else { break }
            let lastWidth = visibleAvailable * CGFloat(last.bytes) / CGFloat(visibleBytes)
            guard lastWidth < labelMinWidth else { break }
            folded.insert(visible.removeLast(), at: 0)
        }
        // A fold of one keeps its identity instead; the view widens it to the floor.
        guard folded.count >= 2 else { return Fold(visible: nodes, folded: []) }
        return Fold(visible: visible, folded: folded)
    }

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 3
            let fold = Self.fold(nodes: nodes, availableWidth: geo.size.width, spacing: spacing)
            let total = max(1, nodes.reduce(0) { $0 + $1.bytes })
            let tileCount = fold.visible.count + (fold.folded.isEmpty ? 0 : 1)
            let available = max(0, geo.size.width - spacing * CGFloat(max(0, tileCount - 1)))
            // The tail never falls below the label floor, since it exists to be read; the
            // visible tiles share what remains in proportion.
            let tailWidth = fold.folded.isEmpty ? 0
                : max(Self.labelMinWidth, available * CGFloat(fold.tailBytes) / CGFloat(total))
            let visibleBytes = max(1, total - fold.tailBytes)
            let visibleAvailable = max(0, available - tailWidth)
            let widths = Self.visibleWidths(fold.visible, floorLastTile: fold.folded.isEmpty,
                                            available: visibleAvailable, visibleBytes: visibleBytes)
            HStack(spacing: spacing) {
                let ramp = Self.ramp(hue, count: fold.visible.count)
                ForEach(Array(fold.visible.enumerated()), id: \.offset) { idx, node in
                    tile(node, color: color(for: idx, in: ramp, node: node),
                         label: labelColor(for: idx, in: ramp, node: node), width: widths[idx])
                }
                if !fold.folded.isEmpty {
                    tailTile(fold, width: tailWidth)
                }
            }
        }
        .frame(height: 88)
    }

    /// The visible tiles' widths, which sum to `available`: computed together, not per tile.
    ///
    /// A lone straggler the fold left visible is held at the label floor and takes its width
    /// first; the rest share what remains in proportion. Widening it without taking the extra from
    /// the others would paint past the card's edge, since an `HStack` of fixed widths doesn't
    /// compress and a `GeometryReader` doesn't clip.
    ///
    /// One exception: an all-zero-byte visible set has no proportions, so the floored tile takes
    /// the floor and the rest nothing. Under-fill, never overflow.
    nonisolated static func visibleWidths(_ visible: [TreemapNode], floorLastTile: Bool,
                                          available: CGFloat, visibleBytes: Int) -> [CGFloat] {
        guard !visible.isEmpty else { return [] }
        func proportional(_ nodes: ArraySlice<TreemapNode>, of space: CGFloat, bytes: Int) -> [CGFloat] {
            nodes.map { space * CGFloat($0.bytes) / CGFloat(max(1, bytes)) }
        }
        guard floorLastTile, let last = visible.last else {
            return proportional(visible[...], of: available, bytes: visibleBytes)
        }
        let lastProportional = available * CGFloat(last.bytes) / CGFloat(max(1, visibleBytes))
        let lastWidth = max(lastProportional, min(labelMinWidth, available))
        // Nothing left to redistribute from — one tile, or the floor has eaten the row.
        guard visible.count > 1 else { return [lastWidth] }
        let rest = visible.dropLast()
        let restBytes = rest.reduce(0) { $0 + $1.bytes }
        return proportional(rest, of: max(0, available - lastWidth), bytes: restBytes) + [lastWidth]
    }

    /// The tail: neutral like "Other", labeled with what it absorbed, enumerating on hover.
    private func tailTile(_ fold: Fold, width: CGFloat) -> some View {
        let names = fold.folded.map(\.name).joined(separator: ", ")
        let bytes = FileSyncManager.formatBytes(fold.tailBytes)
        return RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
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
            .accessibilityLabel("\(fold.folded.count) more area\(fold.folded.count == 1 ? "" : "s"), \(bytes): \(names)")
    }

    @ViewBuilder
    private func tile(_ node: TreemapNode, color: Color, label: Color, width: CGFloat) -> some View {
        // A real area never collapses to nothing: a hairline still shows it exists.
        let clamped = max(width, 3)
        RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
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
