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
    ///
    /// **Kept to one line at the settings column's 547pt**, which is a layout constraint on the
    /// prose and not a style note. Appearance is the tab that has to fit a small display's
    /// clamped opening, and it has ~13pt of margin there — a caption line is ~13pt, so a
    /// two-line caption here is the whole budget. The version this replaced ran 121 characters
    /// and wrapped, putting a `.none` user's tab at exactly its opening with zero margin while
    /// every fit test measured the default hue and saw nothing. `appearanceFitsEveryAccentHue`
    /// now measures the worst case; the one-line budget is about 108 characters, and the right
    /// response to exceeding it is to shorten the sentence, not to widen the test.
    static func caption(for hue: LiquidGlassHue) -> String {
        guard hue != .none else {
            // `.none` is not "no accent anywhere": it defers to the system accent, which is why
            // the strip below still renders a filled button. Saying so is the whole job of this
            // case — an unexplained coloured button under a swatch labelled "None" reads as a bug.
            // "The glass stays untinted" is the short form of what the doc comment above records
            // in full: `gradientColors` are clear AND the surface tint wash opts out.
            //
            // 98 characters — ONE line at the 11pt caption size in the 547pt column. The longer
            // form wrapped to a second line, which was exactly the worst-case 14pt that put a
            // `.none` user's tab over a 1280×800 display's clamped opening. Measure before
            // lengthening.
            return "None. Filled controls, selection, and seam chrome use your macOS accent; the glass stays untinted."
        }
        return "\(hue.displayName). Used for filled controls, selection, and the seam chrome."
    }
}

/// A live sample of the accent in use: the pane action bar's filled transfer button beside the
/// differences count pill, on a neutral ground.
///
/// Both chips are the SHIPPING surfaces, not lookalikes — `actionBarButtonSurface(.primary…)`,
/// which is the paint `ActionBarButtonStyle` puts on a real button, and `semanticCapsuleSurface`
/// with `SemanticCapsuleStyle.onAccent`. That is the point of the strip rather than a nicety: a
/// hand-drawn preview would be free to show a livelier pairing than the app can actually render,
/// and the pairing is exactly what a user is here to judge.
///
/// Both are surfaces rather than controls, which is the other half of the design: neither chip is
/// a `Button`, so neither is reachable by pointer, keyboard, or assistive reader by construction
/// rather than by modifiers that switch those paths off one at a time.
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
        // 5, not the 8 the strip landed with: 6 of the ~34pt Appearance gave back to fit a
        // 1280×800-class display's clamped opening (see `SettingsSheetMetrics.baseSize`). The
        // chips keep their full size — only their ground tightens — and the AccentPreviewTests
        // sample points (5pt inside each capsule's edge, at mid-height) stay inside the paint.
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
    /// as "the fill the app paints".
    ///
    /// **There is no `Button` here, by construction.** The chip is a picture of a control, and the
    /// only thing that makes it one is `ActionBarButtonSurface` — the paint `.actionBar(.primary…)`
    /// puts on a real button, pinned at its resting phase. A view that was never a button has no
    /// input path to close.
    ///
    /// That replaced three modifiers talking an inert `Button` out of three separate paths:
    /// `allowsHitTesting(false)` for the pointer, the strip's `accessibilityElement(children:
    /// .ignore)` for assistive readers, and `.focusable(false)` for Full Keyboard Access, which
    /// otherwise tabbed onto a control VoiceOver was just told did not exist and fired its empty
    /// action on Space. The last one was the reason to do this: it was the repo's only
    /// `.focusable(false)`, its behaviour could only be trusted rather than asserted (an offscreen
    /// `NSHostingView` has an empty accessibility tree and no key window to walk focus through),
    /// and a MANUAL_CHECKS.md entry was carrying the whole verification. None of the three is
    /// needed now, and none can silently stop working.
    ///
    /// Note it is still not `.disabled`: the surface honours `isEnabled` and would drop to
    /// `ActionBarMetrics.disabledOpacity`, showing a washed-out version of the colour being chosen.
    /// It rests at full strength because nothing can press or hover it, not because it is exempt.
    ///
    /// The count pill below is built the same way (`semanticCapsuleSurface`, no `Button` anywhere).
    /// Hand-drawing either one in Settings is the one thing this strip must never do — see the
    /// type's doc comment on why both chips are the SHIPPING components rather than lookalikes.
    private var transferButton: some View {
        // "arrow.right" is `TransferGlyph.copy(toRight:)` — spelled out because that type
        // lives in FileExplorer, which Settings does not depend on.
        Label("Copy 12 to iCloud", systemImage: "arrow.right")
            .actionBarButtonSurface(.primary,
                                    tint: hue.accentFillColor,
                                    onTint: hue.onAccentLabelColor)
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
