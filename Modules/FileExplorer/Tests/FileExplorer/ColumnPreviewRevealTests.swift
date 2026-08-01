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
/// **`.serialized` is load-bearing, not tidiness.** Two tests here assert a stack STAYS where the
/// user put it, and two others commit a new `columnWidthDefaultsKey` / `previewColumnWidthDefaultsKey`
/// — the very preferences whose change fires a reveal in every pane. Those keys are process-wide by
/// design (the app has one domain and all panes share it, which is what the drivers on those keys
/// are for), and `@AppStorage` delivers their change notification by KEY NAME across stores: a
/// write into one test's `ScratchDefaults` re-evaluates the same key in every other pane alive in
/// the process, `.defaultAppStorage` isolation notwithstanding. Traced directly — one write raised
/// a single burst of driver fires spanning three panes here plus one in `ColumnPreviewLayoutTests`,
/// whose tree root is a temp directory and whose store is a different UUID suite entirely.
///
/// Run in parallel, then, a widening test's commit lands inside an absence test's observation
/// window and reveals ITS stack to the far end — `testAPreviewWidthCommitLeavesAPreviewlessPaneAlone`
/// to exactly its 150pt extent, `testClosingThePreviewLeavesAScrolledBackStackWhereItWas` to its
/// 570pt one. That was already flaking before this trait existed (1 full-suite run in 4), and it is
/// a property of the harness, not of the pane: in the app those cross-pane fires are correct.
///
/// The cost is real and worth it: serialized, this suite becomes the FileExplorer target's critical
/// path and takes it from ~11s to ~32s. The 11s was buying a 1-in-4 flake.
@MainActor
@Suite(.serialized) struct ColumnPreviewRevealTests {

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
            // Place the reveal outright instead of easing it across. Not a speed-up: this window
            // is offscreen and never key, so whenever the machine throttles CoreAnimation — the
            // display asleep, or Low Power Mode on battery — a SwiftUI animation in it NEVER
            // advances, and the reveal's scroll never lands at all. Measured on one commit with
            // the shipped ease: 6/6 here with the display awake, 5/6 FAILING with it asleep,
            // reporting the exact geometry of the defect these tests exist to catch (deepest
            // column 420…630, viewport 0…270). An unattended self-hosted runner sleeps its
            // display by definition, so that is CI's normal state — which made the verdict a
            // property of the machine rather than of the code.
            //
            // This is the injection the ambient lever cannot do: `.transaction { $0.animation =
            // nil }` here is beaten by the explicit `withAnimation` at the state change inside
            // `revealDeepestColumn`, so the animation has to be nil where that call reads it.
            //
            // It costs these tests nothing they were measuring. Every assertion below is about
            // WHERE the scroll lands, never how it travels, and `scrollTo` resolves the same
            // destination against the same post-layout viewport either way — including through
            // the deferred hop and the retry, both of which still run.
            .environment(\.paneColumnRevealAnimation, nil)
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

    /// Scrolls the stack back to a legal origin, the way a user reading earlier columns does,
    /// and waits for it to rest there.
    private func scrollBack(_ mounted: Mounted, toX x: CGFloat) async {
        let clip = mounted.stack.contentView
        clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
        mounted.stack.reflectScrolledClipView(clip)
        await settle(mounted)
    }

    /// Widening the COLUMNS pushes the deepest column's trailing edge past the preview's seam —
    /// the same defect class the preview divider had, from the other divider. The reveal has to
    /// follow the column divider's commit too.
    ///
    /// Driven by writing the stored width, exactly as the preview-divider test above: the drag
    /// renders from `dragWidth` and commits to the preference in `onEnded`, and the committed
    /// state is what the view keys its driver on.
    @Test func testWideningTheColumnsKeepsTheDeepestColumnOnScreen() async throws {
        let mounted = try await mount(paneWidth: 690, depth: 2)
        defer { _ = mounted.window }

        let full = mounted.stack.contentView.bounds.width
        #expect(await openPreview(mounted, viewportWas: full), "no preview appeared")

        let deepestBefore = try #require(columnFrames(mounted).last)
        #expect(deepestBefore.maxX <= visibleSpan(mounted).upperBound + 1,
                "the deepest column was already hidden before the resize — this test's premise is gone")

        let contentBefore = mounted.stack.documentView?.frame.width ?? 0
        let originBefore = mounted.stack.contentView.bounds.origin.x

        // A drag that grows every column from 210 to 260, committed.
        mounted.defaults.set(260.0, forKey: PaneViewMode.columnWidthDefaultsKey)
        await wait(mounted.window, upTo: 25) {
            (mounted.stack.documentView?.frame.width ?? 0) > contentBefore
        }
        await wait(mounted.window, upTo: 25) {
            mounted.stack.contentView.bounds.origin.x != originBefore
        }
        await settle(mounted)

