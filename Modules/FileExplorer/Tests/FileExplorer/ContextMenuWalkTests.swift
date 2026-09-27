import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// A click no longer makes every row's context menu walk the tree (CP9).
///
/// SwiftUI builds a row's context menu with the row, so `FileContextMenu`'s body runs for every
/// visible row on every click — in both panes, because each pane's menus also take the other
/// pane's selection. Those bodies used to walk the tree. `menuNodes` now answers a row outside the
/// selection from the row itself, and `PaneSelectionResolver` walks once per selection for the
/// rows inside it and for the other pane's. The rules are pinned here as plain functions, and the
/// last case renders a real menu for every row to show that the bodies share the walks.
@MainActor
@Suite struct ContextMenuWalkTests {

    private static let nodes: [FileNode] = [
        FileNode(id: "/r/a.txt", name: "a.txt", isDirectory: false),
        FileNode(id: "/r/b.txt", name: "b.txt", isDirectory: false),
        FileNode(id: "/r/dir", name: "dir", isDirectory: true, children: [
            FileNode(id: "/r/dir/c.txt", name: "c.txt", isDirectory: false),
            FileNode(id: "/r/dir/sub", name: "sub", isDirectory: true, children: [
                FileNode(id: "/r/dir/sub/d.txt", name: "d.txt", isDirectory: false),
            ]),
        ]),
    ]

    private static func allRows(_ rows: [PaneRow]) -> [PaneRow] {
        rows.flatMap { [$0] + allRows($0.children ?? []) }
    }

