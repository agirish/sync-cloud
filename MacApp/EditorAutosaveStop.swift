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
        case .diverged(.missing), .failed: return false
        }
    }
}
