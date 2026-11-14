import Testing
import AppKit
import Design
import EventsTestSupport
import SwiftUI
import Sync
@testable import FileExplorer

/// The column stack's reveal: what brings the deepest column back on screen, and what must leave a
/// stack the user scrolled back where they put it. A drill, a narrowing pane and a column divider
/// committed wider can each hide the deepest column; the reveal must follow each, on exactly the
/// edge that can occlude. The tests measure where the deepest column lands in the clip's visible span.
///
/// `.serialized` matters: some tests assert a stack stays put while others commit a new
/// `columnWidthDefaultsKey`, which fires a reveal in every pane. `@AppStorage` delivers that change
/// by key name across stores, `.defaultAppStorage` notwithstanding, so in parallel a widening
/// test's commit would reveal an absence test's stack. In the app those cross-pane fires are correct.
@MainActor
@Suite(.serialized) struct ColumnPreviewRevealTests {

    final class Box: ObservableObject {
        @Published var browsePath = PaneBrowsePath()
        @Published var selection: Set<String> = []
    }

    static let root = "/root"
    private static let levels = ["a", "b", "c", "d"]

    /// A chain `depth` directories deep, branching 3 ways at each level, with five files in the
    /// leaves. Depth is a parameter because the column count that overflows the stack differs by
    /// pane: three overflow a comparison pane's leftover room but not a rail's.
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

    /// A file in the deepest column.
    private static func deepestFile(depth: Int) -> String {
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
                delegate: NoOpFileActionDelegate(), diffIndex: .empty, otherPaneName: "R",
                isSingleSource: false, density: .compact, isActivePane: true,
                placement: nil, onBarEdgeFlip: nil, onQuickLook: { _ in },
                onBackgroundDeselect: { _ in }
            )
            // The column width is `@AppStorage`, and a value left in the test process's standard
            // domain by another suite would decide this test's geometry.
            .defaultAppStorage(defaults)
            // Place the reveal outright instead of easing it. This window is offscreen and never
            // key, so when the machine throttles CoreAnimation an animation in it never advances and
            // the scroll never lands, faking the defect these tests catch (`docs/flaky-tests.md`,
            // "The machine decides the verdict — throttled CoreAnimation"). An ambient
            // `.transaction { $0.animation = nil }` loses to the explicit `withAnimation` in
            // `revealDeepestColumn`. Where the scroll lands is the same either way.
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

    /// Pumps until `condition` holds or the deadline passes, and returns whether it held, through the
    /// shared `LayoutPumpWait.pump`. See `pumpFloor` there for why a deadline alone doesn't bound a
    /// congested main actor.
    @discardableResult
    private func wait(_ window: NSWindow, upTo seconds: Double,
                      for condition: () -> Bool) async -> Bool {
        await LayoutPumpWait.pump(window, upTo: seconds, until: condition).held
    }

    /// Pumps until the stack's horizontal offset has held still for `quiet` seconds.
    ///
    /// **Never sufficient on its own.** Stillness can't tell "finished" from "not started", and the
    /// reveal is deferred a run-loop turn and retried after `revealRetryDelay`, which under
    /// contention can outlast the quiet window. Callers wait for the movement they expect first.
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

    /// A one-shot flag a queued block can set (a captured mutable local can't be), so the queue, not
    /// the wall clock, is what's observed.
    private final class Marker {
        var fired = false
    }

