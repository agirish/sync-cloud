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
                placement: nil, onBarEdgeFlip: nil, onQuickLook: { _ in }, onBackgroundDeselect: { _ in }
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

    /// Mounts the pane with three columns open in a 520pt window — 630pt of content, so the
    /// stack genuinely scrolls. Returns the window (kept alive by the caller), the stack's
    /// scroll view and the columns' lists.
    private func mountThreeColumns() async throws -> (window: NSWindow, stack: NSScrollView, columns: [NSScrollView]) {
        let box = Box()
        let tree = Self.tree()
        let index = PaneChildrenIndex(tree: tree, treeRoot: Self.root)
        let host = NSHostingView(rootView: Harness(box: box, tree: tree, index: index))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 520)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()

        box.browsePath = PaneBrowsePath(components: ["a2", "b3"])
        await pump(window, seconds: 1.5)

        let all = scrollViews(window.contentView!)
        let stack = try #require(all.first { !($0.documentView is NSTableView) }, "no stack scroll view")
        let columns = all.filter { $0.documentView is NSTableView }
        return (window, stack, columns)
    }

    @Test func testTheMountedStackScrollsNatively() async throws {
        let (window, stack, columns) = try await mountThreeColumns()
        defer { _ = window }
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

    /// The watchdog must be guarding the STACK's scroll view — resolution is the one thing the
    /// synthetic tests below cannot pin, and targeting a column's list instead would look
    /// identical from the outside.
    @Test func testTheMountedWatchdogGuardsTheStacksScrollView() async throws {
        let (window, stack, _) = try await mountThreeColumns()
        defer { _ = window }

        var watchdogs: [PaneColumnsOverscrollReturn.WatchdogView] = []
        func walk(_ v: NSView) {
            if let w = v as? PaneColumnsOverscrollReturn.WatchdogView { watchdogs.append(w) }
            for sub in v.subviews { walk(sub) }
        }
        walk(window.contentView!)
        let watchdog = try #require(watchdogs.first, "no watchdog mounted in the columns stack")
        #expect(watchdog.resolvedScroller === stack,
                "the watchdog resolved the wrong scroll view — a column's list would now be fought over")
    }

    /// The watchdog must never disturb the mounted stack at rest. After the drill's own
    /// auto-scroll settles, nothing may move the stack again — a watchdog that nudges legal
    /// resting positions would fight every scroll the user makes.
    ///
    /// (The pull itself is driven synthetically in `PaneColumnsOverscrollReturnRuleTests`: the
    /// mounted stack cannot be stranded from test code, because SwiftUI's own clip view clamps
    /// programmatic `setBoundsOrigin` — only the lost-phase elastic gesture reaches the stranded
    /// state, and no bounds-setting fixture reproduces that routing.)
    @Test func testTheMountedStackAtRestIsLeftAlone() async throws {
        let (window, stack, _) = try await mountThreeColumns()
        defer { _ = window }
        let clip = stack.contentView

        // Wait for genuine rest first: the drill's own deferred auto-scroll can land late under a
        // loaded parallel run, and a baseline read before it lands fails this test against the
        // scroll, not the watchdog. Rest = the origin holding still for a full second.
        var settled = clip.bounds.origin
        var heldSince = Date()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, Date().timeIntervalSince(heldSince) < 1.0 {
            window.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 8_000_000)
            if clip.bounds.origin != settled {
                settled = clip.bounds.origin
                heldSince = Date()
            }
        }

        await pump(window, seconds: 0.8)
        #expect(clip.bounds.origin == settled,
                "the watchdog moved a stack that was resting in range")
    }

    /// The jitter probe must observe its OWN column's scroll view and genuinely emit when that
    /// column travels vertically — silent instrumentation would read as a healthy pane.
    @Test func testTheJitterProbeReportsAColumnsVerticalTravel() async throws {
        let (window, _, columns) = try await mountThreeColumns()
        defer { _ = window }
        // Shrink the window so a column's six rows genuinely overflow it and can scroll.
        window.setContentSize(NSSize(width: 520, height: 100))
        await pump(window, seconds: 0.5)

        var probes: [PaneColumnJitterProbe.ProbeView] = []
        func walk(_ v: NSView) {
            if let p = v as? PaneColumnJitterProbe.ProbeView { probes.append(p) }
            for sub in v.subviews { walk(sub) }
        }
        walk(window.contentView!)
        #expect(probes.count == columns.count, "expected one probe per column")

        let probe = try #require(probes.first { $0.resolvedClip != nil }, "no probe resolved a clip")
        let clip = try #require(probe.resolvedClip)
        #expect(clip.documentView is NSTableView, "the probe's clip does not host a table")
        #expect(columns.contains { $0.contentView === clip },
                "a probe observed something other than a column's own list")

        let scrollable = (clip.documentView?.frame.height ?? 0) - clip.bounds.height
        #expect(scrollable > 10, "fixture column does not overflow, so the emission check is vacuous")

        // Both halves live in ONE test because they share a process-wide switch: as two tests they
        // interleave at their `await` points and each flips the flag under the other — which is
        // exactly how the first draft failed, the "silent" case logging a line its sibling had
        // enabled. Owning the flag for the whole test removes the ordering question rather than
        // answering it.
        let wasEnabled = PaneScrollTrace.isEnabled
        defer { PaneScrollTrace.isEnabled = wasEnabled }

        // Asked for: the probe must genuinely emit. Silent instrumentation would report a healthy
        // pane no matter what the pane did.
        PaneScrollTrace.isEnabled = true
        let before = probe.linesLogged
        clip.scroll(to: NSPoint(x: 0, y: min(30, scrollable)))
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
        let deadline = Date().addingTimeInterval(5)
        while probe.linesLogged == before, Date() < deadline {
            window.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        #expect(probe.linesLogged > before, "the probe never reported the column's travel")

        // Not asked for — how it ships. The same travel, back the way it came, must write nothing.
        // `LogFileWriter` caps the log at 5 MB and trims it from the TAIL, so a per-frame line does
        // not merely sit there: it evicts the sync runs and errors the log is kept for.
        PaneScrollTrace.isEnabled = false
        let afterTracing = probe.linesLogged
        clip.scroll(to: NSPoint(x: 0, y: 0))
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
        await pump(window, seconds: 0.8)
        #expect(probe.linesLogged == afterTracing,
                "the travel trace wrote to the log with the diagnostic switched off")
    }
}

