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
    public static let cornerRadius: CGFloat = 4
    public static let horizontalPadding: CGFloat = 4
    public static let verticalPadding: CGFloat = 1
    public static let borderWidth: CGFloat = 0.75

    /// How far the keycap is inset from its host's trailing edge.
    public static let trailingInset: CGFloat = 4

    /// Alpha of the black scrim under an on-accent keycap.
    ///
    /// **Darkens, deliberately, and the direction is the whole point.** `accentFillColor` is
    /// already deepened until white clears 4.55:1 on it (`AccentFill.targetLuminance`), so a
    /// *lightened* chip — the obvious "translucent white key" — would push its own backing back up
    /// the luminance curve and drop the white glyph on it below that floor, while every other
    /// label on the same button stayed fine. Scrimming down can only move contrast the good way:
    /// the keycap glyph is guaranteed to be at least as legible as the button's own label, by
    /// construction rather than by measurement.
    public static let onAccentScrim: Double = 0.18

    /// Alpha of the hairline around an on-accent keycap. White, so the key reads as an object on
    /// the fill rather than a hole in it.
    public static let onAccentBorder: Double = 0.55
}

/// Which surface a keycap is sitting on, which is all it needs to know to color itself.
public enum ShortcutKeycapSurface: Sendable {
    /// A control with no strong fill of its own — a glyph button, an outline button, plain chrome.
    case standard
    /// A control that already carries a solid, label-is-white fill: `.actionBar(.primary)`, whose
    /// tint `AccentFill.deepened`s, and `.borderedProminent`, whose bezel AppKit fills with the
    /// system accent and labels in white.
    ///
    /// The two are NOT the same colour, and the keycap does not need them to be. Its guarantee is
    /// *relative* — the scrim only ever darkens, so the white glyph on it is at least as legible as
    /// the white label beside it, whatever the fill underneath. That is why this case can be
    /// applied to a `.borderedProminent` button whose fill is the raw system accent (which the user
    /// may have set to something as light as Yellow) without inheriting a new contrast problem:
    /// it inherits the button's existing one, unchanged, rather than adding to it.
    case accentFill
}

/// The badge itself. Rendered only while the reveal is active; see `.shortcutKeycap(_:)`.
public struct ShortcutKeycap: View {
    private let symbol: String
    private let surface: ShortcutKeycapSurface

    public init(_ symbol: String, surface: ShortcutKeycapSurface = .standard) {
        self.symbol = symbol
        self.surface = surface
    }

    public var body: some View {
        Text(symbol)
            .scaledFont(.caption2.monospaced().weight(.medium))
            .foregroundStyle(labelStyle)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, ShortcutKeycapMetrics.horizontalPadding)
            .padding(.vertical, ShortcutKeycapMetrics.verticalPadding)
            .background(shape.fill(fillStyle))
            .overlay(shape.strokeBorder(borderStyle, lineWidth: ShortcutKeycapMetrics.borderWidth))
            // Not a hit target and not a second thing to announce: the shortcut reaches VoiceOver
            // through the hint the modifier applies to the CONTROL, where it belongs.
            //
            // `allowsHitTesting(false)` is load-bearing — a SwiftUI overlay takes hits by default,
            // and this one sits ON the control it describes, so without it the badge would swallow
            // the click on exactly the button whose shortcut you just looked up (worst on the
            // icon-only controls, where the keycap covers the whole target).
            //
            // **Asserted by construction, not by test, and deliberately so.** A test was written
            // for it and deleted: `NSHostingView.hitTest` does not decompose a SwiftUI overlay into
            // its own view, so it returns the hosting view whether or not this line is here — the
            // test passed with `allowsHitTesting(true)` and was proving nothing. There is no seam
            // in this process that can tell the two apart, and a test that cannot fail is a worse
            // claim of coverage than none.
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ShortcutKeycapMetrics.cornerRadius, style: .continuous)
    }

    private var labelStyle: AnyShapeStyle {
        switch surface {
        case .standard: return AnyShapeStyle(.secondary)
        case .accentFill: return AnyShapeStyle(.white)
        }
    }

    private var fillStyle: AnyShapeStyle {
        switch surface {
        case .standard: return AnyShapeStyle(.quaternary.opacity(0.4))
        case .accentFill: return AnyShapeStyle(Color.black.opacity(ShortcutKeycapMetrics.onAccentScrim))
        }
    }

    private var borderStyle: AnyShapeStyle {
        switch surface {
        case .standard: return AnyShapeStyle(.quaternary)
        case .accentFill: return AnyShapeStyle(Color.white.opacity(ShortcutKeycapMetrics.onAccentBorder))
        }
    }
}

