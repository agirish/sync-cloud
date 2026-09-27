import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// `ColumnRowBottomsProbe` — where each open column's visible rows end, for the action bar, read from
/// the column's table instead of from a `GeometryReader` on every row.
///
/// The reason it exists is a cost: a `.global` reader on every column row subscribed every row to
/// the stack's sideways scroll, and a 12 s swipe in the app kept the main thread 47% busy re-laying
/// out row hosting views that had not changed. So the suite pins two things. The BEHAVIOUR the bar
/// depends on — every open column reports its visible rows, a vertical scroll moves them, a closed
/// column takes them back — and the PROPERTY the change was for: a sideways scroll moves nothing,
/// and no column row carries a geometry reader to subscribe it again.
///
/// Mounted offscreen with the reveal unanimated, like `PaneColumnsScrollTests`, whose harness this
/// follows: three columns in a 520pt window, so the stack genuinely scrolls sideways.
@MainActor
@Suite(.serialized) struct ColumnRowBottomsProbeTests {

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

    final class Box: ObservableObject {
        @Published var browsePath = PaneBrowsePath()
        @Published var selection: Set<String> = []
    }

    static let root = "/root"

    /// 30 folders, each holding 30 folders of 12 files: every column is taller than the window, so
    /// each one has rows above and below its viewport to scroll between.
    private static func tree() -> PaneTree {
        let top = (0..<30).map { a -> FileNode in
            let dir = "\(root)/a\(a)"
            let mids = (0..<30).map { b -> FileNode in
                let bPath = "\(dir)/b\(b)"
                return FileNode(id: bPath, name: "b\(b)", isDirectory: true,
                                children: (0..<12).map {
                                    FileNode(id: "\(bPath)/f\($0).pdf", name: "f\($0).pdf", isDirectory: false)
                                })
            }
            return FileNode(id: dir, name: "a\(a)", isDirectory: true, children: mids)
        }
        return PaneTree(side: .left, version: 1, nodes: top)
    }

    private struct Harness: View {
        @ObservedObject var box: Box
        let tree: PaneTree
        let index: PaneChildrenIndex
        let placement: PaneBarPlacement

        var body: some View {
            PaneColumnsView(
                tree: tree, otherTree: PaneTree(side: .right, version: 1, nodes: []),
                childrenIndex: index, treeRoot: ColumnRowBottomsProbeTests.root,
                browsePath: $box.browsePath, onNavigate: { box.browsePath = $0 },
                selection: $box.selection, otherSelection: [], isLeft: true,
                delegate: StubDelegate(), diffIndex: .empty, otherPaneName: "R",
                isSingleSource: false, density: .comfortable, isActivePane: true,
                placement: placement, onBarEdgeFlip: {}, onQuickLook: { _ in },
                onBackgroundDeselect: { _ in }
            )
            .environment(\.paneColumnRevealAnimation, nil)
        }
    }

    private struct Mounted {
        let window: NSWindow
        let box: Box
        let tree: PaneTree
        let placement: PaneBarPlacement
    }

    /// Lets the main run loop run for `seconds` by SUSPENDING, a frame at a time. A synchronous
    /// `RunLoop.run` inside a `@MainActor` test never drains the main queue, so the pane's queued
    /// work — the drill's reveal, a probe's `rearm()` — would silently never run; see
    /// `PaneScrollMemoryTests.pump`, where that made a working feature read as broken.
    private func pump(_ seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { try? await Task.sleep(nanoseconds: 8_000_000) }
    }

    private func mount(components: [String] = ["a2", "b3"]) async -> Mounted {
        let box = Box()
        let tree = Self.tree()
        let placement = PaneBarPlacement()
        let host = NSHostingView(rootView: Harness(box: box, tree: tree,
                                                   index: PaneChildrenIndex(tree: tree, treeRoot: Self.root),
                                                   placement: placement))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        // Full-size content, as the app's `.hiddenTitleBar` window is, so the content view's space
        // is the window's — the one SwiftUI's `.global` frames use.
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        box.browsePath = PaneBrowsePath(components: components)
        await pump(1.2)
        return Mounted(window: window, box: box, tree: tree, placement: placement)
    }

