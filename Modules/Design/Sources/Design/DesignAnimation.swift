import SwiftUI

/// Animation that respects **Reduce Motion**, without every call site having to read the
/// environment to do it.
///
/// The app honoured the setting in ten files while twenty-eight animated, so most of its motion was
/// unconditional — not by decision, but because opting in meant adding an `@Environment` property to
/// whatever view owned the animation, and a modifier chain is a bad place to need one. This puts the
/// read inside the modifier, so honouring the setting costs a call site nothing.
///
/// ## What this is for, and what it is NOT for
///
/// **Reduce Motion asks for less MOVEMENT, not less feedback.** Apple's own guidance replaces
/// motion with a cross-fade rather than removing the change, and `HoverAffordanceMetrics` already
/// strikes exactly that bargain: under the setting it zeroes `lift` and `scale` and keeps `wash`,
/// `ring` and `shadow`. So this wrapper is for animation that moves something on screen — a pane
/// sliding, a card springing in, a strip growing — and three families are deliberately left alone:
///
/// - **Hover and press ladders** (`HoverAffordance`, `ActionBarButtonStyle`). What animates there is
///   a colour, and the parts that moved are already dropped by the metrics table. Gating the
///   cross-fade as well would make a hovered control snap between two fills, which is more visually
///   abrupt than the thing the setting exists to calm.
/// - **Numeric content transitions** (`Pill`, `StatPill`, the reclaim tally). A rolling digit is a
///   content transition, sanctioned in the reclaim pill's own comment as legible rather than
///   decorative — it says a number changed, which is information a user with the setting on still
///   needs.
/// - **Opacity cross-fades on overlays** (the settings, help and setup panels). A cross-fade IS the
///   Reduce Motion answer; replacing it with an instant swap would be a regression against the
///   setting rather than a concession to it.
///
/// Do not "finish the job" by converting those. The audit that leaves them alone is the design.
///
/// **And the audit is enforced, because in prose alone it could not tell an exempted site from a
/// missed one.** `ReduceMotionCoverageScanTests` reads every raw `.animation(_:value:)` in
/// `Modules/*/Sources` and `MacApp` and fails unless each is listed with the family it belongs to.
/// It was written after six movers turned up unconverted on the first sweep — both of
/// `PaneTabStrip`'s drag animations, both of `LensWorkspaceView`'s list settles,
/// `ActivePaneMark`'s focus ring and the selection bar's appear/disappear — none of which belonged
/// to any of the three families above. A new raw `.animation` fails that test until it is
/// classified, which is the step that did not happen before.
public extension View {

    /// Applies `animation` unless Reduce Motion is on, in which case the change arrives with no
    /// animation at all.
    ///
    /// Same signature as `.animation(_:value:)`, so converting a site is a rename — which is the
    /// point: a wrapper that needed its arguments rearranged would not get adopted.
    ///
    /// - Parameters:
    ///   - animation: the motion to use when the setting is off. Optional so a caller that already
    ///     computes a nil-able animation can pass it straight through.
    ///   - value: the change to animate, exactly as `.animation(_:value:)` means it.
    func designAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(DesignAnimationModifier(animation: animation, value: value))
    }
}

/// See `View.designAnimation(_:value:)`. A `ViewModifier` rather than a free function because
/// `@Environment` can only be read by something that participates in the view graph — which is
/// precisely the friction that kept call sites from honouring the setting by hand.
public struct DesignAnimationModifier<V: Equatable>: ViewModifier {
    let animation: Animation?
    let value: V

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public func body(content: Content) -> some View {
        content.animation(DesignAnimationRule.resolve(animation, reduceMotion: reduceMotion), value: value)
    }
}

/// The resolved decision, exposed so it can be tested without rendering anything.
///
/// The modifier above is three lines and the rule inside it is the whole design, so the rule lives
/// here as a pure function and the modifier calls the same thing a test does — rather than a test
/// asserting a duplicate of the logic, which would pass just as happily when the modifier stopped
/// agreeing with it.
public enum DesignAnimationRule {
    /// What `designAnimation` will actually apply.
    public static func resolve(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// `withAnimation`, honouring Reduce Motion — the imperative half of the wrapper above.
///
/// **`designAnimation(_:value:)` covers only one of SwiftUI's two animation doors, and the scan
/// that enforces it covered only that one too.** A change made inside `withAnimation` carries its
/// own animation into the transaction, and while an `.animation(_:value:)` on the same value does
/// win over it — measured, not assumed — a mover that *only* has a `withAnimation` behind it has
/// nothing to override: no modifier names its value, so the setting never reaches it. Four such
/// movers were live after the sweep that was supposed to have finished this work: the expanding
/// search field's reveal (in three of its four hosts), Browse's folder sidebar, an Activity Log
/// row's disclosure, and the Differences count pills.
///
/// The signature is `withAnimation`'s plus the flag, so converting a site is a rename and one
/// argument — the same bargain `designAnimation` struck, for the same reason. The flag is passed
/// rather than read because this is a free function: it does not participate in the view graph, so
/// it cannot read `@Environment` itself. The caller is a `View` and can.
public func withDesignAnimation<Result>(
    _ animation: Animation?,
    reduceMotion: Bool,
    _ body: () throws -> Result
) rethrows -> Result {
    try withAnimation(DesignAnimationRule.resolve(animation, reduceMotion: reduceMotion), body)
}
