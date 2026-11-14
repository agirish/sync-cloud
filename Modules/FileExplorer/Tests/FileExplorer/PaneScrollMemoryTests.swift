import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// `PaneScrollMemory`: a pane rebuilt by a workspace switch comes back scrolled where it was. The
/// rebuild is modelled as `ContentView` does it: a new `PaneColumnsView` over the same stack, with
/// nothing carried across but the memory.
@MainActor
@Suite(.serialized) struct PaneScrollMemoryTests {

    private typealias Position = PaneScrollMemory.Position

    // MARK: - The rules

    /// A stack's position comes back only onto the very stack it was taken on, under the same tree
    /// root.
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

    /// A position is kept as what it means: within a point of the end is "at the end", an elastic
    /// overscroll is clamped. Put back, "at the end" is the range's end as it is now.
    @Test func aPositionIsKeptAsWhatItMeans() {
        #expect(Position.resting(at: 99.5, in: 0...100) == Position(offset: 99.5, atEnd: true))
        #expect(Position.resting(at: 50, in: 0...100) == Position(offset: 50, atEnd: false))
        #expect(Position.resting(at: 130, in: 0...100) == Position(offset: 100, atEnd: true),
                "an overscroll past the end was kept as a place")
        #expect(Position.resting(at: -20, in: 0...100) == Position(offset: 0, atEnd: false))
        // Content that fits has no end: kept at its start, which a restore cannot move.
        #expect(Position.resting(at: -32, in: -32 ... -32) == Position(offset: -32, atEnd: false))
        #expect(Position.resting(at: -32, in: -32 ... -32).isAtStart(of: -32 ... 400))
        #expect(!Position(offset: 120, atEnd: false).isAtStart(of: -32 ... 400))
        #expect(!Position(offset: -32, atEnd: true).isAtStart(of: -32 ... 400))
        // A stack that fits keeps its end: rebuilt narrower, its deepest column must stay in view.
        #expect(Position.resting(at: 0, in: 0...0, noRoomIsEnd: true) == Position(offset: 0, atEnd: true))
        #expect(Position.resting(at: 0, in: 0...0, noRoomIsEnd: true).resolved(in: 0...240) == 240)
        let atEnd = Position(offset: 100, atEnd: true)
        #expect(atEnd.resolved(in: 0...40) == 40, "the end of a range that shrank")
        #expect(atEnd.resolved(in: 0...300) == 300, "the end of a range that grew")
        #expect(Position(offset: 50, atEnd: false).resolved(in: 0...40) == 40)
        #expect(Position(offset: 50, atEnd: false).resolved(in: 0...300) == 50)
    }

    /// The folders' positions are bounded, the oldest dropped first.
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

    /// Only a fresh wheel or trackpad scroll is the user scrolling, which drops a restore still
    /// waiting to land. The keystroke that switched workspaces is still `NSApp.currentEvent` while
    /// the rebuilt pane lays out; read as a scroll, it would drop every restore.
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

    final class Box: ObservableObject {
        @Published var browsePath: PaneBrowsePath
        @Published var selection: Set<String> = []
        init(_ components: [String]) { browsePath = PaneBrowsePath(components: components) }
    }

    static let root = "/root"

    /// A fresh memory and the left Browse pane's slot on it.
    private static func memorySlot() -> (PaneScrollMemory, PaneScrollMemorySlot) {
        let memory = PaneScrollMemory()
        return (memory, PaneScrollMemorySlot(memory: memory, surface: "Browse.left"))
    }

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
                delegate: NoOpFileActionDelegate(), diffIndex: .empty, otherPaneName: "R",
                isSingleSource: false, density: .comfortable, isActivePane: true,
                placement: nil, onBarEdgeFlip: nil, onQuickLook: { _ in }, onBackgroundDeselect: { _ in },
                searchRevealTarget: searchRevealTarget
            )
            .environment(\.paneColumnRevealAnimation, nil)
            .environment(\.paneScrollMemory, slot)
        }
    }

    /// Lets the main run loop run for `seconds` by suspending. It must suspend: a `@MainActor` test
    /// body runs on the main queue, so a synchronous `RunLoop.run` never drains the
    /// `DispatchQueue.main` blocks the pane queues, which reads like the feature not working.
    private func pump(_ seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
    }

    /// Waits for `condition` to arrive, a frame at a time, up to `timeout` (`docs/flaky-tests.md`,
    /// "Fixed pumps and fixed sleeps").
    @discardableResult
    private func waitUntil(_ timeout: Double = 15, _ condition: () -> Bool) async -> Bool {
        await LayoutPumpWait.poll(upTo: timeout, until: condition).held
    }

    /// Mounts a pane already standing on `components`: a rebuild, not a drill, so no `browsePath`
    /// change fires. Returns once all three columns are laid out.
    private func mount(_ components: [String], slot: PaneScrollMemorySlot?,
                       searchRevealTarget: String? = nil, watch: FrameWatch? = nil,
                       wide: Bool = false) async -> NSWindow {
        let host = NSHostingView(rootView: Harness(box: Box(components), slot: slot,
                                                   searchRevealTarget: searchRevealTarget))
        host.frame = NSRect(x: 0, y: 0, width: wide ? 1_600 : 520, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        watch?.window = window
        window.contentView = host
        await waitUntil {
            guard self.lists(window).count == 3, let stack = try? self.stack(window),
                  let width = stack.contentView.documentView?.frame.width, width > 0 else { return false }
            return wide || ((try? self.room(window)) ?? 0) > 60
        }
        return window
    }

    /// How far the stack can scroll sideways, as laid out right now.
    private func room(_ window: NSWindow) throws -> CGFloat {
        let clip = try stack(window).contentView
        return (clip.documentView?.frame.width ?? 0) - clip.bounds.width
    }

    private func stack(_ window: NSWindow) throws -> NSScrollView {
        try #require(PaneRowRevealTests.scrollViews(window.contentView!).first { !($0.documentView is NSTableView) },
                     "no stack scroll view")
    }

    private func lists(_ window: NSWindow) -> [NSScrollView] {
        PaneRowRevealTests.scrollViews(window.contentView!)
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

    /// Reads the pane at the end of every main run-loop turn, after layout and Core Animation's
    /// commit: a position put back a turn late shows as a turn that ended visible in the wrong
    /// place. `@unchecked Sendable`: only touched on the main thread, by its observer.
    final class FrameWatch: @unchecked Sendable {
        weak var window: NSWindow?
        private var observer: CFRunLoopObserver?
        /// Turns that ended with the watched scroll view on screen, and the offset each showed.
        private(set) var shown: [CGFloat] = []

        /// `read` answers the watched scroll view's offset, or nil while it is not visible.
        func start(_ read: @escaping @MainActor @Sendable (NSWindow) -> CGFloat?) {
            // Ordered after Core Animation's commit (2,000,000), so the turn's layout has happened.
            observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue,
                                                          true, 2_000_001) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, let x = read(window) else { return }
                    self.shown.append(x)
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }

        func stop() {
            if let observer { CFRunLoopObserverInvalidate(observer) }
            observer = nil
        }
    }

    /// Whether `view` would be drawn: in a window, and neither it nor an ancestor hidden or clear.
    private static func isVisible(_ view: NSView) -> Bool {
        guard view.window != nil else { return false }
        var next: NSView? = view
        while let v = next {
            if v.isHidden || v.alphaValue == 0 { return false }
            next = v.superview
        }
        return true
    }

    private func scroll(_ scroller: NSScrollView, to origin: NSPoint) async {
        let clip = scroller.contentView
        clip.setBoundsOrigin(origin)
        scroller.reflectScrolledClipView(clip)
        await pump(0.1)
    }

    /// The stack comes back to the offset it was left at, not its first or deepest column.
    @Test func aRebuiltPaneReturnsToItsStackOffset() async throws {
        let (memory, slot) = Self.memorySlot()
        // Seeded as already visited, so the first mount restores rather than reveals: a first
        // visit's reveal scrolls from queued blocks that can land seconds late, after this scroll.
        memory.recordStack(surface: "Browse.left", treeRoot: Self.root, components: ["a2", "b3"],
                           position: Position(offset: 0, atEnd: false))
        let first = await mount(["a2", "b3"], slot: slot)
        let firstStack = try stack(first)
        let range = (firstStack.contentView.documentView?.frame.width ?? 0) - firstStack.contentView.bounds.width
        try #require(range > 60, "the stack does not overflow, so there is no offset to keep")
        // Scroll to 50 until it sticks: the first mount's queued restore to 0 can land after it
        // under load. A generous ceiling, as a starved main actor resumes this loop only every few
        // seconds.
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

    /// A stack kept at its end comes back to the end as it lays out now, not to the number it was,
    /// or the deepest column would be hidden.
    @Test func aStackKeptAtItsEndComesBackToItsEndAsItIsNow() async throws {
        let (memory, slot) = Self.memorySlot()
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

    /// A position that no longer fits lands, clamped, as soon as the columns lay out, rather than
    /// waiting out every fallback check for room that never comes, showing the first column.
    @Test func aPositionThatNoLongerFitsLandsWithoutWaitingOutTheFallback() async throws {
        let (memory, slot) = Self.memorySlot()
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
        let (memory, slot) = Self.memorySlot()
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

    /// A list kept at its bottom comes back to the bottom as it is now.
    @Test func aListKeptAtItsBottomComesBackToItsBottom() async throws {
        let (memory, slot) = Self.memorySlot()
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

    /// Only the column holding a search hit yields to it; every other keeps its place.
    @Test func onlyTheColumnHoldingASearchHitYieldsToIt() async throws {
        let (memory, slot) = Self.memorySlot()
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

    /// A stack that changed while the pane was away reveals its deepest column, as a drill would.
    /// Seeded, so there is certainly an old position a looser key would hand over.
    @Test func aChangedStackRevealsItsDeepestColumnInstead() async throws {
        let (memory, slot) = Self.memorySlot()
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

    /// A rebuilt stack is never shown before its position lands. The restore waits for the columns
    /// to lay out and lands the turn after, so the turn that first lays them out could show the
    /// stack at its first column. Every turn from the mount on is read: hidden, or in place.
    @Test func aRebuiltStackIsNeverShownBeforeItsPositionLands() async throws {
        let (memory, slot) = Self.memorySlot()
        memory.recordStack(surface: "Browse.left", treeRoot: Self.root, components: ["a2", "b3"],
                           position: Position(offset: 50, atEnd: false))
        let watch = FrameWatch()
        watch.start { window in
            guard let stack = try? self.stack(window), Self.isVisible(stack) else { return nil }
            return stack.contentView.bounds.origin.x
        }
        let window = await mount(["a2", "b3"], slot: slot, watch: watch)
        defer { window.contentView = nil }
        let clip = try stack(window).contentView
        let landed = await waitUntil { abs(clip.bounds.origin.x - 50) < 1 && Self.isVisible(clip) }
        // Until a turn has shown the stack, not a fixed pump that can end with none recorded
        // (`docs/flaky-tests.md`, "The control that stops an absence being vacuous is itself
        // load-dependent").
        await waitUntil { !watch.shown.isEmpty }
        watch.stop()
        try #require(landed, "the stack never came back to 50, so there is nothing to time")
        try #require(!watch.shown.isEmpty, "no turn ever showed the stack — the watch proves nothing")
        let early = watch.shown.filter { abs($0 - 50) >= 1 }
        #expect(early.isEmpty, "the stack was shown at \(early) before it landed at 50")
    }

    /// A rebuilt list is never shown before its position lands: `aRebuiltStackIsNeverShownBefore…`
    /// for a column's vertical position, which waits for the column's rows.
    @Test func aRebuiltListIsNeverShownBeforeItsPositionLands() async throws {
        let (memory, slot) = Self.memorySlot()
        // No stack position: a stack waiting on its own would be held clear too, and would hide the
        // list along with it — the list's own wait would go untested. Unkept, the stack reveals.
        memory.recordList(directory: "/root/a2", position: Position(offset: 80, atEnd: false))
        let watch = FrameWatch()
        watch.start { window in
            guard let middle = self.lists(window).dropFirst().first,
                  (middle.documentView as? NSTableView)?.numberOfRows ?? 0 > 0,
                  Self.isVisible(middle) else { return nil }
            return middle.contentView.bounds.origin.y
        }
        let window = await mount(["a2", "b3"], slot: slot, watch: watch)
        defer { window.contentView = nil }
        let middle = try #require(lists(window).dropFirst().first)
        let landed = await waitUntil { abs(middle.contentView.bounds.origin.y - 80) < 1 && Self.isVisible(middle) }
        // Until a turn has shown the list, not a fixed 0.1 s, for the stack test's reason above.
        await waitUntil { !watch.shown.isEmpty }
        watch.stop()
        try #require(landed, "the middle list never came back to 80, so there is nothing to time")
        try #require(!watch.shown.isEmpty, "no turn ever showed the list — the watch proves nothing")
        let early = watch.shown.filter { abs($0 - 80) >= 1 }
        #expect(early.isEmpty, "the middle list was shown at \(early) before it landed at 80")
    }

    /// A column nobody scrolled is never held clear: a restore can't move it, so a cover would only
    /// blank it for a frame on every switch back.
    @Test func aColumnNobodyScrolledIsNeverHeldClear() async throws {
        let (_, slot) = Self.memorySlot()
        let first = await mount(["a2", "b3"], slot: slot)
        await pump(0.3)                                   // laid out, so its columns are kept
        first.contentView = nil
        let watch = FrameWatch()
        watch.start { window in
            let lists = self.lists(window)
            guard !lists.isEmpty else { return nil }
            // The lists' OWN veils. The stack is kept at its end (it reveals the deepest column)
            // and is rightly held clear until it lands there; that is the stack test's business.
            return lists.allSatisfy { $0.alphaValue == 1 } ? 0 : 1
        }
        let second = await mount(["a2", "b3"], slot: slot, watch: watch)
        defer { second.contentView = nil }
        await pump(0.3)
        await waitUntil { !watch.shown.isEmpty }          // the control is the run loop's, not the clock's
        watch.stop()
        try #require(!watch.shown.isEmpty, "no turn ever saw the lists — the watch proves nothing")
        #expect(!watch.shown.contains(1), "a column at its top was held clear for \(watch.shown.filter { $0 == 1 }.count) turn(s)")
    }

    /// A row of columns that fits is never held clear: kept "at its end" (`noRoomIsEnd`) with no
    /// room, a restore can't move it. `aRebuiltStackIsNeverShownBeforeItsPositionLands` is the half
    /// for one that can move.
    @Test func aStackThatFitsIsNeverHeldClear() async throws {
        let (memory, slot) = Self.memorySlot()
        // What `record` keeps for a row with no room: at its start, and at its end.
        let kept = PaneScrollMemory.Position.resting(at: 0, in: 0...0, noRoomIsEnd: true)
        try #require(kept.atEnd)
        memory.recordStack(surface: "Browse.left", treeRoot: Self.root, components: ["a2", "b3"], position: kept)
        let watch = FrameWatch()
        watch.start { window in
            guard self.lists(window).count == 3, let stack = try? self.stack(window) else { return nil }
            return Self.isVisible(stack) ? 0 : 1
        }
        let second = await mount(["a2", "b3"], slot: slot, watch: watch, wide: true)
        defer { second.contentView = nil }
        await pump(0.3)
        await waitUntil { !watch.shown.isEmpty }          // the control is the run loop's, not the clock's
        watch.stop()
        try #require(try room(second) <= 1, "the columns do not fit a wide window — nothing to test")
        try #require(!watch.shown.isEmpty, "no turn ever saw the columns — the watch proves nothing")
        #expect(!watch.shown.contains(1), "a stack that fits was held clear for \(watch.shown.filter { $0 == 1 }.count) turn(s)")
    }

    /// The control: a pane with no memory mounts at its first column.
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
