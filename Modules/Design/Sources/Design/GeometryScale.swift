import SwiftUI

/// The corner-radius scale.
///
/// **Four stops, and every one of them is a value the app already prevailed at** — 6 (26 sites),
/// 8 (18), 10 (8, and already named `LiquidGlass.smallCornerRadius`) and 14 (already named
/// `cardCornerRadius`). Naming what was there rather than inventing a grid is deliberate: a scale
/// whose stops are new numbers restyles the app on the way in, and there was no finding asking for
/// that. Adopting these is a rename, not a redesign.
///
/// What the scale *does* fix is the strays around each stop. Before this the app hand-wrote eleven
/// distinct radii, so 5, 6 and 7 — indistinguishable at a glance — sat on three chips inside one
/// card, and 9, 10 and 11 did the same one level up. They diverged because each was typed at its
/// own call site with nothing to type instead; that is the defect, not any single number.
///
/// **Off-scale values that carry meaning stay off-scale.** The 1–3pt radii are bar caps and rules
/// (a 2pt progress bar's cap is half its height, not a corner), and 12 is 2pt from both `well` and
/// `card` — a judgement call rather than a near-duplicate, so it is left where its author put it.
/// Collapsing those would be the redesign this scale is avoiding.
public enum Radius {
    /// Chips, pills, inline badges, token swatches — anything riding *inside* a row.
    /// Absorbs the former 5 and 7.
    public static let chip: CGFloat = 6
    /// Buttons, thumbnails, small wells — a control with its own ground.
    public static let control: CGFloat = 8
    /// Grouped regions and inset panels: a container of controls, not a control.
    /// Absorbs the former 9 and 11. Same value as `LiquidGlass.smallCornerRadius`, which now
    /// reads from here.
    public static let well: CGFloat = 10
    /// Floating cards and panels. Same value as `LiquidGlass.cardCornerRadius`, which reads
    /// from here.
    public static let card: CGFloat = 14

    /// The stops, ascending — for tests, and for anything that needs to snap a value.
    public static let all: [CGFloat] = [chip, control, well, card]
}

// **There is deliberately no matching `Space` scale.** One shipped here and was removed the same
// day with zero call sites, which is the whole argument: the padding literals worth naming are 4,
// 8 and 12, and those read perfectly well as themselves, while the long tail at 5, 6, 7, 9 and 11
// is load-bearing in ways a grid cannot see — `LiquidGlass.cardGutter` is 5 by measurement, chrome
// rows are pinned to heights a 1pt change breaks, and the Settings rail has 0.4pt of margin at the
// largest text size. A scale nobody may safely apply is not a vocabulary, it is an invitation to
// round a measured number onto a grid, and the next reader would have taken it.

public extension View {
    /// The elevation a floating overlay panel sits at — the setup sheet, the help book, the
    /// destination picker and the settings overlay.
    ///
    /// All four wrote `.shadow(color: .black.opacity(0.3), radius: 30, y: 8)` inline, character for
    /// character, because there was nothing to write instead. They are the only things in the app
    /// that float over a dimmed window, so they should not be able to drift apart; four copies of a
    /// number can only ever agree by luck.
    func overlayPanelShadow() -> some View {
        shadow(color: LiquidGlass.overlayShadow.color,
               radius: LiquidGlass.overlayShadow.radius,
               x: LiquidGlass.overlayShadow.x,
               y: LiquidGlass.overlayShadow.y)
    }
}
