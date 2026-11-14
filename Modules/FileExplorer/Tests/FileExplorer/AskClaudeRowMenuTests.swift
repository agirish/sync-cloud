import AppKit
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// Ask Claude About This on a row's menu, and File with Claude after it, read off the real row
/// menu through `NSHostingMenu`: where they sit, what they say for one row and for several, and
/// that a hidden row gets both greyed and Show to Claude instead of Hide.
@MainActor
@Suite struct AskClaudeRowMenuTests {

    private final class Stub: NoOpFileActions, @unchecked Sendable {
        var asks = true
        var hidden: Set<String> = []
        var canAskClaude: Bool { asks }
        func askClaudeRefusal(_ nodes: [FileNode]) -> String? {
            nodes.contains { hidden.contains($0.id) } ? "It’s hidden from Claude." : nil
        }
        func isHiddenFromClaude(_ node: FileNode) -> Bool { hidden.contains(node.id) }
        var covers: [String: String] = [:]
        func hiddenFromClaudeCover(_ node: FileNode) -> String? { covers[node.id] }
    }

    private static func menu(selecting nodes: [FileNode], row: FileNode, delegate: Stub) -> [NSMenuItem] {
        let menu = NSHostingMenu(rootView: FileContextMenu(
            row: PaneRow(side: .left, version: 1, node: row, children: nil),
            selection: Set(nodes.map(\.id)),
            tree: PaneTree(side: .left, version: 1, nodes: nodes.isEmpty ? [row] : nodes),
            otherTree: PaneTree(side: .right, version: 1, nodes: []),
            otherSelection: [], isLeft: true, currentPath: "/a",
            delegate: delegate, otherPaneName: "Right", isSingleSource: true,
            onQuickLook: { _ in }, selectionResolver: PaneSelectionResolver()))
        menu.update()
        return menu.items
    }

    private let file = FileNode(id: "/a/never-on-disk-lease.pdf", name: "never-on-disk-lease.pdf", isDirectory: false)

