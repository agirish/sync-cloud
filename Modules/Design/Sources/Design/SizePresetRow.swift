import SwiftUI

/// The row of `SizePreset` tiles: the one control that answers "how much do you want on screen?"
/// in a click, in both places the app asks it.
///
/// A tile either names the two settings it applies or draws them, depending on the surface
/// (`Style`). In Settings it says `100%` over `Comfortable`: the reader has the app in front of
/// them and the tab has the width. Setup runs before the person has seen a file list, so the words
/// name nothing yet, and at that width they truncate; there a tile draws a miniature of the result
/// instead (rows at the preset's type size and spacing). Same values, same order.
///
/// The row scales with the text size it sets, unlike a segmented picker (`FontSize`'s known limit:
/// AppKit draws its labels), since a control that stayed small at 135% would fail exactly when
/// someone uses it to fix legibility. In the settings sheet's narrowest column the named labels
/// then want 399pt of 307pt, so they shrink there (see `tile(_:)`).
public struct SizePresetRow: View {
    /// How a tile labels itself.
    public enum Style: Sendable {
        /// Percentage over the row-spacing name. Settings ▸ Readability.
        case named
        /// Percentage under a miniature of the resulting rows. The setup form.
        case specimen
    }

    /// How far a tile's label may shrink before SwiftUI would truncate it instead. A named constant
    /// so the settings-column fit test measures against the same number, not a copy of it.
    public static let minimumLabelScale: CGFloat = 0.7

    @Binding private var fontSize: FontSize
    @Binding private var density: ListDensity
    private let style: Style
    /// The chosen tile's wash and border wear the hue the user picked — on the setup sheet
    /// that is the swatch just clicked, a row below.
    @AppStorage(LiquidGlass.hueKey) private var hueRaw: String = LiquidGlassHue.blue.rawValue
    private var accent: Color { (LiquidGlassHue(rawValue: hueRaw) ?? .blue).accentColor }

    public init(fontSize: Binding<FontSize>, density: Binding<ListDensity>, style: Style) {
        self._fontSize = fontSize
        self._density = density
        self.style = style
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
        // Frosted and Clear: the chosen tile's wash and border as one glass lens that stretches
        // between tiles.
        .selectionLensHost(Self.lensChannel, selected: selected, style: Self.lensStyle(accent: accent))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Size and spacing")
    }

    /// The chosen tile's wash and border, named once because the selection lens wears them too.
    static let selectedWash: Double = 0.10
    static let selectedBorder: CGFloat = 1.5
    /// The row's selection lens — see `SelectionLens`.
    static let lensChannel = SelectionLensChannel("size.presets")
    static func lensStyle(accent: Color) -> SelectionLensStyle {
        SelectionLensStyle(shape: .roundedRect(Radius.control), color: accent, markerOpacity: selectedWash,
                           ring: .init(color: accent, width: selectedBorder))
    }

    private func tile(_ preset: SizePreset) -> some View {
        let isSelected = preset == selected
        return Button {
            fontSize = preset.fontSize
            density = preset.density
        } label: {
            VStack(spacing: style == .specimen ? 3 : 1) {
                if style == .specimen {
                    SizePresetSpecimen(preset: preset, isSelected: isSelected, accent: accent)
                }
                Text("\(preset.fontSize.percent)%")
                    .scaledFont(.system(size: style == .specimen ? 10 : 12, weight: .semibold))
                if style == .named {
                    Text(preset.densityName)
                        .scaledFont(.system(size: 10))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                }
            }
            // Shrink rather than truncate: five eleven-character words want 399pt at 135%, and the
            // settings sheet's narrowest column offers 307pt. Only that corner engages it; at the
            // sheet's normal width every tile draws at full size.
            .lineLimit(1)
            .minimumScaleFactor(Self.minimumLabelScale)
            // Label colour on the chosen tile too: the hue is its wash and border, and a word in
            // the hue on a wash of it reads at 2.7:1 on Green.
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, style == .specimen ? 4 : 6)
            .padding(.horizontal, 4)
            // The chosen tile's wash and accent border are the Solid marker: in Frosted and Clear
            // the lens carries both and the chosen tile draws no border, since a border over the
            // lens would put a grey line on top of its accent ring.
            .background {
                if isSelected {
                    SelectionLensTodayMarker {
                        RoundedRectangle(cornerRadius: Radius.control)
                            .fill(accent.opacity(Self.selectedWash))
                    }
                }
            }
            .overlay {
                if isSelected {
                    SelectionLensTodayMarker {
                        RoundedRectangle(cornerRadius: Radius.control)
                            .strokeBorder(accent, lineWidth: Self.selectedBorder)
                    }
                } else {
                    RoundedRectangle(cornerRadius: Radius.control)
                        .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                }
            }
            .selectionLensStop(Self.lensChannel, id: preset)
            // The border is drawn, not filled, so without this the tile is hit-testable on a
            // 1.5pt ring alone — the whole face has to take the click.
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .chromeHover()
        .accessibilityLabel("\(preset.fontSize.percent) percent text, \(preset.densityName) rows")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .help("\(preset.fontSize.percent)% text · \(preset.densityName) rows")
    }
}