    /// How far the stack's origin ever strays from `origin` before a marker queued now drains: how
    /// an absence is bounded here. A reveal is one main-queue hop plus a `revealRetryDelay` retry,
    /// and a marker queued after the trigger's layout change has a later deadline than anything the
    /// trigger scheduled, so under load both slip together, unlike a wall-clock window. The whole
    /// interval is sampled, so a stack that moves and is put back still fails.
    private func maxOriginDrift(_ mounted: Mounted, from origin: CGFloat) async -> CGFloat {
        let marker = Marker()
        // Past the retry, plus margin, so a retry that fired has visibly moved the clip.
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

    /// The overscroll watchdogs mounted under this pane. The watchdog enforces the axis lock, so
    /// swapping its `axisLock` for a test-owned tracker is the only deterministic way to hold a
    /// mounted stack: `WheelGestureTracker.shared` is driven by the machine's own trackpad.
    private func watchdogs(_ mounted: Mounted) -> [PaneColumnsOverscrollReturn.WatchdogView] {
        var found: [PaneColumnsOverscrollReturn.WatchdogView] = []
        func walk(_ v: NSView) {
            if let w = v as? PaneColumnsOverscrollReturn.WatchdogView { found.append(w) }
            for sub in v.subviews { walk(sub) }
        }
        walk(mounted.window.contentView!)
        return found
    }

    /// The pane's one watchdog, or a failure naming how many were found. Swapping the wrong one of
    /// several would leave the gate on `WheelGestureTracker.shared`, and the test would measure
    /// whatever the person at the Mac is scrolling.
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
        // Long enough for the columns to exist; the drill's auto-scroll is waited out by `settle`.
        await pump(window, seconds: 0.3)

        let stack = try #require(
            PaneRowRevealTests.scrollViews(window.contentView!).first { !($0.documentView is NSTableView) },
            "no stack scroll view")
        let mounted = Mounted(window: window, box: box, stack: stack, defaults: defaults,
                              depth: opened)
        // Let the drill's own scroll finish, so a late drill isn't mistaken for the reveal under test.
        await wait(window, upTo: 25) { self.columnFrames(mounted).count == opened + 1 }
        await settle(mounted)
        return mounted
    }

    /// The columns' frames in the stack document's own coordinates, leading edge first.
    private func columnFrames(_ mounted: Mounted) -> [CGRect] {
        guard let document = mounted.stack.documentView else { return [] }
        return PaneRowRevealTests.scrollViews(mounted.window.contentView!)
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

    /// The easing the app gets. Every other test here turns the animation off, so a default that
    /// drifted to `nil` (the stack jumping instead of sliding) would pass them all; setting the
    /// default to `nil` must fail this test.
    @Test func testTheShippedRevealAnimationIsTheEasedOne() {
        #expect(EnvironmentValues().paneColumnRevealAnimation == .easeOut(duration: 0.18),
                "the reveal's shipped animation changed — the app now scrolls differently than the 0.18s ease this suite's harness deliberately opts out of")
    }

    /// Scrolls the stack back to a legal origin, as a user reading earlier columns does, and waits
    /// for it to rest there. Drains the reveal chain first (`quiesceReveals`): every caller scrolls
    /// back after a drill, and a reveal attempt still owed its scroll would land on top of this one.
    private func scrollBack(_ mounted: Mounted, toX x: CGFloat) async {
        await quiesceReveals(mounted)
        let clip = mounted.stack.contentView
        clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
        mounted.stack.reflectScrolledClipView(clip)
        await settle(mounted)
    }

    /// Waits out every attempt of any reveal chain scheduled before this call, issued and landed,
    /// so a scroll made after it is the last word on the stack's origin.
    ///
    /// `settle` can't: a reveal's two attempts (a deferred hop, then `revealRetryDelay`) resolve the
    /// same target, so the retry moves the stack zero points while its `proxy.scrollTo` is still
    /// owed a SwiftUI update, which under load can land after the scroll-back and undo it
    /// (`docs/flaky-tests.md`, "Fixed pumps and fixed sleeps"). So the bound is the queue, as in
    /// `maxOriginDrift`: `asyncAfter` blocks drain in deadline order, so when a marker queued now
    /// fires every attempt has run; the drain after it lets the last one land.
    ///
    /// **Holds only while nothing defers.** An attempt against a held stack re-parks itself for up
    /// to `revealHoldChecks` checks, queued after this marker, so a held stack is asserted against.
    ///
    /// Not tested: a deliberate scroll within `revealRetryDelay` of a drill being overridden
    /// (`revealDeepestColumn`), since staging it would race a 0.25s timer against load.
    /// `testALateRetryFollowsTheStackAsItIsWhenItRuns` and
    /// `testACancelledRevealsQueuedRetryScrollsNothing` cover the retry without racing it.
    private func quiesceReveals(_ mounted: Mounted) async {
        // The precondition the deadline argument rests on. `watchdogs`, not `soleWatchdog`, so a
        // pane that mounted two can't hide the held one.
        #expect(watchdogs(mounted).allSatisfy { !$0.isStackHeld },
                "this pane's stack is held, so a reveal chain can be parked past this marker — the wait below does not cover it")
        let marker = Marker()
        DispatchQueue.main.asyncAfter(deadline: .now() + PaneColumnsView.revealRetryDelay + 0.3) {
            MainActor.assumeIsolated { marker.fired = true }
        }
        // A wall-clock ceiling is tolerable here: it bounds one queued block, not a render chain.
        let fired = await wait(mounted.window, upTo: 60) { marker.fired }
        // Asserted, not discarded: an unread expiry would make this a vacuous pass.
        #expect(fired, "the reveal marker never drained in 60s — the scroll below is not the last word on the stack")
        await drain(mounted.window, turns: Self.applyTurns)
    }

    /// How many main-queue turns an issued `proxy.scrollTo` gets to reach the clip: measured at one,
    /// twelve because turns are cheap here and scale with load.
    private static let applyTurns = 12

    /// Runs `turns` real main-queue turns, laying the window out around each. Turns, not wall time:
    /// this drains work already queued, and a turn is one unit of that however slow the machine.
    private func drain(_ window: NSWindow, turns: Int) async {
        for _ in 0..<turns {
            window.layoutIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        window.layoutIfNeeded()
    }

    /// One column committed wider pushes the deepest past the edge, and the driver on the
    /// per-column widths, which nothing else fires, reveals it.
    @Test func testSizingOneColumnWiderKeepsTheDeepestColumnOnScreen() async throws {
        let mounted = try await mount(paneWidth: 690, depth: 2)
        defer { _ = mounted.window }

        let contentBefore = mounted.stack.documentView?.frame.width ?? 0
        let originBefore = mounted.stack.contentView.bounds.origin.x

        // The first column, not the deepest, sized from 210 to 300 on its own and committed.
        mounted.defaults.set(ColumnWidthOverrides(widths: [0: 300]).rawValue,
                             forKey: PaneViewMode.columnWidthOverridesDefaultsKey)
        await wait(mounted.window, upTo: 25) {
            (mounted.stack.documentView?.frame.width ?? 0) > contentBefore
        }
        await wait(mounted.window, upTo: 25) {
            mounted.stack.contentView.bounds.origin.x != originBefore
        }
        await settle(mounted)

        let content = mounted.stack.documentView?.frame.width ?? 0
        #expect(content > contentBefore, "the column's own width never reached the layout — nothing below measures it")
        #expect(content > mounted.stack.contentView.bounds.width, "the stack does not overflow — the reveal is unobservable")
        let (visible, report) = try deepestColumnIsVisible(mounted)
        #expect(visible, "sizing one column wider hid the deepest one: \(report)")
    }

    /// The stack keeps a gutter after its last column, outside its scroll view, so the viewport and
    /// the deepest column revealed into it end `columnStackTrailingGutter` short of the pane's edge,
    /// where the Compare splitter or the inspector's seam is drawn.
    @Test func testTheViewportEndsAGutterShortOfThePanesEdge() async throws {
        let mounted = try await mount(paneWidth: 690, depth: 2)
        defer { _ = mounted.window }
        let viewport = mounted.stack.contentView.bounds.width
        #expect(viewport == 690 - PaneViewMode.columnStackTrailingGutter,
                "the viewport is \(viewport), not the pane less the gutter")
        let deepest = try #require(columnFrames(mounted).last)
        #expect(deepest.maxX <= visibleSpan(mounted).upperBound + 1, "the deepest column is not whole in the viewport")
    }

    /// No column is drawn wider than its viewport. Widths are shared by every surface and go to
    /// 600pt, and a wider column would be revealed by its trailing edge, cutting off icons and names.
    @Test func testAColumnIsNeverDrawnWiderThanItsViewport() async throws {
        let mounted = try await mount(paneWidth: 520, depth: 2)
        defer { _ = mounted.window }
        mounted.defaults.set(ColumnWidthOverrides(widths: [1: 600]).rawValue,
                             forKey: PaneViewMode.columnWidthOverridesDefaultsKey)
        let viewport = mounted.stack.contentView.bounds.width
        await wait(mounted.window, upTo: 25) {
            self.columnFrames(mounted).dropFirst().first.map { $0.width > PaneViewMode.defaultColumnWidth + 1 } ?? false
        }
        await settle(mounted)
        let widths = columnFrames(mounted).map(\.width)
        #expect(widths.count == 3)
        #expect(widths.allSatisfy { $0 <= viewport + 0.5 },
                "a column is \(widths.max() ?? 0)pt in a \(viewport)pt viewport")
        #expect(widths.dropFirst().first.map { abs($0 - viewport) < 1 } == true,
                "the 600pt column was not drawn at the viewport's width: \(widths)")
    }

    /// Narrowing the columns can only reduce occlusion, so there is nothing to reveal; firing anyway
    /// would drag a scrolled-back stack somewhere the user didn't ask, in a pane that never dragged.
    @Test func testNarrowingTheColumnsLeavesAScrolledBackStackWhereItWas() async throws {
        let mounted = try await mount(paneWidth: 690, depth: 4)
        defer { _ = mounted.window }
        let clip = mounted.stack.contentView

        let contentBefore = mounted.stack.documentView?.frame.width ?? 0
        #expect(contentBefore > clip.bounds.width,
                "fixture does not overflow its viewport (content \(contentBefore)pt in \(clip.bounds.width)pt) — a wrong reveal would be invisible")
        // Waited for, not sampled: the drill's reveal is deferred and retried, so the stack can
        // still be at 0 when `mount` returns, and scrolling back to 0 would then be no scroll-back.
        await wait(mounted.window, upTo: 25) { clip.bounds.origin.x > 0 }
        #expect(clip.bounds.origin.x > 0, "the drill never revealed, so the scroll-back proves nothing")
        await scrollBack(mounted, toX: 0)
        try #require(clip.bounds.origin.x == 0, "fixture failed to scroll the stack back")

        // The other pane's column divider commits narrower: 210 → 180.
        mounted.defaults.set(180.0, forKey: PaneViewMode.columnWidthDefaultsKey)
        await wait(mounted.window, upTo: 25) {
            (mounted.stack.documentView?.frame.width ?? 0) < contentBefore
        }
        let content = mounted.stack.documentView?.frame.width ?? 0
        #expect(content < contentBefore,
                "the narrower width never reached the layout (content \(content)pt, was \(contentBefore)pt) — nothing below measures a narrowing")
        // The shrunken stack must still overflow, or 0 is the only legal origin and the absence
        // below holds however wrongly the driver behaves.
        #expect(content > clip.bounds.width,
                "the narrowed stack fits its viewport (content \(content)pt in \(clip.bounds.width)pt) — a wrong reveal would be invisible, so this is vacuous")

        #expect(await maxOriginDrift(mounted, from: 0) == 0,
                "narrowing the columns scrolled a stack the user had deliberately scrolled back")
    }

    /// A deliberate trade: widening the columns pulls every pane, even a scrolled-back one, to its
    /// deepest column, since the shared width grew its content past its edge.
    @Test func testWideningTheColumnsPullsAScrolledBackPaneToItsDeepestColumn() async throws {
        let mounted = try await mount(paneWidth: 690, depth: 3)
        defer { _ = mounted.window }
        let clip = mounted.stack.contentView

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
        let (visible, report) = try deepestColumnIsVisible(mounted)
        #expect(visible, "widening the columns left the deepest column off screen in a scrolled-back pane: \(report)")
    }

    /// The reveal's 0.25s retry must resolve its target when it runs, not when it was scheduled.
    /// Drill a→b, then b→c 0.10s later: a stale first retry would aim at b and jerk the stack back a
    /// column. Measured as monotonicity, which a final-position check can't see: both drills move
    /// forward, so only a stale retry retreats.
    @Test func testALateRetryFollowsTheStackAsItIsWhenItRuns() async throws {
        let mounted = try await mount(paneWidth: 690, depth: 4, openTo: 2)
        defer { _ = mounted.window }
        let clip = mounted.stack.contentView
        // Three 210pt columns fit a 690pt pane, so nothing has revealed yet; all movement below
        // belongs to the two drills.
        try #require(clip.bounds.origin.x == 0, "the fixture did not start at the leading edge")

        // Not a race: the second drill is a main-queue continuation with an earlier deadline than
        // the first reveal's retry, so it drains first however loaded the machine.
        mounted.box.browsePath = Self.browsePath(depth: 3)
        try? await Task.sleep(nanoseconds: 100_000_000)
        mounted.box.browsePath = Self.browsePath(depth: 4)

        // Queued, not timed, as in `maxOriginDrift`. Past both retries.
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

        // Positive control: the drills really travelled.
        let frames = columnFrames(mounted)
        #expect(frames.count == 5, "the fixture opened \(frames.count) columns, expected 5")
        let content = mounted.stack.documentView?.frame.width ?? 0
        #expect(content > clip.bounds.width,
                "the drilled stack does not overflow its viewport — nothing here could have retreated")
        let (visible, report) = try deepestColumnIsVisible(mounted)
        #expect(visible, "the drill never revealed its deepest column: \(report)")
    }

    /// A reveal must wait out the user's in-flight vertical momentum in the same pane, not be
    /// defeated by it. `enforceHold` reverts any horizontal movement, the reveal's own included,
    /// while a vertical gesture is inside the axis lock's `staleness` window, and a momentum tail
    /// can outlast both attempts; with no driver left to fire, the new deepest column would stay
    /// behind the edge for good. The hold is asserted too: while the gesture delivers the stack
    /// must hold still, or the sideways wiggle the lock prevents is back.
    @Test func testAnInFlightVerticalGestureDefersARevealInsteadOfDefeatingIt() async throws {
        let mounted = try await mount(paneWidth: 690, depth: 4, openTo: 2)
        defer { _ = mounted.window }
        let clip = mounted.stack.contentView
        // Three columns fit, so nothing has revealed yet.
        try #require(clip.bounds.origin.x == 0, "the fixture did not start at the leading edge")

        // This pane's watchdog moves onto a tracker this test drives by hand.
        let (lock, ahead) = try holdStack(mounted)
        let inStack = clip.convert(NSPoint(x: 20, y: 20), to: nil)

        try await drillToFourColumns(mounted)

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

        expectFourOverflowing(mounted)

        // The finger leaves and the momentum runs out: `momentumPhase.ended` is how the tracker
        // releases a real flick.
        lock.ingest(phase: [], momentumPhase: .ended, dx: 0, dy: 0,
                    window: mounted.window, locationInWindow: inStack, at: ahead + 0.5)
        try #require(!lock.shouldHoldHorizontalDrift(for: clip),
                     "the fixture failed to release the hold")

        let revealed = await wait(mounted.window, upTo: 25) {
            guard let deepest = self.columnFrames(mounted).last else { return false }
            return deepest.maxX <= self.visibleSpan(mounted).upperBound + 1
        }
        let (whole, report) = try deepestColumnIsVisible(mounted)
        #expect(revealed, "the reveal was defeated by the pane's own in-flight gesture and never re-issued: \(report)")
        #expect(whole, "the re-issued reveal cut the deepest column off on its leading edge: \(report)")
    }

    /// Puts `mounted`'s stack under a hold this test owns, and returns the tracker holding it.
    /// Dated an hour ahead (as in `PaneColumnsAxisLockTests`) so the hold can't lapse on its own;
    /// only the release ends it, so "the reveal came back on release" means something.
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
    /// gap. A duration, not `PaneColumnsView.revealHoldChecks`, because this is the user-facing
    /// claim, and reading the constant would let the test agree with any value it took.
    private static let plausibleContinuousGesture: TimeInterval = 5.0

    /// A reveal deferred by a hold must outlive an ordinary continuous gesture. The deferral
    /// re-checks every `WheelGestureTracker.staleness`; a budget spent by ordinary scrolling would
    /// drop the reveal silently, and with no other driver to fire the column stays hidden. The
    /// release is the only event in the window.
    @Test func testAHeldRevealOutlivesAnOrdinaryFiveSecondGesture() async throws {
        let mounted = try await mount(paneWidth: 690, depth: 4, openTo: 2)
        defer { _ = mounted.window }
        let clip = mounted.stack.contentView
        // Three columns fit, so nothing has revealed yet.
        try #require(clip.bounds.origin.x == 0, "the fixture did not start at the leading edge")

        let held = try holdStack(mounted)

        try await drillToFourColumns(mounted)

        // The gesture keeps delivering for the whole plausible span, past both attempts' chains.
        await pump(mounted.window,
                   seconds: Self.plausibleContinuousGesture + PaneColumnsView.revealRetryDelay + 1.0)

        // The hold is asserted too: the stack holds still while the gesture delivers.
        #expect(clip.bounds.origin.x == 0,
                "the stack moved sideways while a vertical gesture was delivering in its own pane — the axis lock's hold is gone")
        try #require(held.lock.shouldHoldHorizontalDrift(for: clip),
                     "the hold lapsed during the wait — the reveal was never actually made to wait")

        expectFourOverflowing(mounted)

        // The finger leaves and the momentum runs out.
        held.lock.ingest(phase: [], momentumPhase: .ended, dx: 0, dy: 0,
                         window: mounted.window, locationInWindow: .zero, at: held.at + 0.5)
        try #require(!held.lock.shouldHoldHorizontalDrift(for: clip),
                     "the fixture failed to release the hold")

        let revealed = await wait(mounted.window, upTo: 25) {
            guard let deepest = self.columnFrames(mounted).last else { return false }
            return deepest.maxX <= self.visibleSpan(mounted).upperBound + 1
        }
        let (_, report) = try deepestColumnIsVisible(mounted)
        #expect(revealed,
                "a \(Self.plausibleContinuousGesture)s gesture spent the reveal's deferral budget and the column never came back: \(report)")
    }

    /// One frame at 60Hz, the cadence momentum events arrive on: the gap the post-scroll re-ask must
    /// span. Not `WheelGestureTracker.staleness`, since stating the hazard in the fix's own constant
    /// would agree with any re-ask delay.
    private static let momentumFrame: TimeInterval = 1.0 / 60.0

    /// The reveal must survive a hold that re-engages in the frame after it scrolled. The gate reads
    /// a snapshot of `now - lastEventAt < staleness`, so a main-thread hitch can let one check read
    /// unheld; the attempt scrolls, the next momentum event re-engages the lock a frame later and
    /// `enforceHold` reverts it. The chain must ask again on that cadence: a re-ask at
    /// `deferReveal(by: 0)` would read the same gap and retire.
    ///
    /// The verdict is that the chain is still parked, not a stranded column: with
    /// `paneColumnRevealAnimation` nil, a one-step scroll into a gap becomes the watchdog's new
    /// `restX` and stands, and faking the revert leaves SwiftUI's offset out of step with the clip.
    /// That a surviving chain then reveals is pinned by
    /// `testAHeldRevealOutlivesAnOrdinaryFiveSecondGesture` and
    /// `testAnInFlightVerticalGestureDefersARevealInsteadOfDefeatingIt`.
    @Test func testARevealSurvivesAHoldThatReEngagesTheFrameAfterItScrolled() async throws {
        let mounted = try await mount(paneWidth: 690, depth: 4, openTo: 2)
        defer { _ = mounted.window }
        let clip = mounted.stack.contentView
        // Three columns fit, so nothing has revealed yet.
        try #require(clip.bounds.origin.x == 0, "the fixture did not start at the leading edge")

        let held = try holdStack(mounted)
        let watchdog = try #require(soleWatchdog(mounted))
        let gate = try #require(watchdog.holdGate,
                                "the pane's watchdog carries no gate — there is no chain here to watch")

        try await drillToFourColumns(mounted)
        // Past both attempts, so the chain that scrolls below is a parked one that waited.
        await pump(mounted.window, seconds: PaneColumnsView.revealRetryDelay + 0.3)
        try #require(clip.bounds.origin.x == 0,
                     "the stack moved while the hold was engaged — the deferral is already gone and this test measures nothing")
        try #require(gate.hasPendingReveal,
                     "no chain is parked before the gap is opened — there is nothing here that could be spent")

        // The momentum stream resumes one frame after the reveal's scroll lands, armed before the
        // gap opens so it can't miss the scroll. Attributed to a point inside this stack, like
        // `holdStack`'s gesture: an unattributed one would hold every stack, hiding a cross-pane leak.
        let inStack = clip.convert(NSPoint(x: 20, y: 20), to: nil)
        let interference = Interference(clip: clip, restX: 0) { [weak window = mounted.window] in
            guard let window else { return }
            held.lock.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0,
                             window: window, locationInWindow: inStack, at: held.at + 1)
            held.lock.ingest(phase: .changed, momentumPhase: [], dx: 1, dy: -12,
                             window: window, locationInWindow: inStack, at: held.at + 1.01)
        }
        defer { interference.stop() }

        // The hitch: the gate reads unheld for one check. The gesture hasn't ended (a real one is
        // still coasting), so the interference above puts it straight back.
        held.lock.ingest(phase: [], momentumPhase: .ended, dx: 0, dy: 0,
                         window: mounted.window, locationInWindow: .zero, at: held.at + 0.5)
        try #require(!held.lock.shouldHoldHorizontalDrift(for: clip),
                     "the fixture failed to open the gap the re-ask has to span")

        try #require(await wait(mounted.window, upTo: 25) { interference.fired },
                     "the reveal never scrolled into the gap — there was nothing for a re-engaging hold to defeat, so this test would pass vacuously")
        try #require(await wait(mounted.window, upTo: 10) {
                        held.lock.shouldHoldHorizontalDrift(for: clip)
                     },
                     "the interference did not re-engage the hold — the chain was never put back under one")

        // The discriminating assertion: with the gesture delivering again the chain's only correct
        // state is parked, since one that retired inside the gap never comes back.
        try #require(await wait(mounted.window, upTo: 5) { gate.hasPendingReveal },
                     "the chain retired while the gesture was delivering again — it asked the gate inside the very gap that made it read false, which is the same outcome as never asking")

        expectFourOverflowing(mounted)

        // Its budget is pinned in `testTheHoldBudgetIsLongerThanAnyGestureAndShorterThanForever`.
        interference.stop()
    }

    /// A cancelled reveal's already-queued attempt does nothing when it runs. `.onDisappear` calls
    /// `cancelPendingReveal`, but the two attempts are a `DispatchQueue.main.async` and an
    /// `.asyncAfter(+revealRetryDelay)`, neither cancellable, so a pane torn down in between must
    /// not have its retry scroll or park a fresh chain on the cleared gate. Pinned on the gate,
    /// since a torn-down pane can't be observed; the cancel lands on the chain's own parking
    /// (`hasPendingReveal`), between the attempts whatever the load. Positive control:
    /// `testAHeldRevealOutlivesAnOrdinaryFiveSecondGesture`.
    @Test func testACancelledRevealsQueuedRetryScrollsNothing() async throws {
        let mounted = try await mount(paneWidth: 690, depth: 4, openTo: 2)
        defer { _ = mounted.window }
        let clip = mounted.stack.contentView
        try #require(clip.bounds.origin.x == 0, "the fixture did not start at the leading edge")

        let held = try holdStack(mounted)
        let watchdog = try #require(soleWatchdog(mounted))
        let gate = try #require(watchdog.holdGate,
                                "the pane's watchdog carries no gate — there is nothing here to cancel")

        try await drillToFourColumns(mounted)

        // The teardown, landed between the reveal's two attempts.
        try #require(await wait(mounted.window, upTo: 25) { gate.hasPendingReveal },
                     "the reveal never parked a chain — there is nothing here for a cancel to make final")
        gate.cancelPendingReveal()

        // The hold goes away, so the queued retry finds nothing stopping it. Only the cancel can.
        held.lock.ingest(phase: [], momentumPhase: .ended, dx: 0, dy: 0,
                         window: mounted.window, locationInWindow: .zero, at: held.at + 0.5)
        try #require(!held.lock.shouldHoldHorizontalDrift(for: clip),
                     "the fixture failed to release the hold — an unmoved stack below would prove only that the hold won")

        expectFourOverflowing(mounted)

        // Bounded by a queued marker, not the wall clock, and sampled throughout (`maxOriginDrift`).
        let drift = await maxOriginDrift(mounted, from: 0)
        #expect(drift <= 1,
                "the stack moved \(drift)pt after the reveal was cancelled — an attempt queued before the cancel still spoke for the pane, which is what makes the cancel not final")
    }

    /// A momentum stream that resumes one frame after the reveal's scroll first moves the stack.
    /// The frame matters: re-engaging synchronously would restore the lock before even a zero-delay
    /// re-ask drained, and the defect would pass.
    ///
    /// A bounds observer, not a poll: the scroll and the resumption are one run-loop turn apart, and
    /// `setBoundsOrigin` posts `boundsDidChangeNotification` synchronously. **Never mutate the clip
    /// inside the notification** (as `holdAgainstVerticalGestureLeak` doesn't): a write re-posts
    /// it, recursing until the stack overflows.
    @MainActor private final class Interference {
        @MainActor private final class Flag { var fired = false }
        private let flag = Flag()
        private var observer: NSObjectProtocol?
        var fired: Bool { flag.fired }

        init(clip: NSClipView, restX: CGFloat, reEngage: @escaping @MainActor () -> Void) {
            clip.postsBoundsChangedNotifications = true
            let flag = self.flag
            let frame = ColumnPreviewRevealTests.momentumFrame
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak clipRef = clip] _ in
                MainActor.assumeIsolated {
                    guard let clip = clipRef, clip.bounds.origin.x != restX, !flag.fired else {
                        return
                    }
                    flag.fired = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + frame) {
                        MainActor.assumeIsolated { reEngage() }
                    }
                }
            }
        }

        /// Explicit rather than a `deinit`, for `OriginTrace`'s reason.
        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }

    /// Every horizontal origin the clip is ever set to, in order, including one put back a turn
    /// later. `setBoundsOrigin` posts synchronously, so this sees a movement the watchdog reverts,
    /// which a polling loop misses. At exhaustion the reveal is expected to be reverted, so "was it
    /// issued at all" is the measurement.
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
        /// Explicit rather than a `deinit`: a nonisolated `deinit` can't touch the stored,
        /// non-Sendable observer token.
        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
        var origins: [CGFloat] { log.origins }
        var peak: CGFloat { log.origins.map(abs).max() ?? 0 }
    }

    /// The end of the budget must be a logged best-effort scroll, not a silent drop that strands the
    /// deepest column with nothing in `~/sync-cloud.log`. Pinned three ways: 1. the exhaustion is
    /// logged; 2. the scroll is issued anyway (if `enforceHold` reverts it nothing is lost, if the
    /// hold has lapsed it lands); 3. the hold still wins, since a reveal that beats the lock (the
    /// sideways wiggle) would pass 1 and 2. The budget is injected at 0 so the first attempt is the
    /// exhausted one.
    @Test func testAnExhaustedHoldBudgetScrollsAnywayAndSaysSo() async throws {
        let mounted = try await mount(paneWidth: 690, depth: 4, openTo: 2, holdChecks: 0)
        defer { _ = mounted.window }
        let clip = mounted.stack.contentView
        try #require(clip.bounds.origin.x == 0, "the fixture did not start at the leading edge")

        let held = try holdStack(mounted)
        let trace = OriginTrace(clip)
        defer { trace.stop() }
        let log = LogCapture()

        try await drillToFourColumns(mounted)

        let marker = Marker()
        DispatchQueue.main.asyncAfter(deadline: .now() + PaneColumnsView.revealRetryDelay + 0.5) {
            MainActor.assumeIsolated { marker.fired = true }
        }
        _ = await wait(mounted.window, upTo: 30) { marker.fired }

        expectFourOverflowing(mounted)

        // 1. The exhaustion is logged. Read once, not polled: the marker drained after both attempts
        //    (`maxOriginDrift`), so the line is written by now if it ever will be.
        #expect(await log.holds(containing: "reveal waited out"),
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

    /// The hold budget bounded from both ends, as a duration so a change to
    /// `WheelGestureTracker.staleness` counts too. Too short and an ordinary scroll spends it; too
    /// long and a deferred chain keeps a torn-down pane's captures and `ScrollViewProxy` alive.
    @Test func testTheHoldBudgetIsLongerThanAnyGestureAndShorterThanForever() {
        let seconds = Double(PaneColumnsView.revealHoldChecks) * WheelGestureTracker.staleness
        #expect(seconds >= 30,
                "the hold budget is \(seconds)s — an ordinary continuous scroll reaches that, and reaching it costs the reveal its wait")
        #expect(seconds <= 120,
                "the hold budget is \(seconds)s — that is how long one deferred chain can retain a pane that is already gone")
    }

    /// Drills one deeper: four 210pt columns are 840pt in a 690pt pane, so the new deepest column
    /// is off the trailing edge and only a reveal can bring it back.
    private func drillToFourColumns(_ mounted: Mounted,
                                    sourceLocation: SourceLocation = #_sourceLocation) async throws {
        mounted.box.browsePath = Self.browsePath(depth: 3)
        try #require(await wait(mounted.window, upTo: 25) { self.columnFrames(mounted).count == 4 },
                     "the drill never opened a fourth column", sourceLocation: sourceLocation)
    }

    /// Nothing is vacuous: four columns, and they overflow the viewport, so a reveal (or a stray
    /// scroll) has real distance to move.
    private func expectFourOverflowing(_ mounted: Mounted,
                                       sourceLocation: SourceLocation = #_sourceLocation) {
        let frames = columnFrames(mounted)
        #expect(frames.count == 4, "the fixture opened \(frames.count) columns, expected 4",
                sourceLocation: sourceLocation)
        let viewport = mounted.stack.contentView.bounds.width
        let content = mounted.stack.documentView?.frame.width ?? 0
        #expect(content > viewport,
                "the drilled stack does not overflow its \(viewport)pt viewport (content \(content)pt) — the reveal is unobservable here",
                sourceLocation: sourceLocation)
    }

    /// Whether the deepest column lies wholly inside the clip, with the measurement for a message.
    private func deepestColumnIsVisible(_ mounted: Mounted) throws -> (Bool, String) {
        let deepest = try #require(columnFrames(mounted).last, "no deepest column")
        let visible = visibleSpan(mounted)
        let report = "column \(deepest.minX)…\(deepest.maxX), visible \(visible.lowerBound)…\(visible.upperBound)"
        return (deepest.maxX <= visible.upperBound + 1 && deepest.minX >= visible.lowerBound - 1, report)
    }

    /// The pane narrowing (a smaller window, a panel opening beside it) shrinks the viewport while
    /// the clip keeps its origin, sliding the deepest column off the trailing edge. Four 210pt
    /// columns fit 1100pt; at 760pt the deepest sits at 630…840, and only the `paneWidth` driver
    /// can bring it back.
    @Test func testNarrowingThePaneKeepsTheDeepestColumnOnScreen() async throws {
        let mounted = try await mount(paneWidth: 1100, depth: 3)
        defer { _ = mounted.window }
        let clip = mounted.stack.contentView
        let wide = clip.bounds.width

        let originBefore = clip.bounds.origin.x
        mounted.window.setContentSize(NSSize(width: 760, height: 520))
        await wait(mounted.window, upTo: 25) { clip.bounds.width < wide }
        try #require(clip.bounds.width < wide, "the pane never narrowed")
        let content = mounted.stack.documentView?.frame.width ?? 0
        try #require(content > clip.bounds.width,
                     "the stack fits its narrowed viewport (content \(content)pt in \(clip.bounds.width)pt) — vacuous")
        await wait(mounted.window, upTo: 25) { clip.bounds.origin.x != originBefore }
        await settle(mounted)

        let (visible, report) = try deepestColumnIsVisible(mounted)
        #expect(visible, "narrowing the pane hid the deepest column: \(report), viewport \(wide) → \(clip.bounds.width)pt")
    }

    /// The other edge: widening the pane only adds viewport, so a scrolled-back stack stays put.
    /// With a positive control, since one handler drives both. Five 210pt columns are 1050pt, so
    /// 760 → 1000 widens the viewport and still overflows it.
    @Test func testWideningThePaneLeavesAScrolledBackStackWhereItWas() async throws {
        let mounted = try await mount(paneWidth: 760, depth: 4)
        defer { _ = mounted.window }
        let clip = mounted.stack.contentView
        await wait(mounted.window, upTo: 25) { clip.bounds.origin.x > 0 }

        await scrollBack(mounted, toX: 0)
        try #require(clip.bounds.origin.x == 0, "fixture failed to scroll the stack back")
        let narrow = clip.bounds.width
        mounted.window.setContentSize(NSSize(width: 1000, height: 520))
        await wait(mounted.window, upTo: 25) { clip.bounds.width > narrow }
        try #require(clip.bounds.width > narrow, "the pane never widened")
        let content = mounted.stack.documentView?.frame.width ?? 0
        try #require(content > clip.bounds.width,
                     "the stack fits its widened viewport (content \(content)pt in \(clip.bounds.width)pt) — a wrong reveal would be invisible")
        #expect(await maxOriginDrift(mounted, from: 0) == 0,
                "widening the pane yanked a scrolled-back stack away from x 0")

        // Positive control: narrowing back must still reveal.
        mounted.window.setContentSize(NSSize(width: 760, height: 520))
        await wait(mounted.window, upTo: 25) { clip.bounds.origin.x > 0 }
        #expect(clip.bounds.origin.x > 0, "narrowing stopped revealing — the absence above is vacuous")
    }

    /// The preview is drawn in the window's Info inspector, so selecting a file changes neither the
    /// stack's viewport nor its scroll. Scrolled back to x 0 first: at the revealed position a
    /// reveal fired by the selection would move nothing, and the drift check couldn't fail.
    @Test func testSelectingAFileHoldsTheStackStill() async throws {
        let mounted = try await mount(paneWidth: 690, depth: 3)
        defer { _ = mounted.window }
        let clip = mounted.stack.contentView
        let width = clip.bounds.width
        let content = mounted.stack.documentView?.frame.width ?? 0
        try #require(content > width, "the stack fits its viewport — a movement would be invisible")
        await scrollBack(mounted, toX: 0)
        try #require(clip.bounds.origin.x == 0, "fixture failed to scroll the stack back")

        mounted.box.selection = [Self.deepestFile(depth: mounted.depth)]
        #expect(await maxOriginDrift(mounted, from: 0) == 0,
                "selecting a file moved the stack")
        #expect(clip.bounds.width == width,
                "selecting a file resized the stack (\(width) → \(clip.bounds.width)pt)")
    }

    /// Widening out of push mode is the one widening that hides the column you were in: below
    /// `pushNavigationBelowWidth` the pane shows one column, and back above it the whole stack
    /// returns at origin 0 with the deepest column past the trailing edge (closing the Info
    /// inspector over a narrow Compare pane, say).
    @Test func testWideningOutOfPushModeRevealsTheDeepestColumn() async throws {
        let mounted = try await mount(paneWidth: 690, depth: 3)
        defer { _ = mounted.window }
        let clip = mounted.stack.contentView

        let narrow = PaneViewMode.pushNavigationBelowWidth - 30
        mounted.window.setContentSize(NSSize(width: narrow, height: 520))
        await wait(mounted.window, upTo: 25) { self.columnFrames(mounted).count == 1 }
        try #require(columnFrames(mounted).count == 1, "the pane never went to one column — not push mode")
        await settle(mounted)

        mounted.window.setContentSize(NSSize(width: 690, height: 520))
        await wait(mounted.window, upTo: 25) { self.columnFrames(mounted).count == mounted.depth + 1 }
        try #require(columnFrames(mounted).count == mounted.depth + 1, "the stack never came back")
        let content = mounted.stack.documentView?.frame.width ?? 0
        try #require(content > clip.bounds.width,
                     "the stack fits its viewport (content \(content)pt in \(clip.bounds.width)pt) — vacuous")
        await wait(mounted.window, upTo: 25) { clip.bounds.origin.x > 0 }
        await settle(mounted)

        let (visible, report) = try deepestColumnIsVisible(mounted)
        #expect(visible, "widening out of push mode left the deepest column hidden: \(report)")
    }
}