/// The watchdog's two pieces of pure logic, pinned directly: which scroll view is the stack's,
/// and where "home" is for a stranded origin.
@MainActor
@Suite struct PaneColumnsOverscrollReturnRuleTests {

    /// A column's scroll view (an `NSTableView` document) must be walked past; the stack's
    /// (anything else) is the one to take.
    @Test func testItSkipsAColumnsListAndTakesTheStacksScrollView() {
        let stack = NSScrollView()
        stack.documentView = NSView()          // the row of columns
        let columnList = NSScrollView()
        columnList.documentView = NSTableView() // one column's list
        stack.documentView?.addSubview(columnList)
        let probe = NSView()
        columnList.documentView?.addSubview(probe)

        let found = PaneColumnsOverscrollReturn.WatchdogView.findStackScrollView(from: probe)
        #expect(found === stack, "the walk stopped at a column's own list instead of the stack")
    }

    /// Nothing to find is answered with nil rather than a guess.
    @Test func testItRefusesWhenThereIsNoStackScroller() {
        let columnList = NSScrollView()
        columnList.documentView = NSTableView()
        let probe = NSView()
        columnList.documentView?.addSubview(probe)

        #expect(PaneColumnsOverscrollReturn.WatchdogView.findStackScrollView(from: probe) == nil)
    }

    /// A clip view 200pt wide over 600pt of content: home for any origin is inside [0, 400].
    private func clip() -> NSClipView {
        let view = NSClipView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        return view
    }

    @Test func testHomeForAnOriginPastTheStartIsTheStart() {
        let home = PaneColumnsOverscrollReturn.WatchdogView.legalOrigin(for: NSPoint(x: -40, y: 0), clip: clip())
        #expect(home == NSPoint(x: 0, y: 0))
    }

