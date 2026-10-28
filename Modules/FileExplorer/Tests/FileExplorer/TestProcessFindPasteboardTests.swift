import AppKit
import Testing
import TestProcessFindPasteboard

/// **Every find bar in this test process reads and writes a Find pasteboard of its own**, because
/// the target links `TestProcessFindPasteboard`, whose constructor points requests for the Find
/// pasteboard at a board named for this process before any test runs. Fails if the target stops
/// linking it — and then another test process's search string can land in a find bar between a
/// test's seeding and its read: `docs/flaky-tests.md` ▸ *A named NSPasteboard is machine-global, so
/// two test PROCESSES share it*.
@Suite struct TestProcessFindPasteboardTests {
    @Test func theFindPasteboardIsThisProcesssOwn() {
        let name = TestProcessFindPasteboardName()
        #expect(name != NSPasteboard.Name.find.rawValue)
        #expect(name.hasSuffix(".\(ProcessInfo.processInfo.processIdentifier)"))
        #expect(NSPasteboard(name: .find).name.rawValue == name)
    }

    /// AppKit's own write, not only `NSPasteboard(name:)`: Use Selection for Find lands on the
    /// private board.
    @Test @MainActor func useSelectionForFindWritesThePrivateBoard() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.usesFindBar = true
        view.string = "private word"
        view.setSelectedRange(NSRange(location: 0, length: 7))
        let sender = NSMenuItem()
        sender.tag = NSTextFinder.Action.setSearchString.rawValue
        view.performTextFinderAction(sender)
        let board = NSPasteboard(name: NSPasteboard.Name(TestProcessFindPasteboardName()))
        #expect(board.string(forType: .string) == "private")
    }
}