/// The detent labels under the text-size slider: the four named sizes, at their real positions,
/// so 125% reads as "Large" and the right-hand end as the last stop. Positioned from the values
/// rather than evenly, so a size whose percentage moves takes its label with it.
public struct FontSizeDetentLabels: View {
    private let selected: FontSize
    @AppStorage(LiquidGlass.hueKey) private var hueRaw: String = LiquidGlassHue.blue.rawValue
    private var accent: Color { (LiquidGlassHue(rawValue: hueRaw) ?? .blue).accentColor }

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
                // No tick mark of its own: a `Slider` with a `step` already draws the system's
                // ticks at every stop, and a second mark would sit on top of them. The label sits
                // over the system tick it names.
                VStack(spacing: 2) {
                    Text(size.presetName ?? "\(size.percent)%")
                        .scaledFont(.system(size: 9.5,
                                            weight: size == selected ? .semibold : .regular))
                        .foregroundStyle(size == selected ? accent : Color.secondary)
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

/// A few file rows drawn as the panes draw them in Tree (with each file's size-and-date line;
/// Columns shows names alone), at the chosen size and spacing.
///
/// The only part of the section that shows what the settings do. Row spacing can't be read off its
/// name: Compact drops each file's size and date (`showsSecondaryDetail`), shrinks the icon from
/// 17pt to 14pt and cuts row padding from 6pt to 2pt.
///
/// Row metrics come from `ListDensityMetrics` and type from the same `ScaledFont` values
/// `PaneRowFonts` builds (`.system(.body, design: .rounded)` for the name, `.caption` for the
/// detail). They can't share one expression, since `PaneRowFonts` lives in FileExplorer, which
/// Design can't see, so `thePreviewDrawsTheTypeThePanesDraw` keeps them from parting.
public struct SizeSpacingPreview: View {
    private let fontSize: FontSize
    private let density: ListDensity
    @AppStorage(LiquidGlass.hueKey) private var hueRaw: String = LiquidGlassHue.blue.rawValue
    private var accent: Color { (LiquidGlassHue(rawValue: hueRaw) ?? .blue).accentColor }

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

    /// The type a real file row draws. `public` so `thePreviewDrawsTheTypeThePanesDraw` — which
    /// has to live in FileExplorer, the only module that can see both these and `PaneRowFonts` —
    /// can hold them against the pane's own values rather than against a restatement of them.
    public static let nameFont = ScaledFont.system(.body, design: .rounded)
    public static let detailFont = ScaledFont.caption

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
                            .fill(accent.opacity(0.55))
                            .frame(width: metrics.treeIconSize, height: metrics.treeIconSize)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name)
                                .scaledFont(Self.nameFont)
                            if metrics.showsSecondaryDetail {
                                Text(row.detail)
                                    .scaledFont(Self.detailFont)
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
            RoundedRectangle(cornerRadius: Radius.control)
                .fill(Color.secondary.opacity(0.07))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview at \(fontSize.percent) percent, \(density.displayName) rows")
    }
}

struct SizePresetSpecimen: View {
    let preset: SizePreset
    let isSelected: Bool
    let accent: Color

    /// The tile face's fixed height, so every `%` label in the row sits on one baseline whatever
    /// the preset draws above it.
    ///
    /// 24pt is a budget: `SizePreset.all` holds two presets at 100%, compact and comfortable, whose
    /// labels both read `100%`, so this picture alone tells them apart. At 14pt the difference
    /// would be three bars against two, three pixels apart; at 24 (with `maximumRows` to match) it
    /// is a stack of single bars against a stack of paired ones. The setup sheet has the room
    /// (`SetupSheetFitTests`).
    static let faceHeight: CGFloat = 24

    /// Never draw more than this many rows, however small the type gets: past this the bars read
    /// as a texture, not rows of text. Moves with `faceHeight`, because the cap is really bars per
    /// point of face: raising the face alone lets the comfortable presets climb to the cap the
    /// compact ones already hit, and the two 100% tiles come out alike.
    static let maximumRows = 7

    /// The height of one miniature row at `preset`: a name bar, plus the size-and-date bar when
    /// this density shows one.
    static func rowHeight(for preset: SizePreset) -> CGFloat {
        let bar = barHeight(for: preset)
        return preset.density.metrics.showsSecondaryDetail ? bar * 2 + detailGap : bar
    }

    /// Scaled from the app's workhorse 11pt row text, so the bars really do thicken with the
    /// setting. A sixth of it: thin enough to read as a line of text rather than a block.
    static func barHeight(for preset: SizePreset) -> CGFloat {
        max(1, FontSize.scaledPointSize(11, scale: preset.fontSize.scale) / 6)
    }

    static let detailGap: CGFloat = 1

    static func rowGap(for preset: SizePreset) -> CGFloat {
        preset.density.metrics.showsSecondaryDetail ? 2 : 1.5
    }

    /// How many rows fit the fixed face, which is the point of the picture. A fixed count would
    /// overflow the face at large sizes, and SwiftUI centres rather than clips, so the bars would
    /// bleed over the tile's border while every geometry test passed. Derived, the tile is also
    /// truthful: more rows in a fixed height is what a tighter spacing buys.
    /// `theSpecimenNeverOverflowsItsFace` pins the arithmetic.
    static func rowCount(for preset: SizePreset) -> Int {
        let row = rowHeight(for: preset)
        let gap = rowGap(for: preset)
        let fits = Int(((faceHeight + gap) / (row + gap)).rounded(.down))
        return min(max(fits, 1), maximumRows)
    }

    private var metrics: ListDensityMetrics { preset.density.metrics }

    var body: some View {
        VStack(spacing: Self.rowGap(for: preset)) {
            ForEach(0..<Self.rowCount(for: preset), id: \.self) { _ in
                VStack(alignment: .leading, spacing: Self.detailGap) {
                    bar(widthFraction: 1)
                    if metrics.showsSecondaryDetail {
                        bar(widthFraction: 0.62)
                    }
                }
            }
        }
        .frame(height: Self.faceHeight)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private func bar(widthFraction: CGFloat) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 0.5)
                .fill(isSelected ? accent.opacity(0.85) : Color.secondary.opacity(0.55))
                .frame(width: proxy.size.width * widthFraction, height: Self.barHeight(for: preset))
        }
        .frame(height: Self.barHeight(for: preset))
    }
}