    @Test func testHomeForAnOriginPastTheEndIsTheEnd() {
        let home = PaneColumnsOverscrollReturn.WatchdogView.legalOrigin(for: NSPoint(x: 5000, y: 0), clip: clip())
        #expect(home == NSPoint(x: 400, y: 0))
    }

    @Test func testAVerticalDisplacementIsPulledFlat() {
        // The document exactly fills the clip vertically, so any y offset is illegal.
        let home = PaneColumnsOverscrollReturn.WatchdogView.legalOrigin(for: NSPoint(x: 100, y: -30), clip: clip())
        #expect(home == NSPoint(x: 100, y: 0))
    }

    @Test func testAnInRangeOriginIsItsOwnHome() {
        let origin = NSPoint(x: 150, y: 0)
        #expect(PaneColumnsOverscrollReturn.WatchdogView.legalOrigin(for: origin, clip: clip()) == origin)
    }

    /// A document NARROWER than the clip — the left pane resting with three columns in a wide
    /// pane. Home collapses to the document's leading edge: a zero-based clamp happened to give
    /// the same x here, but only by luck of the document sitting at zero, and the width case has
    /// to be pinned because a dragged-and-stranded *fitting* stack must still return.
    @Test func testAFittingDocumentsHomeIsItsLeadingEdge() {
        let view = NSClipView(frame: NSRect(x: 0, y: 0, width: 772, height: 100))
        view.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 100))
        #expect(PaneColumnsOverscrollReturn.WatchdogView.legalOrigin(
            for: NSPoint(x: -60, y: 0), clip: view) == NSPoint(x: 0, y: 0))
        #expect(PaneColumnsOverscrollReturn.WatchdogView.legalOrigin(
            for: NSPoint(x: 45, y: 0), clip: view) == NSPoint(x: 0, y: 0))
    }

    /// The pull's threshold exists and is meaningfully sub-visible: SwiftUI parks clips at
    /// fractional origins, and a watchdog without slack for that corrects them every quiescence
    /// interval forever — the 18,000-pull night. The cycle suite drives the behavior; this pins
    /// the constant's floor so a future "tighten it up" cannot silently reintroduce the loop.
    @Test func testTheToleranceClearsPixelAlignmentButNotVisibleStrandings() {
        #expect(PaneColumnsOverscrollReturn.WatchdogView.tolerance >= 1,
                "sub-point pixel alignment must never trigger a pull")
        #expect(PaneColumnsOverscrollReturn.WatchdogView.tolerance <= 8,
                "a stranding this size is visible — the watchdog would ignore real bugs")
    }
}

/// The watchdog's full cycle — observe, wait for rest, pull home — driven over a synthetic
/// scroll view whose clip can actually be stranded.
///
/// The real stranded state is reachable only through the lost-phase elastic gesture: SwiftUI's
/// own clip view clamps programmatic `setBoundsOrigin`, so no bounds-setting fixture can strand
/// the mounted stack (tried; the origin snapped straight back). This permissive clip view stands
/// in for the elastic state — out-of-range bounds that nothing re-constrains — which is exactly
/// the state the watchdog exists to notice.
@MainActor
@Suite struct PaneColumnsOverscrollReturnCycleTests {

    /// Lets any proposed bounds through, the way the rubber band's in-flight state does.
    private final class StrandableClipView: NSClipView {
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect { proposedBounds }
    }

    /// A 200pt scroll view over 600pt of content, with the watchdog mounted inside the document
    /// view — the same position the SwiftUI `.background` gives it in the real stack.
    private func mount() -> (window: NSWindow, scroller: NSScrollView, clip: NSClipView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroller = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let clip = StrandableClipView()
        scroller.contentView = clip
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        scroller.documentView = document
        document.addSubview(PaneColumnsOverscrollReturn.WatchdogView())
        window.contentView?.addSubview(scroller)
        return (window, scroller, clip)
    }

    private func pump(seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
    }

