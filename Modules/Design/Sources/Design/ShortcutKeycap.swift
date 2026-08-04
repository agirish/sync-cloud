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
    /// A control already filled with `LiquidGlassHue.accentFillColor`, whose label is white.
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
    ///     `.bottomTrailing` keeps a bare glyph visible under its badge.
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

    func body(content: Content) -> some View {
        content
            // `.overlay` and not an `HStack`: an overlay takes its size FROM the host and gives
            // none back, which is the zero-layout-shift guarantee in one modifier. The ternary
            // swaps only what the overlay draws, never whether the overlay exists, so the host's
            // measured size cannot depend on the reveal.
            .overlay(alignment: alignment) {
                if isRevealActive {
                    ShortcutKeycap(symbol, surface: surface)
                        .padding(.trailing, ShortcutKeycapMetrics.trailingInset)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isRevealActive)
            // Ungated, on purpose — see the file header. A hint rather than appending to the
            // label, so the control's name stays the thing VoiceOver leads with.
            .accessibilityHint("Keyboard shortcut: \(ShortcutKeycapSpeech.spoken(symbol))")
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
    /// Ordered longest-first so multi-character names are not eaten by a single-character rule.
    private static let names: [(glyph: String, spoken: String)] = [
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
        ("esc", "Escape"),
    ]

    public static func spoken(_ symbol: String) -> String {
        var text = symbol
        for (glyph, spoken) in names {
            text = text.replacingOccurrences(of: glyph, with: spoken)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
