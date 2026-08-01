import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// Opening the preview must leave the column it describes on screen.
///
/// The preview is pinned OUTSIDE the scroll view (`PaneColumnsView.columnStack`), so its arrival
/// narrows the column stack's viewport while AppKit keeps `bounds.origin.x` exactly where it was.
/// Whatever occupied the points the preview now covers is simply hidden — and that is the deepest
/// column, the one holding the very file the preview is describing.
///
/// Nothing else in the pane corrects this. The only scroll driver keys on `browsePath`, and
/// clicking a file in the deepest column normally leaves `browsePath` untouched (`truncate` at
/// that depth is a no-op), so it never fires. The overscroll watchdog cannot help either:
/// narrowing the clip *grows* the legal scroll range, so the stale origin stays legal and
/// `legalOrigin` has nothing to clamp.
///
/// These tests measure the LAID-OUT result — where the deepest column's frame lands relative to
/// the clip's visible span — rather than the widths that feed it, because the widths were never
/// in doubt; what they add up to on screen was.
///
/// Both pane widths are exercised deliberately. The bug was reported as "Tidy works, Compare
/// doesn't", and that difference is pure geometry, not two code paths: there is exactly one
/// `PaneColumnsView` call site. A full-width rail has room left over after the preview takes its
/// 420pt, so a shallow stack stays wholly visible and the missing scroll driver never shows;
/// half a window does not. Pin both, so the rail cannot quietly regress the day someone drills
/// one column deeper than this fixture does.
@MainActor
@Suite struct ColumnPreviewRevealTests {

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
    private static let levels = ["a", "b", "c", "d"]

    /// A chain `depth` directories deep, branching 3 ways at each level, with five files in the
    /// leaves. Depth is a parameter because how many columns it takes to overflow the stack is the
    /// whole difference between the two panes: three columns overflow a comparison pane's leftover
    /// room and not a rail's.
    private static func tree(depth: Int) -> PaneTree {
        func children(of path: String, level: Int) -> [FileNode] {
            guard level < depth else {
                return (0..<5).map {
                    FileNode(id: "\(path)/f\($0).pdf", name: "f\($0).pdf", isDirectory: false)
                }
            }
            return (0..<3).map { index in
                let name = "\(levels[level])\(index)"
                let child = "\(path)/\(name)"
                return FileNode(id: child, name: name, isDirectory: true,
                                children: children(of: child, level: level + 1))
            }
        }
        return PaneTree(side: .left, version: 1, nodes: children(of: root, level: 0))
    }

    /// The stack `tree(depth:)` opens when walked down its first branch: `depth + 1` columns.
    private static func browsePath(depth: Int) -> PaneBrowsePath {
        PaneBrowsePath(components: levels.prefix(depth).map { "\($0)0" })
    }

    /// A file in the DEEPEST column — the only place a preview target can live
    /// (`ColumnPreview.item`).
    private static func previewTarget(depth: Int) -> String {
        (["\(root)"] + levels.prefix(depth).map { "\($0)0" }).joined(separator: "/") + "/f1.pdf"
    }

    private struct Harness: View {
        @ObservedObject var box: Box
        let tree: PaneTree
        let index: PaneChildrenIndex
        let defaults: UserDefaults

        var body: some View {
            PaneColumnsView(
                tree: tree, otherTree: PaneTree(side: .right, version: 1, nodes: []),
                childrenIndex: index, treeRoot: ColumnPreviewRevealTests.root,
                browsePath: $box.browsePath, onNavigate: { box.browsePath = $0 },
                selection: $box.selection, otherSelection: [], isLeft: true,
                delegate: StubDelegate(), diffIndex: .empty, otherPaneName: "R",
                isSingleSource: false, density: .compact, isActivePane: true,
                placement: nil, onBarEdgeFlip: nil, onQuickLook: { _ in },
                onBackgroundDeselect: { _ in }
            )
            // The preview toggle and the column width are both `@AppStorage`, and a value left in
            // the test process's standard domain by another suite would decide this test's
            // geometry — a stored `false` makes every assertion below vacuously true.
            .defaultAppStorage(defaults)
        }
    }

    /// One mounted pane, plus the handles the measurements need.
    private struct Mounted {
        let window: NSWindow
        let box: Box
        let stack: NSScrollView
        let defaults: UserDefaults
        let depth: Int
    }

    private func pump(_ window: NSWindow, seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            window.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        window.layoutIfNeeded()
    }

    /// Pumps until `condition` holds, or the deadline passes. Returns whether it held.
    @discardableResult
    private func wait(_ window: NSWindow, upTo seconds: Double,
                      for condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            window.layoutIfNeeded()
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        window.layoutIfNeeded()
        return condition()
    }

