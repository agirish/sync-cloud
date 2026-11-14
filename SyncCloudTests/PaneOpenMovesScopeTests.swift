import Testing
import Foundation
import FileExplorer
import Settings
import Sync
@testable import SyncCloud

/// Open moves Organize's scope; browsing does not, since the left pane is also how destinations
/// are inspected while filing, and a scope that followed it would destroy the queue mid-file. The
/// gate is `ownsOrganizeScope`, not the layout: on the comparison panes the same call is "Compare
/// only this folder". Asserted both ways, since an always- or never-scoping delegate passes one.
@MainActor
@Suite struct PaneOpenMovesScopeTests {
    private func delegate(isSingleSource: Bool,
                          ownsOrganizeScope: Bool? = nil,
                          scoped: @escaping (FileNode) -> Void) -> PaneActionDelegate {
        // `ownsOrganizeScope` defaults to `isSingleSource`; the Browse and diagonal cases pass it.
        paneDelegate(isSingleSource: isSingleSource, ownsOrganizeScope: ownsOrganizeScope ?? isSingleSource,
                     onOrganizeScope: scoped)
    }

    private static func folder(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true)
    }

    private static func file(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false)
    }

    /// `(single source, owns the scope, Open on a folder moves the scope)`.
    @Test(arguments: [
        // Open on the single-source rail moves the scope.
        (true, true, true),
        // Browse is `.singleSource` too, so a layout gate would let Open in Browse silently re-aim
        // every Organize lens, surviving relaunch.
        (true, false, false),
        // "Compare only this folder", the same call on the comparison panes: they isolate a
        // mapping; they don't choose what Organize answers about.
        (false, false, false),
        // The other diagonal: a comparison layout that owns the scope. Not a shipping combination;
        // it proves the flag, not the layout, is what is consulted.
        (false, true, true),
    ])
    func openMovesTheScopeOnlyWhereThePaneOwnsIt(isSingleSource: Bool, ownsOrganizeScope: Bool, moves: Bool) {
        var scoped: [String] = []
        let d = delegate(isSingleSource: isSingleSource, ownsOrganizeScope: ownsOrganizeScope) { scoped.append($0.id) }
        d.handleFocus(Self.folder("/Users/u/Documents/Legal"))
        #expect(scoped == (moves ? ["/Users/u/Documents/Legal"] : []))
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
        // Open is navigation: routed through `onOrganizeFolder` it would run a filing pass for
        // every folder stepped into. Scope filters rather than rescans.
        var scanned: [String] = []
        var scoped: [String] = []
        let d = paneDelegate(isSingleSource: true, ownsOrganizeScope: true,
                             onOrganizeFolder: { scanned.append($0.id) }, onOrganizeScope: { scoped.append($0.id) })

        d.handleFocus(Self.folder("/Users/u/Documents/Legal"))
        #expect(scoped == ["/Users/u/Documents/Legal"])
        #expect(scanned.isEmpty, "Open started a scan — that belongs to Organize This Folder…")

        // And Organize This Folder… still both scans and (via ContentView) scopes.
        d.handleOrganizeFolder(Self.folder("/Users/u/Documents/Finance"))
        #expect(scanned == ["/Users/u/Documents/Finance"])
    }
}