// MARK: - The adopter's modifier

public extension View {
    /// Badges this control with `symbol` while the ⌥-hold reveal is active, and names the same
    /// shortcut to VoiceOver unconditionally.
    ///
    /// The badge rides in an overlay pinned to the control's trailing edge, so it costs the
    /// control's layout nothing — pass the shortcut in the form a user reads it (`"⌘R"`, `"⇧⌘→"`,
    /// `"esc"`), which is also what the accessibility hint says.
    ///
    /// - Parameters:
    ///   - symbol: the shortcut as displayed, e.g. `"⌘F"`.
    ///   - surface: `.accentFill` on a button already filled with the hue's accent, so the keycap
    ///     scrims down instead of washing out. `.standard` everywhere else.
    ///   - alignment: where the badge sits over the control. Trailing suits a labelled button;
    ///     `.center` suits an icon-only one, where a keycap is nearly as wide as the whole control.
    ///
    /// **Apply this ABOVE any `.disabled(…)` on the control**, so the modifier sits inside that
    /// scope and can read `isEnabled` — the same ordering rule `ChromeHoverModifier` documents,
    /// and for the same reason: a badge on a greyed-out button advertises a shortcut that does
    /// nothing when you press it.
    func shortcutKeycap(_ symbol: String,
                        surface: ShortcutKeycapSurface = .standard,
                        alignment: Alignment = .trailing) -> some View {
        modifier(ShortcutKeycapModifier(symbol: symbol, surface: surface, alignment: alignment))
    }
}

private struct ShortcutKeycapModifier: ViewModifier {
    let symbol: String
    let surface: ShortcutKeycapSurface
    let alignment: Alignment

    @Environment(\.shortcutRevealActive) private var isRevealActive
    /// A disabled control's shortcut does not fire, so it must not advertise one. Same guard, and
    /// the same reasoning, as `HoverAffordanceMetrics.resolve`'s `isEnabled` check.
    @Environment(\.isEnabled) private var isEnabled

    private var showsKeycap: Bool { isRevealActive && isEnabled }

    func body(content: Content) -> some View {
        content
            // `.overlay` and not an `HStack`: an overlay takes its size FROM the host and gives
            // none back, which is the zero-layout-shift guarantee in one modifier. The ternary
            // swaps only what the overlay draws, never whether the overlay exists, so the host's
            // measured size cannot depend on the reveal.
            .overlay(alignment: alignment) {
                if showsKeycap {
                    ShortcutKeycap(symbol, surface: surface)
                        // Only for a trailing badge — the inset exists to hold it off the control's
                        // edge. Applied unconditionally it would push a CENTRED badge (what the
                        // icon-only controls use) half the inset off-centre, which on a 28pt glyph
                        // button is visible.
                        .padding(.trailing, alignment.horizontal == .trailing
                                 ? ShortcutKeycapMetrics.trailingInset : 0)
                        .transition(.opacity)
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
    ]

    public static func spoken(_ symbol: String) -> String {
        var text = symbol
        for (glyph, spoken) in names {
            text = text.replacingOccurrences(of: glyph, with: spoken)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
