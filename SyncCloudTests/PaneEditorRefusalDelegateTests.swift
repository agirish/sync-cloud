import Testing
import Foundation
import Sync
import Settings
import FileExplorer
@testable import SyncCloud

/// **Only Edit's own pane dims anything**, and the field that says so takes part in the pane's
/// equality — the two claims TE41's dimming rests on.
///
/// **Local-only** — app target, invisible to CI; run by hand and named in the commit body.
@MainActor
@Suite struct PaneEditorRefusalDelegateTests {

    private func delegate(servesEditor: Bool,
                          syncManager: FileSyncManager, settings: SettingsManager) -> PaneActionDelegate {
        PaneActionDelegate(
            handler: nil, syncManager: syncManager, settings: settings, isLeft: true,
            leftProviderId: "left", rightProviderId: "right", isSingleSource: true, ownsOrganizeScope: false,
            servesEditor: servesEditor,
            forceRefreshAction: {}, onGetInfo: { _ in }, onChooseDestination: { _, _ in }, onOpenInEditor: { _ in },
            ignoreStateToken: [], keptNamesToken: [],
            homeBadgeCoverage: nil, onFindDuplicatesOf: { _ in },
            onOrganizeFolder: { _ in }, onCheckFolderShape: { _ in }, onOrganizeScope: { _ in }, onOpenInNewTab: { _ in }, onNewTabHere: { _ in }, onCloseTab: { })
    }

    /// The same three rows against both delegates: only (Edit, a file, not text) answers.
    @Test func onlyTheEditorsDelegateRefusesAnything() {
        let manager = FileSyncManager()
        let settings = SettingsManager()
        let browse = delegate(servesEditor: false, syncManager: manager, settings: settings)
        let edit = delegate(servesEditor: true, syncManager: manager, settings: settings)

        #expect(browse.editorRefusal(forPath: "/a/x.pdf", isDirectory: false, size: 10) == nil)
        #expect(browse.editorRefusal(forPath: "/a/x.md", isDirectory: false, size: 10) == nil)
        #expect(browse.editorRefusal(forPath: "/a/x.pdf", isDirectory: true, size: 0) == nil)

        #expect(edit.editorRefusal(forPath: "/a/x.pdf", isDirectory: false, size: 10) == "Not a kind Edit opens.")
        #expect(edit.editorRefusal(forPath: "/a/x.md", isDirectory: false, size: 10) == nil)
        // A folder named like a PDF is still a folder: it leads out of the listing and stays bright.
        #expect(edit.editorRefusal(forPath: "/a/x.pdf", isDirectory: true, size: 0) == nil)
    }

    /// The size refusal is the rail's sentence, from the rail's one static — so the two surfaces
    /// cannot drift. Checked against the static rather than a literal, because the number in it is
    /// `BoundedTextRead.maxBytes`, which this target cannot see.
    @Test func aTooLargeTextFileIsRefusedInTheRailsWords() {
        let edit = delegate(servesEditor: true, syncManager: FileSyncManager(), settings: SettingsManager())
        let huge = 64 * 1024 * 1024
        let expected = EditorRailEntry.tooLargeReason(size: huge)
        #expect(expected != nil, "the fixture is not over the limit, so the test below proves nothing")
        #expect(edit.editorRefusal(forPath: "/a/x.md", isDirectory: false, size: huge) == expected)
        #expect(edit.editorRefusal(forPath: "/a/x.md", isDirectory: false, size: 10) == nil)
        // The kind comes first: a huge PDF is refused for its kind, not its size.
        #expect(edit.editorRefusal(forPath: "/a/x.pdf", isDirectory: false, size: huge) == "Not a kind Edit opens.")
    }

    /// **The one that guards the re-render.** `FileTreeView` is `Equatable` through
    /// `isEquivalent`; a field left out of it means switching into Edit does not re-render the
    /// pane and the rows stay bright until something unrelated moves.
    @Test func servesEditorTakesPartInEquivalence() {
        let manager = FileSyncManager()
        let settings = SettingsManager()
        let browse = delegate(servesEditor: false, syncManager: manager, settings: settings)
        let edit = delegate(servesEditor: true, syncManager: manager, settings: settings)
        let browseAgain = delegate(servesEditor: false, syncManager: manager, settings: settings)

        #expect(browse.isEquivalent(to: edit) == false, "two delegates differing only in servesEditor read as equivalent")
        // The control: with the field equal, the comparison still opts in — so the line above is
        // failing on the field and not on something else in the comparison.
        #expect(browse.isEquivalent(to: browseAgain), "the fixture pair is not equivalent even with servesEditor equal")
    }
}
