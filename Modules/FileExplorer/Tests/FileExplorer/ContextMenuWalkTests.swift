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
