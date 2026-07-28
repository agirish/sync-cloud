import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// The column stack must not rubber-band horizontally, and the styler must disarm the STACK's
/// scroll view rather than one of the columns' lists — the two mistakes are indistinguishable from
/// the outside, since both leave a scroll view somewhere with elasticity switched off.
@Suite struct PaneColumnsScrollStylerRuleTests {

    /// A column's scroll view (an `NSTableView` document) must be walked past; the stack's (anything
    /// else) is the one to take.
    @MainActor
    @Test func testItSkipsAColumnsListAndTakesTheStacksScrollView() {
        let stack = NSScrollView()
        stack.documentView = NSView()          // the row of columns

        let columnList = NSScrollView()
        columnList.documentView = NSTableView() // one column's list
        stack.documentView?.addSubview(columnList)

        let probe = NSView()
        columnList.documentView?.addSubview(probe)

        let found = PaneColumnsScrollStyler.StylerView.findStackScrollView(from: probe)
        #expect(found === stack, "the walk stopped at a column's own list instead of the stack")
    }

    /// Nothing to find is answered with nil rather than a guess.
    @MainActor
    @Test func testItRefusesWhenThereIsNoStackScroller() {
        let columnList = NSScrollView()
        columnList.documentView = NSTableView()
        let probe = NSView()
        columnList.documentView?.addSubview(probe)

        #expect(PaneColumnsScrollStyler.StylerView.findStackScrollView(from: probe) == nil)
    }
}

/// End to end: the real pane, mounted, with its horizontal elasticity actually off.
@MainActor
@Suite struct PaneColumnsScrollStylerTests {

    private struct StubDelegate: FileActionDelegate {
        func handleRefresh() {}
        func handleFocus(_ node: FileNode) {}
        func handleCopy(_ nodes: [FileNode]) {}
        func handleMove(_ nodes: [FileNode]) {}
        func handleDelete(_ nodes: [FileNode]) {}
        func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) {}
        func handlePaste(_ targetDir: FileNode) {}
        func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode]) {}
        func handlePasteToPath(_ path: String) {}
        func handleDrop(_ nodes: [FileNode], toPath path: String, isMove: Bool) {}
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

    private static func tree() -> PaneTree {
        let top = (0..<6).map { a -> FileNode in
            let dir = "\(root)/a\(a)"
            let mids = (0..<6).map { b -> FileNode in
                let bPath = "\(dir)/b\(b)"
                return FileNode(id: bPath, name: "b\(b)", isDirectory: true,
                                children: (0..<5).map { FileNode(id: "\(bPath)/f\($0).pdf", name: "f\($0).pdf", isDirectory: false) })
            }
            return FileNode(id: dir, name: "a\(a)", isDirectory: true, children: mids)
        }
        return PaneTree(side: .left, version: 1, nodes: top)
    }

    private struct Harness: View {
        @ObservedObject var box: Box
        let tree: PaneTree
        let index: PaneChildrenIndex

        var body: some View {
            PaneColumnsView(
                tree: tree, otherTree: PaneTree(side: .right, version: 1, nodes: []),
                childrenIndex: index, treeRoot: PaneColumnsScrollStylerTests.root,
                browsePath: $box.browsePath, onNavigate: { box.browsePath = $0 },
                selection: $box.selection, otherSelection: [], isLeft: true,
                delegate: StubDelegate(), diffIndex: .empty, otherPaneName: "R",
                isSingleSource: false, density: .compact, isActivePane: true,
                placement: nil, onBarEdgeFlip: nil, onQuickLook: { _ in }
            )
        }
    }

    private func pump(_ window: NSWindow, seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            window.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        window.layoutIfNeeded()
    }

    private func scrollViews(_ view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView { found.append(s) }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return found
    }

    @Test func testTheMountedStackHasHorizontalElasticityOff() async throws {
        let box = Box()
        let tree = Self.tree()
        let index = PaneChildrenIndex(tree: tree, treeRoot: Self.root)
        let host = NSHostingView(rootView: Harness(box: box, tree: tree, index: index))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 520)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()

        // Three columns in a 520pt pane: 630pt of content, so the stack really scrolls.
        box.browsePath = PaneBrowsePath(components: ["a2", "b3"])
        await pump(window, seconds: 1.5)

        let all = scrollViews(window.contentView!)
        let stack = try #require(all.first { !($0.documentView is NSTableView) }, "no stack scroll view")
        let columns = all.filter { $0.documentView is NSTableView }
        #expect(columns.count == 3, "expected three column lists, found \(columns.count)")

        #expect(stack.horizontalScrollElasticity == .none,
                "the column stack can still rubber-band past its edges")
        // The columns' own vertical bounce is deliberately untouched.
        #expect(columns.allSatisfy { $0.verticalScrollElasticity != .none },
                "a column list lost its vertical bounce — the styler disarmed the wrong scroll view")
    }
}
