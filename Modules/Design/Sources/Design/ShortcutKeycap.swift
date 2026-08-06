import SwiftUI

// MARK: - Shortcut keycap
//
// The badge half of the ⌥-hold reveal (`ShortcutReveal.swift` owns the state). One modifier,
// `.shortcutKeycap(_:)`, so every adopter renders identically and there is exactly one place to
// restyle — the same rule `HoverAffordanceStyle` follows for hover.
//
// Two invariants this file exists to hold:
//
// 1. **Zero layout shift.** The keycap is drawn in an `.overlay`, which is sized by its host and
//    never contributes to it. A badged control's frame is pixel-identical with the reveal on and
//    off, so nothing moves or resizes under a settled pointer. `ShortcutKeycapTests` measures it
//    rather than trusting it.
// 2. **The shortcut reaches assistive tech unconditionally.** The *visual* gating is a
//    decluttering choice for people looking at the screen; a VoiceOver user has no ⌥-hold to
//    discover. So the accessibility hint is applied whether or not the reveal is active, from the
//    same call site — one modifier, both channels, impossible to adopt half of.

/// Every number the keycap paints, in one place so they can be asserted without rendering.
public enum ShortcutKeycapMetrics {
    public static let cornerRadius: CGFloat = 6
    public static let horizontalPadding: CGFloat = 8
    public static let verticalPadding: CGFloat = 4
    public static let borderWidth: CGFloat = 0.75

    /// How far the control itself fades back while its keycap is showing.
    ///
    /// This is what makes the reveal read as an answer rather than as a collision. The keycap used
    /// to be a small chip anchored to the control's trailing edge, and on anything whose content
    /// already fills it — which is every control — that lands the chip ON the content: half over
    /// the last word of "Copy 1 to Dropbox", or squarely on top of a 15pt magnifier glyph, which
    /// looked like a rendering fault rather than a badge. Partial occlusion always does.
    ///
    /// Fading the whole control and centring an opaque key on it occludes nothing partially: the
    /// control steps back, the key steps forward, and both are legible for what they are. Low
    /// enough that the label underneath cannot be misread as still-active, high enough that the
    /// control's shape, position and colour are all still there.
    public static let contentOpacity: Double = 0.13

    /// Alpha of the drop shadow that lifts the key off the control — see `ShortcutKeycap.body`.
    public static let shadowOpacity: Double = 0.28
}

/// The badge itself. Rendered only while the reveal is active; see `.shortcutKeycap(_:)`.
///
/// **Opaque, and appearance-semantic rather than tinted.** It used to come in two variants so its
/// contrast could be reasoned about against whatever fill it sat on — a translucent chip on a
/// deepened accent, a different one elsewhere. An opaque key needs none of that: its legibility is
/// a property of the key itself, `labelColor` on `controlBackgroundColor`, which AppKit pairs and
/// which holds on a blue button, a white sheet and a dark window alike. One appearance everywhere
/// is also what a key *is* — keys do not change colour with what they are sitting on.
public struct ShortcutKeycap: View {
    private let symbol: String

    public init(_ symbol: String) {
        self.symbol = symbol
    }

    public var body: some View {
        Text(symbol)
            .scaledFont(.subheadline.monospaced().weight(.semibold))
            // Pinned colours, not `.secondary`/`.quaternary`. Hierarchical styles resolve against
            // the *enclosing* foreground style, which inside a filled button is white — so the
            // hierarchical version rendered a white glyph on a light key the moment it was dropped
            // onto the primary transfer button.
            .foregroundStyle(Color(nsColor: .labelColor))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, ShortcutKeycapMetrics.horizontalPadding)
            .padding(.vertical, ShortcutKeycapMetrics.verticalPadding)
            .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor),
                                        lineWidth: ShortcutKeycapMetrics.borderWidth))
            // Lifts the key off the control it is sitting on. Needed most in LIGHT mode, where the
            // faded control cannot get out of the way on its own: a white label on a coloured fill
            // converges to the white ground as it fades, so the letterforms stay visible as
            // negative space no matter how far the fade goes. The shadow is what still separates
            // "key on top" from "key embedded in the label" there. Dark mode fades properly and
            // barely needs it.
            .shadow(color: .black.opacity(ShortcutKeycapMetrics.shadowOpacity), radius: 2.5, y: 1)
            // Not a hit target and not a second thing to announce: the shortcut reaches VoiceOver
            // through the hint the modifier applies to the CONTROL, where it belongs.
            //
            // `allowsHitTesting(false)` is load-bearing — a SwiftUI overlay takes hits by default,
            // and this one sits ON the control it describes, so without it the badge would swallow
            // the click on exactly the button whose shortcut you just looked up.
            //
            // **Asserted by construction, not by test, and deliberately so.** A test was written
            // for it and deleted: `NSHostingView.hitTest` does not decompose a SwiftUI overlay into
            // its own view, so it returns the hosting view whether or not this line is here — the
            // test passed with `allowsHitTesting(true)` and was proving nothing.
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
    /// control's frame never changes. Pass the shortcut in the form a user reads it (`"⌘R"`,
    /// `"⇧⌘→"`, `"esc"`), which is also what the accessibility hint says.
    ///
    /// **Apply this ABOVE any `.disabled(…)` on the control**, so the modifier sits inside that
    /// scope and can read `isEnabled` — the same ordering rule `ChromeHoverModifier` documents,
    /// and for the same reason: a badge on a greyed-out button advertises a shortcut that does
    /// nothing when you press it.
    func shortcutKeycap(_ symbol: String) -> some View {
        modifier(ShortcutKeycapModifier(symbol: symbol))
    }
}

