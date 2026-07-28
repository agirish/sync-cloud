import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// The column stack's scrolling is NATIVE, and must stay that way.
///
/// Three commits (`63bb6cf` → `60fd18f` → `7021b28`) tried to tame the stack's horizontal
/// overscroll by hand — first switching elasticity off, then swapping in a custom `NSClipView`
/// that capped and gated the slack. Each round fixed its predecessor's symptom and shipped a new
/// one, because the swap replaced a clip view SwiftUI had configured with one it hadn't:
///
/// - The custom constrain granted ±44pt of **vertical** slack during a gesture, on a stack whose
///   native vertical elasticity SwiftUI sets to `.none` — the axis was locked until the swap
///   unlocked it. That is how a horizontal Miller-column stack ended up displaced *downward* by
///   a scroll gesture.
/// - The slack was gated on `willStart`/`didEndLiveScroll`, and `didEndLiveScroll` fires at
///   finger-lift — before the momentum phase, which is where a flick actually meets the edge.
///   Result: a dead stop instead of a bounce, plus a 0.22s snap-home animation racing the
///   momentum events still arriving — the jank when flinging back to the first column.
///
/// AppKit's own rubber band is bounded, momentum-aware and self-returning, and SwiftUI already
/// configures the stack correctly (horizontal `.allowed`, vertical `.none`). These tests pin that
/// configuration so the machinery is not reintroduced: the moment something swaps the clip view
/// or kills the elasticity again, the mounted assertions fail.
@MainActor
@Suite struct PaneColumnsScrollTests {

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
                childrenIndex: index, treeRoot: PaneColumnsScrollTests.root,
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

    @Test func testTheMountedStackScrollsNatively() async throws {
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

        // The stack really scrolls, so none of the assertions below hold vacuously.
        let extent = max(0, (stack.documentView?.frame.width ?? 0) - stack.contentSize.width)
        #expect(extent > 0, "fixture does not overflow, so the scrolling assertions are vacuous")

        // Horizontal bounce is AppKit's own: present, bounded, momentum-aware. `.none` is the
        // dead stop that was reported as "no bounce effect"; reintroduce it and this fails.
        #expect(stack.horizontalScrollElasticity != .none,
                "the stack lost its bounce — it stops dead at each edge")
        // Vertically the stack must be inert: SwiftUI sets `.none` for a horizontal-only
        // ScrollView, and this is what keeps a scroll gesture from dragging the columns downward.
        #expect(stack.verticalScrollElasticity == .none,
                "the stack can be displaced vertically — a scroll will pull the columns down")

        // The clip view is SwiftUI's own, exactly `NSClipView`. A custom subclass here means the
        // swap is back — and with it whatever constraint relaxations it carries. (Note this is a
        // class check, not a behavior check: a mutation run showed `isFlipped` self-corrects once
        // the document is reattached, so flippedness detects nothing.)
        #expect(type(of: stack.contentView) == NSClipView.self,
                "the stack's clip view was swapped for a custom subclass — the machinery is back")

        // The columns' own lists keep their native vertical bounce. (No class check here: a
        // List's clip view is a private SwiftUI subclass, so `NSClipView.self` is the wrong
        // expectation — the stack's plain `NSClipView` is the special case, not the rule.)
        #expect(columns.allSatisfy { $0.verticalScrollElasticity != .none },
                "a column list lost its vertical bounce")
    }
}
