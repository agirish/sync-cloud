import Testing
import Foundation
import FileExplorer
import Settings
import Sync
@testable import SyncCloud

/// `PaneActionDelegate`'s ways out of a row (Find Duplicates, Organize, PDF Tools), asserted on the
/// real delegate, through the existential every caller uses, and on the handlers themselves.
@MainActor
@Suite struct PaneDoorDelegateTests {

    private func delegate(syncManager: FileSyncManager, settings: SettingsManager) -> PaneActionDelegate {
        PaneActionDelegate(
            handler: nil, syncManager: syncManager, settings: settings, isLeft: true,
            leftProviderId: "left", rightProviderId: "right", isSingleSource: false, ownsOrganizeScope: false, servesEditor: false,
            forceRefreshAction: {}, onGetInfo: { _ in }, onChooseDestination: { _, _ in }, onOpenInEditor: { _ in },
            ignoreStateToken: [], keptNamesToken: [], onFindDuplicatesOf: { _ in },
            onOrganizeFolder: { _ in }, onCheckFolderShape: { _ in }, onOrganizeScope: { _ in }, onOpenInNewTab: { _ in }, onNewTabHere: { _ in }, onCloseTab: { })
    }

    /// The protocol's defaults offer nothing, so a conformer with no workspace behind it (every
    /// test stub, every pane that isn't a real provider view) draws none of these items. Reached
    /// through an existential, the call shape `FileTreeView` makes, because a member declared only
    /// in a protocol extension dispatches statically.
    @Test func aDelegateWithNoWorkspaceOffersNoDoorThroughTheExistential() {
        struct Stub: FileActionDelegate {
            func handleRefresh() {}
            func handleOpenInEditor(_ path: String) {}
            func handleFocus(_ node: FileNode) {}
            func handleCopy(_ nodes: [FileNode]) {}
            func handleMove(_ nodes: [FileNode]) {}
            func handleDelete(_ nodes: [FileNode]) {}
            func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) {}
            func handlePaste(_ targetDir: FileNode) {}
            func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode]) {}
            func handlePasteToPath(_ path: String) {}
            func handleRename(_ node: FileNode) {}
            func handleCreateFolder(at path: String) {}
            func handleGetInfo(for path: String) {}
            func handleSort(_ option: SortOption) {}
            func handleIgnore(_ nodes: [FileNode]) {}
            func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool { false }
        }
        let existential: FileActionDelegate = Stub()
        #expect(existential.canFindDuplicates == false,
                "a stub with no workspace behind it offered the Duplicates door")
        #expect(existential.canOrganizeFolder == false,
                "a stub with no workspace behind it offered the Organize door")
        #expect(existential.canRunPDFTools == false,
                "a stub with no window behind it offered the PDF Tools submenu")
    }

    /// PDF Tools, through the existential the row menu uses; its handler passes on PDFs only, and
    /// password tools one file at a time, whatever the menu did.
    @Test func thePDFToolsDoorSurvivesTheExistentialAndGuardsItsHandler() {
        var asked: [(PDFToolRequest, [String])] = []
        var concrete = delegate(syncManager: FileSyncManager(), settings: SettingsManager())
        concrete.onPDFTool = { asked.append(($0, $1)) }
        let existential: FileActionDelegate = concrete
        #expect(existential.canRunPDFTools,
                "the real pane's answer did not survive the existential — the member is extension-only")
        existential.handlePDFTool(.compress, paths: ["/a/One.pdf", "/a/Two.pdf"])
        existential.handlePDFTool(.protect, paths: ["/a/One.pdf"])
        existential.handlePDFTool(.compress, paths: ["/a/One.pdf", "/a/notes.md"])
        existential.handlePDFTool(.removePassword, paths: ["/a/One.pdf", "/a/Two.pdf"])
        existential.handlePDFTool(.compress, paths: [])
        #expect(asked.map(\.0) == [.compress, .protect], "the handler passed on \(asked)")
        #expect(asked.map(\.1) == [["/a/One.pdf", "/a/Two.pdf"], ["/a/One.pdf"]])
    }

    /// A real pane does offer Find Duplicates and Organize, so the stub test above can't pass by
    /// the items being gated off everywhere.
    @Test func aRealPaneOffersTheDuplicatesDoor() {
        let d = delegate(syncManager: FileSyncManager(), settings: SettingsManager())
        #expect(d.canFindDuplicates)
        #expect(d.canOrganizeFolder)
    }

    /// The dispatch trap, through an existential. Every caller reaches the delegate through
    /// `FileActionDelegate`, so a member declared only in the protocol extension dispatches
    /// statically to the default and the conformer's override is never reached; the menu just
    /// never draws the item. This keeps the member a protocol requirement.
    @Test func theOrganizeDoorSurvivesTheExistential() {
        let concrete = delegate(syncManager: FileSyncManager(), settings: SettingsManager())
        let existential: FileActionDelegate = concrete
        #expect(existential.canOrganizeFolder,
                "the real pane's answer did not survive the existential — the member is extension-only and dispatching to the default")
    }

    /// Files never reach the Organize handoff: "where do the loose files in here belong" means
    /// nothing for a file. Asserted on the handler, not only the menu, so the guarantee travels
    /// with the action, and in both directions, or the guard proves nothing.
    @Test func theOrganizeHandoffIgnoresFiles() {
        var asked: [String] = []
        let base = delegate(syncManager: FileSyncManager(), settings: SettingsManager())
        let d = PaneActionDelegate(
            handler: nil, syncManager: base.syncManager, settings: base.settings, isLeft: true,
            leftProviderId: "left", rightProviderId: "right", isSingleSource: false, ownsOrganizeScope: false, servesEditor: false,
            forceRefreshAction: {}, onGetInfo: { _ in }, onChooseDestination: { _, _ in }, onOpenInEditor: { _ in },
            ignoreStateToken: [], keptNamesToken: [],
            onFindDuplicatesOf: { _ in }, onOrganizeFolder: { asked.append($0.id) }, onCheckFolderShape: { _ in }, onOrganizeScope: { _ in }, onOpenInNewTab: { _ in }, onNewTabHere: { _ in }, onCloseTab: { })

        d.handleOrganizeFolder(FileNode(id: "/Users/u/Projects/a.txt", name: "a.txt",
                                        isDirectory: false, children: nil))
        #expect(asked.isEmpty, "a file reached the Organize handoff")

        d.handleOrganizeFolder(FileNode(id: "/Users/u/Projects", name: "Projects",
                                        isDirectory: true, children: []))
        #expect(asked == ["/Users/u/Projects"],
                "a folder did NOT reach the handoff — the guard above proves nothing")
    }

    /// Folders never reach the duplicates handoff: a folder overlap group is a different unit.
    /// Asserted on the handler, not only the menu, so the guarantee travels with the action.
    @Test func theDuplicatesHandoffIgnoresFolders() {
        var asked: [String] = []
        var d = delegate(syncManager: FileSyncManager(), settings: SettingsManager())
        d = PaneActionDelegate(
            handler: nil, syncManager: d.syncManager, settings: d.settings, isLeft: true,
            leftProviderId: "left", rightProviderId: "right", isSingleSource: false, ownsOrganizeScope: false, servesEditor: false,
            forceRefreshAction: {}, onGetInfo: { _ in }, onChooseDestination: { _, _ in }, onOpenInEditor: { _ in },
            ignoreStateToken: [], keptNamesToken: [],
            onFindDuplicatesOf: { asked.append($0.id) }, onOrganizeFolder: { _ in }, onCheckFolderShape: { _ in }, onOrganizeScope: { _ in }, onOpenInNewTab: { _ in }, onNewTabHere: { _ in }, onCloseTab: { })

        d.handleFindDuplicates(FileNode(id: "/Users/u/Projects", name: "Projects",
                                        isDirectory: true, children: []))
        #expect(asked.isEmpty, "a folder reached the duplicates handoff")

        d.handleFindDuplicates(FileNode(id: "/Users/u/Projects/a.txt", name: "a.txt",
                                        isDirectory: false, children: nil))
        #expect(asked == ["/Users/u/Projects/a.txt"],
                "a file did NOT reach the handoff — the guard above proves nothing")
    }
}
