import Design
import SwiftUI

/// The Appearance tab's accent picker: eleven swatches, a live sample of what the accent paints,
/// and a caption naming the choice and where it lands. Takes its hue as a plain value, so snapshot
/// tests can render a hue without a defaults suite; the storage stays in the tab.
struct AccentColorSection: View {
    let selectedHue: LiquidGlassHue
    let onSelect: (LiquidGlassHue) -> Void

    var body: some View {
        SettingsSection("Accent color", caption: Self.caption(for: selectedHue)) {
            // Eleven hues share this row; the tighter spacing gives each swatch more room.
            HStack(spacing: 5) {
                ForEach(LiquidGlassHue.allCases) { hue in
                    HueOptionView(
                        hue: hue,
                        isSelected: selectedHue == hue,
                        action: { onSelect(hue) }
                    )
                }
            }
            .frame(maxWidth: .infinity)
            // Frosted and Clear: the chosen swatch's ring as a glass halo that travels to the
            // swatch you pick.
            .selectionLensHost(Self.lensChannel, selected: selectedHue, style: Self.lensStyle)
            AccentPreviewStrip(hue: selectedHue)
        }
    }

    /// The row's selection lens — see `SelectionLens`.
    static let lensChannel = SelectionLensChannel("settings.accent")
    /// A halo around the swatch, never glass over it, and never tinted. The swatch is the colour
    /// being chosen, so the lens sits behind it and shows only as a band outside its edge: `outset`
    /// 3 puts the 2pt ring on the band's rim with the setup form's 1pt gap. `markerOpacity` 0 keeps
    /// the glass clear of accent at every Tint, since a halo of one hue around a swatch of another
    /// would contradict what it marks.
    static let lensStyle = SelectionLensStyle(
        shape: .circle, color: HueOptionView.ringColor, markerOpacity: 0,
        ring: .init(color: HueOptionView.ringColor, width: HueOptionView.ringWidth), outset: 3)

    /// The caption, in the idiom of the neighbouring sections (`AppearanceMode.detail`,
    /// `GlassLevel.detail`): name the current value, then say what it does.
    ///
    /// The three uses named are the three that exist: filled controls (`PaneActionBar`'s transfer
    /// buttons, `DestinationPicker`'s selected rail row), the pane selection wash (`FileTreeView`),
    /// and the seam chrome (`ContentView`'s swap button and rail spine). The tint wash has its own
    /// section below. `.none` keeps all three, because `LiquidGlassHue.none.accentColor` is the
    /// system accent; what it removes is the glass background (clear `gradientColors`, no surface
    /// tint wash).
    ///
    /// Keep it to one line at the settings column's 547pt, about 108 characters: a wrap costs the
    /// tab ~13pt of height. `appearanceFitsEveryAccentHue` measures every hue's caption; if it
    /// fails, shorten the sentence rather than widen the test.
    static func caption(for hue: LiquidGlassHue) -> String {
        guard hue != .none else {
            // `.none` defers to the system accent, which is why the strip still shows a filled
            // button; without saying so, a coloured button under "None" reads as a bug. 98
            // characters, one line at the 11pt caption size: measure before lengthening.
            return "None. Filled controls, selection, and seam chrome use your macOS accent; the glass stays untinted."
        }
        return "\(hue.displayName). Used for filled controls, selection, and the seam chrome."
    }
}

/// A live sample of the accent in use: the pane action bar's filled transfer button beside the
/// differences count pill, on a neutral ground.
///
/// Both chips are the shipping surfaces, not lookalikes (`actionBarButtonSurface(.primary…)` and
/// `semanticCapsuleSurface` with `SemanticCapsuleStyle.onAccent`), so the preview can't show a
/// livelier pairing than the app renders. Neither is a `Button`, so neither can be reached by
/// pointer, keyboard or assistive reader. It previews the selected hue, never the hovered one, so
/// it always shows the current setting and sweeping the swatches doesn't strobe it.
struct AccentPreviewStrip: View {
    let hue: LiquidGlassHue

    /// What `DifferencesView.countPillDressing` builds for the count pill in every state: the
    /// deepened accent under a white label. The raw `accentColor` would be brighter but leave white
    /// at 2.68:1 (see `AccentFill`), so this reads the same two properties the app does, and
    /// `AccentPreviewTests` pins that.
    private var countCapsule: SemanticCapsuleStyle {
        .onAccent(fill: hue.accentFillColor, label: hue.onAccentLabelColor)
    }

    var body: some View {
        // 12pt, wider than a real bar's 8pt: both chips carry the same solid fill and never sit
        // together in the app, so at bar spacing they would read as one block of colour.
        HStack(spacing: 12) {
            transferButton
            countPill
        }
        .padding(.horizontal, 10)
        // 5pt, trimmed for the tab's height budget (see `SettingsSheetMetrics.baseSize`). Only
        // the ground tightens; AccentPreviewTests samples 5pt inside each capsule's edge, which
        // stays inside the paint.
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(Color.primary.opacity(ActionBarMetrics.outlineStrokeOpacity),
                              lineWidth: PillVariant.strokeWidth)
        )
        // Hugs its content instead of stretching: a full-width ground would read as a container
        // the section's controls live in rather than as one sample sitting under them.
        .fixedSize()
        // One element, not a pair of controls: these are pictures of controls. Left in the tree,
        // not hidden, because the sample answers "what does this change?", and read as a sample so
        // VoiceOver never offers a button that does nothing.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(for: hue))
    }

    /// The strip's spoken label, with the same `.none` branch as `AccentColorSection.caption(for:)`
    /// so VoiceOver never hears "None accent on a filled button". A static helper so
    /// `AccentPreviewTests` can pin the branch.
    static func accessibilityLabel(for hue: LiquidGlassHue) -> String {
        guard hue != .none else {
            return "Preview: your macOS accent color on a filled button and a count pill."
        }
        return "Preview: \(hue.displayName) accent on a filled button and a count pill."
    }

    /// `PaneActionBar`'s transfer button, to the property: it passes
    /// `AccentFill.deepened(glassHue.accentColor)` as the tint, which is `accentFillColor`.
    /// `.primary` deepens again, a no-op on an already-deepened colour.
    ///
    /// No `Button`, by construction: `ActionBarButtonSurface` is the paint a real button gets, at
    /// its resting phase, so there is no pointer, keyboard or VoiceOver path to switch off. Not
    /// `.disabled` either, which would wash out the colour being chosen. **Never** hand-draw this
    /// chip or the count pill; the strip exists to show the shipping components.
    private var transferButton: some View {
        // "arrow.right" is `TransferGlyph.copy(toRight:)`, spelled out because that type lives in
        // FileExplorer, which Settings doesn't depend on.
        Label("Copy 12 to iCloud", systemImage: "arrow.right")
            .actionBarButtonSurface(.primary,
                                    tint: hue.accentFillColor,
                                    onTint: hue.onAccentLabelColor)
    }

    /// The differences count pill: `StatPill`'s semantic path (a number, a label, the flat accent
    /// capsule). Assembled from `StatPill`'s Design constants because `StatPill` is in
    /// FileExplorer; the capsule is the same `semanticCapsuleSurface`.
    private var countPill: some View {
        HStack(spacing: Pill.contentSpacing) {
            Text(22.formatted())
                .scaledFont(PillVariant.standard.numberFont.monospacedDigit())
            Text("Differences")
                .scaledFont(PillVariant.standard.labelFont)
        }
        .foregroundStyle(countCapsule.content)
        .semanticCapsuleSurface(countCapsule)
    }
}
