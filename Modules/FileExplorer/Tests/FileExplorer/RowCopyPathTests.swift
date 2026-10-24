import AppKit
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// **The file row's menu offers Copy Path (BR15).** It was on tabs, the Info sidebar and the
/// Differences rows, but not on the row itself — and a comment in `DetailsSidebar` claimed the row
/// menu had it. Read off the real row menu through `NSHostingMenu`.
@MainActor
@Suite struct RowCopyPathTests {

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

    private static func titles(selecting nodes: [FileNode], row: FileNode) -> [String] {
        let menu = NSHostingMenu(rootView: FileContextMenu(
            row: PaneRow(side: .left, version: 1, node: row, children: nil),
            selection: Set(nodes.map(\.id)),
            tree: PaneTree(side: .left, version: 1, nodes: nodes),
            otherTree: PaneTree(side: .right, version: 1, nodes: []),
            otherSelection: [], isLeft: true, currentPath: "/a",
            delegate: Stub(), otherPaneName: "Right", isSingleSource: true,
            onQuickLook: { _ in }, selectionResolver: PaneSelectionResolver()))
        menu.update()
        return menu.items.map(\.title)
    }

    /// One file: Copy Path, right after Quick Look.
    @Test func aFileRowOffersCopyPathAfterQuickLook() throws {
        let file = FileNode(id: "/a/never-on-disk-report.txt", name: "never-on-disk-report.txt",
                            isDirectory: false)
        let titles = Self.titles(selecting: [], row: file)
        let quickLook = try #require(titles.firstIndex(of: "Quick Look"), "the menu reads \(titles)")
        #expect(titles.dropFirst(quickLook + 1).first == "Copy Path", "the menu reads \(titles)")
    }

    /// The control: a selection of two has no single path, so no Copy Path — the item rides on the
    /// single-row branch, not on every menu.
    @Test func aSelectionOfTwoOffersNone() {
        let a = FileNode(id: "/a/x.txt", name: "x.txt", isDirectory: false)
        let b = FileNode(id: "/a/y.txt", name: "y.txt", isDirectory: false)
        let titles = Self.titles(selecting: [a, b], row: a)
        #expect(titles.contains { $0.hasPrefix("Move") }, "the premise: a real menu was built — \(titles)")
        #expect(!titles.contains("Copy Path"))
    }

    /// The item writes the absolute path as text — on a private pasteboard, never his clipboard.
    @Test func itCopiesTheAbsolutePathAsText() {
        let board = NSPasteboard(name: NSPasteboard.Name("RowCopyPathTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.setString("stale", forType: .string)
        SharedFileMenuItems.copyPath("/a/b/report.txt", to: board)
        #expect(board.string(forType: .string) == "/a/b/report.txt")
        #expect(board.pasteboardItems?.count == 1)
    }
}