    /// Pumps until the stack's horizontal offset has held still for `quiet` seconds.
    ///
    /// **Never sufficient on its own.** Stillness cannot distinguish "the scroll has finished" from
    /// "the scroll has not started yet", and both are common here: the reveal is deferred a runloop
    /// turn and then animates for 0.18s. Waiting only for quiescence is what made these tests pass
    /// with two mounted panes in the suite and fail with three — the third pane's contention pushed
    /// the deferred hop past the quiet window, so a stack that had not moved yet read as settled.
    /// Callers wait for the movement they expect FIRST, then use this to wait out its animation.
    ///
    /// A fixed sleep is what all of this replaces, and it is why the first version passed under
    /// `--filter` and failed in the full suite: 1.5s is ample on an idle machine and nowhere near
    /// enough when 574 tests contend for the main thread. `PaneColumnsScrollTests` learned the same
    /// thing about the drill's own auto-scroll.
    private func settle(_ mounted: Mounted, quiet: Double = 0.6, upTo seconds: Double = 25) async {
        let clip = mounted.stack.contentView
        var last = clip.bounds.origin.x
        var heldSince = Date()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, Date().timeIntervalSince(heldSince) < quiet {
            mounted.window.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 8_000_000)
            let now = clip.bounds.origin.x
            if now != last {
                last = now
                heldSince = Date()
            }
        }
        mounted.window.layoutIfNeeded()
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

