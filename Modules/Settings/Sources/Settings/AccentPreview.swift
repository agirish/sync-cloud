import Design
import SwiftUI

/// The Appearance tab's accent picker: twelve swatches, a live sample of what the accent actually
/// paints, and a caption naming the choice and where it lands.
///
/// Split out of `AppearanceSettingsTab` and given its hue as a plain value rather than reading
/// `@AppStorage` itself, so the snapshot tests can render a chosen hue without standing up a
/// defaults suite — the storage stays in the tab, which is the only thing that owns a setting.
struct AccentColorSection: View {
    let selectedHue: LiquidGlassHue
    let onSelect: (LiquidGlassHue) -> Void

    var body: some View {
        SettingsSection("Accent color", caption: Self.caption(for: selectedHue)) {
            // Twelve hues share this row; the tighter spacing gives each swatch more room.
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
            AccentPreviewStrip(hue: selectedHue)
        }
    }

    /// The caption, in the idiom the neighbouring sections use (`AppearanceMode.detail`,
    /// `GlassLevel.detail`): name the current value, then say what it does. This section was the
    /// only one on the tab that never said what it changed.
    ///
    /// The three uses named are the three that exist, checked rather than assumed: filled controls
    /// (`PaneActionBar`'s transfer buttons, `DestinationPicker`'s selected rail row), the pane
    /// selection wash (`FileTreeView`), and the seam chrome (`ContentView`'s swap button and rail
    /// spine). The tint wash is deliberately not listed — it has its own section and its own
    /// caption directly below.
    ///
    /// `.none` keeps all three of those uses — they resolve `Color.accentColor`, the macOS accent,
    /// because `LiquidGlassHue.none.accentColor` IS the system accent (the selection wash paints
    /// `glassHue.accentColor` like everything else; see `FileTreeView.rowSelectionBackground`).
    /// What `.none` actually removes is the glass background: its `gradientColors` are clear and
    /// the surface tint wash opts out. An earlier caption said "the panes get no wash", which
    /// described the background but read as a claim about SELECTION — false, and exactly the kind
    /// of unexplained mismatch the strip below would then appear to contradict.
    static func caption(for hue: LiquidGlassHue) -> String {
        guard hue != .none else {
            // `.none` is not "no accent anywhere": it defers to the system accent, which is why
            // the strip below still renders a filled button. Saying so is the whole job of this
            // case — an unexplained coloured button under a swatch labelled "None" reads as a bug.
            return "None. Filled controls, selection, and the seam chrome follow your macOS accent color; the glass background is not tinted."
        }
        return "\(hue.displayName). Used for filled controls, selection, and the seam chrome."
    }
}

/// A live sample of the accent in use: the pane action bar's filled transfer button beside the
/// differences count pill, on a neutral ground.
///
/// Both chips are the SHIPPING components, not lookalikes — `ActionBarButtonStyle` at `.primary`
/// and `SemanticCapsuleStyle.onAccent`, reached through Design. That is the point of the strip
/// rather than a nicety: a hand-drawn preview would be free to show a livelier pairing than the
/// app can actually render, and the pairing is exactly what a user is here to judge.
///
/// **Previews the SELECTED hue, never the hovered one.** Hover-preview is livelier and was
/// rejected: the strip would then show something that is not the current setting, so a glance
/// away from the pointer reports the wrong answer, and sweeping twelve swatches to read the
/// captions would strobe the whole section. Selected-only is always true.
struct AccentPreviewStrip: View {
    let hue: LiquidGlassHue

    /// Exactly what `DifferencesView.countPillDressing` builds for the count pill in every state:
    /// the DEEPENED accent carrying a white label. The raw `accentColor` renders a brighter, more
    /// appealing capsule and strands white on it at 2.68:1 — see `AccentFill`. A preview showing a
    /// pairing the app cannot ship is worse than no preview, so this reads the same two properties
    /// the app does and `AccentPreviewTests` pins that it still does.
    private var countCapsule: SemanticCapsuleStyle {
        .onAccent(fill: hue.accentFillColor, label: hue.onAccentLabelColor)
    }

