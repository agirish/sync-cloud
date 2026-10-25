import FileExplorer
import Sync

/// Why the editor has stopped writing on its own.
///
/// **Named as a type rather than left as two optionals on `ContentView`**, because the two cases
/// are one question — "is autosave working right now?" — and every reader of it (the header's
/// status line, the flush at every route out, the quit guard) asks exactly that. Two flags would be
/// two things to check and one of them to forget.
enum EditorAutosaveStop: Equatable {
    /// The file changed, or stopped being where the buffer thinks it is. The buffer is intact and
    /// the choice is whose version wins.
    case diverged(EditorFileStore.Divergence)
    /// The write itself failed — a full disk, a volume gone read-only, a permission change. The
    /// message is already reader-facing.
    case failed(String)
    /// **The write landed, and the look afterwards failed** (TE114) — the clause after "Saved “x”,
    /// but …". Stopped all the same: the document has no stamp for what is on disk now, so the next
    /// write could not ask whether it was about to overwrite something.
    case unchecked(String)

    /// What the header says while this is in force. Short, because it sits on one line beside the
    /// file name — the alert is where the detail is.
    var caption: String {
        switch self {
        case .diverged(.changed): return "not saving — changed on disk"
        // Not "moved or renamed" any more: a move is followed (TE59), so what is left is a file
        // that is gone — deleted, or put somewhere the editor could not follow.
        case .diverged(.missing): return "not saving — no longer on disk"
        case .failed: return "not saving — couldn’t write"
        case .unchecked: return "not saving — couldn’t check the save"
        }
    }

    /// **The reason behind the header's words**, as the word's tooltip (TE114) — the banner that
    /// said it fades, and "couldn't write" alone gives nothing to act on. `nil` for a divergence,
    /// whose words are a door to the comparison and carry its own tooltip.
    var detail: String? {
        switch self {
        case .diverged: return nil
        case .failed(let message): return message
        case .unchecked(let clause): return "Saved, but \(clause)"
        }
    }

    /// **What a save that did not end clean says, in the banner** (TE114). A failure is a failure;
    /// a write that landed is not reported as one that could not be made — "Couldn't save “x” —
    /// Saved, but…" said both — and is a warning: the work is on disk, and only the check is owed.
    func banner(name: String) -> OperationBanner? {
        switch self {
        case .diverged: return nil
        case .failed(let message): return .error("Couldn’t save “\(name)” — \(message)")
        case .unchecked(let clause): return Self.savedBut(name: name, clause: clause)
        }
    }

    /// "Saved “name”, but …" — an unchecked save's banner, and a checked one's that kept another
    /// version beside it (FR48), which stops nothing and so has no stop to say it.
    static func savedBut(name: String, clause: String) -> OperationBanner {
        .warning("Saved “\(name)”, but \(clause)")
    }

    /// The stop a write that threw leaves — see ``EditorAutosave/Outcome/savedUnchecked(_:)``.
    init(saveError error: Error) {
        if let clause = (error as? EditorFileStore.Failure)?.savedBut {
            self = .unchecked(clause)
        } else {
            self = .failed(error.localizedDescription)
        }
    }

    /// **Whether the header's amber words are a DOOR back to the question, or just words.**
    ///
    /// The alert is modal and Cancel dismisses it while leaving the latch set, so without a second
    /// door the only way back to "which version wins" is ⌘S — a keystroke whose name says "save",
    /// pressed to reach a question about not saving. The stop line is already on screen saying the
    /// thing the diff would explain, so it is the honest place to put that door.
    ///
    /// **Only for `.diverged(.changed)`, and the exclusions are not tidiness.** `.diverged(.missing)`
    /// has nothing at the path to read, so the right-hand column of a diff would be empty and the
    /// control would be a promise the app cannot keep. `.failed` is not a disagreement between two
    /// versions at all — it is a full disk or a read-only volume, where there is one version and
    /// nothing to compare it against.
    ///
    /// A property on the stop rather than a condition at the header's call site, because it is a
    /// rule about which stops have a second version to show and the view must not be the place that
    /// knows.
    var offersDiff: Bool {
        switch self {
        case .diverged(.changed): return true
        case .diverged(.missing), .failed, .unchecked: return false
        }
    }

    /// **Whether the header's words save** (TE149): a failed write is settled by writing again, so
    /// "not saving — couldn't write" is ⌘S. Not a divergence — that is a question first — and not
    /// "couldn't check the save", which TE147 clears by itself.
    var savesFromTheHeader: Bool {
        if case .failed = self { return true }
        return false
    }

    /// **Whether the header's words are Save Again** (TE149): "not saving — no longer on disk".
    var savesAgainFromTheHeader: Bool { self == .diverged(.missing) }
}