        let content = mounted.stack.documentView?.frame.width ?? 0
        #expect(content > contentBefore,
                "the stored column width never reached the layout (content \(content)pt) — nothing below measures a resize")
        #expect(content > mounted.stack.contentView.bounds.width,
                "the widened stack does not overflow its viewport — the reveal is unobservable here, so this is vacuous")
        let deepest = try #require(columnFrames(mounted).last)
        let visible = visibleSpan(mounted)
        #expect(deepest.maxX <= visible.upperBound + 1,
                "widening the columns pushed the deepest column off screen and nothing revealed it: column \(deepest.minX)…\(deepest.maxX), visible \(visible.lowerBound)…\(visible.upperBound)")
        #expect(deepest.minX >= visible.lowerBound - 1,
                "the deepest column is cut off on its leading edge: column \(deepest.minX)…\(deepest.maxX), visible \(visible.lowerBound)…\(visible.upperBound)")
    }

    /// The preview-width key is ONE process-wide preference shared by every `PaneColumnsView`
    /// (both comparison panes and the Tidy rail). Ending a preview-divider drag in one pane fires
    /// the stored-width driver in all of them — but a pane whose preview is HIDDEN had its
    /// viewport untouched by that drag, and revealing there clobbers a scroll-back the user made
    /// deliberately. This pane never opens a preview at all; the shared key changing must leave
    /// its stack exactly where the user put it.
    @Test func testAPreviewWidthCommitLeavesAPreviewlessPaneAlone() async throws {
        let mounted = try await mount(paneWidth: 690, depth: 3)
        defer { _ = mounted.window }
        let clip = mounted.stack.contentView

        // No selection was ever made, so no preview: the stack keeps the full pane's viewport,
        // and four columns overflow it — a wrong reveal would genuinely move the stack.
        let content = mounted.stack.documentView?.frame.width ?? 0
        #expect(content > clip.bounds.width,
                "fixture does not overflow its viewport (content \(content)pt in \(clip.bounds.width)pt) — a wrong reveal would be invisible, so this proves nothing")
        #expect(clip.bounds.width > 690 - PaneViewMode.minimumPreviewColumnWidth,
                "a preview took room from this pane — the premise of a preview-less pane is gone")

        // The drill's own reveal parked the stack at its trailing edge; the user scrolls back.
        #expect(clip.bounds.origin.x > 0,
                "the drill never revealed, so the scroll-back below distinguishes nothing")
        await scrollBack(mounted, toX: 0)
        try #require(clip.bounds.origin.x == 0, "fixture failed to scroll the stack back")

        // Another pane's preview divider commits: the shared key changes, this viewport does not.
        mounted.defaults.set(470.0, forKey: PaneViewMode.previewColumnWidthDefaultsKey)
        // Absence has no observable to wait on, so hold a window comfortably past the reveal's
        // deferred hop (one runloop turn), its 0.25s retry, and its 0.18s animation.
        await pump(mounted.window, seconds: 2.0)
        #expect(clip.bounds.origin.x == 0,
                "a preview-width commit scrolled a pane whose preview is hidden, to x \(clip.bounds.origin.x)")
    }

    /// Closing the preview GROWS the viewport, so a scrolled-back origin stays legal — and must
    /// stay put. The falling edge used to reveal unconditionally, yanking the whole stack to the
    /// deepest column the moment the preview closed; the only close that needs correcting is an
    /// origin the grown viewport made illegal, and that is the overscroll watchdog's clamp, not
    /// this driver's business.
    @Test func testClosingThePreviewLeavesAScrolledBackStackWhereItWas() async throws {
        let mounted = try await mount(paneWidth: 690, depth: 3)
        defer { _ = mounted.window }
        let clip = mounted.stack.contentView

        let full = clip.bounds.width
        #expect(await openPreview(mounted, viewportWas: full), "no preview appeared")
        let narrow = clip.bounds.width
        try #require(narrow < full, "the preview never narrowed the viewport")

        // The user scrolls back to read the first columns...
        await scrollBack(mounted, toX: 0)
        try #require(clip.bounds.origin.x == 0, "fixture failed to scroll the stack back")

        // ...then closes the preview (clearing the selection is how a preview goes away).
        mounted.box.selection = []
        await wait(mounted.window, upTo: 25) { clip.bounds.width > narrow }
        #expect(clip.bounds.width > narrow,
                "the preview never closed — nothing below measures the falling edge")
        // The stack must still overflow the grown viewport: a fitting stack sits at origin 0 no
        // matter what fires, and the assertion below would hold with the yank present.
        let content = mounted.stack.documentView?.frame.width ?? 0
        #expect(content > clip.bounds.width,
                "the stack fits its restored viewport (content \(content)pt in \(clip.bounds.width)pt) — a wrong reveal would be invisible, so this is vacuous")
        await pump(mounted.window, seconds: 2.0)
        #expect(clip.bounds.origin.x == 0,
                "closing the preview yanked a scrolled-back stack to x \(clip.bounds.origin.x)")
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
