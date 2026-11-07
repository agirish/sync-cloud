import Testing
import Foundation
import Sync
import Settings
import FileExplorer
@testable import SyncCloud

/// Only Edit's own pane dims anything, and the field that says so takes part in the pane's
/// equality: the two claims Edit's dimming of unopenable rows rests on.
///
/// Local-only: an app-target suite CI doesn't run, so run it by hand.
@MainActor
@Suite struct PaneEditorRefusalDelegateTests {

    private func delegate(servesEditor: Bool,
                          syncManager: FileSyncManager, settings: SettingsManager) -> PaneActionDelegate {
        paneDelegate(syncManager: syncManager, settings: settings, isSingleSource: true, servesEditor: servesEditor)
    }

    /// The same rows against both delegates: only (Edit, a file, a kind Edit doesn't open)
    /// answers. Edit opens PDFs, so they stay bright.
    @Test func onlyTheEditorsDelegateRefusesAnything() {
        let manager = FileSyncManager.scratch()
        let settings = SettingsManager.scratch()
        let browse = delegate(servesEditor: false, syncManager: manager, settings: settings)
        let edit = delegate(servesEditor: true, syncManager: manager, settings: settings)

        #expect(browse.editorRefusal(forPath: "/a/x.pdf", isDirectory: false, size: 10) == nil)
        #expect(browse.editorRefusal(forPath: "/a/x.md", isDirectory: false, size: 10) == nil)
        #expect(browse.editorRefusal(forPath: "/a/x.pdf", isDirectory: true, size: 0) == nil)

        #expect(edit.editorRefusal(forPath: "/a/x.zip", isDirectory: false, size: 10) == "Not a kind Edit opens.")
        #expect(edit.editorRefusal(forPath: "/a/x.pdf", isDirectory: false, size: 10) == nil)
        #expect(edit.editorRefusal(forPath: "/a/x.md", isDirectory: false, size: 10) == nil)
        // A folder named like a PDF is still a folder: it leads out of the listing and stays bright.
        #expect(edit.editorRefusal(forPath: "/a/x.pdf", isDirectory: true, size: 0) == nil)
    }

    /// The size refusal is the rail's sentence, from the rail's one static, so the two can't
    /// drift. Checked against the static, not a literal, because its number is
    /// `BoundedTextRead.maxBytes`, which this target can't see.
    @Test func aTooLargeTextFileIsRefusedInTheRailsWords() {
        let edit = delegate(servesEditor: true, syncManager: FileSyncManager.scratch(), settings: SettingsManager.scratch())
        let huge = 64 * 1024 * 1024
        let expected = EditorRailEntry.tooLargeReason(size: huge)
        #expect(expected != nil, "the fixture is not over the limit, so the test below proves nothing")
        #expect(edit.editorRefusal(forPath: "/a/x.md", isDirectory: false, size: huge) == expected)
        #expect(edit.editorRefusal(forPath: "/a/x.md", isDirectory: false, size: 10) == nil)
        // The kind comes first: a huge archive is refused for its kind, not its size.
        #expect(edit.editorRefusal(forPath: "/a/x.zip", isDirectory: false, size: huge) == "Not a kind Edit opens.")
        // A huge PDF isn't refused at all: PDFKit draws it, and the text read's limit isn't its own.
        #expect(edit.editorRefusal(forPath: "/a/x.pdf", isDirectory: false, size: huge) == nil)
    }

    /// Guards the re-render. `FileTreeView` is `Equatable` through `isEquivalent`; a field left out
    /// of it means switching into Edit doesn't re-render the pane, and rows stay bright until
    /// something unrelated moves.
    @Test func servesEditorTakesPartInEquivalence() {
        let manager = FileSyncManager.scratch()
        let settings = SettingsManager.scratch()
        let browse = delegate(servesEditor: false, syncManager: manager, settings: settings)
        let edit = delegate(servesEditor: true, syncManager: manager, settings: settings)
        let browseAgain = delegate(servesEditor: false, syncManager: manager, settings: settings)

        #expect(browse.isEquivalent(to: edit) == false, "two delegates differing only in servesEditor read as equivalent")
        // The control: with the field equal the pair is equivalent, so the line above fails on the
        // field and not on something else.
        #expect(browse.isEquivalent(to: browseAgain), "the fixture pair is not equivalent even with servesEditor equal")
    }
}
