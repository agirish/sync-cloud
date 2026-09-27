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

    private func pump(_ seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { try? await Task.sleep(nanoseconds: 8_000_000) }
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
        await pump(1.0)

        let widths = lists(host).map { $0.frame.width }
        try #require(widths.count == 3, "expected three columns, found \(widths.count)")
        #expect(abs(widths[0] - 210) < 1, "column 0 is \(widths[0]), not the shared 210")
        #expect(abs(widths[1] - 400) < 1, "column 1 is \(widths[1]), not the 400 it was sized to")
        #expect(abs(widths[2] - 210) < 1, "column 2 is \(widths[2]), not the shared 210")
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

    /// **The deepest column has a resize handle.** Dividers used to be drawn only BETWEEN columns — one
    /// shared width needed no more — which left the column most worth widening, the deepest one
    /// listing files, with no handle at all. A source scan, because a SwiftUI gesture view exposes
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
        #expect(!body.contains("visible.count - 1"), "the divider is excluded from the last column again")
    }
}