    /// Mounts the pane at `paneWidth` with `depth + 1` columns open, after the drill's own
    /// auto-scroll has settled.
    private func mount(paneWidth: CGFloat, depth: Int) async throws -> Mounted {
        let box = Box()
        let defaults = ScratchDefaults("column-preview-reveal")
        let tree = Self.tree(depth: depth)
        let index = PaneChildrenIndex(tree: tree, treeRoot: Self.root)
        let host = NSHostingView(rootView: Harness(box: box, tree: tree, index: index,
                                                   defaults: defaults))
        host.frame = NSRect(x: 0, y: 0, width: paneWidth, height: 520)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()

        box.browsePath = Self.browsePath(depth: depth)
        // Long enough for the columns to exist at all; the drill's own auto-scroll is then waited
        // out by `settle` below, not by this.
        await pump(window, seconds: 0.3)

        let stack = try #require(
            scrollViews(window.contentView!).first { !($0.documentView is NSTableView) },
            "no stack scroll view")
        let mounted = Mounted(window: window, box: box, stack: stack, defaults: defaults,
                              depth: depth)
        // The drill scrolls the stack too. Letting it finish before the preview opens keeps the
        // two from being read as one movement — and keeps a late-landing drill from being mistaken
        // for the reveal under test.
        await wait(window, upTo: 25) { self.columnFrames(mounted).count == depth + 1 }
        await settle(mounted)
        return mounted
    }

    /// The columns' frames in the stack document's own coordinates, leading edge first.
    private func columnFrames(_ mounted: Mounted) -> [CGRect] {
        guard let document = mounted.stack.documentView else { return [] }
        return scrollViews(mounted.window.contentView!)
            .filter { $0.documentView is NSTableView }
            .map { $0.convert($0.bounds, to: document) }
            .sorted { $0.minX < $1.minX }
    }

    /// The span of the document the clip is currently showing.
    private func visibleSpan(_ mounted: Mounted) -> ClosedRange<CGFloat> {
        let clip = mounted.stack.contentView
        let origin = clip.bounds.origin.x
        return origin...(origin + clip.bounds.width)
    }

    /// Selects the deepest column's file — which is what raises the preview — then waits for the
    /// preview to actually take its room and for the stack to stop moving.
    ///
    /// - Returns: whether the viewport ever narrowed, i.e. whether a preview rendered at all.
    @discardableResult
    private func openPreview(_ mounted: Mounted, viewportWas width: CGFloat) async -> Bool {
        let clip = mounted.stack.contentView
        let originBefore = clip.bounds.origin.x
        mounted.box.selection = [Self.previewTarget(depth: mounted.depth)]
        // The preview taking its points is the event this test is about; wait for that first, so a
        // slow mount cannot be misread as a missing reveal.
        let narrowed = await wait(mounted.window, upTo: 25) { clip.bounds.width < width }
        // Then for the stack to actually move. This does wait on the outcome, which is the trade
        // the repo already makes for the drill's auto-scroll — and it is not the assertion: this
        // asks only whether the stack moved AT ALL, while the assertions ask WHERE it landed. A
        // scroll in the wrong direction, or one that stops short, satisfies this wait and still
        // fails the measurement.
        await wait(mounted.window, upTo: 25) { clip.bounds.origin.x != originBefore }
        await settle(mounted)
        return narrowed
    }

    /// Opens a preview over a `depth + 1` column stack in a `paneWidth` pane and asserts the
    /// column the preview describes is wholly on screen afterwards.
    ///
    /// Every guard here exists because its absence would let the assertion pass for the wrong
    /// reason: the wrong number of columns, no preview at all, or — the subtle one — a stack that
    /// fits its narrowed viewport, where the deepest column is visible at *any* scroll offset and
    /// the reveal is untestable.
    private func expectDeepestColumnVisible(paneWidth: CGFloat, depth: Int) async throws {
        let mounted = try await mount(paneWidth: paneWidth, depth: depth)
        defer { _ = mounted.window }

        let before = columnFrames(mounted)
        #expect(before.count == depth + 1,
                "fixture opened \(before.count) columns, expected \(depth + 1) — nothing below measures the reported case")
        let widthBefore = mounted.stack.contentView.bounds.width

        let narrowed = await openPreview(mounted, viewportWas: widthBefore)

        let after = columnFrames(mounted)
        #expect(after.count == depth + 1,
                "the preview restructured the stack (\(after.count) columns) — it must only narrow it")
        let widthAfter = mounted.stack.contentView.bounds.width
        #expect(narrowed && widthAfter < widthBefore,
                "no preview appeared at \(paneWidth)pt within the wait — the stack kept its full \(widthBefore)pt, so this case proves nothing")

        // The load-bearing guard. If the columns still fit the narrowed viewport there is no
        // offset at which the deepest one is hidden, and the assertions below hold whether or not
        // the reveal exists. This is exactly why a three-column stack could not detect the bug on
        // a full-width rail.
        let content = mounted.stack.documentView?.frame.width ?? 0
        #expect(content > widthAfter,
                "the stack does not overflow its \(widthAfter)pt viewport (content \(content)pt) — the reveal is unobservable here, so this case is vacuous")

        let deepest = try #require(after.last, "no deepest column")
        let visible = visibleSpan(mounted)
        let report = """
            column \(deepest.minX)…\(deepest.maxX), visible \(visible.lowerBound)…\(visible.upperBound) \
            (pane \(paneWidth)pt, stack \(widthBefore)pt → \(widthAfter)pt, content \(content)pt)
            """
        #expect(deepest.maxX <= visible.upperBound + 1,
                "the deepest column is hidden behind the preview: \(report)")
        #expect(deepest.minX >= visible.lowerBound - 1,
                "the deepest column is cut off on its leading edge: \(report)")
    }

    /// A comparison pane — half a window, three columns. The reported failure: measured before the
    /// fix, the stack narrowed 690 → 270 with the deepest column sitting at 420…630, entirely off
    /// screen.
    @Test func testACompareWidthPaneRevealsTheColumnThePreviewDescribes() async throws {
        try await expectDeepestColumnVisible(paneWidth: 690, depth: 2)
    }

    /// Widening the preview walks its seam left across the deepest column. The reveal has to
    /// follow, or a drag re-creates the very defect opening the preview no longer has.
    ///
    /// Driven by writing the stored width, which is precisely what a finished drag does — the
    /// divider renders from `dragPreviewWidth` while the finger is down and commits to the
    /// preference in `onEnded`. That is also why this is keyed on the stored value in the view: a
    /// `DragGesture` cannot be synthesized here, but the state it commits can, and it is the same
    /// state.
    @Test func testWideningThePreviewKeepsTheDeepestColumnOnScreen() async throws {
        let mounted = try await mount(paneWidth: 690, depth: 2)
        defer { _ = mounted.window }

        let full = mounted.stack.contentView.bounds.width
        #expect(await openPreview(mounted, viewportWas: full), "no preview appeared")

        let deepestBefore = try #require(columnFrames(mounted).last)
        let narrowViewport = mounted.stack.contentView.bounds.width
        #expect(deepestBefore.maxX <= visibleSpan(mounted).upperBound + 1,
                "the deepest column was already hidden before the resize — this test's premise is gone")

        // A drag that grows the preview from 420 to 470, committed.
        let originBefore = mounted.stack.contentView.bounds.origin.x
        mounted.defaults.set(470.0, forKey: PaneViewMode.previewColumnWidthDefaultsKey)
        await wait(mounted.window, upTo: 25) {
            mounted.stack.contentView.bounds.width < narrowViewport
        }
        await wait(mounted.window, upTo: 25) {
            mounted.stack.contentView.bounds.origin.x != originBefore
        }
        await settle(mounted)

        let viewport = mounted.stack.contentView.bounds.width
        #expect(viewport < narrowViewport,
                "the stored width did not reach the layout (viewport \(viewport)pt, was \(narrowViewport)pt) — nothing below measures a resize")
        let deepest = try #require(columnFrames(mounted).last)
        let visible = visibleSpan(mounted)
        #expect(deepest.maxX <= visible.upperBound + 1,
                "widening the preview pushed the deepest column back off screen: column \(deepest.minX)…\(deepest.maxX), visible \(visible.lowerBound)…\(visible.upperBound)")
    }

    /// A Tidy rail — full width, and deep enough that the rail overflows too.
    ///
    /// Depth matters: at three columns this width passed before the fix as well, because 980pt of
    /// leftover viewport covers a 630pt stack no matter where it is scrolled. That is the whole
    /// reason the bug read as "Tidy works" — not a different code path, just a stack that had not
    /// outgrown the rail yet. Five columns overflow it, which makes this case detect the same
    /// defect the comparison pane hit at three.
    @Test func testATidyWidthRailRevealsTheColumnThePreviewDescribes() async throws {
        try await expectDeepestColumnVisible(paneWidth: 1400, depth: 4)
    }
}
