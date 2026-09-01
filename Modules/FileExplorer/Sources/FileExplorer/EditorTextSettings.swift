import Foundation

/// How the editor draws text, as opposed to what is in it.
///
/// **Preferences, so they persist — unlike ``EditorMode``, and the difference is worth stating.**
/// The mode capsule describes *which representation of one document you are reading*, which is a
/// fact about a session and is deliberately forgotten at launch. These are facts about how somebody
/// likes to work: a person who turns wrapping off for log files wants it off tomorrow too.
///
/// Read straight from the shared defaults by ``PlainTextEditor``, the way the window's glass
/// settings are read by the views that draw it — they are settings, not state anybody owns.
public enum EditorTextSettings {

    /// Whether lines wrap at the column edge, or run on with a horizontal scroller.
    ///
    /// On by default, because prose is the common case here and an unwrapped paragraph is unreadable
    /// in a 260pt column. Off is what a log, a CSV or a long shell line needs, where a wrap invents
    /// a line break that is not in the file.
    public static let wrapsKey = "editorWrapsLines"
    public static let wrapsDefault = true

    /// Whether the spell checker underlines as you type.
    ///
    /// **Off by default, and this is the half that had to be separated from the other.** Everything
    /// in this editor that *rewrites* text unasked — smart quotes, dash substitution, text
    /// replacement, autocorrect — is off unconditionally and has no switch anywhere, because these
    /// are real files and a curly quote in somebody's YAML is a corrupted file. Checking only draws
    /// a red line under a word; it changes nothing. They were one setting and are now two.
    public static let checksSpellingKey = "editorChecksSpelling"
    public static let checksSpellingDefault = false
}
