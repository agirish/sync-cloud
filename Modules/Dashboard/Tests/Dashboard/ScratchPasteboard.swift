import AppKit

/// A pasteboard of the calling test's own, emptied as it is handed over: `.general` is the user's
/// clipboard. Named for the file and the test (or the `label` a helper serving several tests
/// passes), since a suite's tests run in parallel and `clearContents()` is no defence against a
/// sibling writing. Named for this process too: named boards live in the machine-wide pasteboard
/// server, so two test processes would share one (`docs/flaky-tests.md`, "A named NSPasteboard is
/// machine-global, so two test PROCESSES share it").
func scratchPasteboard(_ label: String = #function, fileID: String = #fileID) -> NSPasteboard {
    let board = NSPasteboard(name: NSPasteboard.Name(
        "SyncCloudTests.\(fileID).\(label).\(ProcessInfo.processInfo.processIdentifier)"))
    board.clearContents()
    return board
}
