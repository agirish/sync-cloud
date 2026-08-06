import SwiftUI

// MARK: - Shortcut hints in tooltips
//
// The app has a real shortcut vocabulary — ⌘Z to undo a run, Space for Quick Look, esc to close a
// sheet, ⌘, for Settings — and until now nothing in the interface taught any of it. The shortcuts
// were reachable from the Help book and the ⌘/ reference sheet, both of which you have to already
// suspect exist before you can be told anything.
//
// A tooltip is the right surface for this precisely because it is on-demand: you asked for it by
// resting the pointer, so naming the shortcut there costs nobody any screen real estate and
// declutters nothing away from the people who never hover.
//
// Every adopting call site runs its `.help(_:)` through `ShortcutHint.tooltip` rather than writing
// the string itself, so the form stays uniform across the app and there is one place to change it.
// That matters more than it looks: before this, two of the adopters had already invented their own
// conventions — `"Undo this operation (⌘Z)"` and `"…the copy being copied (space) — right-click…"`
// — parenthesised, mid-sentence, one spelling the key as a word and the other as a glyph.

/// One-line tooltip naming a control's keyboard shortcut.
///
/// **Only ever call this with a shortcut the control actually has.** A tooltip is a promise, and
/// an unbound chord in one is worse than no hint at all — the reader tries it, nothing happens,
/// and every other hint in the app is now suspect. Three sites were deliberately left alone for
/// exactly this reason when the hints went in: the differences list's *Clear selection* has no
/// `esc` binding on this line, and the pane *Find* field does not exist here at all.
public enum ShortcutHint {
    /// `"Rescan   ⌘R"`. Three spaces rather than a separator character: a macOS tooltip is a plain
    /// string with no columns to align to, so the gap itself is what has to read as the break. One
    /// space reads as part of the sentence; a dash or a bullet reads as punctuation the description
    /// owns.
    public static func tooltip(_ description: String, _ symbol: String) -> String {
        "\(description)   \(symbol)"
    }
}
