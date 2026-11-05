import SwiftUI

public extension KeyEquivalent {

    /// The numeric keypad's Enter key, the second ⏎ on every full-size keyboard.
    ///
    /// **`.return` does not match it.** Keypad Enter (keyCode 76) sends `NSEnterCharacter`, U+0003,
    /// where the main ⏎ (keyCode 36) sends U+000D, and SwiftUI hands `onKeyPress` whatever
    /// character arrived. A handler written `keys: [.return]` (or `onKeyPress(.return)`) is
    /// silently deaf to it.
    ///
    /// Measured on a real window's responder chain (`FilingWalkthroughCardKeyTests`' harness),
    /// `press` as delivered to `onKeyPress`:
    ///
    /// | sent | `press.key` | `press.characters` | `press.modifiers` rawValue |
    /// |---|---|---|---|
    /// | keyCode 36, `"\r"`, flags `[]` | `KeyEquivalent("\r")` | U+000D | 0 |
    /// | keyCode 76, `"\u{3}"`, flags `[.numericPad, .function]` | `KeyEquivalent("\u{3}")` | U+0003 | 96 |
    ///
    /// The event is delivered, so no `NSEvent` monitor is needed; the key set just needs this
    /// second member.
    ///
    /// Pair it with `.return` wherever ⏎ means "the primary decision", and guard the handler with
    /// `KeyPress.isPlainKeystroke`: this key always carries `.numericPad` and `.function`, so a
    /// `modifiers.isEmpty` guard would refuse every press.
    static let keypadEnter = KeyEquivalent("\u{3}")
}
