import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// Columns sized one at a time, on a mounted pane: each column takes its own width, the deepest one
/// has a handle, and a double-click fit leaves the longest name whole.
///
/// The width rules themselves are pure and live in `ColumnWidthsTests` (Design). This suite pins that
/// `PaneColumnsView` actually draws from them, and that the fit measures what it claims to.
@MainActor
@Suite(.serialized) struct ColumnWidthsMountTests {

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
        @Published var browsePath = PaneBrowsePath(components: ["a", "b"])
        @Published var selection: Set<String> = []
    }

    private static let tree: PaneTree = {
        let files = (0..<6).map { FileNode(id: "/r/a/b/f\($0).pdf", name: "f\($0).pdf", isDirectory: false) }
        let b = FileNode(id: "/r/a/b", name: "b", isDirectory: true, children: files)
        let a = FileNode(id: "/r/a", name: "a", isDirectory: true, children: [b])
        return PaneTree(side: .left, version: 1, nodes: [a])
    }()

    private struct Harness: View {
        @ObservedObject var box: Box
        let defaults: UserDefaults

        var body: some View {
            PaneColumnsView(
                tree: ColumnWidthsMountTests.tree, otherTree: PaneTree(side: .right, version: 1, nodes: []),
                childrenIndex: PaneChildrenIndex(tree: ColumnWidthsMountTests.tree, treeRoot: "/r"),
                treeRoot: "/r",
                browsePath: $box.browsePath, onNavigate: { box.browsePath = $0 },
                selection: $box.selection, otherSelection: [], isLeft: true,
                delegate: StubDelegate(), diffIndex: .empty, otherPaneName: "R",
                isSingleSource: false, density: .comfortable, isActivePane: true,
                placement: nil, onBarEdgeFlip: nil, onQuickLook: { _ in }, onBackgroundDeselect: { _ in }
            )
            .environment(\.paneColumnRevealAnimation, nil)
            .defaultAppStorage(defaults)
        }
    }

    /// Waits for `condition` — arrival, not a fixed time — up to a ceiling a loaded full run cannot
    /// outlast (`docs/flaky-tests.md`, "quiescence is not arrival").
    @discardableResult
    private func waitUntil(_ timeout: Double = 15, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        return condition()
    }

    private func lists(_ root: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, s.documentView is NSTableView { found.append(s) }
            v.subviews.forEach(walk)
        }
        walk(root)
        return found.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    /// Each column takes the width it was given on its own, and the others keep the shared one.
    @Test func eachColumnTakesItsOwnWidth() async throws {
        let defaults = ScratchDefaults("ColumnWidthsMountTests")
        defaults.set(210.0, forKey: PaneViewMode.columnWidthDefaultsKey)
        defaults.set(ColumnWidthOverrides(widths: [1: 400]).rawValue,
                     forKey: PaneViewMode.columnWidthOverridesDefaultsKey)
        let host = NSHostingView(rootView: Harness(box: Box(), defaults: defaults))
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        await waitUntil { self.lists(host).count == 3 && self.lists(host).map(\.frame.width).contains { abs($0 - 400) < 1 } }

        let widths = lists(host).map { $0.frame.width }
        try #require(widths.count == 3, "expected three columns, found \(widths.count)")
        #expect(abs(widths[0] - 210) < 1, "column 0 is \(widths[0]), not the shared 210")
        #expect(abs(widths[1] - 400) < 1, "column 1 is \(widths[1]), not the 400 it was sized to")
        #expect(abs(widths[2] - 210) < 1, "column 2 is \(widths[2]), not the shared 210")
    }

    /// Mounts the harness at `paneWidth` with nothing opened — the pane at rest, one column.
    private func mountAtRest(paneWidth: CGFloat, defaults: UserDefaults) -> (NSWindow, NSHostingView<Harness>) {
        let box = Box()
        box.browsePath = PaneBrowsePath()
        let host = NSHostingView(rootView: Harness(box: box, defaults: defaults))
        host.frame = NSRect(x: 0, y: 0, width: paneWidth, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        return (window, host)
    }

    /// The stack's own scroll view — the one whose document is not a column's table.
    private func stack(_ root: NSView) -> NSScrollView? {
        var found: NSScrollView?
        func walk(_ v: NSView) {
            if found == nil, let s = v as? NSScrollView, !(s.documentView is NSTableView) { found = s; return }
            v.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    /// **At rest, the one column has its own width** — the width it was sized to at depth 0, not the
    /// pane's. It used to span the pane until a folder was opened, then snap to this width on the
    /// first click. The dead space after it is the stack's filler: the content still exactly fills
    /// the viewport, which keeps the gutter after it.
    @Test func aRestingColumnTakesItsOwnWidth() async throws {
        let defaults = ScratchDefaults("ColumnWidthsMountTests")
        defaults.set(210.0, forKey: PaneViewMode.columnWidthDefaultsKey)
        defaults.set(ColumnWidthOverrides(widths: [0: 300]).rawValue,
                     forKey: PaneViewMode.columnWidthOverridesDefaultsKey)
        let (window, host) = mountAtRest(paneWidth: 1100, defaults: defaults)
        defer { window.contentView = nil }
        await waitUntil { self.lists(host).count == 1 }

        let widths = lists(host).map { $0.frame.width }
        try #require(widths.count == 1, "expected one column at rest, found \(widths.count)")
        #expect(abs(widths[0] - 300) < 1, "the resting column is \(widths[0]), not the 300 it was sized to")
        let viewport = 1100 - PaneViewMode.columnStackTrailingGutter
        let stack = try #require(stack(host), "no stack scroll view")
        #expect(abs(stack.frame.width - viewport) < 1, "the stack kept no gutter: \(stack.frame.width)")
        #expect(abs((stack.documentView?.frame.width ?? 0) - viewport) < 1,
                "the filler does not take the slack after the column: \(stack.documentView?.frame.width ?? 0)")
    }

    /// **Push mode still spans.** Below two minimum columns a pane shows one column at every depth,
    /// and that column takes the whole pane — no gutter, whatever width the column was sized to.
    @Test func aPushingPaneSpansItsOneColumn() async throws {
        let defaults = ScratchDefaults("ColumnWidthsMountTests")
        defaults.set(Double(PaneViewMode.minimumColumnWidth), forKey: PaneViewMode.columnWidthDefaultsKey)
        let paneWidth = PaneViewMode.pushNavigationBelowWidth - 10
        let (window, host) = mountAtRest(paneWidth: paneWidth, defaults: defaults)
        defer { window.contentView = nil }
        await waitUntil { self.lists(host).count == 1 }

        let widths = lists(host).map { $0.frame.width }
        try #require(widths.count == 1, "expected one column, found \(widths.count)")
        #expect(abs(widths[0] - paneWidth) < 1, "the pushing column is \(widths[0]) in a \(paneWidth)pt pane")
    }

    /// **The fit leaves the longest name whole — and not a point more than needed.** Rendered at the
    /// fitted width minus the list's inset, the row paints exactly as it does with all the room in the
    /// world; thirty points narrower, the name is cut. The control is what makes the first claim mean
    /// something: a harness that painted nothing would pass it.
    @Test(.machinePinned(.pixelSampling)) func aFittedColumnShowsItsLongestNameWhole() throws {
        let name = "Brokerage Statement - Individual Account - February 2024.pdf"
        let rows = ["a.pdf", "Notes.txt", name].map {
            PaneRow(side: .left, version: 0, node: FileNode(id: "/r/\($0)", name: $0, isDirectory: false), children: nil)
        }
        let fitted = PaneColumnsView.fittedWidth(for: rows, density: .comfortable, fonts: .unscaled,
                                                 diffIndex: .empty, riskyReason: { _ in nil })
        let rowWidth = fitted - PaneViewMode.columnRowHorizontalInset
        #expect(fitted < PaneViewMode.maximumColumnWidth, "the fit hit the ceiling, so it measured nothing")

        func bitmap(_ width: CGFloat) throws -> NSBitmapImageRep {
            let subject = ColumnRowView(row: rows[2], isIgnored: false, diffStatus: nil, containedDiffCount: 0,
                                        density: .comfortable, showsChevron: false)
                .frame(width: width, height: 26, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .light)
            let host = NSHostingView(rootView: AnyView(subject))
            host.frame = CGRect(x: 0, y: 0, width: width, height: 26)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.colorSpace = .sRGB
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep
        }
        func differing(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, upTo width: CGFloat) -> Int {
            let scale = Double(a.pixelsWide) / Double(a.size.width)
            var n = 0
            for y in 0..<min(a.pixelsHigh, b.pixelsHigh) {
                for x in 0..<Int(Double(width) * scale) {
                    guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
                    if max(abs(p.redComponent - q.redComponent), max(abs(p.greenComponent - q.greenComponent),
                           abs(p.blueComponent - q.blueComponent))) > 0.02 { n += 1 }
                }
            }
            return n
        }
        let roomy = try bitmap(900)
        let fit = try bitmap(rowWidth)
        let tight = try bitmap(rowWidth - 30)
        #expect(differing(roomy, fit, upTo: rowWidth - 1) == 0, "at the fitted width the longest name is cut")
        #expect(differing(roomy, tight, upTo: rowWidth - 31) > 0,
                "thirty points narrower than the fit the name is still whole — the fit is not tight, or nothing was painted")
    }

    /// **The fit finds the widest name, not the longest.** Candidates are the names that SET widest,
    /// so a name of wide letters — here twenty CJK characters — is measured even among forty-odd
    /// Latin names with more characters and less width. Counting characters would leave it out of
    /// the pool, and the column would be fitted too narrow to show it.
    @Test func theFitFindsTheWidestNameNotTheLongest() {
        let wide = "四半期報告書二〇二四年度第三四半期決算資料"
        let latin = (0..<45).map { "file-\($0)-iiiiiiiiiiiiiiiiiiiiii.txt" }
        let rows = ([wide] + latin).map {
            PaneRow(side: .left, version: 0, node: FileNode(id: "/r/\($0)", name: $0, isDirectory: false), children: nil)
        }
        #expect(latin.allSatisfy { $0.count > wide.count }, "the fixture no longer has the CJK name as the SHORTER one")
        func fit(_ rows: [PaneRow]) -> CGFloat {
            PaneColumnsView.fittedWidth(for: rows, density: .comfortable, fonts: .unscaled,
                                        diffIndex: .empty, riskyReason: { _ in nil })
        }
        let needed = fit([rows[0]])
        #expect(needed < PaneViewMode.maximumColumnWidth, "the CJK row alone hit the ceiling — the fixture measures nothing")
        #expect(fit(rows) >= needed, "fitted to \(fit(rows)) — narrower than the \(needed) the widest name needs")
    }

    /// **The List's leading inset is the half of `columnRowHorizontalInset` it budgets.** The fit
    /// lays rows out on their own and adds that constant for what the List puts around a row — a
    /// number measured once, by eye (16–16.5pt leading, 17pt trailing, rounded up to 34). Here the
    /// leading half is measured through the real stack: the row's icon, its first painted pixel,
    /// starts no further in than half the constant.
    ///
    /// **Only the leading half can be seen from here.** Offscreen, `cacheDisplay` captures the
    /// icon — an `NSImage` — but none of SwiftUI's text or symbols inside a List cell: a first
    /// version of this test compared a fitted column's name against a wider one's and passed with
    /// the constant cut to 14, because no name was ever painted. The trailing half stays the measured
    /// number it was.
    @Test(.machinePinned(.pixelSampling)) func theListsLeadingInsetIsTheHalfTheFitBudgets() async throws {
        let defaults = ScratchDefaults("ColumnWidthsMountTests-inset")
        let host = NSHostingView(rootView: Harness(box: Box(), defaults: defaults).environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        defer { window.contentView = nil }
        await waitUntil { self.lists(host).count == 3 }
        host.layoutSubtreeIfNeeded()
        let deepest = try #require(lists(host).last)
        let column = deepest.convert(deepest.bounds, to: host)
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = Double(rep.pixelsWide) / Double(host.bounds.width)
        let ground = try #require(rep.colorAt(x: Int((column.maxX - 3) * scale), y: Int((column.minY + 3) * scale)))
        var firstPainted: Double?
        scan: for x in Int(column.minX * scale)..<Int(column.maxX * scale) {
            for y in Int(column.minY * scale)..<min(Int(column.maxY * scale), rep.pixelsHigh) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if max(abs(c.redComponent - ground.redComponent), abs(c.greenComponent - ground.greenComponent),
                       abs(c.blueComponent - ground.blueComponent)) > 0.05 {
                    firstPainted = Double(x) / scale - column.minX
                    break scan
                }
            }
        }
        let leading = try #require(firstPainted, "nothing was painted in the column — the measurement is vacuous")
        #expect(leading <= PaneViewMode.columnRowHorizontalInset / 2 + 0.5,
                "a row's content starts \(leading)pt into its column, past the \(PaneViewMode.columnRowHorizontalInset / 2) the fit budgets for it")
    }

    /// **The deepest column has a resize handle** — a resting pane's lone column included. Dividers
    /// used to be drawn only BETWEEN columns — one shared width needed no more — which left the column
    /// most worth widening, the deepest one listing files, with no handle at all. A source scan, because a SwiftUI gesture view exposes
    /// nothing a mounted test can find; scoped to the overlay that places the divider.
    @Test func theDeepestColumnHasAResizeHandle() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/PaneColumnsView.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        let overlay = try #require(code.range(of: ".overlay(alignment: .trailing) {"), "the divider overlay moved")
        let body = code[overlay.upperBound...].prefix(900)
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(body.contains("divider(depth: depth"), "the overlay no longer places a column's divider")
        #expect(!body.contains("visible.count"), "the divider is excluded by column count again — a lone column needs one too")
    }
}
