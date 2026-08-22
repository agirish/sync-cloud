import SwiftUI

public extension KeyEquivalent {

    /// The numeric keypad's **Enter** key — the second ⏎ on every full-size keyboard.
    ///
    /// **It is not a carriage return, and `.return` does not match it.** The keypad's Enter is
    /// keyCode 76 and sends `NSEnterCharacter` — U+0003 — where the main row's ⏎ (keyCode 36)
    /// sends U+000D. SwiftUI hands `onKeyPress` whatever character the event carried, so a
    /// handler written `keys: [.return]` (or the single-key `onKeyPress(.return)`) is silently
    /// deaf to one of the two keycaps that say "Enter".
    ///
    /// Measured through a probe view on a real window's responder chain
    /// (`FilingWalkthroughCardKeyTests`' harness), `press` as delivered to `onKeyPress`:
    ///
    /// | sent | `press.key` | `press.characters` | `press.modifiers` rawValue |
    /// |---|---|---|---|
    /// | keyCode 36, `"\r"`, flags `[]` | `KeyEquivalent("\r")` | U+000D | 0 |
    /// | keyCode 76, `"\u{3}"`, flags `[.numericPad, .function]` | `KeyEquivalent("\u{3}")` | U+0003 | 96 |
    ///
    /// and, with both keys in a handler's set, each press matched exactly the member spelled the
    /// way it arrived: `[.return]` matched only the first row, `[KeyEquivalent("\u{3}")]` only the
    /// second. **The event is delivered** — this is not an `onKeyPress` blind spot needing an
    /// `NSEvent` monitor (which would be a window-level equivalent, the very shape the card keys
    /// were moved off). It is the key set that misses it, so the fix is a second member.
    ///
    /// Pair it with `.return` wherever ⏎ means "the primary decision", and guard the handler with
    /// `KeyPress.isPlainKeystroke`: this key ALWAYS arrives carrying `.numericPad` and
    /// `.function` (rawValue 96 above), so a `modifiers.isEmpty` guard would refuse every one of
    /// them — the same trap the arrow keys sprang.
    static let keypadEnter = KeyEquivalent("\u{3}")
}
