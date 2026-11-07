import SwiftUI
import AppKit
import Design

/// How much of itself the toolbar's search pill can afford to show. Two rungs, no third: the ⌘K
/// key is what the control is for, so a glyph-only rung would leave a magnifier that teaches
/// nothing and doesn't search the panes either (⌘F does). The word goes first.
public enum CommandPaletteBarStyle: Equatable, Sendable {
    /// Magnifier, the word, and the key.
    case full
    /// Magnifier and the key.
    case compact
}

/// The pill's width arithmetic, pure so the toolbar's shedding ladder can be tested without a
/// toolbar, as with `WorkspaceBarMetrics`. A toolbar that doesn't fit doesn't truncate: macOS
/// folds the overflow behind a chevron, where nobody finds it.
public enum CommandPaletteBarMetrics {

    /// The capsule's inset, both edges.
    public static let horizontalPadding: CGFloat = 9
    /// 6, not 4: at 4 the 24pt keycap filled 75% of the tray and looked jammed in. Vertical padding
    /// costs the row nothing, since the shedding ladder spends width.
    public static let verticalPadding: CGFloat = 6
    /// The magnifier.
    public static let glyphWidth: CGFloat = 14
    /// Between the glyph, the word and the key.
    public static let contentGap: CGFloat = 7
    /// The gap the `Spacer` holds between the word and the key, so the pill reads as a field with
    /// a key at its trailing end rather than three things in a row.
    public static let keyGap: CGFloat = 14

    /// The ⌘K keycap's own width: `ShortcutKeycap` pads a monospaced subheadline by 8pt a side.
    /// Measured through `NSFont` because the app scales its own type. Measured at 13pt where
    /// `.subheadline` resolves to 11, deliberately over: this is charged into the reserve the
    /// workspace bar sheds against, and under-measuring pushes the toolbar behind the chevron.
    /// `theArithmeticMatchesWhatIsDrawn` holds both ends.
    public static func keycapWidth(symbol: String, scale: CGFloat) -> CGFloat {
        let font = NSFont.checkedMonospacedSystemFont(ofSize: 13 * scale, weight: .semibold)
        let text = (symbol as NSString).size(withAttributes: [.font: font]).width
        return text + 2 * ShortcutKeycapMetrics.horizontalPadding
    }

    /// How much wider SwiftUI draws the word than `NSString.size` reports for the same font: `Text`
    /// and `NSString.size` disagree about tracking and the ellipsis. Rendered, the full pill measured
    /// about 10pt over the arithmetic, all of it in the label. Kept a few points generous, because
    /// under-measuring folds the toolbar behind the overflow chevron.
    /// `theArithmeticMatchesWhatIsDrawn` holds both ends.
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
/// A button that looks like a field, not a field: a second query beside the palette's own would
/// drift from it, and the palette owns the query, results and routing. This says the app has a
/// search, names its key, and opens it.
///
/// The key is drawn at rest, the one place the app does that. Other controls show their chord only
/// under the ⌥-hold reveal, but the palette has no on-screen surface of its own, so a chord shown
/// only to someone holding ⌥ teaches nobody. So this view does **not** take `.shortcutKeycap(_:)`,
/// which would draw ⌘K on top of ⌘K.
public struct CommandPaletteBar: View {

    let style: CommandPaletteBarStyle
    /// The chord as a user reads it, passed in so the bar and the menu item can't disagree about
    /// which key opens the palette.
    let chord: String
    let action: () -> Void

    public init(style: CommandPaletteBarStyle, chord: String, action: @escaping () -> Void) {
        self.style = style
        self.chord = chord
        self.action = action
    }

    /// The word. Not "Search": this control doesn't search the panes (⌘F does), and a magnifier
    /// labelled Search promises that. "Go to" names what the palette is: places, folders, people,
    /// actions.
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
        // The workspace bar's own container wash: this sits beside it and is the same kind of
        // thing, a resting surface rather than a raised button.
        .background(Capsule().fill(.quaternary.opacity(0.5)))
        .buttonStyle(.plain)
        .chromeHover()
        .fixedSize()
        .accessibilityLabel("Command palette")
        // Said out loud, because `ShortcutKeycap` is `accessibilityHidden`: without this the control
        // whose job is to advertise a chord would hide it from screen readers. The same sentence
        // `.shortcutKeycap(_:)` applies elsewhere.
        .accessibilityHint("Keyboard shortcut: \(ShortcutKeycapSpeech.spoken(chord))")
        // `.help` goes outside the hint, the ordering rule `ShortcutKeycap` documents: on macOS
        // both land on the element's accessibility help and the outermost wins. The other way
        // round, the bare chord would replace the tooltip's description.
        .help(ShortcutHint.tooltip("Go to a place, folder, person or action", chord))
    }
}
