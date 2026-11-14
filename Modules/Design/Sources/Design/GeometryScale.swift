import SwiftUI

/// The corner-radius scale.
///
/// Four stops, each a value the app already used widely, so adopting them is a rename, not a
/// redesign. What the scale prevents is strays: radii a point apart (5, 6, 7 on chips in one card)
/// that look the same but drift because each was typed at its own call site.
///
/// Off-scale values that carry meaning stay off-scale: the 1–3pt radii are bar caps and rules (a
/// 2pt progress bar's cap is half its height), and 12 sits between `well` and `card` by choice.
public enum Radius {
    /// Chips, pills, inline badges, token swatches: anything riding inside a row.
    public static let chip: CGFloat = 6
    /// Buttons, thumbnails, small wells: a control with its own ground.
    public static let control: CGFloat = 8
    /// Grouped regions and inset panels: a container of controls, not a control.
    public static let well: CGFloat = 10
    /// Floating cards and panels.
    public static let card: CGFloat = 14

    /// The stops, ascending, for tests and for anything that snaps a value.
    public static let all: [CGFloat] = [chip, control, well, card]
}

// There is deliberately no matching `Space` scale. The padding literals worth naming (4, 8, 12)
// read fine as themselves, and the odd values are load-bearing in ways a grid can't see:
// `LiquidGlass.cardGutter` is 5 by measurement, chrome rows are pinned to heights a 1pt change
// breaks, and the Settings rail has 0.4pt of margin at the largest text size. A scale would invite
// rounding a measured number onto a grid.

public extension View {
    /// The elevation a floating overlay panel sits at: the setup sheet, the help book, the
    /// destination picker and the settings overlay. They are the only things that float over a
    /// dimmed window, so they share one shadow and can't drift apart.
    func overlayPanelShadow() -> some View {
        shadow(color: LiquidGlass.overlayShadow.color,
               radius: LiquidGlass.overlayShadow.radius,
               x: LiquidGlass.overlayShadow.x,
               y: LiquidGlass.overlayShadow.y)
    }
}
