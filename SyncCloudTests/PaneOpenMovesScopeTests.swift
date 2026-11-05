import Testing
import Foundation
import FileExplorer
import Settings
import Sync
@testable import SyncCloud

/// Open moves Organize's scope; browsing does not. The scope must not follow wherever the pane
/// drifts: the left pane is also how destinations get inspected while filing, so a scope that
/// followed every navigation would destroy the queue mid-file. Open is the user naming a folder,
/// like "Organize This Folder…", so it re-aims the lenses too.
///
/// The gate is `ownsOrganizeScope`, not the layout: on the comparison panes the same call is
/// "Compare only this folder", a claim about the comparison, and must not re-aim the lenses.
/// Asserted in both directions, since a delegate that always or never scoped would pass one.
@MainActor
@Suite struct PaneOpenMovesScopeTests {

    private func delegate(isSingleSource: Bool,
                          ownsOrganizeScope: Bool? = nil,
                          scoped: @escaping (FileNode) -> Void) -> PaneActionDelegate {
        PaneActionDelegate(
            handler: nil, syncManager: FileSyncManager(), settings: SettingsManager(),
            isLeft: true, leftProviderId: "left", rightProviderId: "right",
            isSingleSource: isSingleSource,
            // Defaults to `isSingleSource`; the two Browse and diagonal cases pass it explicitly.
            ownsOrganizeScope: ownsOrganizeScope ?? isSingleSource, servesEditor: false,
            forceRefreshAction: {}, onGetInfo: { _ in }, onChooseDestination: { _, _ in }, onOpenInEditor: { _ in },
            ignoreStateToken: [], keptNamesToken: [],
            onFindDuplicatesOf: { _ in }, onOrganizeFolder: { _ in }, onCheckFolderShape: { _ in },
            onOrganizeScope: scoped, onOpenInNewTab: { _ in }, onNewTabHere: { _ in }, onCloseTab: { })
    }

    private static func folder(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true)
    }

    private static func file(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false)
    }

    /// Browse looks like the rail to a layout question and isn't the rail.
    /// `TopPaneVisibility.mode(for:)` calls Browse and Storage `.singleSource`, so gating on layout
    /// would let Right-click ▸ Open in Browse re-aim every Organize lens at a folder Organize was
    /// never told about, surviving relaunch, with nothing looking broken.
    @Test func openInBrowseDoesNOTMoveTheScope() {
        var scoped: [String] = []
        let d = delegate(isSingleSource: true, ownsOrganizeScope: false) { scoped.append($0.id) }
        d.handleFocus(Self.folder("/Users/u/Documents/Legal"))
        #expect(scoped.isEmpty)
    }

    /// Layout and ownership must be separately answerable: a delegate that read `isSingleSource`
    /// instead of `ownsOrganizeScope` would pass the case above only by accident.
    @Test func scopeOwnershipIsReadRatherThanInferredFromTheLayout() {
        var scoped: [String] = []
        // The other diagonal: a comparison layout that owns the scope. Not a shipping combination;
        // it proves the flag is what is consulted.
        let d = delegate(isSingleSource: false, ownsOrganizeScope: true) { scoped.append($0.id) }
        d.handleFocus(Self.folder("/Users/u/Documents/Legal"))
        #expect(scoped == ["/Users/u/Documents/Legal"])
    }

    @Test func openOnTheSingleSourceRailMovesTheScope() {
        var scoped: [String] = []
        let d = delegate(isSingleSource: true) { scoped.append($0.id) }
        d.handleFocus(Self.folder("/Users/u/Documents/Legal"))
        #expect(scoped == ["/Users/u/Documents/Legal"])
    }

    @Test func compareOnlyThisFolderDoesNOTMoveTheScope() {
        // Same call, different verb: the comparison panes isolate a mapping; they don't choose
        // what Organize answers about.
        var scoped: [String] = []
        let d = delegate(isSingleSource: false) { scoped.append($0.id) }
        d.handleFocus(Self.folder("/Users/u/Documents/Legal"))
        #expect(scoped.isEmpty)
    }

    @Test func focusingAFILEMovesNothing() {
        // Defensive: a scope is a subtree. `handleFocus` is reached from a folder-only menu
        // branch, but a scope set to a file path would filter every lens to nothing, unexplained.
        var scoped: [String] = []
        let d = delegate(isSingleSource: true) { scoped.append($0.id) }
        d.handleFocus(Self.file("/Users/u/Documents/Legal/lease.pdf"))
        #expect(scoped.isEmpty)
    }

    @Test func openDoesNotAlsoStartAScan() {
        // Open is navigation. `onOrganizeFolder` is what scans ("Organize This Folder…"); routing
        // Open through it would run a filing pass for every folder stepped into. Scope filters
        // rather than rescans, so the lenses re-answer for free.
        var scanned: [String] = []
        var scoped: [String] = []
        let d = PaneActionDelegate(
            handler: nil, syncManager: FileSyncManager(), settings: SettingsManager(),
            isLeft: true, leftProviderId: "left", rightProviderId: "right", isSingleSource: true, ownsOrganizeScope: true, servesEditor: false,
            forceRefreshAction: {}, onGetInfo: { _ in }, onChooseDestination: { _, _ in }, onOpenInEditor: { _ in },
            ignoreStateToken: [], keptNamesToken: [],
            onFindDuplicatesOf: { _ in },
            onOrganizeFolder: { scanned.append($0.id) }, onCheckFolderShape: { _ in },
            onOrganizeScope: { scoped.append($0.id) }, onOpenInNewTab: { _ in }, onNewTabHere: { _ in }, onCloseTab: { })

        d.handleFocus(Self.folder("/Users/u/Documents/Legal"))
        #expect(scoped == ["/Users/u/Documents/Legal"])
        #expect(scanned.isEmpty, "Open started a scan — that belongs to Organize This Folder…")

        // And Organize This Folder… still both scans and (via ContentView) scopes.
        d.handleOrganizeFolder(Self.folder("/Users/u/Documents/Finance"))
        #expect(scanned == ["/Users/u/Documents/Finance"])
    }
}
