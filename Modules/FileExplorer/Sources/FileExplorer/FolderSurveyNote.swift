import Sync

/// The words a finished folder-memory survey reports, for the note above the menu item that runs it.
///
/// **Pure and separate so the sentence can be asserted without mounting a menu.** A `Menu`'s content
/// is not rendered until the menu is opened, so a test that mounts the header can see this string
/// only by reading the source — which is the kind of test that passes while the words say nothing.
/// The same reasoning that put `RenameBacklogTally`'s strings in their own type puts this here.
///
/// This is where ``LensWorkspaceView``'s finished survey report went when it left row 2 of the
/// header card. It used to be the widest tenant of that row (223pt on the Renames lens, measured),
/// the only one the layout could shorten, and the only one that was not about the list on screen —
/// it reports on *Update folder memory*, a Rescan-menu item, so it now sits above that item.
enum FolderSurveyNote {

    /// - Parameter report: the last survey's own account of itself.
    ///
    /// `foldersLearned` is carried here because a menu has room for both halves where a 22pt row
    /// had room for neither: on row 2 the sentence was the visible half and this was hidden in a
    /// tooltip behind it, which meant the standing fact — how much of the tree the memory actually
    /// knows — was reachable only by hovering a sentence that was itself truncated.
    static func text(for report: FileSyncManager.FilingSurveyReport) -> String {
        "Last survey: \(report.summary) "
            + "\(report.foldersLearned) folder\(report.foldersLearned == 1 ? "" : "s") "
            + "\(report.foldersLearned == 1 ? "has" : "have") learned content from the documents "
            + "already filed in them."
    }
}
