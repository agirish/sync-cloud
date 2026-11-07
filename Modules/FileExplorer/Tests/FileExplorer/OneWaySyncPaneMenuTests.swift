import AppKit
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// In SyncCloud's own Dropbox pane, renaming or deleting a synced file isn't offered: the row
/// menu's Rename and Move to Trash are off for it, and on for a Dropbox-only file. Read off the
/// real row menu through `NSHostingMenu`.
@MainActor
@Suite(.serialized) struct OneWaySyncPaneMenuTests {

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

    private static func items(for row: FileNode) -> [NSMenuItem] {
        let menu = NSHostingMenu(rootView: FileContextMenu(
            row: PaneRow(side: .right, version: 1, node: row, children: nil),
            selection: [row.id],
            tree: PaneTree(side: .right, version: 1, nodes: [row]),
            otherTree: PaneTree(side: .left, version: 1, nodes: []),
            otherSelection: [], isLeft: false, currentPath: (row.id as NSString).deletingLastPathComponent,
            delegate: Stub(), otherPaneName: "Left", isSingleSource: true,
            onQuickLook: { _ in }, selectionResolver: PaneSelectionResolver()))
        menu.update()
        return menu.items
    }

    @Test func aSyncedDropboxFileIsNotOfferedRenameOrTrash() throws {
        let scratch = try OneWaySyncControllerTests.Scratch()
        let shared = OneWaySyncController.shared
        let (record, state) = (shared.record, shared.state)
        shared.adopt(scratch.record, state: OneWaySyncSavedState())
        defer { shared.adopt(record, state: state) }

        func enabled(_ path: String) -> [String: Bool] {
            let node = FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false)
            var answer: [String: Bool] = [:]
            for item in Self.items(for: node) where item.title == "Rename" || item.title.hasPrefix("Move to Trash") {
                answer[item.title.hasPrefix("Move") ? "trash" : "rename"] = item.isEnabled
            }
            return answer
        }
        let synced = enabled(scratch.dropbox.appendingPathComponent("Legal/Will.pdf").path)
        #expect(synced == ["rename": false, "trash": false], "\(synced)")
        let mine = enabled(scratch.dropbox.appendingPathComponent("Legal/mine.txt").path)
        #expect(mine == ["rename": true, "trash": true], "\(mine)")
    }
}
