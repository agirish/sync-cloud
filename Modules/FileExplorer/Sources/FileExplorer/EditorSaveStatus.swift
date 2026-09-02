import Design
/// What the editor's header says about the document's relationship to the file.
///
/// **A value rather than two computed properties on the view**, because the three states are one
/// question asked twice — once for the words and once for the dot — and a view that resolved them
/// separately could say "saved" beside a lit dot. It is also the only way to test the rule: the
/// header itself needs a whole workspace around it to render.
enum EditorSaveStatus: Equatable {
    /// Nothing can be written, so nothing is pending. A lossy decode, mostly.
    case readOnly
    /// The buffer is ahead of the file — from the keystroke until the debounce elapses and the
    /// write returns. **A real state, not a courtesy:** it is the window in which a crash costs
    /// something, and saying "saved" through it would be a claim the app cannot support.
    case unsaved
    /// The file matches the buffer.
    case saved
    /// Autosave has stopped and is not going to write until somebody settles it.
    case stopped(String)
    /// The buffer is ahead of the file **and autosave is switched off for it**, so nothing is
    /// coming to write it. Distinct from ``unsaved`` because the two ask different things of the
    /// reader: one resolves itself in about two seconds, and this one waits for ⌘S.
    case heldUnsaved

    /// **A stop outranks dirtiness, and read-only outranks both.** A stopped document is dirty by
    /// definition — that is the only reason a stop is interesting — so reporting "unsaved" there
    /// would be the same fact in the less useful of its two spellings.
    static func resolve(isReadOnly: Bool, isDirty: Bool, stopped: String?,
                        autosaveOff: Bool = false) -> EditorSaveStatus {
        if isReadOnly { return .readOnly }
        if let stopped { return .stopped(stopped) }
        guard isDirty else { return .saved }
        return autosaveOff ? .heldUnsaved : .unsaved
    }

    /// The word the header shows, or `nil` when there is nothing worth saying.
    ///
    /// **Optional, and that is the whole design of this line.** The header used to end in a word at
    /// all times — `saved` while nothing was happening, `unsaved` for the two seconds after a
    /// keystroke — which put a label on the two states that need no label and made the two that do
    /// look like more of the same. A word appears here only where it changes what the reader must
    /// do about it:
    ///
    /// - **`saved`** is gone. It was reassurance nobody should take on trust: the header said it
    ///   whether or not anything had ever been written. The dot going out is the evidence.
    /// - **`unsaved`** is gone *for the ordinary case*. Autosave is coming in about two seconds, so
    ///   the dot is the whole story and a word implies a decision that is not being asked for.
    /// - **`unsaved — ⌘S`** stays, because autosave is switched off for this file and the reader is
    ///   now the one who has to act.
    /// - **A stop** stays, because it is exceptional and the reason is what settles it.
    /// - **`read only`** stays, because saving is not on offer at all.
    var word: String? {
        switch self {
        case .readOnly: return "read only"
        case .heldUnsaved: return "unsaved — \(AppChord.saveDocument.display)"
        case .stopped(let reason): return reason
        case .unsaved, .saved: return nil
        }
    }

    /// Whether the dot beside the file name is drawn at all. **Off for `saved` and for `readOnly`**
    /// — one because there is nothing pending, the other because there never will be.
    var showsDot: Bool {
        switch self {
        case .saved, .readOnly: return false
        case .unsaved, .heldUnsaved, .stopped: return true
        }
    }

    /// Whether that dot is a warning rather than a status. Pending work is ordinary and wears the
    /// accent; a stop is a problem and wears amber.
    var isWarning: Bool {
        if case .stopped = self { return true }
        return false
    }
}
