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

    /// **A stop outranks dirtiness, and read-only outranks both.** A stopped document is dirty by
    /// definition — that is the only reason a stop is interesting — so reporting "unsaved" there
    /// would be the same fact in the less useful of its two spellings.
    static func resolve(isReadOnly: Bool, isDirty: Bool, stopped: String?) -> EditorSaveStatus {
        if isReadOnly { return .readOnly }
        if let stopped { return .stopped(stopped) }
        return isDirty ? .unsaved : .saved
    }

    /// The last segment of the header's meta line.
    var caption: String {
        switch self {
        case .readOnly: return "read only"
        case .unsaved: return "unsaved"
        case .saved: return "saved"
        case .stopped(let reason): return reason
        }
    }

    /// Whether the dot beside the file name is drawn at all. **Off for `saved` and for `readOnly`**
    /// — one because there is nothing pending, the other because there never will be.
    var showsDot: Bool {
        switch self {
        case .saved, .readOnly: return false
        case .unsaved, .stopped: return true
        }
    }

    /// Whether that dot is a warning rather than a status. Pending work is ordinary and wears the
    /// accent; a stop is a problem and wears amber.
    var isWarning: Bool {
        if case .stopped = self { return true }
        return false
    }
}
