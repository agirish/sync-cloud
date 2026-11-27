import AppKit
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// The row menu's New Folder with Selection: Finder's title with the count, last of the verbs that
/// put the selection somewhere, offered only for items in one folder and only by a host that can
/// make the folder. Read off the real row menu through `NSHostingMenu`.
@MainActor
@Suite struct NewFolderWithSelectionMenuTests {

    private final class Host: NoOpFileActions {
        var canMakeFolderWithSelection: Bool { true }
    }

    private static func menu(selecting nodes: [FileNode], row: FileNode,
                             delegate: FileActionDelegate) -> NSMenu {
        let menu = NSHostingMenu(rootView: FileContextMenu(
            row: PaneRow(side: .left, version: 1, node: row, children: nil),
            selection: Set(nodes.map(\.id)),
            tree: PaneTree(side: .left, version: 1, nodes: nodes),
            otherTree: PaneTree(side: .right, version: 1, nodes: []),
            otherSelection: [], isLeft: true, currentPath: "/a",
            delegate: delegate, otherPaneName: "Right", isSingleSource: true,
            onQuickLook: { _ in }, selectionResolver: PaneSelectionResolver()))
        menu.update()
        return menu
    }

    private static func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "" : $0.title }
    }

    private static let x = FileNode(id: "/a/x.txt", name: "x.txt", isDirectory: false)
    private static let y = FileNode(id: "/a/y.txt", name: "y.txt", isDirectory: false)

    @Test func severalItemsInOneFolderAreOfferedItAheadOfPasteHere() throws {
        let titles = Self.titles(Self.menu(selecting: [Self.x, Self.y], row: Self.x, delegate: Host()))
        let item = try #require(titles.firstIndex(of: "New Folder with Selection (2 Items)"), "the menu reads \(titles)")
        let paste = try #require(titles.firstIndex(of: "Paste Here"), "the menu reads \(titles)")
        #expect(item + 1 == paste, "the menu reads \(titles)")
        #expect(titles[item - 1] == "Move 2 Items to…", "the menu reads \(titles)")
    }

    @Test func oneItemReadsOneItem() {
        let titles = Self.titles(Self.menu(selecting: [Self.x], row: Self.x, delegate: Host()))
        #expect(titles.contains("New Folder with Selection (1 Item)"), "the menu reads \(titles)")
    }

    @Test func itemsInTwoFoldersAreNotOfferedIt() {
        let deeper = FileNode(id: "/a/sub/z.txt", name: "z.txt", isDirectory: false)
        let titles = Self.titles(Self.menu(selecting: [Self.x, deeper], row: Self.x, delegate: Host()))
        #expect(!titles.contains { $0.hasPrefix("New Folder with Selection") }, "the menu reads \(titles)")
    }

    @Test func aHostThatCannotMakeTheFolderDrawsNoItem() {
        let titles = Self.titles(Self.menu(selecting: [Self.x, Self.y], row: Self.x, delegate: NoOpFileActionDelegate()))
        #expect(!titles.contains { $0.hasPrefix("New Folder with Selection") }, "the menu reads \(titles)")
    }
}