    @Test func oneRowGetsAskFileAndHideRightAfterCopyPath() throws {
        let titles = Self.menu(selecting: [], row: file, delegate: Stub()).map(\.title)
        let copyPath = try #require(titles.firstIndex(of: "Copy Path"), "the menu reads \(titles)")
        #expect(Array(titles.dropFirst(copyPath + 1).prefix(3)) == ["Ask Claude About This", "File with Claude", "Hide from Claude"],
                "the menu reads \(titles)")
    }

    /// File with Claude's tooltip says what it asks: where files go, or a folder's loose files.
    @Test func fileWithClaudeSaysWhatItAsksForFilesAndFolders() throws {
        let folder = FileNode(id: "/a/Scans", name: "Scans", isDirectory: true)
        let forFile = try #require(Self.menu(selecting: [], row: file, delegate: Stub()).first { $0.title == "File with Claude" })
        #expect(forFile.isEnabled)
        #expect(forFile.toolTip == "Asks Claude where this goes. Nothing moves until you press Apply.")
        let forFolder = try #require(Self.menu(selecting: [], row: folder, delegate: Stub()).first { $0.title == "File with Claude" })
        #expect(forFolder.toolTip == "Asks Claude to file the loose files in this folder. Nothing moves until you press Apply.")
    }

    @Test func severalRowsGetOneItemCountingThem() throws {
        let a = FileNode(id: "/a/x.txt", name: "x.txt", isDirectory: false)
        let b = FileNode(id: "/a/y.txt", name: "y.txt", isDirectory: false)
        let c = FileNode(id: "/a/z", name: "z", isDirectory: true)
        let titles = Self.menu(selecting: [a, b, c], row: a, delegate: Stub()).map(\.title)
        let ask = try #require(titles.firstIndex(of: "Ask Claude About These 3 Items"), "the menu reads \(titles)")
        // One title for any count: the item above it counts them.
        #expect(titles.dropFirst(ask + 1).first == "File with Claude", "the menu reads \(titles)")
        #expect(titles.filter { $0 == "File with Claude" }.count == 1)
        #expect(!titles.contains("Hide from Claude"))
        let items = Self.menu(selecting: [a, b, c], row: a, delegate: Stub())
        #expect(items.first { $0.title == "File with Claude" }?.toolTip
                == "Asks Claude where these go, and to file the loose files in each folder. Nothing moves until you press Apply.")
    }

    @Test func aHiddenRowIsGreyedAndOffersShow() throws {
        let stub = Stub()
        stub.hidden = [file.id]
        let items = Self.menu(selecting: [], row: file, delegate: stub)
        let ask = try #require(items.first { $0.title == "Ask Claude About This" }, "the menu reads \(items.map(\.title))")
        #expect(!ask.isEnabled)
        let fileItem = try #require(items.first { $0.title == "File with Claude" }, "the menu reads \(items.map(\.title))")
        #expect(!fileItem.isEnabled && fileItem.toolTip == "It’s hidden from Claude.")
        #expect(items.contains { $0.title == "Show to Claude" } && !items.contains { $0.title == "Hide from Claude" })
    }

    /// A row hidden by the folder it's in: Show takes that whole folder off the list, so the item
    /// names it, not "Show to Claude" as if it were this row alone.
    @Test func aRowHiddenByItsFolderNamesTheFolderShowWouldShow() throws {
        let stub = Stub()
        stub.hidden = [file.id]
        stub.covers = [file.id: "Taxes"]
        let items = Self.menu(selecting: [], row: file, delegate: stub)
        let show = try #require(items.first { $0.title.hasPrefix("Show") }, "the menu reads \(items.map(\.title))")
        #expect(show.title == "Show “Taxes” to Claude")
        #expect(show.toolTip?.contains("takes Taxes off the Hidden from Claude list, with everything in it") == true,
                "the tooltip reads \(show.toolTip ?? "nothing")")
    }

    /// The control: a host with no Ask Claude behind it draws neither item.
    @Test func aHostWithoutAskClaudeDrawsNone() {
        let stub = Stub()
        stub.asks = false
        let titles = Self.menu(selecting: [], row: file, delegate: stub).map(\.title)
        #expect(titles.contains("Copy Path"), "the premise: a real menu was built — \(titles)")
        #expect(!titles.contains { $0.hasPrefix("Ask Claude") || $0.hasSuffix("Claude") })
    }

    @Test func aDifferencesRowAttachesTheSidesThatExist() throws {
        let both = FileDifference(relativePath: "a.txt", leftItemPath: "/L/a.txt", rightItemPath: "/R/a.txt",
                                  type: .differentDates, action: .copyToRight, description: "newer")
        let oneSided = FileDifference(relativePath: "b.txt", leftItemPath: "/L/b.txt", rightItemPath: "/R/b.txt",
                                      type: .missingOnLeft, action: .copyToLeft, description: "only right")
        var asked: [[String]] = []
        let askClaude = DifferencesAskClaude(refusal: { _ in nil }, ask: { asked.append($0) })
        let item = DifferencesAskClaudeItem(askClaude: askClaude, rows: [both, oneSided], paneNames: .leftRight)
        #expect(item.paths == ["/L/a.txt", "/R/a.txt", "/R/b.txt"])
        let menu = NSHostingMenu(rootView: item)
        menu.update()
        #expect(menu.items.map(\.title) == ["Ask Claude About These 2 Items"])
        let refused = NSHostingMenu(rootView: DifferencesAskClaudeItem(
            askClaude: DifferencesAskClaude(refusal: { _ in "hidden" }, ask: { _ in }), rows: [both], paneNames: .leftRight))
        refused.update()
        let only = try #require(refused.items.first)
        #expect(only.title == "Ask Claude About This" && !only.isEnabled)
    }
}
