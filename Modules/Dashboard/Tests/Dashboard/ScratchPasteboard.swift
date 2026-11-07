import AppKit

/// A pasteboard of the calling test's own, emptied as it is handed over, for a `FileActionHandler`
/// that needs one but never copies: `.general` is the user's clipboard. Named for the file and the
/// test, since a suite's tests run in parallel, and for this process, since named boards live in
/// the machine-wide pasteboard server.
func scratchPasteboard(_ function: String = #function, fileID: String = #fileID) -> NSPasteboard {
    let board = NSPasteboard(name: NSPasteboard.Name(
        "SyncCloudTests.\(fileID).\(function).\(ProcessInfo.processInfo.processIdentifier)"))
    board.clearContents()
    return board
}
