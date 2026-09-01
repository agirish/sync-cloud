import FileExplorer

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

    /// What the header says while this is in force. Short, because it sits on one line beside the
    /// file name — the alert is where the detail is.
    var caption: String {
        switch self {
        case .diverged(.changed): return "not saving — changed on disk"
        case .diverged(.missing): return "not saving — moved or renamed"
        case .failed: return "not saving — couldn't write"
        }
    }
}
