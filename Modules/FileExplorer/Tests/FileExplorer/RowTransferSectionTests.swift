import AppKit
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// The row menu puts Cut, Copy, the two transfers and Paste Here in one section, with no divider
/// between. Paste Here comes last because it is the one item that acts on the clicked folder
/// rather than the selection. Read off the real row menu through `NSHostingMenu`, where a divider
/// is an untitled separator item.
@MainActor
@Suite struct RowTransferSectionTests {

    private final class Stub: FileActionDelegate, @unchecked Sendable {
        func handleOpenInEditor(_ path: String) {}
        func handleRefresh() {}
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

    /// The titles from Cut through Paste Here, separators included as "".
    private static func section(selecting nodes: [FileNode], row: FileNode,
                                isSingleSource: Bool) throws -> [String] {
        let menu = NSHostingMenu(rootView: FileContextMenu(
            row: PaneRow(side: .left, version: 1, node: row, children: nil),
            selection: Set(nodes.map(\.id)),
            tree: PaneTree(side: .left, version: 1, nodes: nodes),
            otherTree: PaneTree(side: .right, version: 1, nodes: []),
            otherSelection: [], isLeft: true, currentPath: "/a",
            delegate: Stub(), otherPaneName: "Right", isSingleSource: isSingleSource,
            onQuickLook: { _ in }, selectionResolver: PaneSelectionResolver()))
        menu.update()
        let titles = menu.items.map { $0.isSeparatorItem ? "" : $0.title }
        let cut = try #require(titles.firstIndex { $0.hasPrefix("Cut") }, "the menu reads \(titles)")
        let paste = try #require(titles.firstIndex(of: "Paste Here"), "the menu reads \(titles)")
        try #require(cut < paste, "the menu reads \(titles)")
        return Array(titles[cut...paste])
    }

    private static let file = FileNode(id: "/a/never-on-disk-report.txt",
                                       name: "never-on-disk-report.txt", isDirectory: false)

    /// One pane: the transfers open a folder picker.
    @Test func oneSourceReadsCutCopyTransfersPaste() throws {
        let section = try Self.section(selecting: [], row: Self.file, isSingleSource: true)
        #expect(section == ["Cut", "Copy", "Copy to…", "Move to…", "Paste Here"])
    }

    /// Two panes: the transfers send to the other pane, in the same slot.
    @Test func twoPanesReadCutCopyTransfersPaste() throws {
        let section = try Self.section(selecting: [], row: Self.file, isSingleSource: false)
        #expect(section == ["Cut", "Copy", "Copy to Right", "Move to Right", "Paste Here"])
    }

    /// A batch keeps the order with counted titles.
    @Test func aBatchKeepsTheOrder() throws {
        let a = FileNode(id: "/a/x.txt", name: "x.txt", isDirectory: false)
        let b = FileNode(id: "/a/y.txt", name: "y.txt", isDirectory: false)
        let section = try Self.section(selecting: [a, b], row: a, isSingleSource: true)
        #expect(section == ["Cut 2 Items", "Copy 2 Items", "Copy 2 Items to…", "Move 2 Items to…",
                            "Paste Here"])
    }
}
