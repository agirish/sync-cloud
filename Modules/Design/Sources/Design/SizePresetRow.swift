import SwiftUI

/// The row of `SizePreset` tiles — the one control that answers "how much do you want on screen?"
/// in a click, in both places the app asks it.
///
/// **Each tile names both settings it applies** — the percentage over the row spacing — which is
/// what lets the two 100% tiles tell themselves apart with no legend, rail, or end labels under
/// the row.
///
/// The row **does** scale with the text size it sets, which the segmented picker it replaced could
/// not (`FontSize`'s KNOWN LIMIT — AppKit draws its own labels). A control that stayed small at
/// 135% would be illegible exactly when somebody is using it to fix legibility. That is also the
/// one case where the tiles run out of room: five eleven-character words want 399pt against the
/// 307pt the settings sheet's narrowest column offers, so the labels shrink to fit rather than
/// truncate — see `tile(_:)`.
public struct SizePresetRow: View {
    /// How far a tile's label may shrink before SwiftUI would truncate it instead.
    ///
    /// Internal to the type rather than a literal at the call site because the settings-column fit
    /// test has to measure against the same number — a test restating 0.7 would keep passing after
    /// this moved.
    public static let minimumLabelScale: CGFloat = 0.7

    @Binding private var fontSize: FontSize
    @Binding private var density: ListDensity

    public init(fontSize: Binding<FontSize>, density: Binding<ListDensity>) {
        self._fontSize = fontSize
        self._density = density
    }

    private var selected: SizePreset? {
        SizePreset.matching(fontSize: fontSize, density: density)
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(SizePreset.all) { preset in
                tile(preset)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Size and spacing")
    }

    private func tile(_ preset: SizePreset) -> some View {
        let isSelected = preset == selected
        return Button {
            fontSize = preset.fontSize
            density = preset.density
        } label: {
            VStack(spacing: 1) {
                Text("\(preset.fontSize.percent)%")
                    .scaledFont(.system(size: 12, weight: .semibold))
                Text(preset.densityName)
                    .scaledFont(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            // **Shrink rather than truncate.** Five tiles each carrying an eleven-character word
            // want 399pt at 135%, and the settings sheet's narrowest column offers 307pt — the
            // case that made an earlier draft drop the words entirely. Scaling the label down is
            // what keeps them, and it only ever engages in that corner: at the sheet's normal
            // width every tile draws at full size.
            .lineLimit(1)
            .minimumScaleFactor(Self.minimumLabelScale)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.35),
                                  lineWidth: isSelected ? 1.5 : 1)
            }
            // The border is drawn, not filled, so without this the tile is hit-testable on a
            // 1.5pt ring alone — the whole face has to take the click.
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .chromeHover()
        .accessibilityLabel("\(preset.fontSize.percent) percent text, \(preset.densityName) rows")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .help("\(preset.fontSize.percent)% text · \(preset.densityName) rows")
    }
}

/// The detent labels under the text-size slider — the four named sizes, at their real positions.
///
/// A slider with a bare percentage readout gives no sense of where the shipped sizes are; these
/// are what make 125% recognisably "Large" and the right-hand end recognisably the last stop.
/// Positioned from the values themselves rather than laid out evenly, so a preset whose percentage
/// moves takes its label with it instead of quietly pointing at the wrong place.
public struct FontSizeDetentLabels: View {
    private let selected: FontSize

    public init(selected: FontSize) { self.selected = selected }

    /// Where a percentage sits along the track, 0...1.
    static func position(_ percent: Int) -> CGFloat {
        let span = CGFloat(FontSize.maximumPercent - FontSize.minimumPercent)
        return (CGFloat(percent) - CGFloat(FontSize.minimumPercent)) / span
    }

    /// Half a slider knob. The track a `Slider` draws is inset by this at each end, so a label
    /// placed at a raw fraction of the full width drifts away from its tick — most visibly at the
    /// two ends, which are exactly the labels somebody checks.
    static let knobInset: CGFloat = 9

    public var body: some View {
        GeometryReader { proxy in
            let usable = max(proxy.size.width - Self.knobInset * 2, 1)
            ForEach(FontSize.allCases) { size in
                // **No tick mark of its own.** A `Slider` with a `step` draws the system's own
                // ticks under the track at every stop, and an earlier draft added a second mark
                // per detent directly on top of them — two tick rows saying different things at
                // the same y. The label alone, positioned over the system tick it names, is what
                // was missing.
                VStack(spacing: 2) {
                    Text(size.presetName ?? "\(size.percent)%")
                        .scaledFont(.system(size: 9.5,
                                            weight: size == selected ? .semibold : .regular))
                        .foregroundStyle(size == selected ? Color.accentColor : Color.secondary)
                        .fixedSize()
                }
                .position(x: Self.knobInset + Self.position(size.percent) * usable,
                          y: proxy.size.height / 2)
            }
        }
        .frame(height: 22)
        .accessibilityHidden(true)
    }
}

/// A few file rows drawn exactly as the panes draw them, at the chosen size and spacing.
///
/// **This is the only part of the section that shows what the settings actually do.** Row spacing
/// in particular cannot be read off its own name: going Compact drops each file's size and date
/// entirely (`showsSecondaryDetail`), shrinks the icon 17pt → 14pt and cuts row padding 6pt → 2pt,
/// and nobody choosing from the word alone would guess the date disappears.
///
/// It takes its metrics from `ListDensityMetrics` and its fonts through `scaledFont`, so it is the
/// real thing rather than a picture of it — a change to either setting's effect shows up here
/// without anyone remembering to update a mock.
public struct SizeSpacingPreview: View {
    private let fontSize: FontSize
    private let density: ListDensity

    public init(fontSize: FontSize, density: ListDensity) {
        self.fontSize = fontSize
        self.density = density
    }

    /// Real-looking documents rather than "Item 1": the point is to judge legibility, and a name
    /// of a plausible length is what makes that judgement transferable.
    static let rows: [(name: String, detail: String)] = [
        ("Birth Certificate.pdf", "12 Aug 2026 · 2.4 MB"),
        ("Tax Return 2025.pdf", "3 Apr 2026 · 812 KB"),
        ("Passport scan.jpeg", "27 Jan 2026 · 4.1 MB"),
    ]

    private var metrics: ListDensityMetrics { density.metrics }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview — \(fontSize.percent)% · \(density.displayName.lowercased()) rows")
                .scaledFont(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.rows, id: \.name) { row in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor.opacity(0.55))
                            .frame(width: metrics.treeIconSize, height: metrics.treeIconSize)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name)
                                .scaledFont(.system(size: 11))
                            if metrics.showsSecondaryDetail {
                                Text(row.detail)
                                    .scaledFont(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, metrics.flatRowVerticalPadding)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.07))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview at \(fontSize.percent) percent, \(density.displayName) rows")
    }
}