    var body: some View {
        // 12pt, wider than the 8pt these would get in a real bar. The two chips carry the SAME
        // fill — the count pill wears a solid accent capsule in every state, not the tint wash an
        // older mockup drew — and in the app they never sit together, one being in the pane action
        // bar and the other in the differences header. Butted up at bar spacing they read as one
        // block of colour; this is the gap that keeps them two samples.
        HStack(spacing: 12) {
            transferButton
            countPill
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(ActionBarMetrics.outlineStrokeOpacity),
                              lineWidth: PillVariant.strokeWidth)
        )
        // Hugs its content instead of stretching: a full-width ground would read as a container
        // the section's controls live in rather than as one sample sitting under them.
        .fixedSize()
        // One element, and not a pair of controls: these are pictures of controls. Left in the
        // tree (rather than hidden) because the sample is the section's answer to "what does this
        // change?", and read as a sample so VoiceOver never offers a button that does nothing.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(for: hue))
    }

    /// The strip's spoken label, with the same `.none` branch `AccentColorSection.caption(for:)`
    /// takes and for the same reason: "None accent on a filled button" is the self-contradiction
    /// the sighted caption special-cases — VoiceOver users were the only ones still getting it.
    /// A static helper rather than an inline ternary so `AccentPreviewTests` pins the branch.
    static func accessibilityLabel(for hue: LiquidGlassHue) -> String {
        guard hue != .none else {
            return "Preview: your macOS accent color on a filled button and a count pill."
        }
        return "Preview: \(hue.displayName) accent on a filled button and a count pill."
    }

    /// `PaneActionBar`'s transfer button, to the property: it passes
    /// `AccentFill.deepened(glassHue.accentColor)` as the tint, which IS `accentFillColor`.
    ///
    /// `.primary` deepens its tint internally, so handing it the already-deepened fill is a no-op
    /// rather than a double-darkening — `AccentFill.deepened` never lightens and returns an
    /// already-dark colour unchanged. Passing the deepened value anyway keeps this call readable
    /// as "the fill the app paints", and keeps the hover shadow the same colour the app's is.
    private var transferButton: some View {
        Button(action: {}) {
            // "arrow.right" is `TransferGlyph.copy(toRight:)` — spelled out because that type
            // lives in FileExplorer, which Settings does not depend on.
            Label("Copy 12 to iCloud", systemImage: "arrow.right")
        }
        .buttonStyle(.actionBar(.primary,
                                tint: hue.accentFillColor,
                                onTint: hue.onAccentLabelColor))
        // Inert, but NOT `.disabled` — a disabled control drops to
        // `ActionBarMetrics.disabledOpacity`, which would show the user a washed-out version of
        // the colour they are choosing. Blocking hit-testing keeps it at full strength and also
        // keeps the pointer from lifting/re-inking a button that has nothing to do.
        .allowsHitTesting(false)
        // …and out of the keyboard focus order too. `allowsHitTesting` only blocks the POINTER,
        // and `accessibilityElement(children: .ignore)` on the strip only hides the button from
        // assistive readers — Full Keyboard Access still tabbed onto it, landing focus on a
        // control VoiceOver was just told does not exist, where Space fired the empty action.
        // `.focusable(false)` closes exactly that third path. Outside the button style on
        // purpose: styles decorate focus, they do not grant it, so the modifier composes.
        .focusable(false)
    }

    /// The differences count pill: `StatPill`'s semantic path, which is a number, a label and the
    /// flat accent capsule — no leading glyph, no chevron. Hand-assembled from the same Design
    /// constants `StatPill` uses because `StatPill` itself is in FileExplorer; the capsule surface
    /// underneath is literally the same modifier (`semanticCapsuleSurface`).
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
