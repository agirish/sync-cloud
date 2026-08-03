import Testing
import AppKit
import Design
import Events
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
///
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
        /// The deferred reveal's hold budget, or `nil` for the shipped one. Only the exhaustion
        /// test shortens it — see `paneColumnRevealHoldChecks`.
        var holdChecks: Int? = nil

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
            .environment(\.paneColumnRevealHoldChecks,
                         holdChecks ?? PaneColumnsView.revealHoldChecks)
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
    /// turn, and issued again after `revealRetryDelay`. Waiting only for quiescence is what made
    /// these tests pass with two mounted panes in the suite and fail with three — the third pane's
    /// contention pushed the deferred hop past the quiet window, so a stack that had not moved yet
    /// read as settled. Callers wait for the movement they expect FIRST, then use this to wait out
    /// whatever is still coming.
    ///
    /// (NOT the reveal's 0.18s ease — this harness sets `paneColumnRevealAnimation` to `nil`, so
    /// each attempt lands in one step. The deferral and the retry are what remain ambiguous, and
    /// they are unaffected by that.)
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

    /// A one-shot flag a queued block can set — a mutable local captured by an escaping closure
    /// would not be, and the whole point here is to observe the QUEUE, not the wall clock.
    private final class Marker {
        var fired = false
    }

    /// How far the stack's origin ever strays from `origin` before a marker queued NOW drains.
    ///
    /// This is how an ABSENCE is bounded here, and it replaces a fixed `pump(seconds: 2.0)`.
    /// A reveal is scheduled as one main-queue hop plus a `revealRetryDelay` retry; a marker
    /// queued after the trigger's own layout change has already been observed therefore has a
    /// strictly later deadline than anything that trigger scheduled, and the main queue drains
    /// them in that order. Under load both slip together, which is exactly what a wall-clock
    /// window cannot do — this file's own `settle` documents that trap, and these two absence
    /// tests were the last places still falling into it: a reveal landing at t=2.1s made them
    /// pass with the bug fully present, and nothing would ever have flagged it.
    ///
    /// The whole interval is sampled, not just its end, so a stack that moves and is put back
    /// still counts as a failure.
    private func maxOriginDrift(_ mounted: Mounted, from origin: CGFloat) async -> CGFloat {
        let marker = Marker()
        // Past the retry, plus margin, so a retry that fired is not merely queued but has visibly
        // moved the clip. The margin does NOT have to cover the reveal's 0.18s ease: this harness
        // sets `paneColumnRevealAnimation` to `nil`, so a scroll that fires lands in one step —
        // which leaves this window with more slack than it needs, not less.
        DispatchQueue.main.asyncAfter(deadline: .now() + PaneColumnsView.revealRetryDelay + 0.3) {
            MainActor.assumeIsolated { marker.fired = true }
        }
        let clip = mounted.stack.contentView
        var worst: CGFloat = 0
        _ = await wait(mounted.window, upTo: 30) {
            worst = max(worst, abs(clip.bounds.origin.x - origin))
            return marker.fired
        }
        return max(worst, abs(clip.bounds.origin.x - origin))
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

    /// The overscroll watchdogs mounted under this pane. The watchdog is where the axis lock is
    /// consulted and enforced, so swapping its `axisLock` for a test-owned tracker is the only way
    /// to put a *mounted* stack under a hold deterministically — `WheelGestureTracker.shared`
    /// installs a real event monitor and is driven by the machine's own trackpad.
    private func watchdogs(_ mounted: Mounted) -> [PaneColumnsOverscrollReturn.WatchdogView] {
        var found: [PaneColumnsOverscrollReturn.WatchdogView] = []
        func walk(_ v: NSView) {
            if let w = v as? PaneColumnsOverscrollReturn.WatchdogView { found.append(w) }
            for sub in v.subviews { walk(sub) }
        }
        walk(mounted.window.contentView!)
        return found
    }

    /// The pane's ONE watchdog, or a failure naming how many were actually found.
    ///
    /// The count is the load-bearing half. Every test that puts a mounted stack under a hold does
    /// it by swapping ONE watchdog's `axisLock` for a tracker it drives; pick the wrong one out of
    /// several and the pane's gate is still wired to `WheelGestureTracker.shared`, which installs a
    /// real `NSEvent` monitor fed by the machine's own trackpad. The test would then assert against
    /// whatever the person at the Mac happens to be scrolling — the ambient-input flake class
    /// `paneClickModifiers` exists to close, arriving by a different door. Today the pane mounts
    /// exactly one; if a future change mounts a second column stack here, this fails loudly at the
    /// swap rather than quietly measuring the room.
    private func soleWatchdog(_ mounted: Mounted) -> PaneColumnsOverscrollReturn.WatchdogView? {
        let found = watchdogs(mounted)
        #expect(found.count == 1,
                "\(found.count) watchdogs mounted in this pane, expected exactly 1 — the swap below would leave the gate on the app-wide lock, which the machine's own trackpad feeds")
        return found.count == 1 ? found.first : nil
    }

    /// Mounts the pane at `paneWidth` over a `depth`-deep tree, with `(openTo ?? depth) + 1`
    /// columns open, after the drill's own auto-scroll has settled.
    ///
    /// - Parameter openTo: how far down to open, when that must be shallower than the tree is
    ///   deep — a test that drills further has to leave itself somewhere to drill to.
    private func mount(paneWidth: CGFloat, depth: Int, openTo: Int? = nil,
                       holdChecks: Int? = nil) async throws -> Mounted {
        let opened = openTo ?? depth
        let box = Box()
        let defaults = ScratchDefaults("column-preview-reveal")
        let tree = Self.tree(depth: depth)
        let index = PaneChildrenIndex(tree: tree, treeRoot: Self.root)
        let host = NSHostingView(rootView: Harness(box: box, tree: tree, index: index,
                                                   defaults: defaults, holdChecks: holdChecks))
        host.frame = NSRect(x: 0, y: 0, width: paneWidth, height: 520)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()

        box.browsePath = Self.browsePath(depth: opened)
        // Long enough for the columns to exist at all; the drill's own auto-scroll is then waited
        // out by `settle` below, not by this.
        await pump(window, seconds: 0.3)

        let stack = try #require(
            scrollViews(window.contentView!).first { !($0.documentView is NSTableView) },
            "no stack scroll view")
        let mounted = Mounted(window: window, box: box, stack: stack, defaults: defaults,
                              depth: opened)
        // The drill scrolls the stack too. Letting it finish before the preview opens keeps the
        // two from being read as one movement — and keeps a late-landing drill from being mistaken
        // for the reveal under test.
        await wait(window, upTo: 25) { self.columnFrames(mounted).count == opened + 1 }
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

    /// The easing the APP gets — the one value in this file no other test here can see.
    ///
    /// Making the animation injectable put the shipped behaviour behind a knob, and every other
    /// test in this suite turns that knob off. So a default that drifted to `nil` would delete the
    /// reveal's animation for real users — the stack would jump to the deepest column instead of
    /// sliding to it — while every case below stayed green, because none of them ever reads the
    /// default. Verified by mutation: setting the default to `nil` fails this test and only this
    /// test.
    @Test func testTheShippedRevealAnimationIsTheEasedOne() {
        #expect(EnvironmentValues().paneColumnRevealAnimation == .easeOut(duration: 0.18),
                "the reveal's shipped animation changed — the app now scrolls differently than the 0.18s ease this suite's harness deliberately opts out of")
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
        #expect(await maxOriginDrift(mounted, from: 0) == 0,
                "a preview-width commit scrolled a pane whose preview is hidden")

        // The positive control. Absence proves nothing unless the same fixture can be shown to
        // move at all: open this pane's own preview and the reveal must fire. Without this, a
        // pane that had quietly stopped revealing for any reason would satisfy the assertion
        // above forever.
        #expect(await openPreview(mounted, viewportWas: clip.bounds.width),
                "no preview appeared — the pane's own reveal path is dead, so the absence above proves nothing")
        #expect(clip.bounds.origin.x > 0,
                "this pane's own preview did not reveal its deepest column — the absence above is vacuous")
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
        #expect(await maxOriginDrift(mounted, from: 0) == 0,
                "closing the preview yanked a scrolled-back stack away from x 0")

        // The positive control, as in the preview-width test above: re-open the preview and the
        // RISING edge must still reveal. Absence and presence are driven by the same handler
        // here, so a handler that had stopped firing altogether would pass the assertion above
        // for entirely the wrong reason.
        #expect(await openPreview(mounted, viewportWas: clip.bounds.width),
                "the preview did not re-open — the absence above proves nothing")
        #expect(clip.bounds.origin.x > 0,
                "the rising edge stopped revealing — the falling-edge absence above is vacuous")
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

    /// NARROWING the columns shrinks every stack's content, which can only reduce occlusion — so
    /// there is nothing for a reveal to correct, and firing anyway drags a pane the user scrolled
    /// back somewhere they did not ask to be. Same asymmetry as the preview's falling edge, from
    /// the other divider, in a pane that never touched the drag.
    @Test func testNarrowingTheColumnsLeavesAScrolledBackStackWhereItWas() async throws {
        let mounted = try await mount(paneWidth: 690, depth: 4)
        defer { _ = mounted.window }
        let clip = mounted.stack.contentView

        let contentBefore = mounted.stack.documentView?.frame.width ?? 0
        #expect(contentBefore > clip.bounds.width,
                "fixture does not overflow its viewport (content \(contentBefore)pt in \(clip.bounds.width)pt) — a wrong reveal would be invisible")
        #expect(clip.bounds.origin.x > 0, "the drill never revealed, so the scroll-back proves nothing")
        await scrollBack(mounted, toX: 0)
        try #require(clip.bounds.origin.x == 0, "fixture failed to scroll the stack back")

        // The other pane's column divider commits NARROWER: 210 → 180.
        mounted.defaults.set(180.0, forKey: PaneViewMode.columnWidthDefaultsKey)
        await wait(mounted.window, upTo: 25) {
            (mounted.stack.documentView?.frame.width ?? 0) < contentBefore
        }
        let content = mounted.stack.documentView?.frame.width ?? 0
        #expect(content < contentBefore,
                "the narrower width never reached the layout (content \(content)pt, was \(contentBefore)pt) — nothing below measures a narrowing")
        // The shrunken stack must STILL overflow, or origin 0 is the only legal origin and the
        // absence below holds however wrongly the driver behaves.
        #expect(content > clip.bounds.width,
                "the narrowed stack fits its viewport (content \(content)pt in \(clip.bounds.width)pt) — a wrong reveal would be invisible, so this is vacuous")

        #expect(await maxOriginDrift(mounted, from: 0) == 0,
                "narrowing the columns scrolled a stack the user had deliberately scrolled back")
    }

    /// The trade the column-width driver's un-gated reach deliberately accepts, pinned so it stays
    /// a decision rather than a surprise: WIDENING the columns really does pull every pane —
    /// including a preview-less one whose user had scrolled back — to its deepest column, because
    /// the shared width genuinely grew that pane's content past its own edge.
    ///
    /// The counterpart of the narrowing test above: together they say the driver fires on exactly
    /// one edge, and nothing here would notice if it were gated on `showsPreview` by mistake.
    @Test func testWideningTheColumnsPullsAScrolledBackPreviewlessPaneToItsDeepestColumn() async throws {
        let mounted = try await mount(paneWidth: 690, depth: 3)
        defer { _ = mounted.window }
        let clip = mounted.stack.contentView

        #expect(clip.bounds.width > 690 - PaneViewMode.minimumPreviewColumnWidth,
                "a preview took room from this pane — the premise of a preview-less pane is gone")
        let contentBefore = mounted.stack.documentView?.frame.width ?? 0
        await scrollBack(mounted, toX: 0)
        try #require(clip.bounds.origin.x == 0, "fixture failed to scroll the stack back")

        mounted.defaults.set(260.0, forKey: PaneViewMode.columnWidthDefaultsKey)
        await wait(mounted.window, upTo: 25) {
            (mounted.stack.documentView?.frame.width ?? 0) > contentBefore
        }
        await wait(mounted.window, upTo: 25) { clip.bounds.origin.x > 0 }
        await settle(mounted)

        let content = mounted.stack.documentView?.frame.width ?? 0
        #expect(content > contentBefore,
                "the wider width never reached the layout (content \(content)pt) — nothing below measures a widening")
        #expect(content > clip.bounds.width,
                "the widened stack does not overflow its viewport — the reveal is unobservable here")
        let deepest = try #require(columnFrames(mounted).last, "no deepest column")
        let visible = visibleSpan(mounted)
        #expect(deepest.maxX <= visible.upperBound + 1,
                "widening the columns left the deepest column off screen in a preview-less pane: column \(deepest.minX)…\(deepest.maxX), visible \(visible.lowerBound)…\(visible.upperBound)")
    }

    /// NARROWING the preview hands the stack's viewport points back, which can only un-hide the
    /// deepest column — the same edge argument the `showsPreview` falling edge already makes, and
    /// the preview-width driver was missing it.
    @Test func testNarrowingThePreviewLeavesAScrolledBackStackWhereItWas() async throws {
        let mounted = try await mount(paneWidth: 690, depth: 3)
        defer { _ = mounted.window }
        let clip = mounted.stack.contentView

        let full = clip.bounds.width
        #expect(await openPreview(mounted, viewportWas: full), "no preview appeared")
        let narrow = clip.bounds.width
        try #require(narrow < full, "the preview never narrowed the viewport")

        await scrollBack(mounted, toX: 0)
        try #require(clip.bounds.origin.x == 0, "fixture failed to scroll the stack back")

        // The preview divider commits NARROWER: 420 → 360, giving the stack 60pt back.
        mounted.defaults.set(360.0, forKey: PaneViewMode.previewColumnWidthDefaultsKey)
        await wait(mounted.window, upTo: 25) { clip.bounds.width > narrow }
        #expect(clip.bounds.width > narrow,
                "the narrower preview never reached the layout (viewport \(clip.bounds.width)pt, was \(narrow)pt) — nothing below measures it")
        let content = mounted.stack.documentView?.frame.width ?? 0
        #expect(content > clip.bounds.width,
                "the stack fits its grown viewport (content \(content)pt in \(clip.bounds.width)pt) — a wrong reveal would be invisible, so this is vacuous")

        #expect(await maxOriginDrift(mounted, from: 0) == 0,
                "narrowing the preview scrolled a stack the user had deliberately scrolled back")
    }

    /// The reveal's 0.25s retry must speak for the stack as it is when the retry RUNS.
    ///
    /// Resolving the target once at fire time let a retry scroll to a column that had stopped
    /// being the deepest one: drill a→b at t=0 (attempts at t=0 and t=0.25), drill b→c at t=0.10
    /// (t=0.10 and t=0.35), and the t=0.25 retry aimed at b. b is still a real, non-last column,
    /// so that is no no-op — the stack visibly jerked BACKWARDS a column's width until t=0.35
    /// corrected it.
    ///
    /// Measured as MONOTONICITY, because that is what the defect breaks and what a final-position
    /// assertion cannot see: both drills move the stack forward, so a correct run never retreats,
    /// and the stale retry is the only thing that can make it.
    @Test func testALateRetryFollowsTheStackAsItIsWhenItRuns() async throws {
        let mounted = try await mount(paneWidth: 690, depth: 4, openTo: 2)
        defer { _ = mounted.window }
        let clip = mounted.stack.contentView
        // Three 210pt columns fit a 690pt pane, so nothing has revealed yet — every point of
        // movement below belongs to one of the two drills.
        try #require(clip.bounds.origin.x == 0, "the fixture did not start at the leading edge")

        // The gap is not a race: the second drill is a main-queue continuation with an earlier
        // deadline than the first reveal's retry, so it drains first however loaded the machine.
        mounted.box.browsePath = Self.browsePath(depth: 3)
        try? await Task.sleep(nanoseconds: 100_000_000)
        mounted.box.browsePath = Self.browsePath(depth: 4)

        // Queued, not timed — same reason as `maxOriginDrift`. Past both retries and their
        // animations.
        let marker = Marker()
        DispatchQueue.main.asyncAfter(deadline: .now() + PaneColumnsView.revealRetryDelay + 0.6) {
            MainActor.assumeIsolated { marker.fired = true }
        }
        var peak = clip.bounds.origin.x
        var worstRetreat: CGFloat = 0
        _ = await wait(mounted.window, upTo: 30) {
            let x = clip.bounds.origin.x
            peak = max(peak, x)
            worstRetreat = max(worstRetreat, peak - x)
            return marker.fired
        }
        await settle(mounted)

        #expect(worstRetreat <= 2,
                "the stack walked \(worstRetreat)pt backwards mid-drill — a retry scrolled to a stack that no longer existed")

        // The positive control: the drills really did travel, so the monotonicity above was not
        // measured on a stack that never moved.
        let frames = columnFrames(mounted)
        #expect(frames.count == 5, "the fixture opened \(frames.count) columns, expected 5")
        let content = mounted.stack.documentView?.frame.width ?? 0
        #expect(content > clip.bounds.width,
                "the drilled stack does not overflow its viewport — nothing here could have retreated")
        let deepest = try #require(frames.last, "no deepest column")
        let visible = visibleSpan(mounted)
        #expect(deepest.maxX <= visible.upperBound + 1,
                "the drill never revealed its deepest column: column \(deepest.minX)…\(deepest.maxX), visible \(visible.lowerBound)…\(visible.upperBound)")
    }

    /// A reveal must survive the user's own in-flight vertical momentum in the SAME pane, instead
    /// of being permanently defeated by it.
    ///
    /// `enforceHold` reverts ANY horizontal movement of the stack — the reveal's own programmatic
    /// scroll included — while a vertical-dominant gesture in that pane is inside the axis lock's
    /// `staleness` window. A trackpad or Magic Mouse momentum tail routinely outlasts
    /// `revealRetryDelay`, so BOTH of the reveal's attempts land inside the hold and both are
    /// reverted. The lock then decays and no further driver fires — not `browsePath` (it already
    /// moved), not `showsPreview`, not either stored width, not the quiescence return (the reverted
    /// origin is perfectly legal). The freshly opened deepest column stays behind the pane's edge
    /// for good.
    ///
    /// The hold is NOT the bug and is asserted here as well: while the gesture is delivering, the
    /// stack must hold still — that is the axis lock's whole job, and the sideways wiggle it fixed
    /// would be back the moment a reveal were allowed to win the fight. What must change is that
    /// the reveal WAITS the gesture out rather than losing to it.
    ///
    /// Bounded by a queued marker rather than the wall clock, for the reason `maxOriginDrift`
    /// gives: the marker is queued after the drill's own layout change has been observed, so it
    /// drains strictly after everything that drill scheduled, however loaded the machine.
    @Test func testAnInFlightVerticalGestureDefersARevealInsteadOfDefeatingIt() async throws {
        let mounted = try await mount(paneWidth: 690, depth: 4, openTo: 2)
        defer { _ = mounted.window }
        let clip = mounted.stack.contentView
        // Three 210pt columns fit a 690pt pane, so nothing has revealed yet and every point of
        // movement below belongs to the drill this test makes.
        try #require(clip.bounds.origin.x == 0, "the fixture did not start at the leading edge")

        // Take this pane's watchdog off the app-wide lock (which a real trackpad feeds) and onto a
        // tracker this test drives by hand.
        let watchdog = try #require(soleWatchdog(mounted))
        let lock = WheelGestureTracker()
        watchdog.axisLock = lock

        // A vertical drag delivering right now, INSIDE this stack. Dated ahead of the wall clock —
        // `PaneColumnsAxisLockTests`' shape — so the hold cannot lapse on its own while the test
        // runs; the release below is then the only thing that can end it.
        let inStack = clip.convert(NSPoint(x: 20, y: 20), to: nil)
        let ahead = CFAbsoluteTimeGetCurrent() + 3600
        lock.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0,
                    window: mounted.window, locationInWindow: inStack, at: ahead)
        lock.ingest(phase: .changed, momentumPhase: [], dx: 1, dy: -12,
                    window: mounted.window, locationInWindow: inStack, at: ahead + 0.01)
        try #require(lock.shouldHoldHorizontalDrift(for: clip),
                     "the fixture's gesture does not hold this stack — nothing below is under a hold")

        // Drill one deeper: four 210pt columns are 840pt of content in a 690pt pane, so the new
        // deepest column is off the trailing edge and only a reveal can bring it back.
        mounted.box.browsePath = Self.browsePath(depth: 3)
        try #require(await wait(mounted.window, upTo: 25) { self.columnFrames(mounted).count == 4 },
                     "the drill never opened a fourth column")

        // Both reveal attempts happen inside this window and the hold is still engaged throughout.
        let marker = Marker()
        DispatchQueue.main.asyncAfter(deadline: .now() + PaneColumnsView.revealRetryDelay + 0.3) {
            MainActor.assumeIsolated { marker.fired = true }
        }
        _ = await wait(mounted.window, upTo: 30) { marker.fired }
        #expect(clip.bounds.origin.x == 0,
                "the stack moved sideways while a vertical gesture was delivering in its own pane — the axis lock's hold is gone")
        try #require(lock.shouldHoldHorizontalDrift(for: clip),
                     "the hold lapsed early — the reveal was never actually fought")

        // Nothing is vacuous: four columns, and they overflow the viewport.
        let frames = columnFrames(mounted)
        #expect(frames.count == 4, "the fixture opened \(frames.count) columns, expected 4")
        let content = mounted.stack.documentView?.frame.width ?? 0
        #expect(content > clip.bounds.width,
                "the drilled stack does not overflow its \(clip.bounds.width)pt viewport (content \(content)pt) — the reveal is unobservable here")

        // The finger leaves and the momentum runs out: `momentumPhase.ended` is exactly how the
        // tracker releases a real flick.
        lock.ingest(phase: [], momentumPhase: .ended, dx: 0, dy: 0,
                    window: mounted.window, locationInWindow: inStack, at: ahead + 0.5)
        try #require(!lock.shouldHoldHorizontalDrift(for: clip),
                     "the fixture failed to release the hold")

        let revealed = await wait(mounted.window, upTo: 25) {
            guard let deepest = self.columnFrames(mounted).last else { return false }
            return deepest.maxX <= self.visibleSpan(mounted).upperBound + 1
        }
        let deepest = try #require(columnFrames(mounted).last, "no deepest column")
        let visible = visibleSpan(mounted)
        #expect(revealed,
                "the reveal was defeated by the pane's own in-flight gesture and never re-issued: column \(deepest.minX)…\(deepest.maxX), visible \(visible.lowerBound)…\(visible.upperBound)")
        #expect(deepest.minX >= visible.lowerBound - 1,
                "the re-issued reveal cut the deepest column off on its leading edge: column \(deepest.minX)…\(deepest.maxX), visible \(visible.lowerBound)…\(visible.upperBound)")
    }

    /// Puts `mounted`'s stack under a hold this test owns, and returns the tracker holding it.
    ///
    /// Dated an hour ahead — `PaneColumnsAxisLockTests`' shape — so the hold cannot lapse on its
    /// own while the test runs, whatever the machine is doing. Releasing it is then the only thing
    /// that can end it, which is what makes "the reveal came back on release" mean something.
    private func holdStack(_ mounted: Mounted) throws -> (lock: WheelGestureTracker, at: TimeInterval) {
        let clip = mounted.stack.contentView
        let watchdog = try #require(soleWatchdog(mounted))
        let lock = WheelGestureTracker()
        watchdog.axisLock = lock
        let inStack = clip.convert(NSPoint(x: 20, y: 20), to: nil)
        let ahead = CFAbsoluteTimeGetCurrent() + 3600
        lock.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0,
                    window: mounted.window, locationInWindow: inStack, at: ahead)
        lock.ingest(phase: .changed, momentumPhase: [], dx: 1, dy: -12,
                    window: mounted.window, locationInWindow: inStack, at: ahead + 0.01)
        try #require(lock.shouldHoldHorizontalDrift(for: clip),
                     "the fixture's gesture does not hold this stack — nothing measured under it is under a hold")
        return (lock, ahead)
    }

    /// How long a person can plausibly keep a wheel gesture delivering without a `staleness`-sized
    /// gap: a flick's momentum tail, then more scrolling, then more. Five seconds of it is
    /// ordinary — a long folder read at a steady pace — and is the number the deferral's budget
    /// used to be set to (50 checks × 0.1s), which is what made an ordinary scroll cost a reveal.
    ///
    /// Written as a duration rather than as `PaneColumnsView.revealHoldChecks`, deliberately. This
    /// is the USER-FACING claim — "keep scrolling for five seconds and your reveal still arrives" —
    /// and reading the production constant here would make the test agree with whatever that
    /// constant becomes, including 50 again.
    private static let plausibleContinuousGesture: TimeInterval = 5.0

    /// A reveal deferred by a hold must outlive an ORDINARY continuous gesture, not be spent by it.
    ///
    /// The deferral re-checks the hold every `WheelGestureTracker.staleness` and used to be capped
    /// at a counted budget of 50, i.e. five seconds, after which the attempt returned — no scroll,
    /// no log, no further driver. That is byte-for-byte the outcome the deferral was added to fix:
    /// the freshly opened deepest column stays behind the pane's edge for good, with nothing in
    /// `~/sync-cloud.log` to say why.
    ///
    /// The budget's stated justification was a lock that never releases, and that is unreachable
    /// under this tracker: `shouldHoldHorizontalDrift(at:)` ands in `now - lastEventAt <
    /// staleness`, unconditionally, so the hold lapses 100ms after the last wheel event whatever
    /// the phase machinery does. What the cap actually caught was a person who kept scrolling —
    /// and it answered them by dropping the reveal.
    ///
    /// So this holds the stack for longer than the old cap allowed and then releases it. The
    /// release is the only event in the window: `browsePath` has already moved, no preview opens,
    /// neither stored width changes, and the origin never leaves 0 so the quiescence return has
    /// nothing to clamp. If the chain gave up while the gesture was still delivering, nothing
    /// brings the column back.
    @Test func testAHeldRevealOutlivesAnOrdinaryFiveSecondGesture() async throws {
        let mounted = try await mount(paneWidth: 690, depth: 4, openTo: 2)
        defer { _ = mounted.window }
        let clip = mounted.stack.contentView
        // Three 210pt columns fit a 690pt pane, so nothing has revealed yet and every point of
        // movement below belongs to the drill this test makes.
        try #require(clip.bounds.origin.x == 0, "the fixture did not start at the leading edge")

        let held = try holdStack(mounted)

        // Drill one deeper: four 210pt columns are 840pt of content in a 690pt pane, so the new
        // deepest column is off the trailing edge and only a reveal can bring it back.
        mounted.box.browsePath = Self.browsePath(depth: 3)
        try #require(await wait(mounted.window, upTo: 25) { self.columnFrames(mounted).count == 4 },
                     "the drill never opened a fourth column")

        // The gesture keeps delivering right through the old cap, and past both reveal attempts'
        // own chains (the retry's starts `revealRetryDelay` later, so it expires last).
        await pump(mounted.window,
                   seconds: Self.plausibleContinuousGesture + PaneColumnsView.revealRetryDelay + 1.0)

        // The hold itself is NOT what changed and is asserted here too: while the gesture delivers,
        // the stack holds still. That is the axis lock's whole job, and the sideways wiggle it
        // fixed would be back the moment a deferred reveal were allowed to win the fight instead of
        // waiting the gesture out.
        #expect(clip.bounds.origin.x == 0,
                "the stack moved sideways while a vertical gesture was delivering in its own pane — the axis lock's hold is gone")
        try #require(held.lock.shouldHoldHorizontalDrift(for: clip),
                     "the hold lapsed during the wait — the reveal was never actually made to wait")

        // Nothing is vacuous: four columns, and they overflow the viewport.
        let frames = columnFrames(mounted)
        #expect(frames.count == 4, "the fixture opened \(frames.count) columns, expected 4")
        let content = mounted.stack.documentView?.frame.width ?? 0
        #expect(content > clip.bounds.width,
                "the drilled stack does not overflow its \(clip.bounds.width)pt viewport (content \(content)pt) — the reveal is unobservable here")

        // The finger leaves and the momentum runs out.
        held.lock.ingest(phase: [], momentumPhase: .ended, dx: 0, dy: 0,
                         window: mounted.window, locationInWindow: .zero, at: held.at + 0.5)
        try #require(!held.lock.shouldHoldHorizontalDrift(for: clip),
                     "the fixture failed to release the hold")

        let revealed = await wait(mounted.window, upTo: 25) {
            guard let deepest = self.columnFrames(mounted).last else { return false }
            return deepest.maxX <= self.visibleSpan(mounted).upperBound + 1
        }
        let deepest = try #require(columnFrames(mounted).last, "no deepest column")
        let visible = visibleSpan(mounted)
        #expect(revealed,
                "a \(Self.plausibleContinuousGesture)s gesture spent the reveal's deferral budget and the column never came back: column \(deepest.minX)…\(deepest.maxX), visible \(visible.lowerBound)…\(visible.upperBound)")
    }

    /// Every horizontal origin the clip is ever SET to, in order — including one put back a runloop
    /// turn later.
    ///
    /// `setBoundsOrigin` posts `boundsDidChangeNotification` synchronously, so this sees a movement
    /// the watchdog reverts; polling the origin from a pumping loop does not, because the revert is
    /// a queued hop that drains inside the loop's own `await`. That distinction is the whole
    /// measurement here: at exhaustion the reveal is EXPECTED to be reverted, and "was it issued at
    /// all" is exactly what separates the fix from the bug.
    @MainActor private final class OriginTrace {
        /// Boxed and captured strongly by the observer, so what the notification appends to does
        /// not depend on the trace object still being referenced by the test.
        @MainActor private final class Log { var origins: [CGFloat] = [] }
        private let log = Log()
        private var observer: NSObjectProtocol?
        init(_ clip: NSClipView) {
            clip.postsBoundsChangedNotifications = true
            let log = self.log
            log.origins = [clip.bounds.origin.x]
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { _ in
                MainActor.assumeIsolated { log.origins.append(clip.bounds.origin.x) }
            }
        }
        /// Explicit rather than a `deinit` — a nonisolated `deinit` cannot touch the stored,
        /// non-Sendable observer token. Called from the test, which is where the trace's life ends.
        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
        var origins: [CGFloat] { log.origins }
        var peak: CGFloat { log.origins.map(abs).max() ?? 0 }
    }

    /// Whether any log line recorded since `since` contains `needle`.
    private func loggedLine(containing needle: String, since: Date) -> Bool {
        Logger.shared.entries.contains { $0.timestamp >= since && $0.message.contains(needle) }
    }

    /// The end of the budget must be a logged best-effort scroll, not a silent drop.
    ///
    /// This is the branch `revealHoldChecks` was shipped with and nothing exercised: `guard
    /// checksLeft > 0 else { return }`. Reaching it produced precisely the user-visible outcome the
    /// deferral was added to remove — the freshly opened deepest column stranded behind the pane's
    /// edge, no scroll, and NOTHING in `~/sync-cloud.log` to say a reveal had ever been pending.
    ///
    /// Both halves of the fix are pinned, and the third assertion is the one that keeps the fix
    /// honest:
    ///
    /// 1. the exhaustion is logged, so a hold that really does last that long is diagnosable;
    /// 2. the scroll is ISSUED anyway — a scroll `enforceHold` reverts leaves the stack exactly
    ///    where returning would have, and if the hold has lapsed by then it lands, so trying is
    ///    strictly better than giving up;
    /// 3. and the hold still WINS. The stack must come to rest where the axis lock put it. Making
    ///    the reveal try harder must not turn into the reveal beating the lock — that is the
    ///    sideways-wiggle regression, and it would pass assertions 1 and 2 on its own.
    ///
    /// The budget is injected at 0 so the very first attempt is the exhausted one; at the shipped
    /// sixty seconds this branch is unreachable in a suite, which is why it went untested.
    @Test func testAnExhaustedHoldBudgetScrollsAnywayAndSaysSo() async throws {
        let mounted = try await mount(paneWidth: 690, depth: 4, openTo: 2, holdChecks: 0)
        defer { _ = mounted.window }
        let clip = mounted.stack.contentView
        try #require(clip.bounds.origin.x == 0, "the fixture did not start at the leading edge")

        let held = try holdStack(mounted)
        let trace = OriginTrace(clip)
        defer { trace.stop() }
        let since = Date()

        mounted.box.browsePath = Self.browsePath(depth: 3)
        try #require(await wait(mounted.window, upTo: 25) { self.columnFrames(mounted).count == 4 },
                     "the drill never opened a fourth column")

        let marker = Marker()
        DispatchQueue.main.asyncAfter(deadline: .now() + PaneColumnsView.revealRetryDelay + 0.5) {
            MainActor.assumeIsolated { marker.fired = true }
        }
        _ = await wait(mounted.window, upTo: 30) { marker.fired }

        // Nothing is vacuous: four columns overflowing the viewport, so there is a real reveal to
        // issue and a real distance for it to move.
        let frames = columnFrames(mounted)
        #expect(frames.count == 4, "the fixture opened \(frames.count) columns, expected 4")
        let content = mounted.stack.documentView?.frame.width ?? 0
        #expect(content > clip.bounds.width,
                "the drilled stack does not overflow its \(clip.bounds.width)pt viewport (content \(content)pt) — there is nothing for a reveal to move")

        // 1. The exhaustion is on the record.
        #expect(await wait(mounted.window, upTo: 10) {
                    self.loggedLine(containing: "reveal waited out", since: since)
                },
                "the reveal ran out of hold checks and logged nothing — a stuck hold is invisible in ~/sync-cloud.log, which is how this defect reads as 'the column just hides'")

        // 2. It scrolled anyway.
        #expect(trace.peak > 0,
                "the exhausted attempt never issued its scroll (the clip was only ever set to \(trace.origins)) — a reveal dropped in silence is the bug the deferral exists to fix")

        // 3. And the hold still won.
        try #require(held.lock.shouldHoldHorizontalDrift(for: clip),
                     "the hold lapsed during the window — assertion 3 below would be measuring nothing")
        #expect(await wait(mounted.window, upTo: 10) { clip.bounds.origin.x == 0 },
                "the stack came to rest at \(clip.bounds.origin.x) while a vertical gesture was still delivering in its own pane — the reveal now beats the axis lock, which is the sideways-wiggle regression")
    }

    /// The budget bounded from ABOVE as well as below, in the terms its own doc argues in.
    ///
    /// The suite already bounds it from below twice over — `testAHeldRevealOutlivesAnOrdinaryFive
    /// SecondGesture` fails under anything near the old 50, and the deferral test needs enough
    /// checks to span its held window. Nothing bounded it from above, and the number is the only
    /// thing deciding how long one deferred chain retains a torn-down pane's captures and its
    /// `ScrollViewProxy`. Stated as the duration the doc reasons about rather than as the count, so
    /// a change to `WheelGestureTracker.staleness` is caught here too.
    @Test func testTheHoldBudgetIsLongerThanAnyGestureAndShorterThanForever() {
        let seconds = Double(PaneColumnsView.revealHoldChecks) * WheelGestureTracker.staleness
        #expect(seconds >= 30,
                "the hold budget is \(seconds)s — an ordinary continuous scroll reaches that, and reaching it costs the reveal its wait")
        #expect(seconds <= 120,
                "the hold budget is \(seconds)s — that is how long one deferred chain can retain a pane that is already gone")
    }

    /// The one case the preview's un-driven falling edge really does leave to someone else: an
    /// origin the GROWN viewport made illegal. Nothing pinned it, which made the trade a promise
    /// rather than a behavior — the falling-edge reveal was removed *because* something else
    /// covers this, so the two have to be pinned together or the removal is a stranding.
    ///
    /// **Who actually corrects it is not what the driver's comment used to claim.** Measured by
    /// mutation: delete `legalOrigin`'s clamp outright and this test still passes. A real pane's
    /// clip re-constrains itself the moment its frame grows, so the correction is AppKit's and it
    /// is immediate — there is no 0.14s-quiescence bounce on this path. The watchdog is the
    /// backstop for a clip that does NOT self-correct, and its own coverage of this exact shape
    /// is pinned where it can be killed, in `PaneColumnsOverscrollReturnCycleTests`.
    ///
    /// What this test therefore pins is the user-visible promise: after a close, the stack rests
    /// somewhere legal rather than stranded past the end.
    @Test func testClosingThePreviewLeavesTheStackAtALegalOrigin() async throws {
        let mounted = try await mount(paneWidth: 690, depth: 3)
        defer { _ = mounted.window }
        let clip = mounted.stack.contentView

        let full = clip.bounds.width
        #expect(await openPreview(mounted, viewportWas: full), "no preview appeared")
        let narrow = clip.bounds.width
        try #require(narrow < full, "the preview never narrowed the viewport")

        // The reveal parks the stack at its far end, which is exactly the resting position that
        // a growing viewport makes illegal — no synthetic scroll needed.
        let content = mounted.stack.documentView?.frame.width ?? 0
        let farEnd = content - narrow
        try #require(abs(clip.bounds.origin.x - farEnd) <= 1,
                     "the stack is not resting at its far end (\(clip.bounds.origin.x), far end \(farEnd)) — this test's premise is gone")

        mounted.box.selection = []
        await wait(mounted.window, upTo: 25) { clip.bounds.width > narrow }
        let grown = clip.bounds.width
        #expect(grown > narrow, "the preview never closed — nothing below measures the falling edge")
        let legalMax = content - grown
        let tolerance = PaneColumnsOverscrollReturn.WatchdogView.tolerance
        try #require(farEnd > legalMax + tolerance,
                     "the grown viewport did not strand the origin (\(farEnd) vs legal max \(legalMax)) — there is nothing to clamp")

        let landed = await wait(mounted.window, upTo: 25) {
            abs(clip.bounds.origin.x - legalMax) <= tolerance
        }
        #expect(landed,
                "an origin the grown viewport made illegal was left stranded at \(clip.bounds.origin.x), legal max \(legalMax)")
    }
}
