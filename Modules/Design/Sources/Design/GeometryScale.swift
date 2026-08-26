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

/// The spacing scale: a 4pt grid with a 2pt half-step at the bottom.
///
/// **This is a vocabulary for new and converted code, not a migration order.** The app's padding
/// literals cluster at 4, 8 and 12 — which are on the grid and convert byte-identically — but a
/// long tail sits at 5, 6, 7, 9 and 11, and those are load-bearing in ways a grid cannot see:
/// `LiquidGlass.cardGutter` is 5 by measurement, chrome rows are pinned to heights that a 1pt
/// padding change breaks (`theRowIsAlwaysTheActionBarHeight`), and the Settings rail has 0.4pt of
/// margin at the largest text size. Rounding those onto the grid would be a layout change wearing
/// a cleanup's clothes.
///
/// So: reach for a stop when the value is genuinely arbitrary, and leave a measured number alone.
/// An off-grid value that a test pins is evidence, not debt.
public enum Space {
    /// Hairline gaps — between a glyph and the text it labels.
    public static let xxs: CGFloat = 2
    /// Tight: inside a chip, between stacked captions.
    public static let xs: CGFloat = 4
    /// The default gap between siblings in a row or stack.
    public static let s: CGFloat = 8
    /// Between groups inside one card.
    public static let m: CGFloat = 12
    /// Between cards, and a card's own inner margin.
    public static let l: CGFloat = 16
    /// Between major regions.
    public static let xl: CGFloat = 24

    /// The steps, ascending — for tests.
    public static let all: [CGFloat] = [xxs, xs, s, m, l, xl]
}

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
