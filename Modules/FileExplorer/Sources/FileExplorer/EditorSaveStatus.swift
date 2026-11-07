import Design
/// What the editor's header says about the document's relationship to the file.
///
/// A value rather than two computed properties on the view, because the words and the dot answer
/// one question, and resolving them separately could say "saved" beside a lit dot. It is also what
/// makes the rule testable: the header needs a whole workspace to render.
enum EditorSaveStatus: Equatable {
    /// Nothing can be written, so nothing is pending. A lossy decode, mostly.
    case readOnly
    /// The buffer is ahead of the file, from the keystroke until the debounce elapses and the write
    /// returns. A real state: a crash in this window loses work, so "saved" would be untrue.
    case unsaved
    /// The file matches the buffer.
    case saved
    /// Autosave has stopped and is not going to write until somebody settles it.
    case stopped(String)
    /// The buffer is ahead of the file and autosave is off for it, so nothing is coming to write
    /// it. Distinct from ``unsaved``, which resolves itself in about two seconds; this waits for ⌘S.
    case heldUnsaved

    /// A stop outranks dirtiness, and read-only outranks both: a stopped document is dirty by
    /// definition, so "unsaved" would say the same thing less usefully.
    static func resolve(isReadOnly: Bool, isDirty: Bool, stopped: String?,
                        autosaveOff: Bool = false) -> EditorSaveStatus {
        if isReadOnly { return .readOnly }
        if let stopped { return .stopped(stopped) }
        guard isDirty else { return .saved }
        return autosaveOff ? .heldUnsaved : .unsaved
    }

    /// The word the header shows, or `nil` when there is nothing worth saying. A word appears only
    /// where it changes what the reader must do:
    ///
    /// - `saved`: no word. The dot going out is the evidence.
    /// - `unsaved`: no word in the ordinary case; autosave comes in about two seconds, and the dot
    ///   says it.
    /// - `unsaved — ⌘S`: autosave is off for this file, so the reader has to act.
    /// - A stop: exceptional, and its reason is what settles it.
    /// - `read only`: saving isn't on offer at all.
    var word: String? {
        switch self {
        case .readOnly: return "read only"
        case .heldUnsaved: return "unsaved — \(AppChord.saveDocument.display)"
        case .stopped(let reason): return reason
        case .unsaved, .saved: return nil
        }
    }

    /// Whether the dot beside the file name is drawn at all: off for `saved`, with nothing pending,
    /// and for `readOnly`, where nothing ever will be.
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

    /// What VoiceOver calls the dot, the header's and the rail's alike: a stop is "Not saving", an
    /// ordinary pending write "Not saved yet", so the two don't sound alike. A held file says, as
    /// its header's word does, that ⌘S saves it; "Not saved yet" would promise an autosave.
    var dotName: String {
        switch self {
        case .stopped: return "Not saving"
        case .heldUnsaved: return "Unsaved — \(AppChord.saveDocument.display) saves it"
        case .unsaved, .saved, .readOnly: return "Not saved yet"
        }
    }
}
