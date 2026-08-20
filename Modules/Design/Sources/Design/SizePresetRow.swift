import SwiftUI

/// The row of `SizePreset` tiles — the one control that answers "how much do you want on screen?"
/// in a click, in both places the app asks it.
///
/// **Each tile is a picture of the outcome rather than a name for it.** Three miniature rows drawn
/// at that preset's type size and row spacing: the bar heights come from `FontSize.scaledPointSize`,
/// the gaps from `ListDensityMetrics`, and a compact preset draws the name bar alone because
/// compact rows genuinely drop the size-and-date line. The percentage underneath is the numeric
/// anchor; the row-spacing word is not on the tile at all.
///
/// That is a measured decision, not a stylistic one, and it replaced a two-line tile that said
/// `100%` over `Comfortable`:
///
/// - **It did not fit.** At 135% in the settings sheet's narrowest column the row wanted 399pt
///   against 307pt available — five tiles each carrying an eleven-character word cannot fit a
///   column that once held a 260pt segmented picker.
///   (`theTextSizeRowFitsTheNarrowestColumnTheSheetCanOffer`.)
/// - **It could not fit on the setup card either**, where "Comfortable" and "Compact" name nothing
///   yet — that screen runs on step one of a first launch, before the person has seen a file list.
///
/// So both surfaces get the same control, and the words live where they are already spelled out:
/// the section caption underneath (`SizePreset.caption`) and the Row spacing picker one control
/// below it.
///
/// The row **does** scale with the text size it sets, which the segmented picker it replaced could
/// not (`FontSize`'s KNOWN LIMIT — AppKit draws its own labels). A control that stayed small at
/// 135% would be illegible exactly when somebody is using it to fix legibility.
public struct SizePresetRow: View {
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
            VStack(spacing: 3) {
                SizePresetSpecimen(preset: preset, isSelected: isSelected)
                Text("\(preset.fontSize.percent)%")
                    .scaledFont(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
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

/// Three miniature rows drawn at a preset's type size and row spacing — a tile's face.
///
/// A picture of the outcome rather than an icon *of* the outcome: a compact preset draws the name
/// bar alone because compact rows genuinely drop the size-and-date line (`showsSecondaryDetail`).
/// Somebody picking from the word "Compact" would not guess the date disappears; somebody picking
/// from this can see it.
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
