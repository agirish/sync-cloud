import FileExplorer
import Sync

/// Why the editor has stopped writing on its own. One type, not separate optionals, because every
/// reader (the header's status line, the flush at every route out, the quit guard) asks the one
/// question "is autosave working right now?", and separate flags invite forgetting one.
enum EditorAutosaveStop: Equatable {
    /// The file changed, or stopped being where the buffer thinks it is. The buffer is intact and
    /// the choice is whose version wins.
    case diverged(EditorFileStore.Divergence)
    /// The write itself failed: a full disk, a volume gone read-only, a permission change. The
    /// message is already reader-facing.
    case failed(String)
    /// The write landed but the look afterwards failed; the clause after "Saved “x”, but …".
    /// Stopped all the same: with no stamp for what is on disk now, the next write couldn't check
    /// whether it was about to overwrite something.
    case unchecked(String)

    /// What the header says while this is in force. Short, because it sits on one line beside the
    /// file name; the alert has the detail.
    var caption: String {
        switch self {
        case .diverged(.changed): return "not saving — changed on disk"
        // Not "moved or renamed": a move is followed, so a missing file is gone, deleted or put
        // somewhere the editor couldn't follow.
        case .diverged(.missing): return "not saving — no longer on disk"
        case .failed: return "not saving — couldn’t write"
        case .unchecked: return "not saving — couldn’t check the save"
        }
    }

    /// The reason behind the header's words, as their tooltip: the banner fades, and "couldn't
    /// write" alone gives nothing to act on. `nil` for a divergence, whose words open the
    /// comparison and carry their own tooltip.
    var detail: String? {
        switch self {
        case .diverged: return nil
        case .failed(let message): return message
        case .unchecked(let clause): return "Saved, but \(clause)"
        }
    }

    /// What a save that didn't end clean says in the banner. A failure is an error; a write that
    /// landed is a warning, not reported as one that couldn't be made: the work is on disk, and
    /// only the check is owed.
    func banner(name: String) -> OperationBanner? {
        switch self {
        case .diverged: return nil
        case .failed(let message): return .error("Couldn’t save “\(name)” — \(message)", log: .error)
        case .unchecked(let clause): return Self.savedBut(name: name, clause: clause)
        }
    }

    /// "Saved “name”, but …": an unchecked save's banner, and also that of a checked save that kept
    /// another version beside it, which stops nothing and so has no stop of its own.
    static func savedBut(name: String, clause: String) -> OperationBanner {
        .warning("Saved “\(name)”, but \(clause)", log: .warn)
    }

    /// The stop a write that threw leaves — see ``EditorAutosave/Outcome/savedUnchecked(_:)``.
    init(saveError error: Error) {
        if let clause = (error as? EditorFileStore.Failure)?.savedBut {
            self = .unchecked(clause)
        } else {
            self = .failed(error.localizedDescription)
        }
    }

    /// Whether the header's amber words open the diff, a way back to "which version wins" after
    /// Cancel leaves the latch set; otherwise only ⌘S would reach it.
    ///
    /// Only for `.diverged(.changed)`: a missing file has nothing to show in the diff's right-hand
    /// column, and a failed or unchecked write has one version, nothing to compare. A property of
    /// the stop, so the view doesn't decide which stops have a second version.
    var offersDiff: Bool {
        switch self {
        case .diverged(.changed): return true
        case .diverged(.missing), .failed, .unchecked: return false
        }
    }

    /// Whether the header's words save: a failed write is settled by writing again, so "not saving —
    /// couldn't write" is ⌘S. Not a divergence, which is a question first, and not "couldn't check
    /// the save", which clears by itself.
    var savesFromTheHeader: Bool {
        if case .failed = self { return true }
        return false
    }

    /// Whether the header's words are Save Again: "not saving — no longer on disk".
    var savesAgainFromTheHeader: Bool { self == .diverged(.missing) }
}
