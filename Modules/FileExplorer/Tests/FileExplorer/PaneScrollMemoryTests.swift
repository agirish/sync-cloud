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

    // MARK: - The rules

    /// A stack's offset comes back only onto the very stack it was taken on — a stack that changed
    /// while the pane was away is a different place, and restoring onto it would scroll to a column
    /// that is not the one the offset described.
    @Test func aStackOffsetComesBackOnlyOntoTheSameStack() {
        let memory = PaneScrollMemory()
        memory.recordStack(surface: "Browse.left", components: ["a", "b"], originX: 120)
        #expect(memory.stackOrigin(surface: "Browse.left", components: ["a", "b"]) == 120)
        #expect(memory.stackOrigin(surface: "Browse.left", components: ["a", "c"]) == nil,
                "an offset was offered to a stack it was not taken on")
        #expect(memory.stackOrigin(surface: "Filing.left", components: ["a", "b"]) == nil,
                "one surface's offset leaked to another — their panes are different widths")
    }

    /// A list's offset belongs to its folder, however the path is spelled.
    @Test func aListOffsetIsKeptPerFolder() {
        let memory = PaneScrollMemory()
        memory.recordList(directory: "/root/a2/", originY: 80)
        #expect(memory.listOrigin(directory: "/root/a2") == 80)
        #expect(memory.listOrigin(directory: "/root/a3") == nil)
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

    /// 30 folders of 30 folders of 12 files: three columns overflow a 520pt window, and every list is
    /// taller than its viewport.
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

        var body: some View {
            PaneColumnsView(
                tree: PaneScrollMemoryTests.tree, otherTree: PaneTree(side: .right, version: 1, nodes: []),
                childrenIndex: PaneChildrenIndex(tree: PaneScrollMemoryTests.tree, treeRoot: PaneScrollMemoryTests.root),
                treeRoot: PaneScrollMemoryTests.root,
                browsePath: $box.browsePath, onNavigate: { box.browsePath = $0 },
                selection: $box.selection, otherSelection: [], isLeft: true,
                delegate: StubDelegate(), diffIndex: .empty, otherPaneName: "R",
                isSingleSource: false, density: .comfortable, isActivePane: true,
                placement: nil, onBarEdgeFlip: nil, onQuickLook: { _ in }, onBackgroundDeselect: { _ in }
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
    private func mount(_ components: [String], slot: PaneScrollMemorySlot?) async -> NSWindow {
        let host = NSHostingView(rootView: Harness(box: Box(components), slot: slot))
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
        memory.recordStack(surface: "Browse.left", components: ["a2", "b3"], originX: 0)
        let first = await mount(["a2", "b3"], slot: slot)
        let firstStack = try stack(first)
        let range = (firstStack.contentView.documentView?.frame.width ?? 0) - firstStack.contentView.bounds.width
        try #require(range > 60, "the stack does not overflow, so there is no offset to keep")
        // **Scroll to 50 until it STICKS.** The first mount's restore to 0 is queued work too, and under
        // a loaded main thread it can land after this scroll — once. So the scroll is re-made whenever
        // it has been moved, until it has held at 50, and been recorded there, for a moment on end. The
        // ceiling is generous because a starved main actor resumes this loop only every few seconds.
        let clip = firstStack.contentView
        var heldSince: Date?
        var moved: [CGFloat] = []
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if abs(clip.bounds.origin.x - 50) >= 1 {
                moved.append(clip.bounds.origin.x)
                clip.setBoundsOrigin(NSPoint(x: 50, y: clip.bounds.origin.y))
                firstStack.reflectScrolledClipView(clip)
                heldSince = nil
            } else if memory.stackOrigin(surface: "Browse.left", components: ["a2", "b3"]) == 50 {
                if heldSince == nil { heldSince = Date() }
                if let heldSince, Date().timeIntervalSince(heldSince) > 0.6 { break }
            }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        var probes: [PaneStackScrollMemoryProbe.ProbeView] = []
        func collect(_ v: NSView) {
            if let p = v as? PaneStackScrollMemoryProbe.ProbeView { probes.append(p) }
            v.subviews.forEach(collect)
        }
        collect(first.contentView!)
        try #require(memory.stackOrigin(surface: "Browse.left", components: ["a2", "b3"]) == 50, """
            the scroll to 50 never held and was never recorded, so a restore would prove nothing — \
            moved off 50 \(moved.count)× (last from \(moved.suffix(5))), now at \(clip.bounds.origin.x), \
            recorded \(String(describing: memory.stackOrigin(surface: "Browse.left", components: ["a2", "b3"]))), \
            probes \(probes.count), resolved to the stack \(probes.filter { $0.resolvedScroller === firstStack }.count)
            """)
        first.contentView = nil

        let second = await mount(["a2", "b3"], slot: slot)
        defer { second.contentView = nil }
        await waitUntil { abs(((try? self.stack(second).contentView.bounds.origin.x) ?? 0) - 50) < 1 }
        let x = try stack(second).contentView.bounds.origin.x
        #expect(abs(x - 50) < 1, "the rebuilt stack sits at \(x), not the 50 it was left at")
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
        let recorded = await waitUntil { memory.listOrigin(directory: "/root/a2") == 80 }
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

    /// A stack that changed while the pane was away is a different place: the offset stays unused and
    /// the deepest column is revealed, as a drill would.
    @Test func aChangedStackRevealsItsDeepestColumnInstead() async throws {
        let memory = PaneScrollMemory()
        let slot = PaneScrollMemorySlot(memory: memory, surface: "Browse.left")
        let first = await mount(["a2", "b3"], slot: slot)
        await scroll(try stack(first), to: NSPoint(x: 0, y: try stack(first).contentView.bounds.origin.y))
        first.contentView = nil

        let second = await mount(["a4", "b1"], slot: slot)
        defer { second.contentView = nil }
        let clip = try stack(second).contentView
        let farEnd = (clip.documentView?.frame.width ?? 0) - clip.bounds.width
        try #require(farEnd > 60)
        await waitUntil { abs(clip.bounds.origin.x - farEnd) < 1 }
        #expect(abs(clip.bounds.origin.x - farEnd) < 1,
                "a changed stack came back at \(clip.bounds.origin.x) instead of revealing its deepest column (\(farEnd))")
    }

    /// The control: a pane with no memory mounts as it always did — at its first column. Without this
    /// the three tests above could be passing on some other mechanism that restores for everyone.
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
