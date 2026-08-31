import Testing
import Foundation
import FileExplorer
import Settings
import Sync
@testable import SyncCloud

/// **Open moves Organize's scope; browsing does not.**
///
/// Those two rules look contradictory and are not. What Organize's scope refuses is *live-binding
/// to whatever folder the pane drifted to* — the left pane is also how destinations get inspected
/// while filing, so a scope that followed every navigation would destroy the queue mid-file. Open
/// is not drift: it is the user naming a folder and re-rooting the pane on it, the same act as
/// "Organize This Folder…" arriving through a different door. Leaving them disagreeing would root
/// the pane at one subject while every lens answered about another.
///
/// The gate is `isSingleSource`, which is exactly when the row menu reads **Open**. On the
/// comparison panes the identical call is "Compare only this folder" — a claim about the
/// comparison, not about what Organize answers — and must not re-aim the lenses.
///
/// Asserted in BOTH directions, because a net over one path proves nothing about the other: a
/// delegate that scoped on every focus would pass a single-source-only test, and one that never
/// scoped would pass a compare-only test.
@MainActor
@Suite struct PaneOpenMovesScopeTests {

    private func delegate(isSingleSource: Bool,
                          ownsOrganizeScope: Bool? = nil,
                          scoped: @escaping (FileNode) -> Void) -> PaneActionDelegate {
        PaneActionDelegate(
            handler: nil, syncManager: FileSyncManager(), settings: SettingsManager(),
            isLeft: true, leftProviderId: "left", rightProviderId: "right",
            isSingleSource: isSingleSource,
            // Defaults to `isSingleSource` so the existing cases keep asking what they asked; the
            // two new ones below pass it explicitly, which is the whole point of the split.
            ownsOrganizeScope: ownsOrganizeScope ?? isSingleSource,
            forceRefreshAction: {}, onGetInfo: { _ in }, onChooseDestination: { _, _ in }, onOpenInEditor: { _ in },
            ignoreStateToken: [], keptNamesToken: [], homeBadgeCoverage: nil,
            onFindDuplicatesOf: { _ in }, onOrganizeFolder: { _ in }, onCheckFolderShape: { _ in },
            onOrganizeScope: scoped, onOpenInNewTab: { _ in }, onNewTabHere: { _ in }, onCloseTab: { })
    }

    private static func folder(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true)
    }

    private static func file(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false)
    }

    /// Browse looks like the rail to a layout question and is not the rail.
    ///
    /// `TopPaneVisibility.mode(for:)` answers `.compare` for exactly one workspace, so Browse and
    /// Storage are both `.singleSource` — the gate this used to be. Right-click ▸ Open anywhere in
    /// Browse therefore re-aimed every Organize lens at a folder the user had never told Organize
    /// about, and it survived relaunch. Paths resolved correctly, so nothing looked broken; the
    /// lenses were simply answering about somewhere else.
    @Test func openInBrowseDoesNOTMoveTheScope() {
        var scoped: [String] = []
        let d = delegate(isSingleSource: true, ownsOrganizeScope: false) { scoped.append($0.id) }
        d.handleFocus(Self.folder("/Users/u/Documents/Legal"))
        #expect(scoped.isEmpty)
    }

    /// The layout question and the ownership question must be separately answerable, or the split
    /// is decorative: a delegate that ignored `ownsOrganizeScope` and kept reading `isSingleSource`
    /// would pass the case above only by accident of the two agreeing.
    @Test func scopeOwnershipIsReadRatherThanInferredFromTheLayout() {
        var scoped: [String] = []
        // The other diagonal: a comparison layout that nonetheless owns the scope. Not a shipping
        // combination — it exists to prove the flag is what is consulted.
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
        // Same call, different verb. The comparison panes isolate a mapping; they do not choose
        // what Organize is answering about.
        var scoped: [String] = []
        let d = delegate(isSingleSource: false) { scoped.append($0.id) }
        d.handleFocus(Self.folder("/Users/u/Documents/Legal"))
        #expect(scoped.isEmpty)
    }

    @Test func focusingAFILEMovesNothing() {
        // Defensive, and cheap: a scope is a subtree. `handleFocus` is reached from a folder-only
        // menu branch today, but a scope silently set to a file path would filter every lens to
        // exactly nothing with no visible cause.
        var scoped: [String] = []
        let d = delegate(isSingleSource: true) { scoped.append($0.id) }
        d.handleFocus(Self.file("/Users/u/Documents/Legal/lease.pdf"))
        #expect(scoped.isEmpty)
    }

    @Test func openDoesNotAlsoStartAScan() {
        // Open is navigation. `onOrganizeFolder` is the door that scans ("Organize This Folder…");
        // routing Open through it too would put a filing pass behind every folder you step into.
        // Scope filters rather than rescans, so the other lenses re-answer for free regardless.
        var scanned: [String] = []
        var scoped: [String] = []
        let d = PaneActionDelegate(
            handler: nil, syncManager: FileSyncManager(), settings: SettingsManager(),
            isLeft: true, leftProviderId: "left", rightProviderId: "right", isSingleSource: true, ownsOrganizeScope: true,
            forceRefreshAction: {}, onGetInfo: { _ in }, onChooseDestination: { _, _ in }, onOpenInEditor: { _ in },
            ignoreStateToken: [], keptNamesToken: [], homeBadgeCoverage: nil,
            onFindDuplicatesOf: { _ in },
            onOrganizeFolder: { scanned.append($0.id) }, onCheckFolderShape: { _ in },
            onOrganizeScope: { scoped.append($0.id) }, onOpenInNewTab: { _ in }, onNewTabHere: { _ in }, onCloseTab: { })

        d.handleFocus(Self.folder("/Users/u/Documents/Legal"))
        #expect(scoped == ["/Users/u/Documents/Legal"])
        #expect(scanned.isEmpty, "Open started a scan — that belongs to Organize This Folder…")

        // And the scanning door still both scans and (via ContentView) scopes.
        d.handleOrganizeFolder(Self.folder("/Users/u/Documents/Finance"))
        #expect(scanned == ["/Users/u/Documents/Finance"])
    }
}
