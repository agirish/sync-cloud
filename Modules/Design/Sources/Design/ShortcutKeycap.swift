import SwiftUI

// MARK: - Shortcut keycap
//
// The badge half of the ⌥-hold reveal (`ShortcutReveal.swift` owns the state). One modifier,
// `.shortcutKeycap(_:)`, so every adopter renders identically and there is one place to restyle,
// as `HoverAffordanceStyle` is for hover. It holds two invariants:
//
// 1. Zero layout shift. The keycap is drawn in an `.overlay`, sized by its host and never
//    contributing to it, so a badged control's frame is identical with the reveal on and off
//    (`ShortcutKeycapTests` measures it).
// 2. The shortcut reaches assistive tech unconditionally. The visual gating declutters the screen,
//    but a VoiceOver user has no ⌥-hold to discover, so the hint is applied whether or not the
//    reveal is active, from the same modifier.

/// Every number the keycap paints, in one place so they can be asserted without rendering.
public enum ShortcutKeycapMetrics {
    public static let cornerRadius: CGFloat = 6
    public static let horizontalPadding: CGFloat = 8
    public static let verticalPadding: CGFloat = 4
    public static let borderWidth: CGFloat = 0.75

    /// How far the control itself fades back while its keycap is showing. Content fills every
    /// control, so a badge anchored to an edge lands on the content, and partial occlusion looks
    /// like a rendering fault. Fading the whole control and centring an opaque key on it occludes
    /// nothing partially. Low enough that the label can't be misread as still active, high enough
    /// that the control's shape, position and colour still show.
    public static let contentOpacity: Double = 0.13

    /// Alpha of the drop shadow that lifts the key off the control — see `ShortcutKeycap.body`.
    public static let shadowOpacity: Double = 0.28

    /// The compact key's padding, for a row of glyph buttons packed closer than the full key is
    /// wide: the format bar's B, I and S sit 27pt apart and "⇧⌘X" is wider, so two full keys would
    /// meet over the button between them. Smaller type and less padding, still the same opaque key.
    public static let compactHorizontalPadding: CGFloat = 3
    public static let compactVerticalPadding: CGFloat = 2
}

/// The badge itself. Rendered only while the reveal is active; see `.shortcutKeycap(_:)`.
///
/// Opaque and appearance-semantic rather than tinted: `labelColor` on `controlBackgroundColor`,
/// which AppKit pairs, holds on a blue button, a white sheet and a dark window alike, so its
/// legibility doesn't depend on the fill below. Keys don't change colour with what they sit on.
public struct ShortcutKeycap: View {
    private let symbol: String
    private let compact: Bool

    /// `compact`: the smaller key, for a control whose neighbours are closer than the full key is
    /// wide — see ``ShortcutKeycapMetrics/compactHorizontalPadding``.
    public init(_ symbol: String, compact: Bool = false) {
        self.symbol = symbol
        self.compact = compact
    }

    public var body: some View {
        Text(symbol)
            .scaledFont(compact ? .caption2.monospaced().weight(.semibold)
                                : .subheadline.monospaced().weight(.semibold))
            // Pinned colours, not `.secondary`/`.quaternary`: hierarchical styles resolve against
            // the enclosing foreground style, which inside a filled button is white, giving a white
            // glyph on a light key.
            .foregroundStyle(Color(nsColor: .labelColor))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, compact ? ShortcutKeycapMetrics.compactHorizontalPadding
                                          : ShortcutKeycapMetrics.horizontalPadding)
            .padding(.vertical, compact ? ShortcutKeycapMetrics.compactVerticalPadding
                                        : ShortcutKeycapMetrics.verticalPadding)
            .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor),
                                        lineWidth: ShortcutKeycapMetrics.borderWidth))
            // Lifts the key off the control. Needed most in light mode: a white label on a coloured
            // fill converges to the white ground as it fades, so its letterforms stay visible as
            // negative space, and the shadow is what separates the key from the label. Dark mode
            // fades properly and barely needs it.
            .shadow(color: .black.opacity(ShortcutKeycapMetrics.shadowOpacity), radius: 2.5, y: 1)
            // Not a hit target and not a second thing to announce: VoiceOver gets the shortcut
            // through the hint the modifier applies to the control.
            //
            // `allowsHitTesting(false)` is load-bearing: a SwiftUI overlay takes hits by default,
            // and this one sits on the control it describes, so it would swallow the click on the
            // very button whose shortcut was looked up. No test can pin it: `NSHostingView.hitTest`
            // doesn't decompose a SwiftUI overlay, so it returns the hosting view either way.
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ShortcutKeycapMetrics.cornerRadius, style: .continuous)
    }
}

// MARK: - The adopter's modifier

public extension View {
    /// Badges this control with `symbol` while the ⌥-hold reveal is active, and names the same
    /// shortcut to VoiceOver unconditionally.
    ///
    /// While the reveal is on, the control fades back and an opaque key sits centred on it; the
    /// control's frame never changes. Pass the shortcut as a user reads it (`"⌘R"`, `"⇧⌘→"`,
    /// `"esc"`), which is also what the accessibility hint says.
    ///
    /// **Apply this above any `.disabled(…)` on the control**, so the modifier sits inside that
    /// scope and can read `isEnabled` (the ordering rule `ChromeHoverModifier` documents): a badge
    /// on a greyed-out button advertises a shortcut that does nothing.
    ///
    /// `symbol` is optional for a control that only sometimes has a chord, such as a rung that
    /// swaps between a bound and an unbound action. `nil` means no badge: `""` would draw a blank
    /// capsule (the trap `.help("")` sets one layer over), and applying the modifier conditionally
    /// at the call site would give the two arms two structural identities, unsafe for a control
    /// that holds state.
    ///
    /// `compact` draws the smaller key, for a control packed close among others that wear one.
    /// `shown: false` keeps the badge off while the chord would go elsewhere (the format bar's ⌘I
    /// is Italic only with the caret in the text) and keeps the VoiceOver hint, which names the
    /// control's key, not where the keyboard is.
    func shortcutKeycap(_ symbol: String?, compact: Bool = false, shown: Bool = true) -> some View {
        modifier(ShortcutKeycapModifier(symbol: symbol, compact: compact, shown: shown))
    }
}

