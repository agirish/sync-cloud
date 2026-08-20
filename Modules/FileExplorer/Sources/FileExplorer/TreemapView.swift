import SwiftUI
import AppKit
import Sync
import Design

/// A single-row proportional treemap of `[TreemapNode]`: rounded tiles whose widths track each
/// area's rolled-up bytes, largest first. A purely visual summary of where space concentrates —
/// it triggers no action and mutates nothing.
struct TreemapView: View {
    let nodes: [TreemapNode]

    /// The hue the ramp is built from. Defaults to the app's blue rather than reading
    /// `@AppStorage` here, so the view stays a pure function of what it is handed and the one
    /// caller decides.
    var hue: LiquidGlassHue = .blue

    /// One sequential ramp, deep to pale, ordered by size — so **colour is the ranking** rather
    /// than a rotating ten-hue palette assigned by index, where blue-for-Work meant nothing and
    /// the eye kept looking for a legend that could not exist.
    ///
    /// Built from the hue's own accent: step 0 **is** that accent, and each later step desaturates
    /// toward white. Luminance is therefore **strictly monotonic** for every hue, which is the
    /// property that lets the ramp be read as an order; `TreemapRampTests` pins it over all twelve.
    ///
    /// The argument, because the first version of this comment gave the wrong one. HSB→RGB is
    /// `b · (1 − s·f)`, with `f ∈ [0,1]` fixed per component by the hue. Falling `s` raises every
    /// component; rising `b` raises every component; so both moves agree — **provided `b` actually
    /// rises**. Six of the twelve hues have `b = 1.0` already, blue and the app's default among
    /// them, and against a flat 0.97 ceiling their brightness would *fall* by three points while
    /// saturation fell. Luminance still rose (saturation dominates), so the ramp was right and the
    /// reason given for it was not. `max(0, …)` makes the ceiling a floor-under-no-change: those
    /// hues hold `b` and ramp on saturation alone, and the sentence above is true as written.
    ///
    /// Absolute endpoints were tried first and abandoned: forcing every hue into one luminance
    /// band turns amber into a dark brown at the deep end. Ramping from each hue's own accent
    /// keeps the hue recognisable and costs only that pale-hued ramps sit higher overall — which
    /// the label rule below already answers.
    nonisolated static func ramp(_ hue: LiquidGlassHue, count: Int) -> [Color] {
        // `.none` resolves to the *system* accent, which is a dynamic color: sampling its
        // components fixes it to whatever appearance happens to be current, and it will not
        // re-resolve when that changes. Every other case is static sRGB. Blue is the app's own
        // default and what this treemap's palette already led with.
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

    /// The label color, from **the fill the tile actually took** rather than a fixed table
    /// parallel to a fixed palette.
    ///
    /// The old `labelPalette` was ten precomputed answers for ten fixed hues; a ramp has as many
    /// fills as there are tiles, so there is nothing to precompute against. `Color.onFillLabel` is
    /// the app's one on-fill pairing rule and it takes a color, so asking it per tile is both
    /// shorter and correct for fills it has never seen.
    ///
    /// **This is why the ramp does not simply delete the contrast problem, as the plan for it
    /// assumed.** That reasoning was "the pale end lands on the small tiles, which carry no
    /// labels anyway" — but the fold floors the smallest visible tile at `labelMinWidth`, which
    /// is exactly the width at which a tile *starts* drawing its name. The palest step is
    /// therefore labelled, and needs the pairing as much as amber ever did.
    private func labelColor(for index: Int, in ramp: [Color], node: TreemapNode) -> Color {
        node.name == "Other" ? .primary : Color.onFillLabel(color(for: index, in: ramp, node: node))
    }

    /// The width below which a tile draws no name — and, since the fold landed, the width below
    /// which it stops being its own tile at all.
    ///
    /// `nonisolated` because the two functions that decide widths from it — `fold` and
    /// `visibleWidths` — are pure arithmetic and say so. Reading a main-actor constant from them
    /// warned at every call site while changing nothing about the value.
    nonisolated static let labelMinWidth: CGFloat = 46

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
    /// Iterative, and that is the correctness point (found in adversarial review): the tail is
    /// clamped to the label floor, and the width that clamp takes comes out of the visible
    /// tiles — which can push the smallest of THEM under the floor, the exact anonymous-sliver
    /// state the fold exists to remove. So the decision replays against the post-clamp widths
    /// until it settles: fold the last tile while it cannot carry a label, then re-measure.
    /// Nodes arrive largest-first, so widths descend and the settled visible set is entirely
    /// at or above the floor.
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
        // A fold of ONE would relabel a tile "+1 more" in the same space its own name could
        // use — the straggler keeps its identity (the view widens it to the floor instead).
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
            // The tail never falls below the label floor — its whole job is to be readable —
            // and the visible tiles share what remains in their own proportions.
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

    /// The visible tiles' widths, which **sum to `available`** — that is the whole point of doing
    /// it here rather than per-tile inside the `ForEach`.
    ///
    /// A single sub-threshold straggler left visible by the fold (a "+1 more" would use the space
    /// its own name could) is held at the label floor, same as the tail. It was widened in place,
    /// though, without the extra being taken from anyone: the other tiles had already been sized to
    /// fill the row, so `[10 000, 8 000, 100]` at 900pt drew about 941pt of tiles. An `HStack` of
    /// fixed-width children does not compress and a `GeometryReader` does not clip, so the excess
    /// was simply painted past the card's right edge.
    ///
    /// The floored tile is paid for exactly the way the tail is: it takes its width first, and the
    /// rest share what remains in their own proportions.
    ///
    /// One exception to "sum to `available`", stated so the invariant is not read as wider than it
    /// is: an all-zero-byte visible set has no proportions to divide, so the floored tile takes the
    /// label floor and the rest take nothing. That is under-fill, never overflow, and a report with
    /// zero-byte areas has nothing to draw anyway.
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
