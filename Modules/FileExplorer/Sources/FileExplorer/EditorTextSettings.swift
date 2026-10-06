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

    /// Whether the format bar is drawn above a Markdown document's source (TE52).
    ///
    /// **On by default**, because the bar is the only place the Markup verbs show themselves — the
    /// menu and the right-click submenu have to be gone looking for. Off is for somebody who knows
    /// the keys and wants the row back. View ▸ Format Bar flips it, and so does Format Bar on the
    /// text's right-click menu — the way back once the bar's own Hide Format Bar has taken the bar,
    /// and its menu, off the screen. Where the bar is drawn at all is
    /// ``EditorFormatBar/isShown(preference:hasDocument:isRefused:isMarkdown:isReadOnly:mode:)``.
    public static let showsFormatBarKey = "editorShowsFormatBar"
    public static let showsFormatBarDefault = true

    /// Whether Return carries a Markdown list on, and Tab and ⇧Tab move an item in and out (TE54,
    /// decision N).
    ///
    /// **On by default, and the one setting here about what is WRITTEN rather than how it is
    /// drawn** — which is why it has a switch at all. Everything else in this editor that adds
    /// characters unasked is off for good (see ``checksSpellingKey``); this adds a marker only on a
    /// Return at the end of a list item in Markdown, one ⌘Z takes it back, and Text ▸ Continue Lists
    /// turns it off for anyone who wants Return to be only a Return.
    public static let continuesListsKey = "editorContinuesLists"
    public static let continuesListsDefault = true

    /// Whether the format bar puts a word beside each icon — Icon and Text — or draws icons alone,
    /// as it first shipped (TE63, TE64).
    ///
    /// **On by default, for everyone** (decision Q = B, 2026-10-04): the words are what make the
    /// bar readable to somebody who does not yet know its glyphs. It is NOT tied to Row spacing,
    /// which stays a setting about lists. Set from the bar's own right-click menu, as Finder's
    /// toolbar is, and only ever a preference: where the words do not fit, the bar draws icons
    /// whatever this says — see ``EditorFormatBar/ladder(showsLabels:)``.
    public static let formatBarShowsLabelsKey = "editorFormatBarShowsLabels"
    public static let formatBarShowsLabelsDefault = true

    /// Whether Preview can be typed in — Text ▸ Edit in Preview (Experimental), and the pill in the
    /// Preview column's corner (TE67).
    ///
    /// **Off by default**: it is experimental, and the read-only preview is what Preview has always
    /// been. App-wide rather than per file, because it is about how somebody likes to work.
    public static let editsInPreviewKey = "editorEditsInPreview"
    public static let editsInPreviewDefault = false

    /// Whether the one-time "Editing in Preview is experimental" popover has been dismissed.
    public static let editsInPreviewIntroSeenKey = "editorEditsInPreviewIntroSeen"

    // MARK: - There is deliberately no "Show Invisibles"
    //
    // **It was specified, costed and dropped on 2026-09-01, and the reason is worth keeping so it
    // is not attempted again as an oversight.** `NSTextView` exposes no invisibles API at all —
    // only `NSLayoutManager.showsInvisibleCharacters` does. That is TextKit 1's, and this editor
    // runs on TextKit 2: measured, `view.textLayoutManager` is non-nil until `view.layoutManager`
    // is READ, and non-nil no longer afterwards. Merely reaching for the property drops the view
    // onto the TextKit 1 compatibility path for the rest of its life.
    //
    // Since the setting would be remembered, anyone who left it on would run the editor on the
    // older engine permanently — including on the large files where TextKit 2's viewport-based
    // layout is what keeps the 4 MiB cap in `BoundedTextRead` comfortable. Trailing whitespace is
    // the only invisible that changes what Markdown MEANS, and two spaces at the end of a line is a
    // narrow thing to spend a layout engine on.
    //
    // Drawing them by hand over TextKit 2 remains open, and is the only route that costs nobody
    // anything. See `reading-layoutmanager-downgrades-textkit`.
}
