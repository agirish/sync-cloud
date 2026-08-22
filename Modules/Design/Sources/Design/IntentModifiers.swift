import SwiftUI

public extension EventModifiers {

    /// The four modifiers that change what a keystroke *means* — ⌘, ⌥, ⌃, ⇧.
    ///
    /// The set a handler must consult when it wants "the plain keystroke the keycap advertises"
    /// and nothing else. Deliberately NOT everything `EventModifiers` can carry: `.capsLock`,
    /// `.numericPad` and `.function` are **state and provenance**, not intent, and every one of
    /// them arrives on presses the user thinks of as unmodified.
    static let intent: EventModifiers = [.command, .option, .control, .shift]
}

public extension KeyPress {

    /// True when this press carries none of ⌘⌥⌃⇧ — i.e. it is the bare keystroke a keycap
    /// advertises, whatever incidental state flags rode along with it.
    ///
    /// **Why this is not `modifiers.isEmpty`.** That is the spelling this replaced, and it was
    /// wrong in a way no test saw, because it fails on presses a keyboard produces constantly:
    ///
    /// - **Arrows always set `.function` and `.numericPad`.** AppKit documents it —
    ///   `NSEvent.ModifierFlags.numericPad` is "also set if any of the arrow keys are pressed" —
    ///   so `modifiers.isEmpty` is FALSE for every arrow that has ever been pressed. A handler
    ///   guarding on it does not fire on → at all, ever.
    /// - **`.capsLock` rides on every event while the lock is engaged.** So the same guard turns
    ///   ⏎, →, esc and ⌫ all dead for a user who left Caps Lock on, with the keycaps still
    ///   advertising them and nothing on screen explaining it.
    ///
    /// Measured through a probe view on a real window's responder chain (`SwiftUI.EventModifiers`
    /// raw values as delivered to `onKeyPress(keys:phases:)`):
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
    /// This lives in `Design`, beside `AppChord`, because it is the same subject — what counts as
    /// a chord — and because both `FileExplorer` surfaces that need it would otherwise repeat the
    /// set literal, which is how the four copies of `.isEmpty` came to be wrong together.
    ///
    /// **Every `onKeyPress` overload needs this, including the single-key `onKeyPress(_:)` one.**
    /// The first cut of this doc said the opposite — that the single-key overload "filters
    /// modifiers itself and needs no guard" — asserted from intent, never measured. It is false:
    /// on `ReviewCardView`'s real responder chain, its `.onKeyPress(.return)` ran the primary
    /// copy for ⌘⏎ and again for ⇧⏎, and fired on key-repeat besides (four copies from one held
    /// ⏎). Anything whose handler must not run for a chord guards on this, whichever overload it
    /// is written with — or takes the `keys:phases:` form, which is the only one that can also
    /// refuse auto-repeat.
    var isPlainKeystroke: Bool {
        modifiers.intersection(.intent).isEmpty
    }
}