private struct ShortcutKeycapModifier: ViewModifier {
    let symbol: String

    @Environment(\.shortcutRevealActive) private var isRevealActive
    /// A disabled control's shortcut does not fire, so it must not advertise one. Same guard, and
    /// the same reasoning, as `HoverAffordanceMetrics.resolve`'s `isEnabled` check.
    @Environment(\.isEnabled) private var isEnabled

    private var showsKeycap: Bool { isRevealActive && isEnabled }

    func body(content: Content) -> some View {
        content
            // The control steps back so the key can be read against it rather than on top of it.
            // Opacity, never `.hidden()` or a branch: both would take the control out of the
            // layout and move everything beside it.
            .opacity(showsKeycap ? ShortcutKeycapMetrics.contentOpacity : 1)
            // `.overlay` and not an `HStack`: an overlay takes its size FROM the host and gives
            // none back, which is the zero-layout-shift guarantee in one modifier. The ternary
            // swaps only what the overlay draws, never whether the overlay exists, so the host's
            // measured size cannot depend on the reveal.
            //
            // Centred, with no alignment choice offered. A trailing anchor was the first design and
            // it is wrong for every control the app actually has: it lands the key ON the content
            // rather than beside it, because the content already fills the control. Centring is
            // also the only placement that cannot overhang asymmetrically onto a neighbour.
            .overlay {
                if showsKeycap {
                    ShortcutKeycap(symbol).transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: showsKeycap)
            // Ungated by the reveal, on purpose — see the file header. Applied to a DISABLED
            // control too: "this button has a shortcut" stays true of the control even when it is
            // momentarily unavailable, and unlike the badge it makes no promise about right now.
            //
            // Ordering note: on macOS `.help(_:)` and `.accessibilityHint(_:)` both land on the
            // element's accessibility help, so whichever is applied OUTERMOST wins. Every adopter
            // puts `.help` outside this modifier and every adopter's help text names the shortcut,
            // so the shortcut survives either way — but a call site that applied `.help` *inside*
            // would lose its description to this line. Keep `.help` outside.
            .accessibilityHint("Keyboard shortcut: \(ShortcutKeycapSpeech.spoken(symbol))")
    }
}

// MARK: - Tooltips

/// The tooltip half of the story, which is **not** gated on the reveal.
///
/// A tooltip is already an on-demand surface — you asked for it by resting the pointer — so there
/// is nothing to declutter, and it is the discovery path for everyone who never finds the ⌥ hold.
/// Every badged control's `.help(_:)` runs through here so the form stays uniform.
public enum ShortcutHint {
    /// `"Rescan   ⌘R"`. Three spaces rather than a separator: macOS tooltips are plain strings
    /// with no columns to align to, and the gap is what reads as one.
    public static func tooltip(_ description: String, _ symbol: String) -> String {
        "\(description)   \(symbol)"
    }
}

// MARK: - Speech

/// Turns a displayed shortcut into something VoiceOver reads as words.
///
/// The glyphs are the correct thing to *show* and close to useless to *speak*: a bare "⇧⌘→" is
/// announced as its Unicode names or skipped entirely, depending on the voice. This is a plain
/// substitution table rather than anything clever, and it stays in the Design module beside the
/// keycap so the two forms of one shortcut cannot drift apart.
public enum ShortcutKeycapSpeech {
    /// Ordered longest glyph first, so a multi-character name can never be half-eaten by a
    /// single-character rule that runs before it. Nothing in the table overlaps today — the
    /// modifier symbols are all one scalar and `esc` shares no character with them — so the order
    /// is insurance rather than load-bearing. It is stated and held anyway, because the failure it
    /// prevents is silent: a wrong substitution produces speech, just not the right speech.
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
        ("⏎", "Return"),
        ("␣", "Space"),
        ("⌫", "Delete"),
        ("⇥", "Tab"),
        // Punctuation keys, named. A bare "." or "," in the hint is sentence punctuation to a
        // voice — "Command ." is announced as just "Command", which is a shortcut that doesn't
        // exist. Letters and digits need no entry; every punctuation key badged anywhere does.
        ("[", "Left Bracket"),
        ("]", "Right Bracket"),
        (".", "Period"),
        (",", "Comma"),
        ("/", "Slash"),
    ]

    public static func spoken(_ symbol: String) -> String {
        var text = symbol
        for (glyph, spoken) in names {
            text = text.replacingOccurrences(of: glyph, with: spoken)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
