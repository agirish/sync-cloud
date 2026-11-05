import SwiftUI

public extension EventModifiers {

    /// The four modifiers that change what a keystroke means: ⌘, ⌥, ⌃, ⇧.
    ///
    /// The set a handler consults for "the plain keystroke the keycap advertises". Not everything
    /// `EventModifiers` can carry: `.capsLock`, `.numericPad` and `.function` are state and
    /// provenance, not intent, and arrive on presses the user thinks of as unmodified.
    static let intent: EventModifiers = [.command, .option, .control, .shift]
}

public extension KeyPress {

    /// True when this press carries none of ⌘⌥⌃⇧: the bare keystroke a keycap advertises, whatever
    /// incidental state flags rode along.
    ///
    /// **Never test `modifiers.isEmpty` instead.** It fails on presses a keyboard produces
    /// constantly:
    ///
    /// - **Arrows always set `.function` and `.numericPad`** (AppKit documents `.numericPad` as set
    ///   for arrow keys), so a handler guarding on `.isEmpty` never fires on → at all.
    /// - **`.capsLock` rides on every event while the lock is engaged**, so the same guard kills ⏎,
    ///   →, esc and ⌫ for a user who left Caps Lock on, with nothing on screen explaining it.
    ///
    /// Measured on a real window's responder chain (`SwiftUI.EventModifiers` raw values as
    /// delivered to `onKeyPress(keys:phases:)`):
    ///
    /// | sent | `press.modifiers` rawValue | `.isEmpty` | `isPlainKeystroke` |
    /// |---|---|---|---|
    /// | → with `[]` (a shape real AppKit never sends) | 0 | true | true |
    /// | → with `[.function, .numericPad]` (the real one) | 96 | **false** | true |
    /// | → with `[.capsLock, .function, .numericPad]` | 97 | **false** | true |
    /// | ⏎ with `[.capsLock]` | 1 | **false** | true |
    /// | esc with `[.function]` | 64 | **false** | true |
    /// | ⏎ with `[.command]` | 16 | false | **false** |
    ///
    /// In `Design`, beside `AppChord`: the same subject (what counts as a chord), shared so callers
    /// don't each repeat the set.
    ///
    /// **Every `onKeyPress` overload needs this, including the single-key `onKeyPress(_:)`**, which
    /// does not filter modifiers: `.onKeyPress(.return)` fires for ⌘⏎ and ⇧⏎, and on key-repeat.
    /// Guard any handler that must not run for a chord, or use the `keys:phases:` form, the only
    /// one that can also refuse auto-repeat.
    var isPlainKeystroke: Bool {
        modifiers.intersection(.intent).isEmpty
    }
}