    /// **A row outside the selection is answered from the row: nothing walks.** Probed with a tree
    /// that carries the row's stamp but none of its nodes, so no walk could return the row — getting
    /// it back means none ran. A row stamped by another publish, or by the other pane, is not this
    /// tree's, so it DOES walk and gets what a walk always gave it: here nothing, since it is absent.
    @Test func aRowOutsideTheSelectionIsAnsweredFromTheRow() {
        let node = FileNode(id: "/r/a.txt", name: "a.txt", isDirectory: false)
        let probe = PaneTree(side: .left, version: 7, nodes: [], rows: [])
        let resolver = PaneSelectionResolver()
        for selection: Set<String> in [[], ["/r/b.txt"]] {
            let own = PaneRow(side: .left, version: 7, node: node, children: nil)
            #expect(FileContextMenu.menuNodes(row: own, selection: selection, tree: probe,
                                              resolver: resolver).map(\.id) == ["/r/a.txt"])
            for foreign in [PaneRow(side: .left, version: 6, node: node, children: nil),
                            PaneRow(side: .right, version: 7, node: node, children: nil)] {
                #expect(FileContextMenu.menuNodes(row: foreign, selection: selection, tree: probe,
                                                  resolver: resolver).isEmpty,
                        "a row from another publish must walk (\(foreign.side), v\(foreign.version))")
            }
        }
        #expect(resolver.walks == 0, "a row outside the selection never reaches the resolver")
    }

    /// **The same answers as before, for every row and every kind of selection.** `menuNodes` is a
    /// faster route to `resolvedSelection`'s answer, never a different one: checked for every row of
    /// a nested tree against no selection, one row, two, a folder together with something inside it
    /// (which prunes to the folder), and selections naming a row that has gone.
    @Test func menuNodesAnswersExactlyAsResolvedSelectionDoes() {
        let tree = PaneTree(side: .left, version: 1, nodes: Self.nodes)
        let rows = Self.allRows(tree.rows)
        #expect(rows.count == 6, "the fixture lost a row")
        let selections: [Set<String>] = [
            [], ["/r/a.txt"], ["/r/a.txt", "/r/b.txt"], ["/r/dir", "/r/dir/sub/d.txt"],
            ["/r/gone.txt"], ["/r/b.txt", "/r/gone.txt"],
        ]
        for selection in selections {
            for row in rows {
                let answered = FileContextMenu.menuNodes(row: row, selection: selection, tree: tree,
                                                         resolver: PaneSelectionResolver())
                let walked = FileContextMenu.resolvedSelection(node: row.node, selection: selection,
                                                               tree: tree.nodes)
                #expect(answered.map(\.id) == walked.map(\.id),
                        "row \(row.id), selection \(selection.sorted())")
            }
        }
    }

    /// **Two nodes at one path answer with the same path.** iCloud's linked Documents appear under
    /// `~` and inside iCloud Drive at one id (`isCoveredElsewhere` on the second). The walk stops at
    /// the first; a row answers with itself. Either way the menu names one path, and every verb acts
    /// by path — which is the equivalence that matters, and all this can promise.
    @Test func aPathListedTwiceAnswersWithThatPath() {
        let real = FileNode(id: "/u/Documents", name: "Documents", isDirectory: true, children: [])
        let linked = FileNode(id: "/u/Documents", name: "Documents", isDirectory: true,
                              isCoveredElsewhere: true)
        let drive = FileNode(id: "/u/Drive", name: "Drive", isDirectory: true, children: [linked])
        let tree = PaneTree(side: .left, version: 1, nodes: [drive, real])
        for row in Self.allRows(tree.rows) {
            let answered = FileContextMenu.menuNodes(row: row, selection: [], tree: tree,
                                                     resolver: PaneSelectionResolver())
            let walked = FileContextMenu.resolvedSelection(node: row.node, selection: [], tree: tree.nodes)
            #expect(answered.map(\.id) == walked.map(\.id), "row \(row.id)")
        }
    }

    /// **One walk per selection, however many rows ask.** Every row builds its menu on every render;
    /// only the selected ones reach the resolver, and they share its walk. A new selection walks
    /// again, and so does a republished tree — a render that changes neither walks nothing.
    @Test func aSelectionIsWalkedOncePerTreeAndSelection() {
        var tree = PaneTree(side: .left, version: 1, nodes: Self.nodes)
        let resolver = PaneSelectionResolver()
        func render(_ selection: Set<String>) {
            for row in Self.allRows(tree.rows) {
                _ = FileContextMenu.menuNodes(row: row, selection: selection, tree: tree, resolver: resolver)
            }
        }
        render([])
        #expect(resolver.walks == 0, "nothing selected, nothing to walk")
        render(["/r/a.txt", "/r/b.txt"])
        render(["/r/a.txt", "/r/b.txt"])
        #expect(resolver.walks == 1, "two selected rows over two renders share one walk")
        render(["/r/b.txt"])
        #expect(resolver.walks == 2, "a new selection is walked afresh")
        tree = PaneTree(side: .left, version: 2, nodes: Self.nodes)
        render(["/r/b.txt"])
        #expect(resolver.walks == 3, "a republished tree is walked afresh")
    }

    /// **A new selection of the same size is resolved afresh.** One resolver across two clicks — `a`
    /// then `b`, same tree, one file each — must answer `b`'s menu with `b`. Every other case here
    /// changes the selection's size or the tree's version as well, so a memo keyed on anything short
    /// of the whole selection (its count, a subset test) would pass them all and hand `b`'s menu
    /// `a` — whose Delete would then trash the file the user clicked away from.
    @Test func aSameSizedSelectionIsResolvedAfresh() throws {
        let tree = PaneTree(side: .left, version: 1, nodes: Self.nodes)
        let rows = Self.allRows(tree.rows)
        let a = try #require(rows.first { $0.id == "/r/a.txt" })
        let b = try #require(rows.first { $0.id == "/r/b.txt" })
        let resolver = PaneSelectionResolver()
        #expect(FileContextMenu.menuNodes(row: a, selection: ["/r/a.txt"], tree: tree,
                                          resolver: resolver).map(\.id) == ["/r/a.txt"])
        #expect(FileContextMenu.menuNodes(row: b, selection: ["/r/b.txt"], tree: tree,
                                          resolver: resolver).map(\.id) == ["/r/b.txt"])
        #expect(resolver.nodes(at: ["/r/a.txt", "/r/dir/c.txt"], in: tree).map(\.id).sorted()
                == ["/r/a.txt", "/r/dir/c.txt"])
        #expect(resolver.nodes(at: ["/r/b.txt", "/r/dir/c.txt"], in: tree).map(\.id).sorted()
                == ["/r/b.txt", "/r/dir/c.txt"])
    }

    /// **An emptied selection lets its entry go.** An entry holds nodes, and a node its subtree: kept
    /// after the selection that made it, it would keep a tree the pane has replaced alive. The other
    /// pane's goes when it is asked about empty, the pane's own when a menu is built with nothing
    /// selected — and either way the next selection walks afresh, which is how this can tell.
    @Test func anEmptiedSelectionLetsItsEntryGo() {
        let left = PaneTree(side: .left, version: 1, nodes: Self.nodes)
        let right = PaneTree(side: .right, version: 1, nodes: Self.nodes)
        let resolver = PaneSelectionResolver()
        _ = resolver.nodes(at: ["/r/a.txt"], in: left)
        _ = resolver.nodes(at: ["/r/a.txt"], in: right)
        #expect(resolver.walks == 2)
        _ = resolver.nodes(at: [], in: right)
        _ = resolver.nodes(at: ["/r/a.txt"], in: right)
        #expect(resolver.walks == 3, "the other pane's entry outlived its empty selection")
        let row = Self.allRows(left.rows)[1]
        _ = FileContextMenu.menuNodes(row: row, selection: [], tree: left, resolver: resolver)
        _ = resolver.nodes(at: ["/r/a.txt"], in: left)
        #expect(resolver.walks == 4, "the pane's own entry outlived its empty selection")
    }

    /// **Favorites does what its label said.** The label is read when the menu is built — with the
    /// row, a render or more before the click — so the click toggles only while the folder is still
    /// in the state the label described. An "Add" made stale by the sidebar adding the folder must
    /// not take it back out, and a stale "Remove" must not put it back.
    @Test func aFavoritesClickFollowsItsLabel() {
        #expect(FileContextMenu.favoriteLabelStillHolds(labelSaidFavorite: false, isFavoriteNow: false))
        #expect(FileContextMenu.favoriteLabelStillHolds(labelSaidFavorite: true, isFavoriteNow: true))
        #expect(!FileContextMenu.favoriteLabelStillHolds(labelSaidFavorite: false, isFavoriteNow: true),
                "a stale Add would remove the folder")
        #expect(!FileContextMenu.favoriteLabelStillHolds(labelSaidFavorite: true, isFavoriteNow: false),
                "a stale Remove would add it back")
    }

    /// **The panes hand every menu the ONE resolver they keep.** A fresh resolver per menu still
    /// answers correctly — which is exactly why nothing else here would notice one — but it walks per
    /// row again, the whole cost CP9 removed. A source scan, because the menus' bodies do not run in
    /// a test window (see `renderMenus`): the pane keeps one as `@State`, hands it to the Tree's
    /// menus and to the Columns view, and the Columns view hands it to its own.
    @Test func everyMenuIsHandedThePanesResolver() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer")
        func code(_ file: String) throws -> String {
            try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
                .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        let tree = try code("FileTreeView.swift")
        let columns = try code("PaneColumnsView.swift")
        func count(_ needle: String, in haystack: String) -> Int { haystack.components(separatedBy: needle).count - 1 }
        #expect(tree.contains("@State private var selectionResolver = PaneSelectionResolver()"))
        #expect(count("selectionResolver: selectionResolver", in: tree) == 2,
                "the Tree's menus and the Columns view must both get the pane's resolver")
        #expect(count("selectionResolver: selectionResolver", in: columns) == 1,
                "the Columns view must hand its menus the resolver it was given")
        #expect(!tree.contains("selectionResolver: PaneSelectionResolver()")
                && !columns.contains("selectionResolver: PaneSelectionResolver()"),
                "a menu is being built with a resolver of its own")
    }

    /// **Each pane's selection keeps its own entry.** Every row's menu asks about both — its own
    /// pane's selection, and the other pane's for the cross-pane items — so one shared entry would
    /// have the two evict each other on every row, which is exactly the per-row walk this removes.
    @Test func eachPanesSelectionKeepsItsOwnEntry() {
        let left = PaneTree(side: .left, version: 1, nodes: Self.nodes)
        let right = PaneTree(side: .right, version: 1, nodes: Self.nodes)
        let resolver = PaneSelectionResolver()
        for _ in 0..<3 {
            #expect(resolver.nodes(at: ["/r/a.txt"], in: left).map(\.id) == ["/r/a.txt"])
            #expect(resolver.nodes(at: ["/r/dir/c.txt"], in: right).map(\.id) == ["/r/dir/c.txt"])
        }
        #expect(resolver.walks == 2)
    }

    // MARK: - Hosted menus

    private struct StubDelegate: FileActionDelegate {
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

    /// Renders one real `FileContextMenu` per row, as a pane's rows each carry one, and lays them
    /// out so every body runs.
    ///
    /// Hosted directly, the way `OpenInEditorVerbTests` hosts one to read its items, because a
    /// mounted pane cannot show this: in a test window — even one ordered in, invisible — the
    /// `.contextMenu` closure runs for every row but SwiftUI runs the menu's BODY for none (checked
    /// 2026-09-27). In the app it runs for every visible row, inside the row's `NSHostingView.layout`
    /// on each click; that is the sample CP9 was measured from.
    private func renderMenus(_ rows: [PaneRow], selection: Set<String>, tree: PaneTree,
                             otherTree: PaneTree, otherSelection: Set<String>,
                             resolver: PaneSelectionResolver) {
        let menus = VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                FileContextMenu(row: row, selection: selection, tree: tree, otherTree: otherTree,
                                otherSelection: otherSelection, isLeft: true, currentPath: "/r",
                                delegate: StubDelegate(), otherPaneName: "Right", isSingleSource: false,
                                onQuickLook: { _ in }, selectionResolver: resolver)
            }
        }
        let host = NSHostingView(rootView: menus.frame(width: 260))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 6000)
        host.layoutSubtreeIfNeeded()
    }

    /// **Every row's menu, rendered: the rows share the walks.** Six menus look at the other pane's
    /// one selected file — for "Copy '…' from Right" — and it is resolved once, not six times. Two
    /// selected rows then cost one walk between them while the other pane's answer is remembered,
    /// and moving the selection costs one more. Nothing here walks per row.
    @Test func everyRowsMenuSharesTheWalks() {
        let left = PaneTree(side: .left, version: 1, nodes: Self.nodes)
        let right = PaneTree(side: .right, version: 1, nodes: [
            FileNode(id: "/o/scan.pdf", name: "scan.pdf", isDirectory: false),
        ])
        let rows = Self.allRows(left.rows)
        let resolver = PaneSelectionResolver()
        func render(_ selection: Set<String>) {
            renderMenus(rows, selection: selection, tree: left, otherTree: right,
                        otherSelection: ["/o/scan.pdf"], resolver: resolver)
        }
        render([])
        #expect(resolver.walks == 1, "six menus, one look at the other pane's selection; walks = \(resolver.walks)")
        render(["/r/a.txt", "/r/b.txt"])
        #expect(resolver.walks == 2, "two selected rows share one walk; walks = \(resolver.walks)")
        render(["/r/dir/c.txt"])
        #expect(resolver.walks == 3, "a moved selection costs one walk; walks = \(resolver.walks)")
    }
}
