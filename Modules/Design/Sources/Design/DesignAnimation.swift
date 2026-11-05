import SwiftUI

/// Animation that respects Reduce Motion, with the environment read inside the modifier so a call
/// site doesn't need its own `@Environment` property.
///
/// ## What this is for, and what it is NOT for
///
/// Reduce Motion asks for less movement, not less feedback: Apple's guidance swaps motion for a
/// cross-fade, as `HoverAffordanceMetrics` does (it zeroes `lift` and `scale`, keeps `wash`, `ring`
/// and `shadow`). So this wrapper is for animation that moves something (a pane sliding, a card
/// springing in, a strip growing), and three families stay raw on purpose:
///
/// - **Hover and press ladders** (`HoverAffordance`, `ActionBarButtonStyle`). Only a colour
///   animates, the moving parts are already dropped, and gating the fade would make a hovered
///   control snap between fills.
/// - **Numeric content transitions** (`Pill`, `StatPill`, the reclaim tally). A rolling digit says
///   a number changed, which a user with the setting on still needs.
/// - **Opacity cross-fades on overlays** (the settings, help and setup panels). A cross-fade is the
///   Reduce Motion answer; an instant swap would be worse.
///
/// Don't convert those. `ReduceMotionCoverageScanTests` enforces the split: every raw
/// `.animation(_:value:)` in `Modules/*/Sources` and `MacApp` must be listed with its family, so a
/// new one fails until it is classified.
public extension View {

    /// Applies `animation` unless Reduce Motion is on, in which case the change arrives with no
    /// animation at all.
    ///
    /// Same signature as `.animation(_:value:)`, so converting a site is a rename.
    ///
    /// - Parameters:
    ///   - animation: the motion to use when the setting is off. Optional so a caller that already
    ///     computes a nil-able animation can pass it straight through.
    ///   - value: the change to animate, exactly as `.animation(_:value:)` means it.
    func designAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(DesignAnimationModifier(animation: animation, value: value))
    }
}

/// See `View.designAnimation(_:value:)`. A `ViewModifier` because only something in the view graph
/// can read `@Environment`.
public struct DesignAnimationModifier<V: Equatable>: ViewModifier {
    let animation: Animation?
    let value: V

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public func body(content: Content) -> some View {
        content.animation(DesignAnimationRule.resolve(animation, reduceMotion: reduceMotion), value: value)
    }
}

/// The resolved decision, as a pure function the modifier and the tests both call, so a test
/// can't pass on a copy of the logic the modifier no longer follows.
public enum DesignAnimationRule {
    /// What `designAnimation` will actually apply.
    public static func resolve(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// `withAnimation`, honouring Reduce Motion: the imperative half of the wrapper above.
///
/// A change inside `withAnimation` carries its own animation. An `.animation(_:value:)` on the same
/// value wins over it, but a mover with only a `withAnimation` behind it has no modifier for the
/// setting to reach, so it needs this.
///
/// `withAnimation`'s signature plus the flag, so converting a site is a rename and one argument.
/// The flag is passed in because a free function can't read `@Environment`; the calling `View` can.
public func withDesignAnimation<Result>(
    _ animation: Animation?,
    reduceMotion: Bool,
    _ body: () throws -> Result
) rethrows -> Result {
    try withAnimation(DesignAnimationRule.resolve(animation, reduceMotion: reduceMotion), body)
}
