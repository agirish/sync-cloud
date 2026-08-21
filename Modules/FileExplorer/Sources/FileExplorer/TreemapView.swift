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
    /// toward white. Both moves push every sRGB component the same way — HSB→RGB is
    /// `b · (1 − s·f)` for an `f` fixed by the hue — so falling saturation and rising brightness
    /// make luminance **strictly monotonic** for every hue, which is the property that lets the
    /// ramp be read as an order. `TreemapRampTests` pins it over all twelve.
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
                                          brightness: b + (0.97 - b) * t,
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
    /// assumed.** That reasoning was "the pale end lands on the small tiles, which carry no labels
    /// anyway" — but a tile draws its name from 46pt up, and on this line nothing folds the small
    /// ones away, so the palest step is labelled whenever the area is big enough to have a name at
    /// all. It needs the pairing as much as amber ever did.
    private func labelColor(for index: Int, in ramp: [Color], node: TreemapNode) -> Color {
        node.name == "Other" ? .primary : Color.onFillLabel(color(for: index, in: ramp, node: node))
    }

    var body: some View {
        let total = max(1, nodes.reduce(0) { $0 + $1.bytes })
        GeometryReader { geo in
            let spacing: CGFloat = 3
            let available = max(0, geo.size.width - spacing * CGFloat(max(0, nodes.count - 1)))
            HStack(spacing: spacing) {
                // The ramp is built for the tiles actually drawn. This line has no fold, so that
                // is every node — see `ramp` for why the count matters.
                let ramp = Self.ramp(hue, count: nodes.count)
                ForEach(Array(nodes.enumerated()), id: \.offset) { idx, node in
                    let width = available * CGFloat(node.bytes) / CGFloat(total)
                    tile(node, color: color(for: idx, in: ramp, node: node),
                         label: labelColor(for: idx, in: ramp, node: node), width: width)
                }
            }
        }
        .frame(height: 88)
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