    /// Waits on the observable rather than sleeping a fixed interval and hoping: under a full
    /// parallel test run, other main-actor work can starve the watchdog's 140ms timer well past
    /// any polite fixed window — which is exactly how these tests first flaked.
    private func waitForOrigin(_ clip: NSClipView, toBecome expected: NSPoint,
                               timeout: Double = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if clip.bounds.origin == expected { return true }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        return clip.bounds.origin == expected
    }

    @Test func testAStrandedClipIsPulledHomeOnceAtRest() async {
        let (window, _, clip) = mount()
        defer { _ = window }
        await pump(seconds: 0.3)  // let the watchdog arm

        // Stranded past the left edge and displaced vertically, as the lost-phase gesture leaves it.
        clip.setBoundsOrigin(NSPoint(x: -40, y: 12))
        #expect(clip.bounds.origin == NSPoint(x: -40, y: 12),
                "fixture failed to strand the clip — the pull below is vacuous")

        #expect(await waitForOrigin(clip, toBecome: NSPoint(x: 0, y: 0)),
                "the watchdog left the clip stranded past the left edge, at \(clip.bounds.origin)")
    }

    @Test func testAClipStrandedPastTheEndIsPulledToTheEnd() async {
        let (window, _, clip) = mount()
        defer { _ = window }
        await pump(seconds: 0.3)

        clip.setBoundsOrigin(NSPoint(x: 460, y: 0))  // 400 is the last legal origin
        #expect(clip.bounds.origin.x == 460, "fixture failed to strand the clip")

        #expect(await waitForOrigin(clip, toBecome: NSPoint(x: 400, y: 0)),
                "the watchdog left the clip stranded past the right edge, at \(clip.bounds.origin)")
    }

    /// Absence has no observable to wait on, so this one holds the fixed window — but waits
    /// FIRST for a full quiescence period to elapse, so the watchdog demonstrably had its chance.
    @Test func testAnInRangeRestIsNeverTouched() async {
        let (window, _, clip) = mount()
        defer { _ = window }
        await pump(seconds: 0.3)

        clip.setBoundsOrigin(NSPoint(x: 150, y: 0))
        await pump(seconds: PaneColumnsOverscrollReturn.WatchdogView.quiescence * 4)
        #expect(clip.bounds.origin == NSPoint(x: 150, y: 0),
                "the watchdog moved a clip resting inside its legal range")
    }

    /// **The loop-breaker.** SwiftUI parks clip origins fractionally off the mathematical home;
    /// pulling those made the watchdog correct the same fraction every quiescence interval all
    /// night — each pull an animated `setBoundsOrigin`, visible as jitter on the left pane's
    /// first column. A sub-tolerance offset must be left exactly where it is, forever.
    @Test func testAFractionalOffsetIsLeftAloneNotCorrectedForever() async {
        let (window, _, clip) = mount()
        defer { _ = window }
        await pump(seconds: 0.3)

        // `setBoundsOrigin` itself pixel-rounds (−0.4 became −0.5 on this backing), so the pin
        // is against the value that actually landed — what matters is that the watchdog never
        // "corrects" it to zero.
        clip.setBoundsOrigin(NSPoint(x: -0.4, y: 0.33))
        let parked = clip.bounds.origin
        #expect(parked != .zero, "fixture failed to park the clip off the mathematical home")
        await pump(seconds: PaneColumnsOverscrollReturn.WatchdogView.quiescence * 6)
        #expect(clip.bounds.origin == parked,
                "the watchdog corrected a sub-point offset — the repeating-pull loop is back")
    }

    /// A FITTING document dragged out and stranded must still return: the tolerance exempts
    /// pixel fractions, not real strandings, and content narrower than the clip is exactly the
    /// state the left pane rests in.
    @Test func testAStrandedFittingDocumentIsPulledToItsLeadingEdge() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroller = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let clip = StrandableClipView()
        scroller.contentView = clip
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 100))
        scroller.documentView = document
        document.addSubview(PaneColumnsOverscrollReturn.WatchdogView())
        window.contentView?.addSubview(scroller)
        defer { _ = window }
        await pump(seconds: 0.3)

        clip.setBoundsOrigin(NSPoint(x: -60, y: 0))
        #expect(clip.bounds.origin.x == -60, "fixture failed to strand the fitting document")

        #expect(await waitForOrigin(clip, toBecome: NSPoint(x: 0, y: 0)),
                "a stranded fitting document was not pulled home, at \(clip.bounds.origin)")
    }

    /// An inset clip legally RESTS at a negative origin (`-insets.top`); clamping it to the
    /// document edge would repeat the pull-forever mistake on any inset list.
    @Test func testAnInsetClipsRestingOriginIsLegal() {
        let clip = NSClipView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        clip.automaticallyAdjustsContentInsets = false
        clip.contentInsets = NSEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)
        clip.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let resting = NSPoint(x: 0, y: -20)
        #expect(PaneColumnsOverscrollReturn.WatchdogView.legalOrigin(for: resting, clip: clip) == resting,
                "an inset clip's natural rest was judged out of range — that is the pull loop")
    }
}

