import Sync

/// The words a finished folder-memory survey reports, for the note above the Rescan menu's
/// *Refresh what’s learned* item that runs it (in ``LensWorkspaceView``).
///
/// Pure and separate so a test can assert the sentence: a `Menu`'s content isn't rendered until it
/// opens, as with `RenameBacklogTally`.
enum FolderSurveyNote {

    /// - Parameter report: the last survey's own account of itself.
    ///
    /// Includes `foldersLearned`, how much of the tree the memory knows, since the menu has room
    /// for both halves.
    static func text(for report: FileSyncManager.FilingSurveyReport) -> String {
        "Last survey: \(report.summary) "
            + "\(report.foldersLearned) folder\(report.foldersLearned == 1 ? "" : "s") "
            + "\(report.foldersLearned == 1 ? "has" : "have") learned content from the documents "
            + "already filed in them."
    }
}
