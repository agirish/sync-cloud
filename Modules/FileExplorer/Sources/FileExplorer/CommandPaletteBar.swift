import SwiftUI
import AppKit
import Design

/// How much of itself the toolbar's search pill can afford to show.
///
/// Two rungs and no third: the ⌘K key is what the control is *for* — the whole argument for putting
/// it on the toolbar at all is that a chord nobody knows about is a chord nobody uses — so a
/// glyph-only rung that dropped the key would leave a magnifier that teaches nothing and does not
/// even search where a magnifier normally does (the panes' ⌘F does that). The word goes first.
public enum CommandPaletteBarStyle: Equatable, Sendable {
    /// Magnifier, the word, and the key.
    case full
    /// Magnifier and the key.
    case compact
}

/// The pill's width arithmetic, pure so the toolbar's shedding ladder can be asserted without
/// laying out a toolbar — the same reason `WorkspaceBarMetrics` exists, and the same failure it
/// guards: a toolbar that does not fit does not truncate, macOS folds the overflow behind a
/// chevron, and a control that is *there but behind a chevron* is a control nobody finds.
public enum CommandPaletteBarMetrics {

    /// The capsule's inset, both edges.
    public static let horizontalPadding: CGFloat = 9
    /// 6, not 4. At 4 the keycap — which is 24pt tall on its own — filled 75%% of the tray and the
    /// compact rung read as a key jammed into something too small for it. Vertical padding costs
    /// the row nothing, since the shedding ladder spends width.
    public static let verticalPadding: CGFloat = 6
    /// The magnifier.
    public static let glyphWidth: CGFloat = 14
    /// Between the glyph, the word and the key.
    public static let contentGap: CGFloat = 7
    /// The gap the `Spacer` holds open between the word and the key, so a search pill reads as a
    /// field with a key parked at its trailing end rather than as three things in a row.
    public static let keyGap: CGFloat = 14

    /// The ⌘K keycap's own width: `ShortcutKeycap` pads a monospaced subheadline by 8pt a side.
    ///
    /// Measured through `NSFont` rather than tabulated, for the reason the workspace bar's labels
    /// are: the app scales its own type, so a constant would be right at exactly one Settings ▸
    /// Text size — and this one is charged into the *reserve* the workspace bar sheds against, so
    /// under-measuring it is what pushes the whole toolbar behind the chevron.
    public static func keycapWidth(symbol: String, scale: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 13 * scale, weight: .semibold)
        let text = (symbol as NSString).size(withAttributes: [.font: font]).width
        return text + 2 * ShortcutKeycapMetrics.horizontalPadding
    }

    /// How much wider SwiftUI draws the word than `NSString.size` reports for the same font.
    ///
    /// **Measured, not padded for luck**: rendered and read back, the full pill came out 135.5pt
    /// against 125.4pt of arithmetic, and every point of that gap is in the label — the compact
    /// rung, which has no label, agreed to within 2pt. `Text` and `NSString.size` disagree about
    /// tracking (and about the ellipsis), and the direction matters: **under-measuring is what
    /// folds the toolbar behind macOS's overflow chevron**, so the estimate is deliberately a few
    /// points generous rather than exact. `theArithmeticMatchesWhatIsDrawn` holds both ends.
    public static let labelSafetyMargin: CGFloat = 14

    /// The word's rendered width at this text scale, plus ``labelSafetyMargin``.
    public static func labelWidth(_ label: String, scale: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12 * scale, weight: .regular)
        return (label as NSString).size(withAttributes: [.font: font]).width
            + labelSafetyMargin * scale
    }

    /// What the pill occupies in this style.
    public static func width(style: CommandPaletteBarStyle, labelWidth: CGFloat,
                             keycapWidth: CGFloat) -> CGFloat {
        let fixed = 2 * horizontalPadding + glyphWidth + contentGap + keycapWidth
        switch style {
        case .compact: return fixed
        case .full: return fixed + labelWidth + keyGap
        }
    }
}

/// The toolbar's search pill: what ⌘K looks like when you are not holding ⌘K.
///
/// **A button that looks like a field, not a field.** Typing here would mean a second query living
/// beside the palette's own, and two fields answering one question is how they drift; the palette
/// is one keystroke (or one click) away and owns the query, the results and the routing. So this is
/// an affordance: it says the app has a search, says which key opens it, and opens it.
///
/// **The key is drawn at rest, and that is the one place this app does that.** Every other badged
/// control shows its chord only under the ⌥-hold reveal, which is right for a control you can
/// already see and click. The palette is the opposite case — it has no on-screen surface of its
/// own, so a chord revealed only to someone already holding ⌥ teaches it to nobody. That is the
/// same argument ROADMAP 14 makes for the palette existing: a user who thinks "rename" needs
/// something to aim at. Consequently this view does **not** take `.shortcutKeycap(_:)` — that
/// modifier fades the control and centres a key on it, which over an already-visible key would
/// draw ⌘K on top of ⌘K.
public struct CommandPaletteBar: View {

    let style: CommandPaletteBarStyle
    /// The chord, in the form a user reads it — passed in rather than reached for, so the bar and
    /// the menu item cannot disagree about which key opens the palette.
    let chord: String
    let action: () -> Void

    public init(style: CommandPaletteBarStyle, chord: String, action: @escaping () -> Void) {
        self.style = style
        self.chord = chord
        self.action = action
    }

    /// The word. Not "Search": this control does not search the panes — ⌘F does, and a magnifier
    /// labelled *Search* beside a window full of files promises exactly that. "Go to" names what
    /// the palette is: places, folders, people, actions.
    public static let label = "Go to…"

    public var body: some View {
        Button(action: action) {
            HStack(spacing: CommandPaletteBarMetrics.contentGap) {
                Image(systemName: "magnifyingglass")
                    .scaledFont(.system(size: 12, weight: .medium))
                    .frame(width: CommandPaletteBarMetrics.glyphWidth)
                if style == .full {
                    Text(Self.label)
                        .scaledFont(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: CommandPaletteBarMetrics.keyGap)
                }
                ShortcutKeycap(chord)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, CommandPaletteBarMetrics.horizontalPadding)
            .padding(.vertical, CommandPaletteBarMetrics.verticalPadding)
            .contentShape(Capsule())
        }
        // The workspace bar's own container wash, because this sits beside it and the two are the
        // same kind of thing — a resting surface in the toolbar, not a raised button.
        .background(Capsule().fill(.quaternary.opacity(0.5)))
        .buttonStyle(.plain)
        .chromeHover()
        .fixedSize()
        .help(ShortcutHint.tooltip("Go to a place, folder, person or action", chord))
        .accessibilityLabel("Command palette")
        // Said out loud, because the badge is decoration to a screen reader: `ShortcutKeycap` is
        // `accessibilityHidden`, deliberately, so without this the one control whose entire job is
        // to advertise a chord would advertise it to everyone except the people who most need the
        // announcement. The same sentence `.shortcutKeycap(_:)` applies for every other control.
        .accessibilityHint("Keyboard shortcut: \(ShortcutKeycapSpeech.spoken(chord))")
    }
}