/// The column-list watchdog: the same treatment, on the lists' VERTICAL axis, driven through the
/// probe that also logs their travel.
///
/// What demanded it is in the live log: `[col] right col0 y 0.0 → -17.5` and, six hundred
/// milliseconds later, `-17.5 → 0.0` — a list PARKED in overscroll, snapping back on some later
/// event. Same lost-phase disease as the stack's, same synthetic-strand test shape, because the
/// real state is only reachable through the broken gesture routing.
@MainActor
@Suite struct PaneColumnListWatchdogTests {

    private final class StrandableClipView: NSClipView {
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect { proposedBounds }
    }

    /// A table-backed scroll view — what a column's List is to the resolver — with the probe
    /// mounted as a frame-matched sibling, exactly as SwiftUI lays a `.background` out.
    private func mount() -> (window: NSWindow, clip: NSClipView, probe: PaneColumnJitterProbe.ProbeView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroller = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let clip = StrandableClipView()
        // In a titled window AppKit hands an automatic top inset to the clip, which widens the
        // legal band and silently legalizes the very park the test strands — zero them so the
        // fixture's legality is exactly its document edges.
        clip.automaticallyAdjustsContentInsets = false
        scroller.contentView = clip
        // A row-less NSTableView as the document auto-sizes itself back to the clip, collapsing
        // the scrollable extent the tests assume. So the document proper is a plain view that
        // keeps its 600pt, and the table sits INSIDE it — the resolver still matches, because it
        // measures the table's enclosing scroll view, which is this scroller either way.
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        document.addSubview(NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 50)))
        scroller.documentView = document
        let probe = PaneColumnJitterProbe.ProbeView()
        probe.label = "test col"
        probe.frame = scroller.frame
        window.contentView?.addSubview(scroller)
        window.contentView?.addSubview(probe)
        return (window, clip, probe)
    }

    private func pump(seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
    }

    private func waitForOrigin(_ clip: NSClipView, toBecome expected: NSPoint,
                               timeout: Double = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if clip.bounds.origin == expected { return true }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        return clip.bounds.origin == expected
    }

    /// The live signature: parked stretched above the top, pulled flat once at rest.
    @Test func testAListParkedInTopOverscrollIsPulledHome() async throws {
        let (window, clip, probe) = mount()
        defer { _ = window }
        await pump(seconds: 0.3)
        try #require(probe.resolvedClip === clip, "probe failed to resolve its list")

        clip.setBoundsOrigin(NSPoint(x: 0, y: -17.5))
        #expect(clip.bounds.origin.y == -17.5, "fixture failed to park the list — the pull is vacuous")

        #expect(await waitForOrigin(clip, toBecome: NSPoint(x: 0, y: 0)),
                "the list stayed parked in top overscroll, at \(clip.bounds.origin)")
    }

    /// A list parked past its bottom comes back to the last legal line.
    @Test func testAListParkedPastTheBottomIsPulledToTheEnd() async throws {
        let (window, clip, probe) = mount()
        defer { _ = window }
        await pump(seconds: 0.3)
        try #require(probe.resolvedClip === clip, "probe failed to resolve its list")

        clip.setBoundsOrigin(NSPoint(x: 0, y: 560))  // 500 is the last legal origin
        #expect(await waitForOrigin(clip, toBecome: NSPoint(x: 0, y: 500)),
                "the list stayed parked past its bottom, at \(clip.bounds.origin)")
    }

    /// A legally scrolled rest — the position a reading user is parked at — is never touched.
    @Test func testALegallyScrolledRestIsNeverTouchedByTheListWatchdog() async throws {
        let (window, clip, probe) = mount()
        defer { _ = window }
        await pump(seconds: 0.3)
        try #require(probe.resolvedClip === clip, "probe failed to resolve its list")

        clip.setBoundsOrigin(NSPoint(x: 0, y: 250))
        await pump(seconds: PaneColumnsOverscrollReturn.WatchdogView.quiescence * 4)
        #expect(clip.bounds.origin == NSPoint(x: 0, y: 250),
                "the watchdog moved a list resting at a legal scroll position")
    }
}