private struct ShortcutKeycapModifier: ViewModifier {
    /// `nil` for a control with no chord right now. It suppresses the badge and the hint together:
    /// a control with no shortcut must not announce one to VoiceOver either.
    let symbol: String?
    var compact = false
    /// The call site's own condition for the badge — see `shortcutKeycap(_:compact:shown:)`.
    var shown = true

    @Environment(\.shortcutRevealActive) private var isRevealActive
    /// A disabled control's shortcut does not fire, so it must not advertise one. Same guard, and
    /// the same reasoning, as `HoverAffordanceMetrics.resolve`'s `isEnabled` check.
    @Environment(\.isEnabled) private var isEnabled

    private var showsKeycap: Bool { symbol != nil && shown && isRevealActive && isEnabled }

    func body(content: Content) -> some View {
        content
            // The control steps back so the key reads against it rather than on top of it.
            // Opacity, never `.hidden()` or a branch: both would take the control out of the layout
            // and move everything beside it.
            .opacity(showsKeycap ? ShortcutKeycapMetrics.contentOpacity : 1)
            // `.overlay`, not an `HStack`: an overlay takes its size from the host and gives none
            // back, which is the zero-layout-shift guarantee. The condition swaps only what the
            // overlay draws, never whether it exists, so the host's size can't depend on the reveal.
            //
            // Centred, with no alignment option: content fills every control, so any other anchor
            // lands the key on the content, and only centring can't overhang onto one neighbour.
            .overlay {
                if showsKeycap, let symbol {
                    ShortcutKeycap(symbol, compact: compact).transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: showsKeycap)
            // Ungated by the reveal (see the file header), and applied to a disabled control too:
            // "this button has a shortcut" stays true while it is momentarily unavailable, and
            // unlike the badge the hint promises nothing about right now.
            //
            // On macOS `.help(_:)` and `.accessibilityHint(_:)` both land on the element's
            // accessibility help, so the outermost wins. Keep `.help` outside this modifier: one
            // applied inside would lose its description to this line.
            .accessibilityHint(symbol.map { "Keyboard shortcut: \(ShortcutKeycapSpeech.spoken($0))" } ?? "")
    }
}

// MARK: - Tooltips

/// The tooltip half, which is not gated on the reveal. A tooltip is already on demand, so there
/// is nothing to declutter, and it is how people who never find the ⌥ hold discover shortcuts.
/// Every badged control's `.help(_:)` runs through here so the form stays uniform.
public enum ShortcutHint {
    /// `"Rescan   ⌘R"`. Three spaces rather than a separator: macOS tooltips are plain strings
    /// with no columns to align to, and the gap is what reads as one.
    public static func tooltip(_ description: String, _ symbol: String) -> String {
        "\(description)   \(symbol)"
    }
}

// MARK: - Speech

/// Turns a displayed shortcut into words VoiceOver reads: a bare "⇧⌘→" is announced as Unicode
/// names or skipped, depending on the voice. A plain substitution table, kept beside the keycap so
/// the two forms of one shortcut can't drift apart.
public enum ShortcutKeycapSpeech {
    /// Ordered longest glyph first, so a multi-character name can't be half-eaten by a
    /// single-character rule before it. Nothing overlaps now, but a wrong substitution fails
    /// silently, producing speech that just isn't the right speech, so the order is kept.
    private static let names: [(glyph: String, spoken: String)] = [
        ("esc", "Escape"),
        ("⇧", "Shift "),
        ("⌘", "Command "),
        ("⌥", "Option "),
        ("⌃", "Control "),
        ("→", "Right Arrow"),
        ("←", "Left Arrow"),
        ("↑", "Up Arrow"),
        ("↓", "Down Arrow"),
        // ↩ is the Return key everywhere it is drawn, as macOS menus draw it; ⏎ stays named for
        // any badge that still spells it the other way.
        ("↩", "Return"),
        ("⏎", "Return"),
        ("␣", "Space"),
        ("⌫", "Delete"),
        ("⇥", "Tab"),
        ("←", "Left Arrow"),
        ("→", "Right Arrow"),
        // Punctuation keys, named. A bare "." or "," in the hint is sentence punctuation to a
        // voice — "Command ." is announced as just "Command", which is a shortcut that doesn't
        // exist. Letters and digits need no entry; every punctuation key badged anywhere does.
        ("[", "Left Bracket"),
        ("]", "Right Bracket"),
        (".", "Period"),
        (",", "Comma"),
        ("/", "Slash"),
        // View ▸ Text Size. The minus is U+2212 — what `AppChord.display` renders for the "-" key —
        // not the hyphen, which no chord badges.
        ("+", "Plus"),
        ("−", "Minus"),
    ]

    public static func spoken(_ symbol: String) -> String {
        var text = symbol
        for (glyph, spoken) in names {
            text = text.replacingOccurrences(of: glyph, with: spoken)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
