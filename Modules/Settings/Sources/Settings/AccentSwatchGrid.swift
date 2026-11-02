import Design
import SwiftUI

/// The accent swatches for an Ask Claude settings card: Settings' own discs, two rows of six at
/// 24 pt in 32 pt slots — 212 pt wide, so the twelve fit a 240 pt card. Settings' row of 32 pt
/// swatches with names under them is about 440 pt wide.
///
/// No names under the discs — there's no room for "Graphite" in a 32 pt slot — so each disc names
/// itself in a tooltip and to VoiceOver, and the line under the grid names the current one. No
/// selection lens either: a card is outside any lens host, so the chosen disc wears today's ring.
public struct AccentSwatchGrid: View {
    let hues: [LiquidGlassHue]
    let selected: LiquidGlassHue?
    /// Claude's suggestion, ringed dashed until it is the current one.
    let suggested: LiquidGlassHue?
    let onSelect: (LiquidGlassHue) -> Void

    public init(hues: [LiquidGlassHue] = LiquidGlassHue.allCases, selected: LiquidGlassHue?,
                suggested: LiquidGlassHue? = nil, onSelect: @escaping (LiquidGlassHue) -> Void) {
        self.hues = hues
        self.selected = selected
        self.suggested = suggested
        self.onSelect = onSelect
    }

    public static let perRow = 6
    static let diameter: CGFloat = 24
    /// Room for the suggestion's dashed ring, so marking a swatch never moves its neighbours.
    static let slot: CGFloat = 32
    static let spacing: CGFloat = 4

    public var body: some View {
        let rows = stride(from: 0, to: hues.count, by: Self.perRow).map { Array(hues[$0..<min($0 + Self.perRow, hues.count)]) }
        VStack(alignment: .leading, spacing: 4) {
            Grid(horizontalSpacing: Self.spacing, verticalSpacing: Self.spacing) {
                ForEach(rows, id: \.self) { row in
                    GridRow {
                        ForEach(row) { swatch($0) }
                    }
                }
            }
            if let selected {
                Text(selected.displayName)
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    private func swatch(_ hue: LiquidGlassHue) -> some View {
        let isSelected = hue == selected
        let isSuggested = hue == suggested && !isSelected
        return Button { onSelect(hue) } label: {
            ZStack {
                HueSwatchDisc(hue: hue)
                    .frame(width: Self.diameter, height: Self.diameter)
                    .overlay {
                        if isSelected {
                            Circle().strokeBorder(HueOptionView.ringColor, lineWidth: HueOptionView.ringWidth)
                        }
                    }
                    .shadow(color: HueSwatchDisc.shadowColor(hue), radius: isSelected ? 4 : 1)
                if isSelected {
                    Image(systemName: "checkmark")
                        .scaledFont(.system(size: 10, weight: .semibold))
                        // As in Settings: the checkmark pairs with the disc's own fill.
                        .foregroundStyle(hue == .none ? Color.primary : .onFillLabel(hue.accentColor))
                        .shadow(color: .black.opacity(0.35), radius: 0.5, x: 0, y: 0.5)
                }
                if isSuggested {
                    Circle()
                        .stroke(Color.primary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .frame(width: Self.diameter + 6, height: Self.diameter + 6)
                }
            }
            .frame(width: Self.slot, height: Self.slot)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverAffordance(.segment, tint: hue.accentColor, shape: .roundedRect(8)))
        .help(isSuggested ? "\(hue.displayName) — Claude’s suggestion" : hue.displayName)
        .accessibilityLabel(hue.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isSuggested ? "Claude suggests this one" : "")
    }
}