/// The gesture-axis lock: a vertical trackpad scroll's leaked horizontal deltas must not move
/// the stack — the sideways wiggle reported as "jitter when a 2nd column is open".
@MainActor
@Suite struct WheelGestureTrackerTests {

    @Test func testAVerticalDragEngagesTheLock() {
        let tracker = WheelGestureTracker()
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0, at: 0)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: 2, dy: -14, at: 0.01)
        #expect(tracker.isVerticalGestureInFlight(at: 0.02))
    }

    @Test func testAHorizontalDragDoesNot() {
        let tracker = WheelGestureTracker()
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0, at: 0)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: -20, dy: 3, at: 0.01)
        #expect(!tracker.isVerticalGestureInFlight(at: 0.02))
    }

    /// The decision is made ONCE, from the first real deltas: a vertical drag that wobbles
    /// horizontal mid-flight stays a vertical drag.
    @Test func testTheFirstRealDeltasDecideForTheWholeGesture() {
        let tracker = WheelGestureTracker()
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0, at: 0)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: 1, dy: -10, at: 0.01)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: -9, dy: 2, at: 0.02)
        #expect(tracker.isVerticalGestureInFlight(at: 0.03),
                "a mid-gesture wobble re-decided the axis")
    }

    /// Momentum inherits the drag's decision and keeps the lock alive while it delivers.
    @Test func testMomentumInheritsTheDecisionAndItsEndReleasesIt() {
        let tracker = WheelGestureTracker()
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0, at: 0)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: 0, dy: -12, at: 0.01)
        tracker.ingest(phase: .ended, momentumPhase: [], dx: 0, dy: 0, at: 0.02)
        tracker.ingest(phase: [], momentumPhase: .changed, dx: -30, dy: -4, at: 0.05)
        #expect(tracker.isVerticalGestureInFlight(at: 0.06),
                "momentum's own deltas re-decided the axis — their direction is history, not intent")
        tracker.ingest(phase: [], momentumPhase: .ended, dx: 0, dy: 0, at: 0.4)
        #expect(!tracker.isVerticalGestureInFlight(at: 0.41))
    }

    /// A gesture that ends with no momentum releases the lock by going quiet — otherwise a
    /// stale lock defeats the drill's own programmatic auto-scroll after the next click.
    @Test func testTheLockDecaysWhenEventsStopArriving() {
        let tracker = WheelGestureTracker()
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0, at: 0)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: 0, dy: -12, at: 0.01)
        tracker.ingest(phase: .ended, momentumPhase: [], dx: 0, dy: 0, at: 0.02)
        #expect(tracker.isVerticalGestureInFlight(at: 0.05), "still within the recency window")
        #expect(!tracker.isVerticalGestureInFlight(at: 0.02 + WheelGestureTracker.staleness + 0.01),
                "the lock outlived its events — the next programmatic scroll will be fought")
    }

    @Test func testANewGestureStartsUndecided() {
        let tracker = WheelGestureTracker()
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0, at: 0)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: 0, dy: -12, at: 0.01)
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0, at: 0.05)
        #expect(!tracker.isVerticalGestureInFlight(at: 0.06),
                "the previous gesture's decision leaked into the new one")
    }

    // MARK: - Traditional (non-phased) scroll wheels
    //
    // Every test above drives a trackpad: `.began`, `.changed`, momentum, `.ended`. A plain wheel
    // mouse sends NONE of those — phase and momentumPhase are both empty on every event — so all
    // three of the clears above are unreachable for it, and the whole suite passed while the lock
    // was permanently stuck for anyone not on a touch surface.

    /// The regression. Each wheel click is its own gesture, so a horizontal one is horizontal even
    /// after a vertical one: without this the first vertical click of the session latched
    /// `verticalDominant` forever and `enforceHold` reverted the stack against every later ⇧-wheel.
    @Test func testAWheelMouseRedecidesEveryEvent() {
        let tracker = WheelGestureTracker()
        tracker.ingest(phase: [], momentumPhase: [], dx: 0, dy: -10, at: 0)
        #expect(tracker.isVerticalGestureInFlight(at: 0.01), "a vertical wheel click must engage the lock")

        tracker.ingest(phase: [], momentumPhase: [], dx: -10, dy: 0, at: 0.02)
        #expect(!tracker.isVerticalGestureInFlight(at: 0.03),
                "a ⇧-wheel horizontal scroll was held against the user by a lock still reading 'vertical'")
    }

    /// The lock must still decay for a wheel mouse, so a burst of vertical clicks cannot defeat the
    /// drill's programmatic auto-scroll once the hand stops.
    @Test func testAWheelMouseLockDecaysOnQuiet() {
        let tracker = WheelGestureTracker()
        tracker.ingest(phase: [], momentumPhase: [], dx: 0, dy: -10, at: 0)
        #expect(!tracker.isVerticalGestureInFlight(at: WheelGestureTracker.staleness + 0.01))
    }

    /// A trackpad gesture's own events must not be mistaken for ungrouped ones — `.ended` carries
    /// an empty momentumPhase, and re-deciding there would drop the lock before momentum arrives.
    @Test func testAPhasedGestureIsNeverTreatedAsUngrouped() {
        let tracker = WheelGestureTracker()
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0, at: 0)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: 1, dy: -12, at: 0.01)
        tracker.ingest(phase: .ended, momentumPhase: [], dx: 0, dy: 0, at: 0.02)
        #expect(tracker.isVerticalGestureInFlight(at: 0.03),
                "`.ended` was read as an ungrouped event and cleared the decision early")
    }
}

