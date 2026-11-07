import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// A click doesn't make every row's context menu walk the tree. SwiftUI builds a row's menu with
/// the row, so `FileContextMenu`'s body runs for every visible row on every click, in both panes.
/// `menuNodes` answers a row outside the selection from the row itself, and `PaneSelectionResolver`
/// walks once per selection. The last case renders a real menu per row to show they share walks.
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

    /// A row outside the selection is answered from the row: nothing walks. The probe tree carries
    /// the row's stamp but none of its nodes, so getting the row back means no walk ran. A row from
    /// another publish or the other pane does walk, and here finds nothing.
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

    /// `menuNodes` is a faster route to `resolvedSelection`'s answer, never a different one:
    /// checked for every row of a nested tree against empty, single, multiple, nested (which
    /// prunes to the folder) and stale selections.
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

    /// Two nodes at one path answer with that path. iCloud's linked Documents appear under `~` and
    /// inside iCloud Drive at one id (`isCoveredElsewhere` on the second); the walk stops at the
    /// first, a row answers with itself. Every verb acts by path, so that is the equivalence.
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

    /// One walk per selection, however many rows ask: only selected rows reach the resolver, and
    /// they share its walk. A new selection or a republished tree walks again; nothing else does.
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

    /// A new selection of the same size is resolved afresh: after `a`, `b`'s menu answers `b`. A
    /// memo keyed on less than the whole selection (its count, a subset test) would pass every
    /// other case and hand `b`'s menu `a`, whose Delete would trash the file clicked away from.
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

    /// An emptied selection lets its entry go, since an entry's nodes would keep a replaced tree
    /// alive. The other pane's goes when asked about empty, the pane's own when a menu is built with
    /// nothing selected; the next selection walking afresh is how this tells.
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

    /// Favorites does what its label said. The label is read when the menu is built, a render or
    /// more before the click, so the click toggles only if the folder is still in that state: a
    /// stale "Add" must not remove it, and a stale "Remove" must not add it back.
    @Test func aFavoritesClickFollowsItsLabel() {
        #expect(FileContextMenu.favoriteLabelStillHolds(labelSaidFavorite: false, isFavoriteNow: false))
        #expect(FileContextMenu.favoriteLabelStillHolds(labelSaidFavorite: true, isFavoriteNow: true))
        #expect(!FileContextMenu.favoriteLabelStillHolds(labelSaidFavorite: false, isFavoriteNow: true),
                "a stale Add would remove the folder")
        #expect(!FileContextMenu.favoriteLabelStillHolds(labelSaidFavorite: true, isFavoriteNow: false),
                "a stale Remove would add it back")
    }

    /// The panes hand every menu the one resolver they keep. A fresh resolver per menu answers
    /// correctly but walks per row again, so nothing else here would notice. A source scan, since
    /// menu bodies don't run in a test window (see `renderMenus`): the pane's `@State` resolver goes
    /// to the Tree's menus and the Columns view, which hands it to its own.
    @Test func everyMenuIsHandedThePanesResolver() throws {
        func code(_ file: String) throws -> String { SourceText.codeOnly(try SourceText.fileExplorer(file)) }
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

    /// Each pane's selection keeps its own entry. Every row's menu asks about both panes'
    /// selections, so one shared entry would have them evict each other on every row.
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

    /// Renders one real `FileContextMenu` per row and lays them out so every body runs. Hosted
    /// directly, as `OpenInEditorVerbTests` does, because in a test window SwiftUI runs a row's
    /// `.contextMenu` closure but never the menu's body. In the app the body runs for every visible
    /// row on each click.
    private func renderMenus(_ rows: [PaneRow], selection: Set<String>, tree: PaneTree,
                             otherTree: PaneTree, otherSelection: Set<String>,
                             resolver: PaneSelectionResolver) {
        let menus = VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                FileContextMenu(row: row, selection: selection, tree: tree, otherTree: otherTree,
                                otherSelection: otherSelection, isLeft: true, currentPath: "/r",
                                delegate: NoOpFileActionDelegate(), otherPaneName: "Right", isSingleSource: false,
                                onQuickLook: { _ in }, selectionResolver: resolver)
            }
        }
        let host = NSHostingView(rootView: menus.frame(width: 260))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 6000)
        host.layoutSubtreeIfNeeded()
    }

    /// Every row's menu, rendered, shares the walks. Six menus look at the other pane's selected
    /// file (for "Copy '…' from Right") and it resolves once. Two selected rows then cost one walk,
    /// and moving the selection one more. Nothing walks per row.
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
