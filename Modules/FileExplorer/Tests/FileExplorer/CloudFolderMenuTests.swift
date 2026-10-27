import AppKit
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// **Where the row menu offers Download All and Keep Downloaded**, read off the real row menu
/// through `NSHostingMenu`. Every path here is spelled, never created: both gates are decided from
/// the path (and, for Keep Downloaded, from attributes a missing file does not have), so nothing is
/// written under the real home.
@MainActor
@Suite struct CloudFolderMenuTests {

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

    private static func items(for row: FileNode, selecting selection: [FileNode] = []) -> [NSMenuItem] {
        let menu = NSHostingMenu(rootView: FileContextMenu(
            row: PaneRow(side: .left, version: 1, node: row, children: nil),
            selection: Set(selection.map(\.id)),
            tree: PaneTree(side: .left, version: 1, nodes: selection.isEmpty ? [row] : selection),
            otherTree: PaneTree(side: .right, version: 1, nodes: []),
            otherSelection: [], isLeft: true, currentPath: (row.id as NSString).deletingLastPathComponent,
            delegate: Stub(), otherPaneName: "Right", isSingleSource: true,
            onQuickLook: { _ in }, selectionResolver: PaneSelectionResolver()))
        menu.update()
        return menu.items
    }

    private static let unique = "never-on-disk-\(UUID().uuidString)"

    @Test func aFolderInAProvidersFolderOffersDownloadAllButNotKeepDownloaded() {
        let path = NSHomeDirectory() + "/Library/CloudStorage/Dropbox/\(Self.unique)"
        let titles = Self.items(for: FileNode(id: path, name: Self.unique, isDirectory: true)).map(\.title)
        #expect(titles.contains("Download All"), "the menu reads \(titles)")
        // Measured ignored outside iCloud Drive, so not offered there.
        #expect(!titles.contains("Keep Downloaded"), "the menu reads \(titles)")
    }

    @Test func aLocalFolderOffersNeither() {
        let titles = Self.items(for: FileNode(id: "/a/\(Self.unique)", name: Self.unique, isDirectory: true)).map(\.title)
        #expect(titles.contains("Copy Path"), "the premise: a real menu was built — \(titles)")
        #expect(!titles.contains("Download All"))
        #expect(!titles.contains("Keep Downloaded"))
    }

    /// A file is never offered Download All — its own Download is the file's verb.
    @Test func aFileInICloudOffersKeepDownloadedUntickedAndNotDownloadAll() throws {
        let path = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/\(Self.unique).txt"
        let items = Self.items(for: FileNode(id: path, name: Self.unique + ".txt", isDirectory: false))
        let keep = try #require(items.first { $0.title == "Keep Downloaded" },
                                "the menu reads \(items.map(\.title))")
        #expect(keep.state == .off)
        #expect(keep.isEnabled)
        #expect(!items.map(\.title).contains("Download All"))
    }

    @Test func aFolderInICloudOffersBoth() {
        let path = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/\(Self.unique)"
        let titles = Self.items(for: FileNode(id: path, name: Self.unique, isDirectory: true)).map(\.title)
        #expect(titles.contains("Download All"), "the menu reads \(titles)")
        #expect(titles.contains("Keep Downloaded"), "the menu reads \(titles)")
    }

    // MARK: - Several selected

    private static func folder(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true)
    }

    /// Two cloud folders selected: Download All over both, offered on either one's menu.
    @Test func severalCloudFoldersOfferDownloadAll() {
        let base = NSHomeDirectory() + "/Library/CloudStorage/Dropbox/\(Self.unique)"
        let nodes = [Self.folder(base + "-a"), Self.folder(base + "-b")]
        let titles = Self.items(for: nodes[1], selecting: nodes).map(\.title)
        #expect(titles.contains("Download All"), "the menu reads \(titles)")
        #expect(!titles.contains("Keep Downloaded"), "the menu reads \(titles)")
    }

    @Test func severalICloudItemsOfferKeepDownloaded() throws {
        let base = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/\(Self.unique)"
        let nodes = [Self.folder(base + "-a"), Self.folder(base + "-b")]
        let items = Self.items(for: nodes[0], selecting: nodes)
        let keep = try #require(items.first { $0.title == "Keep Downloaded" }, "the menu reads \(items.map(\.title))")
        #expect(keep.state == .off)
        #expect(items.map(\.title).contains("Download All"))
    }

    /// Past the cap the tick would cost too much to draw, so the item is withheld — Download All,
    /// which costs no attribute reads, is not.
    @Test func pastTheCapKeepDownloadedIsWithheld() {
        let base = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/\(Self.unique)"
        let nodes = (0...KeepDownloadedOffer.selectionCap).map { Self.folder(base + "-\($0)") }
        let titles = Self.items(for: nodes[0], selecting: nodes).map(\.title)
        #expect(titles.contains("Download All"), "the menu reads \(titles)")
        #expect(!titles.contains("Keep Downloaded"), "the menu reads \(titles)")
    }

    @Test func severalLocalItemsOfferNeither() {
        let nodes = [Self.folder("/a/\(Self.unique)-a"), Self.folder("/a/\(Self.unique)-b")]
        let titles = Self.items(for: nodes[0], selecting: nodes).map(\.title)
        #expect(titles.contains { $0.hasPrefix("Move") || $0.hasPrefix("Copy") }, "the premise: a real menu — \(titles)")
        #expect(!titles.contains("Download All"))
        #expect(!titles.contains("Keep Downloaded"))
    }
}