/// The lock's enforcement on the stack, over the strandable harness: while a vertical gesture
/// delivers, leaked horizontal drift is reverted on the spot; once it releases, horizontal
/// movement is the stack's own business again.
@MainActor
@Suite struct PaneColumnsAxisLockTests {

    private final class StrandableClipView: NSClipView {
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect { proposedBounds }
    }

    /// Never lands where the hold puts it — every revert to x comes back at x+0.5, the way
    /// SwiftUI's animated scroll kept moving the clip against the hold in the crash.
    private final class FightingClipView: NSClipView {
        var fightsBack = false
        private(set) var setCount = 0
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect { proposedBounds }
        override func setBoundsOrigin(_ newOrigin: NSPoint) {
            setCount += 1
            let origin = fightsBack ? NSPoint(x: newOrigin.x + 0.5, y: newOrigin.y) : newOrigin
            super.setBoundsOrigin(origin)
        }
    }

    private func mount() -> (window: NSWindow, clip: NSClipView, watchdog: PaneColumnsOverscrollReturn.WatchdogView, lock: WheelGestureTracker) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroller = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let clip = StrandableClipView()
        clip.automaticallyAdjustsContentInsets = false
        scroller.contentView = clip
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        scroller.documentView = document
        let watchdog = PaneColumnsOverscrollReturn.WatchdogView()
        let lock = WheelGestureTracker()
        watchdog.axisLock = lock
        document.addSubview(watchdog)
        window.contentView?.addSubview(scroller)
        return (window, clip, watchdog, lock)
    }

    private func pump(seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
    }

    @Test func testLeakedHorizontalDriftIsRevertedDuringAVerticalGesture() async throws {
        let (window, clip, watchdog, lock) = mount()
        defer { _ = window }
        await pump(seconds: 0.3)
        try #require(watchdog.resolvedScroller != nil, "watchdog failed to arm")

        // A vertical drag is delivering events right now.
        lock.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0)
        lock.ingest(phase: .changed, momentumPhase: [], dx: 1, dy: -12)

        // Its leaked horizontal components nudge the stack sideways, continuously — a real
        // gesture is a delta STREAM, so the loop keeps stranding and keeps feeding the lock.
        // One-shot stranding is not faithful and flakes: the revert is a runloop hop away by
        // design (reverting synchronously inside the bounds notification is the recursion that
        // crashed at level 1839), and under a loaded parallel run a single hop can land after
        // the lock's recency window, which is a graceful no-op, not a failure.
        // Alternating drifts, because re-setting the CURRENT origin posts no bounds
        // notification: after one late hop, a fixed drift value would never schedule another
        // hold, and the test would report a working hold as broken.
        let deadline = Date().addingTimeInterval(10)
        var reverted = false
        var flip = false
        while !reverted, Date() < deadline {
            lock.ingest(phase: .changed, momentumPhase: [], dx: 1, dy: -8)
            clip.setBoundsOrigin(NSPoint(x: flip ? 12 : 9, y: 0))
            flip.toggle()
            try? await Task.sleep(nanoseconds: 8_000_000)
            reverted = clip.bounds.origin.x == 0
        }
        #expect(reverted,
                "a vertical gesture's leaked deltas moved the stack and the hold never reverted them")
    }

    /// The crash's shape, pinned: something keeps re-scrolling the stack against the hold — as
    /// SwiftUI's own animated scroll did mid-gesture — and the enforcement must stay BOUNDED,
    /// one revert per runloop turn at most, instead of recursing inside the notification until
    /// the stack guard kills the app.
    @Test func testAFightingScrollCannotRecurseTheHold() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroller = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let clip = FightingClipView()
        clip.automaticallyAdjustsContentInsets = false
        scroller.contentView = clip
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        scroller.documentView = document
        let watchdog = PaneColumnsOverscrollReturn.WatchdogView()
        let lock = WheelGestureTracker()
        watchdog.axisLock = lock
        document.addSubview(watchdog)
        window.contentView?.addSubview(scroller)
        defer { _ = window }
        await pump(seconds: 0.3)
        try #require(watchdog.resolvedScroller != nil, "watchdog failed to arm")

        // Vertical gesture in flight; the clip refuses to land on the held position — every
        // revert to 0 comes back half a point off, forever.
        lock.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0)
        lock.ingest(phase: .changed, momentumPhase: [], dx: 1, dy: -12)
        clip.fightsBack = true
        clip.setBoundsOrigin(NSPoint(x: 9, y: 0))

        // Keep the gesture alive for a while; the old in-notification revert would have
        // recursed thousands of frames deep INSIDE the first setBoundsOrigin call.
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            lock.ingest(phase: .changed, momentumPhase: [], dx: 0, dy: -8)
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        // Reaching this line at all is most of the assertion. The set count pins boundedness:
        // ~50 runloop turns elapsed, so per-turn enforcement stays in that order — recursion
        // would have piled up thousands before the first turn ended.
        #expect(clip.setCount < 500,
                "the hold fought a moving scroll \(clip.setCount) times — per-turn bounding is gone")
        // More than the strand's own set: the hold really did engage and fight (once per turn).
        #expect(clip.setCount > 1, "the fixture never engaged the hold at all — nothing was pinned")
    }

    @Test func testHorizontalScrollingIsUntouchedOutsideAVerticalGesture() async throws {
        let (window, clip, watchdog, lock) = mount()
        defer { _ = window }
        await pump(seconds: 0.3)
        try #require(watchdog.resolvedScroller != nil, "watchdog failed to arm")

        lock.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0)
        lock.ingest(phase: .changed, momentumPhase: [], dx: -18, dy: 2)

        clip.setBoundsOrigin(NSPoint(x: 120, y: 0))
        #expect(clip.bounds.origin.x == 120,
                "the lock held the stack during a HORIZONTAL gesture — columns can no longer scroll")
    }
}
