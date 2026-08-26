import SwiftUI

/// The row of `SizePreset` tiles — the one control that answers "how much do you want on screen?"
/// in a click, in both places the app asks it.
///
/// **A tile either names both settings it applies or draws them**, and which one depends on the
/// surface — that is what `Style` is for.
///
/// In Settings a tile says `100%` over `Comfortable`: the reader has the app in front of them, has
/// met both words, and the tab has the width to print them. On the setup form neither is true. It
/// runs on step one of a first launch, before the person has seen a file list, so "Comfortable"
/// and "Compact" name nothing yet — and shipping one style for both surfaces is not a hypothetical
/// cost: framed at the width that step gave it, the words did not shrink, they **truncated**, to
/// "Comfor…" on three of the five tiles.
///
/// So the setup form draws a miniature of the result instead — three rows at that preset's type
/// size and row spacing — which needs no vocabulary and very little width. Same control, same
/// values, same order; only the tile's face changes.
///
/// The row **does** scale with the text size it sets, which the segmented picker it replaced could
/// not (`FontSize`'s KNOWN LIMIT — AppKit draws its own labels). A control that stayed small at
/// 135% would be illegible exactly when somebody is using it to fix legibility. That is also where
/// the named style runs out of room: five eleven-character words want 399pt against the 307pt the
/// settings sheet's narrowest column offers, so there the labels shrink — see `tile(_:)`.
public struct SizePresetRow: View {
    /// How a tile labels itself.
    public enum Style: Sendable {
        /// Percentage over the row-spacing name. Settings ▸ Readability.
        case named
        /// Percentage under a miniature of the resulting rows. The setup form.
        case specimen
    }

    /// How far a tile's label may shrink before SwiftUI would truncate it instead.
    ///
    /// Internal to the type rather than a literal at the call site because the settings-column fit
    /// test has to measure against the same number — a test restating 0.7 would keep passing after
    /// this moved.
    public static let minimumLabelScale: CGFloat = 0.7

    @Binding private var fontSize: FontSize
    @Binding private var density: ListDensity
    private let style: Style

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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Size and spacing")
    }

    private func tile(_ preset: SizePreset) -> some View {
        let isSelected = preset == selected
        return Button {
            fontSize = preset.fontSize
            density = preset.density
        } label: {
            VStack(spacing: style == .specimen ? 3 : 1) {
                if style == .specimen {
                    SizePresetSpecimen(preset: preset, isSelected: isSelected)
                }
                Text("\(preset.fontSize.percent)%")
                    .scaledFont(.system(size: style == .specimen ? 10 : 12, weight: .semibold))
                if style == .named {
                    Text(preset.densityName)
                        .scaledFont(.system(size: 10))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
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
            .padding(.vertical, style == .specimen ? 4 : 6)
            .padding(.horizontal, 4)
            .background {
                RoundedRectangle(cornerRadius: Radius.control)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.control)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.35),
                                  lineWidth: isSelected ? 1.5 : 1)
            }
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

/// A few file rows drawn the way the panes draw them, at the chosen size and spacing.
///
/// **This is the only part of the section that shows what the settings actually do.** Row spacing
/// in particular cannot be read off its own name: going Compact drops each file's size and date
/// entirely (`showsSecondaryDetail`), shrinks the icon 17pt → 14pt and cuts row padding 6pt → 2pt,
/// and nobody choosing from the word alone would guess the date disappears.
///
/// It takes its row metrics from `ListDensityMetrics` and its type from the same `ScaledFont`
/// values `PaneRowFonts` builds — `.system(.body, design: .rounded)` for the name and `.caption`
/// for the size-and-date line. That matters more than it looks: an earlier version drew plain
/// 11pt and 10pt in the DEFAULT face while a real row is 13pt and ROUNDED, and its doc claimed
/// the rows were what the panes draw. The two cannot be shared as one expression
/// (`PaneRowFonts` lives in FileExplorer, which Design cannot see), so
/// `thePreviewDrawsTheTypeThePanesDraw` is what keeps them from parting.
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
                            .fill(Color.accentColor.opacity(0.55))
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

    /// The tile face's fixed height, so every `%` label in the row sits on one baseline no matter
    /// what the preset draws above it.
    ///
    /// **14pt, and the number is a budget rather than a taste.** This row goes on the setup form's
    /// You step, which shares one card with People and Done and is measured against what a
    /// 1280×800 display can show without scrolling (`SetupSheetFitTests.everyBoundedStepFitsThe
    /// CardTheyShare`). The first draft drew a 26pt face with its own label line and caption and
    /// put the step 88pt over that ceiling.
    static let faceHeight: CGFloat = 14

    /// Never draw more than this many rows, however small the type gets — past four the bars stop
    /// reading as rows of text and start reading as a texture.
    static let maximumRows = 4

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

    /// **How many rows fit the fixed face — which is the whole point of the picture.**
    ///
    /// The first version drew three rows at every preset and pinned the face at 14pt, so the
    /// stack simply overflowed: six comfortable bars at 135% want 21.9pt in a 14pt frame, and
    /// SwiftUI does not clip, it centres — the bars bled over the tile's border and towards the
    /// percentage underneath. Rendering it is what caught that; every geometry test passed,
    /// because the frame was the size it claimed and the overflow was outside it.
    ///
    /// Deriving the count instead fixes the overflow *and* makes the tile truthful: a fixed
    /// height showing more rows is exactly what a tighter row spacing buys, and it is what a
    /// person actually sees when they choose Compact. `theSpecimenNeverOverflowsItsFace` pins the
    /// arithmetic.
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
                .fill(isSelected ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.55))
                .frame(width: proxy.size.width * widthFraction, height: Self.barHeight(for: preset))
        }
        .frame(height: Self.barHeight(for: preset))
    }
}
