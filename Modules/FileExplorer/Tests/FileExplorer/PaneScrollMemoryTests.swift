import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// `PaneScrollMemory` — a pane rebuilt by a workspace switch comes back scrolled where it was.
///
/// The rebuild is modelled the way the app does it: the pane is torn out of its window and a NEW
/// `PaneColumnsView` is mounted over the same stack, with nothing carried across but the memory. That
/// is exactly what `ContentView`'s four layout arms do on a switch, and it is why the offsets lived
/// nowhere a rebuilt pane could find them.
@MainActor
@Suite(.serialized) struct PaneScrollMemoryTests {

    private typealias Position = PaneScrollMemory.Position

    // MARK: - The rules

    /// A stack's position comes back only onto the very stack it was taken on, under the same tree
    /// root — a stack that changed while the pane was away is a different place, and so is the same
    /// folder names under another root.
    @Test func aStackPositionComesBackOnlyOntoTheSameStack() {
        let memory = PaneScrollMemory()
        let kept = Position(offset: 120, atEnd: false)
        memory.recordStack(surface: "Browse.left", treeRoot: "/root", components: ["a", "b"], position: kept)
        #expect(memory.stackPosition(surface: "Browse.left", treeRoot: "/root/", components: ["a", "b"]) == kept)
        #expect(memory.stackPosition(surface: "Browse.left", treeRoot: "/root", components: ["a", "c"]) == nil,
                "a position was offered to a stack it was not taken on")
        #expect(memory.stackPosition(surface: "Browse.left", treeRoot: "/other", components: ["a", "b"]) == nil,
                "a position was offered to the same folder names under another root")
        #expect(memory.stackPosition(surface: "Filing.left", treeRoot: "/root", components: ["a", "b"]) == nil,
                "one surface's position leaked to another — their panes are different widths")
    }

    /// A list's position belongs to its folder, however the path is spelled.
    @Test func aListPositionIsKeptPerFolder() {
        let memory = PaneScrollMemory()
        memory.recordList(directory: "/root/a2/", position: Position(offset: 80, atEnd: false))
        #expect(memory.listPosition(directory: "/root/a2")?.offset == 80)
        #expect(memory.listPosition(directory: "/root/a3") == nil)
    }

    /// **A position is kept as what it means.** Resting within a point of the end is "at the end",
    /// and an elastic overscroll is clamped rather than kept as a place. Put back, "at the end" is
    /// the end of the range as it is NOW — longer or shorter — and anything else is the offset,
    /// clamped to what fits.
    @Test func aPositionIsKeptAsWhatItMeans() {
        #expect(Position.resting(at: 99.5, in: 0...100) == Position(offset: 99.5, atEnd: true))
        #expect(Position.resting(at: 50, in: 0...100) == Position(offset: 50, atEnd: false))
        #expect(Position.resting(at: 130, in: 0...100) == Position(offset: 100, atEnd: true),
                "an overscroll past the end was kept as a place")
        #expect(Position.resting(at: -20, in: 0...100) == Position(offset: 0, atEnd: false))
        let atEnd = Position(offset: 100, atEnd: true)
        #expect(atEnd.resolved(in: 0...40) == 40, "the end of a range that shrank")
        #expect(atEnd.resolved(in: 0...300) == 300, "the end of a range that grew")
        #expect(Position(offset: 50, atEnd: false).resolved(in: 0...40) == 40)
        #expect(Position(offset: 50, atEnd: false).resolved(in: 0...300) == 50)
    }

    /// The folders' positions are bounded: one small entry per folder ever scrolled, the oldest
    /// dropped first, so a long session cannot grow the table without end.
    @Test func theListMemoryIsBounded() {
        let memory = PaneScrollMemory()
        let cap = PaneScrollMemory.listCapacity
        for i in 0...cap {
            memory.recordList(directory: "/root/f\(i)", position: Position(offset: CGFloat(i), atEnd: false))
        }
        #expect(memory.listPosition(directory: "/root/f0") == nil, "the oldest folder was kept past the cap")
        #expect(memory.listPosition(directory: "/root/f1")?.offset == 1)
        #expect(memory.listPosition(directory: "/root/f\(cap)")?.offset == CGFloat(cap))
        // Re-recording a folder already kept is an update, not a new entry.
        memory.recordList(directory: "/root/f1", position: Position(offset: 7, atEnd: false))
        #expect(memory.listPosition(directory: "/root/f2")?.offset == 2)
    }

    /// **Only a fresh wheel or trackpad scroll is the user scrolling** — what drops a restore still
    /// waiting to land. The keystroke that switched workspaces is still `NSApp.currentEvent` while the
    /// rebuilt pane lays out, and reading it as a scroll would drop every restore it was meant to make.
    @Test func onlyAFreshScrollIsTheUserScrolling() throws {
        let scroll = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                          wheel1: 4, wheel2: 0, wheel3: 0))
        scroll.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        #expect(PaneScrollMemory.isUserScroll(NSEvent(cgEvent: scroll)))
        scroll.timestamp = CGEventTimestamp((ProcessInfo.processInfo.systemUptime - 5) * 1_000_000_000)
        #expect(!PaneScrollMemory.isUserScroll(NSEvent(cgEvent: scroll)), "a stale scroll is not this one")
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                   context: nil, characters: "1", charactersIgnoringModifiers: "1",
                                   isARepeat: false, keyCode: 18)
        #expect(!PaneScrollMemory.isUserScroll(key), "the ⌘1 that switched workspaces read as a scroll")
        #expect(!PaneScrollMemory.isUserScroll(nil))
    }

    // MARK: - A rebuilt pane

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
        @Published var browsePath: PaneBrowsePath
        @Published var selection: Set<String> = []
        init(_ components: [String]) { browsePath = PaneBrowsePath(components: components) }
    }

    static let root = "/root"

    /// 30 folders of 30 folders of 12 files: three columns overflow a 520pt window, and the first two
    /// lists are taller than their viewports.
    private static let tree: PaneTree = {
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
    }()

    private struct Harness: View {
        @ObservedObject var box: Box
        let slot: PaneScrollMemorySlot?
        var searchRevealTarget: String?

        var body: some View {
            PaneColumnsView(
                tree: PaneScrollMemoryTests.tree, otherTree: PaneTree(side: .right, version: 1, nodes: []),
                childrenIndex: PaneChildrenIndex(tree: PaneScrollMemoryTests.tree, treeRoot: PaneScrollMemoryTests.root),
                treeRoot: PaneScrollMemoryTests.root,
                browsePath: $box.browsePath, onNavigate: { box.browsePath = $0 },
                selection: $box.selection, otherSelection: [], isLeft: true,
                delegate: StubDelegate(), diffIndex: .empty, otherPaneName: "R",
                isSingleSource: false, density: .comfortable, isActivePane: true,
                placement: nil, onBarEdgeFlip: nil, onQuickLook: { _ in }, onBackgroundDeselect: { _ in },
                searchRevealTarget: searchRevealTarget
            )
            .environment(\.paneColumnRevealAnimation, nil)
            .environment(\.paneScrollMemory, slot)
        }
    }

    /// Lets the main run loop run for `seconds` by SUSPENDING, a frame at a time.
    ///
    /// **Suspending is load-bearing.** A `@MainActor` test body is itself running on the main queue,
    /// so spinning `RunLoop.run` synchronously never drains it: every `DispatchQueue.main` block the
    /// pane queues — the restore's attempts, the reveal's two scrolls — waits until the test yields.
    /// A synchronous pump made all three rebuild tests fail with nothing restored and nothing revealed
    /// (traced: the restore was scheduled and never ran) — a harness defect that reads exactly like
    /// the feature not working. While this sleeps, the run loop does layout, display and the queue.
    private func pump(_ seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
    }

    /// Waits for `condition` — ARRIVAL, not quiescence — polling a frame at a time, up to `timeout`.
    ///
    /// Fixed waits were how this suite first failed in a full run: each mount took 18–43 s there
    /// instead of 3, the fixed pumps expired on schedule, and the assertions read a pane that had not
    /// laid out yet. A condition with a generous ceiling costs nothing when things are fast and cannot
    /// be outrun when they are slow (`docs/flaky-tests.md`, the "quiescence is not arrival" family).
    @discardableResult
    private func waitUntil(_ timeout: Double = 15, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        return condition()
    }

    /// Mounts a pane ALREADY standing on `components` — a rebuild, not a drill: the stack exists
    /// before the pane appears, so no `browsePath` change fires. Returns once all three columns are
    /// laid out, so the stack genuinely overflows.
    private func mount(_ components: [String], slot: PaneScrollMemorySlot?,
                       searchRevealTarget: String? = nil) async -> NSWindow {
        let host = NSHostingView(rootView: Harness(box: Box(components), slot: slot,
                                                   searchRevealTarget: searchRevealTarget))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        await waitUntil { self.lists(window).count == 3 && ((try? self.room(window)) ?? 0) > 60 }
        return window
    }

    /// How far the stack can scroll sideways, as laid out right now.
    private func room(_ window: NSWindow) throws -> CGFloat {
        let clip = try stack(window).contentView
        return (clip.documentView?.frame.width ?? 0) - clip.bounds.width
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

    private func stack(_ window: NSWindow) throws -> NSScrollView {
        try #require(scrollViews(window.contentView!).first { !($0.documentView is NSTableView) },
                     "no stack scroll view")
    }

    private func lists(_ window: NSWindow) -> [NSScrollView] {
        scrollViews(window.contentView!)
            .filter { $0.documentView is NSTableView }
            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    private func stackProbe(_ window: NSWindow) -> PaneStackScrollMemoryProbe.ProbeView? {
        var found: PaneStackScrollMemoryProbe.ProbeView?
        func walk(_ v: NSView) {
            if let p = v as? PaneStackScrollMemoryProbe.ProbeView { found = p }
            v.subviews.forEach(walk)
        }
        walk(window.contentView!)
        return found
    }

    private func scroll(_ scroller: NSScrollView, to origin: NSPoint) async {
        let clip = scroller.contentView
        clip.setBoundsOrigin(origin)
        scroller.reflectScrolledClipView(clip)
        await pump(0.1)
    }

    /// The stack comes back to the offset it was left at — not to its first column, which is where a
    /// rebuilt pane landed before, and not to the deepest either, which is where a first visit lands.
    @Test func aRebuiltPaneReturnsToItsStackOffset() async throws {
        let memory = PaneScrollMemory()
        let slot = PaneScrollMemorySlot(memory: memory, surface: "Browse.left")
        // Seeded as a stack already visited and left at its first column, so the first mount RESTORES
        // (once) rather than REVEALING. A first visit's reveal issues two scrolls from queued blocks,
        // and in a full suite both landed seconds late, after this test's scroll — traced: the stack
        // was moved off 50 twice, from 0 and then from 110, with the probe resolved throughout. The
        // reveal has its own test; this one is about the round trip.
        memory.recordStack(surface: "Browse.left", treeRoot: Self.root, components: ["a2", "b3"],
                           position: Position(offset: 0, atEnd: false))
        let first = await mount(["a2", "b3"], slot: slot)
        let firstStack = try stack(first)
        let range = (firstStack.contentView.documentView?.frame.width ?? 0) - firstStack.contentView.bounds.width
        try #require(range > 60, "the stack does not overflow, so there is no offset to keep")
        // **Scroll to 50 until it STICKS.** The first mount's restore to 0 is queued work too, and under
        // a loaded main thread it can land after this scroll — once. So the scroll is re-made whenever
        // it has been moved, until it has held at 50, and been recorded there, for a moment on end. The
        // ceiling is generous because a starved main actor resumes this loop only every few seconds.
        let clip = firstStack.contentView
        func kept() -> Position? {
            memory.stackPosition(surface: "Browse.left", treeRoot: Self.root, components: ["a2", "b3"])
        }
        var heldSince: Date?
        var moved: [CGFloat] = []
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if abs(clip.bounds.origin.x - 50) >= 1 {
                moved.append(clip.bounds.origin.x)
                clip.setBoundsOrigin(NSPoint(x: 50, y: clip.bounds.origin.y))
                firstStack.reflectScrolledClipView(clip)
                heldSince = nil
            } else if kept() == Position(offset: 50, atEnd: false) {
                if heldSince == nil { heldSince = Date() }
                if let heldSince, Date().timeIntervalSince(heldSince) > 0.6 { break }
            }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        try #require(kept() == Position(offset: 50, atEnd: false), """
            the scroll to 50 never held and was never recorded, so a restore would prove nothing — \
            moved off 50 \(moved.count)× (last from \(moved.suffix(5))), now at \(clip.bounds.origin.x), \
            recorded \(String(describing: kept())), \
            probe resolved to the stack: \(stackProbe(first)?.resolvedScroller === firstStack)
            """)
        first.contentView = nil

        let second = await mount(["a2", "b3"], slot: slot)
        defer { second.contentView = nil }
        await waitUntil { abs(((try? self.stack(second).contentView.bounds.origin.x) ?? 0) - 50) < 1 }
        let x = try stack(second).contentView.bounds.origin.x
        #expect(abs(x - 50) < 1, "the rebuilt stack sits at \(x), not the 50 it was left at")
    }

    /// **A stack kept at its end comes back to the end of what it is NOW.** Kept as "at the end", it is
    /// put back at the far end of the stack as it lays out — not at the number it was, which a preview
    /// that has opened since, a narrower window or a column resized elsewhere would leave short of it,
    /// with the deepest column hidden.
    @Test func aStackKeptAtItsEndComesBackToItsEndAsItIsNow() async throws {
        let memory = PaneScrollMemory()
        let slot = PaneScrollMemorySlot(memory: memory, surface: "Browse.left")
        // Kept at the end of a stack that was then a lot narrower than this one is.
        memory.recordStack(surface: "Browse.left", treeRoot: Self.root, components: ["a2", "b3"],
                           position: Position(offset: 12, atEnd: true))
        let window = await mount(["a2", "b3"], slot: slot)
        defer { window.contentView = nil }
        let clip = try stack(window).contentView
        let farEnd = try room(window)
        try #require(farEnd > 60)
        await waitUntil { abs(clip.bounds.origin.x - farEnd) < 1 }
        #expect(abs(clip.bounds.origin.x - farEnd) < 1,
                "a stack kept at its end came back at \(clip.bounds.origin.x), not its end at \(farEnd)")
    }

    /// **A position that no longer fits lands as soon as the columns do — clamped, not late.** It used
    /// to wait for room that was never coming, the whole fallback of checks, with the stack showing its
    /// first column meanwhile. Now it is resolved against the stack once the stack has laid out.
    @Test func aPositionThatNoLongerFitsLandsWithoutWaitingOutTheFallback() async throws {
        let memory = PaneScrollMemory()
        let slot = PaneScrollMemorySlot(memory: memory, surface: "Browse.left")
        memory.recordStack(surface: "Browse.left", treeRoot: Self.root, components: ["a2", "b3"],
                           position: Position(offset: 5_000, atEnd: false))
        let window = await mount(["a2", "b3"], slot: slot)
        defer { window.contentView = nil }
        let clip = try stack(window).contentView
        let farEnd = try room(window)
        await waitUntil { self.stackProbe(window)?.checksUsedByLastRestore != nil }
        #expect(abs(clip.bounds.origin.x - farEnd) < 1,
                "a position past the end came back at \(clip.bounds.origin.x), not clamped to \(farEnd)")
        let used = try #require(stackProbe(window)?.checksUsedByLastRestore, "the restore never landed")
        #expect(used < PaneScrollMemory.restoreAttempts,
                "the restore ran out all \(used) of its checks — it waited for room instead of landing on layout")
    }

    /// Each column's list comes back to where it was scrolled, per folder.
    @Test func aRebuiltPaneReturnsEachListToItsOffset() async throws {
        let memory = PaneScrollMemory()
        let slot = PaneScrollMemorySlot(memory: memory, surface: "Browse.left")
        let first = await mount(["a2", "b3"], slot: slot)
        let firstLists = lists(first)
        try #require(firstLists.count == 3, "expected three column lists")
        let middle = firstLists[1]
        await scroll(middle, to: NSPoint(x: middle.contentView.bounds.origin.x, y: 80))
        let recorded = await waitUntil { memory.listPosition(directory: "/root/a2")?.offset == 80 }
        try #require(recorded, "the scroll to 80 was never recorded, so a restore would prove nothing")
        // Read while the pane is still mounted: a detached scroll view's bounds say nothing.
        let untouchedBefore = firstLists[0].contentView.bounds.origin.y
        first.contentView = nil

        let second = await mount(["a2", "b3"], slot: slot)
        defer { second.contentView = nil }
        let secondLists = lists(second)
        try #require(secondLists.count == 3)
        await waitUntil { abs(secondLists[1].contentView.bounds.origin.y - 80) < 1 }
        let y = secondLists[1].contentView.bounds.origin.y
        #expect(abs(y - 80) < 1, "the rebuilt middle list sits at \(y), not the 80 it was left at")
        let untouchedAfter = secondLists[0].contentView.bounds.origin.y
        #expect(abs(untouchedAfter - untouchedBefore) < 1,
                "an unscrolled list came back at \(untouchedAfter), not the \(untouchedBefore) it was at")
    }

    /// **A list kept at its bottom comes back to its bottom** — of the list as it is now, which a
    /// shorter viewport (Compare's panes are shorter than Browse's) or a folder that lost files moves.
    @Test func aListKeptAtItsBottomComesBackToItsBottom() async throws {
        let memory = PaneScrollMemory()
        let slot = PaneScrollMemorySlot(memory: memory, surface: "Browse.left")
        memory.recordList(directory: "/root/a2", position: Position(offset: 3, atEnd: true))
        let window = await mount(["a2", "b3"], slot: slot)
        defer { window.contentView = nil }
        let middle = try #require(lists(window).dropFirst().first)
        let clip = middle.contentView
        let bottom = (clip.documentView?.frame.height ?? 0) - clip.bounds.height
        try #require(bottom > 60, "the middle list does not scroll, so its bottom proves nothing")
        await waitUntil { abs(clip.bounds.origin.y - bottom) < 1 }
        #expect(abs(clip.bounds.origin.y - bottom) < 1,
                "a list kept at its bottom came back at \(clip.bounds.origin.y), not its bottom at \(bottom)")
    }

    /// **Only the column holding a search hit yields to it.** The hit's column scrolls to the hit;
    /// every other column keeps its place. The rule used to be pane-wide, and a query left in the
    /// field — standing state, not a request — turned the whole memory off.
    @Test func onlyTheColumnHoldingASearchHitYieldsToIt() async throws {
        let memory = PaneScrollMemory()
        let slot = PaneScrollMemorySlot(memory: memory, surface: "Browse.left")
        memory.recordList(directory: "/root", position: Position(offset: 80, atEnd: false))
        memory.recordList(directory: "/root/a2", position: Position(offset: 40, atEnd: false))
        let window = await mount(["a2", "b3"], slot: slot, searchRevealTarget: "/root/a2/b24")
        defer { window.contentView = nil }
        let columns = lists(window)
        try #require(columns.count == 3)
        await waitUntil { abs(columns[0].contentView.bounds.origin.y - 80) < 1 }
        #expect(abs(columns[0].contentView.bounds.origin.y - 80) < 1,
                "the first column, which holds no hit, did not keep its place")
        let hitColumn = try #require(columns[1].documentView as? NSTableView)
        await waitUntil { columns[1].contentView.documentVisibleRect.intersects(hitColumn.rect(ofRow: 24)) }
        #expect(columns[1].contentView.documentVisibleRect.intersects(hitColumn.rect(ofRow: 24)),
                "the hit's column was put back where it was instead of showing the hit")
    }

    /// A stack that changed while the pane was away is a different place: the position stays unused
    /// and the deepest column is revealed, as a drill would. Seeded rather than scrolled, so there is
    /// certainly a position for the OLD stack that a looser key would hand over.
    @Test func aChangedStackRevealsItsDeepestColumnInstead() async throws {
        let memory = PaneScrollMemory()
        let slot = PaneScrollMemorySlot(memory: memory, surface: "Browse.left")
        memory.recordStack(surface: "Browse.left", treeRoot: Self.root, components: ["a2", "b3"],
                           position: Position(offset: 0, atEnd: false))

        let window = await mount(["a4", "b1"], slot: slot)
        defer { window.contentView = nil }
        let clip = try stack(window).contentView
        let farEnd = try room(window)
        try #require(farEnd > 60)
        await waitUntil { abs(clip.bounds.origin.x - farEnd) < 1 }
        #expect(abs(clip.bounds.origin.x - farEnd) < 1,
                "a changed stack came back at \(clip.bounds.origin.x) instead of revealing its deepest column (\(farEnd))")
    }

    /// The control: a pane with no memory mounts as it always did — at its first column. Without this
    /// the tests above could be passing on some other mechanism that restores for everyone.
    @Test func aPaneWithoutMemoryStartsAtItsFirstColumn() async throws {
        let first = await mount(["a2", "b3"], slot: nil)
        await scroll(try stack(first), to: NSPoint(x: 50, y: try stack(first).contentView.bounds.origin.y))
        first.contentView = nil

        let second = await mount(["a2", "b3"], slot: nil)
        defer { second.contentView = nil }
        // A negative cannot be waited for, so give anything that WOULD restore the same second a
        // restore needs when it works.
        await pump(1.0)
        #expect(try stack(second).contentView.bounds.origin.x == 0)
    }
}