    private func scrollViews(_ view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView { found.append(s) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    /// The columns' lists, left to right.
    private func columnLists(_ m: Mounted) -> [NSScrollView] {
        guard let content = m.window.contentView else { return [] }
        return scrollViews(content)
            .filter { $0.documentView is NSTableView }
            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    private func ids(_ m: Mounted, _ directory: String) -> [String] {
        PaneChildrenIndex(tree: m.tree, treeRoot: Self.root).children(atPath: directory)?.map(\.id) ?? []
    }

    // MARK: - What the bar reads

    /// Every open column reports its visible rows, and each column's bottoms run down the column in
    /// row order — the placement can only compare rows it has, and only rows in a sane order mean
    /// anything to it.
    @Test func everyOpenColumnReportsItsVisibleRows() async throws {
        let m = await mount()
        defer { m.window.contentView = nil }
        for directory in ["\(Self.root)", "\(Self.root)/a2", "\(Self.root)/a2/b3"] {
            let reported = ids(m, directory).compactMap { m.placement.rowBottoms[$0] }
            #expect(reported.count >= 5, "the column listing \(directory) reported \(reported.count) rows")
            #expect(reported == reported.sorted(), "\(directory)'s rows are not reported top to bottom")
        }
    }

    /// **The property the change was for.** Sliding the stack sideways moves no row vertically, so
    /// no reported bottom may move — and nothing about it is re-measured. A per-row global reader
    /// re-ran on every frame of exactly this.
    @Test func aSidewaysScrollMovesNoRowBottom() async throws {
        let m = await mount()
        defer { m.window.contentView = nil }
        let stack = try #require(scrollViews(m.window.contentView!).first { !($0.documentView is NSTableView) })
        let clip = stack.contentView
        let range = (clip.documentView?.frame.width ?? 0) - clip.bounds.width
        try #require(range > 40, "the stack does not overflow — a sideways scroll would test nothing")

        let before = m.placement.rowBottoms
        try #require(!before.isEmpty, "nothing was reported before the scroll")
        for x in [range / 3, range, 0] {
            clip.setBoundsOrigin(NSPoint(x: x, y: clip.bounds.origin.y))
            stack.reflectScrolledClipView(clip)
            await pump(0.2)
        }
        #expect(m.placement.rowBottoms == before, "a sideways scroll moved a row's reported bottom")
    }

    /// The positive control for the test above: a VERTICAL scroll of one column moves that column's
    /// rows by exactly the distance scrolled, and leaves every other column's rows alone. Without it,
    /// "nothing moved" could as easily mean "nothing is being reported live".
    @Test func aVerticalScrollMovesThatColumnsRowsByTheScroll() async throws {
        let m = await mount()
        defer { m.window.contentView = nil }
        let lists = columnLists(m)
        try #require(lists.count == 3, "expected three column lists, found \(lists.count)")
        let middle = lists[1]
        let middleIDs = ids(m, "\(Self.root)/a2")
        let firstIDs = ids(m, Self.root)
        let before = m.placement.rowBottoms

        let clip = middle.contentView
        let delta: CGFloat = 60
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + delta))
        middle.reflectScrolledClipView(clip)
        await pump(0.3)

        let moved = middleIDs.compactMap { id -> CGFloat? in
            guard let a = before[id], let b = m.placement.rowBottoms[id] else { return nil }
            return a - b
        }
        try #require(!moved.isEmpty, "no row of the scrolled column was reported both before and after")
        for shift in moved {
            #expect(abs(shift - delta) < 0.5, "a row moved \(shift)pt for a \(delta)pt scroll")
        }
        for id in firstIDs {
            #expect(m.placement.rowBottoms[id] == before[id], "scrolling one column moved another's row")
        }
    }

    /// A column that closes takes its rows back, so the bar can never resolve against a row that is
    /// no longer on screen.
    @Test func closingAColumnWithdrawsItsRows() async throws {
        let m = await mount()
        defer { m.window.contentView = nil }
        let deepest = ids(m, "\(Self.root)/a2/b3")
        try #require(deepest.contains { m.placement.rowBottoms[$0] != nil },
                     "the deepest column reported nothing, so its withdrawal would prove nothing")

        m.box.browsePath = PaneBrowsePath(components: ["a2"])
        await pump(0.8)
        #expect(!deepest.contains { m.placement.rowBottoms[$0] != nil },
                "a closed column's rows are still in the placement")
    }

    /// **The pane leaving the window takes every row back** — the teardown half, and the one the
    /// test above cannot see: a CLOSING column's list collapses before it leaves, so its last report
    /// finds no visible row and clears itself on the way out (traced: `fresh=0` just before the
    /// exit). A whole pane detached intact reports nothing on its way out, and the placement is
    /// `ContentView`'s — it outlives the pane across a workspace switch. Without the withdrawal the
    /// next mount would inherit every row of the last one, at the old layout's positions.
    @Test func leavingTheWindowWithdrawsEveryRow() async throws {
        let m = await mount()
        try #require(!m.placement.rowBottoms.isEmpty, "nothing was reported, so a withdrawal would prove nothing")
        m.window.contentView = nil
        await pump(0.3)
        #expect(m.placement.rowBottoms.isEmpty,
                "\(m.placement.rowBottoms.count) rows outlived the pane that reported them")
    }

    // MARK: - No per-row reader, ever

    /// **A source scan, because the regression is a construct, not a behaviour a fixture can see.**
    /// Any geometry read inside a column row — a `GeometryReader`, `onGeometryChange`, a `.global`
    /// frame — subscribes that row to the stack's sideways scroll, and the cost only shows as frame
    /// drops under a real swipe. Scoped to the column row's modifier chain and to `FileRowView`'s
    /// body, which every column row draws; comment lines stripped so the notes that NAME the
    /// constructs cannot convict themselves.
    @Test func noColumnRowCarriesAGeometryReader() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer")
        func codeOnly(_ text: Substring) -> String {
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                          && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
                .joined(separator: "\n")
        }
        let columns = try String(contentsOf: sources.appendingPathComponent("PaneColumnsView.swift"), encoding: .utf8)
        let rowStart = try #require(columns.range(of: "private func columnRow("), "the column row moved")
        let rowEnd = try #require(columns[rowStart.upperBound...].range(of: "\n    }\n"), "the column row has no end")
        let columnRow = codeOnly(columns[rowStart.lowerBound..<rowEnd.upperBound])
        #expect(columnRow.contains(".tag(node.id)"), "the scan is not reading the column row — it proves nothing")

        let rows = try String(contentsOf: sources.appendingPathComponent("FileTreeView.swift"), encoding: .utf8)
        let fileRowStart = try #require(rows.range(of: "struct FileRowView: View {"), "FileRowView moved")
        let fileRowEnd = try #require(rows[fileRowStart.upperBound...].range(of: "\nstruct "), "no struct follows FileRowView")
        let fileRow = codeOnly(rows[fileRowStart.lowerBound..<fileRowEnd.lowerBound])
        #expect(fileRow.contains("PaneSearchName("), "the scan is not reading FileRowView — it proves nothing")

        for (name, code) in [("the column row", columnRow), ("FileRowView", fileRow)] {
            for construct in ["GeometryReader", "onGeometryChange", "in: .global", "PaneRowBottomsKey"] {
                #expect(!code.contains(construct), """
                        `\(construct)` is in \(name). A geometry read on a column row subscribes every \
                        row to the stack's sideways scroll — see `ColumnRowBottomsProbe` for what that \
                        cost. Report positions from the table instead.
                        """)
            }
        }
    }
}
