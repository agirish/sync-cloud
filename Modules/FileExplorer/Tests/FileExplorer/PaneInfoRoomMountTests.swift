import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// The room a pane keeps for the app's Info column, mounted: the column stack keeps it after the
/// deepest column and says where it is, a drill moves it with the stack, a stack too deep for the
/// pane brings it into view, and taking the room away withdraws it. The app draws Info at whatever
/// this reports, so a room reported in the wrong place is Info drawn in the wrong place.
@MainActor
@Suite struct PaneInfoRoomMountTests {

    final class Box: ObservableObject {
        @Published var browsePath = PaneBrowsePath()
        @Published var selection: Set<String> = []
        @Published var room: PaneInfoRoom?
    }

    static let root = "/root"

    private static func tree() -> PaneTree {
        let top = (0..<4).map { a -> FileNode in
            let dir = "\(root)/a\(a)"
            let mids = (0..<4).map { b -> FileNode in
                let bPath = "\(dir)/b\(b)"
                return FileNode(id: bPath, name: "b\(b)", isDirectory: true,
                                children: (0..<3).map { FileNode(id: "\(bPath)/f\($0).pdf", name: "f\($0).pdf", isDirectory: false) })
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
                childrenIndex: index, treeRoot: PaneInfoRoomMountTests.root,
                browsePath: $box.browsePath, onNavigate: { box.browsePath = $0 },
                selection: $box.selection, otherSelection: [], isLeft: true,
                delegate: NoOpFileActionDelegate(), diffIndex: .empty, otherPaneName: "R",
                isSingleSource: false, density: .compact, isActivePane: true,
                placement: nil, onBarEdgeFlip: nil, onQuickLook: { _ in }, onBackgroundDeselect: { _ in }
            )
            // Placed outright rather than eased: an offscreen window that is never key may never
            // advance an animation (see `PaneColumnsScrollTests.Harness`).
            .environment(\.paneColumnRevealAnimation, nil)
            .environment(\.paneInfoRoom, box.room)
            .coordinateSpace(.named(PaneInfoSlot.coordinateSpace))
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

    private func mount(width: CGFloat, path: [String], room: PaneInfoRoom?) async -> (NSWindow, Box) {
        let box = Box()
        box.room = room
        let tree = Self.tree()
        let host = NSHostingView(rootView: Harness(box: box, tree: tree,
                                                   index: PaneChildrenIndex(tree: tree, treeRoot: Self.root)))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        box.browsePath = PaneBrowsePath(components: path)
        await pump(window, seconds: 1.0)
        return (window, box)
    }

    /// The room sits right after the deepest column, as wide as asked, as tall as the stack, with
    /// the divider on its trailing edge and the stack's visible region to be masked to. A drill one
    /// folder deeper moves it right by a column, at least the columns' 140 floor.
    @Test func theRoomFollowsTheDeepestColumn() async throws {
        let slot = PaneInfoSlot()
        let (window, box) = await mount(width: 1200, path: ["a1"], room: PaneInfoRoom(width: 300, slot: slot))
        defer { _ = window }
        let room = try #require(slot.room, "the stack kept no room for Info, or never said where")
        #expect(room.frame.width == 300)
        #expect(room.frame.height == 400)
        #expect(room.dividerEdge == .trailing)
        #expect(room.hostWidth == 1200)
        // Two columns open (root, a1): the room starts after both, well short of the pane's edge.
        #expect(room.frame.minX >= 2 * PaneViewMode.minimumColumnWidth)
        #expect(room.frame.maxX < 1200 - PaneViewMode.columnStackTrailingGutter)
        let viewport = try #require(room.viewport, "no visible region to mask Info to")
        #expect(abs(viewport.width - (1200 - PaneViewMode.columnStackTrailingGutter)) < 1)

        let before = room.frame.minX
        box.browsePath = PaneBrowsePath(components: ["a1", "b2"])
        await pump(window, seconds: 1.0)
        let after = try #require(slot.room).frame.minX
        #expect(after - before >= PaneViewMode.minimumColumnWidth,
                "a drill did not move Info's room past the new column (\(before) → \(after))")
    }

    /// A stack deeper than the pane is revealed with Info's room at the visible region's trailing
    /// edge, not the deepest column's, or the drill would leave Info off screen.
    @Test func aDeepStackIsRevealedToTheRoom() async throws {
        let slot = PaneInfoSlot()
        let (window, _) = await mount(width: 640, path: ["a2", "b3"], room: PaneInfoRoom(width: 300, slot: slot))
        defer { _ = window }
        let room = try #require(slot.room)
        let viewport = try #require(room.viewport)
        #expect(abs(room.frame.maxX - viewport.maxX) < 1.5,
                "the reveal parked the stack at \(room.frame.maxX), not at the visible edge \(viewport.maxX)")
    }

    /// Info scrolled off the trailing edge comes back on a reveal request (Get Info with Info open),
    /// as it does when it opens. Mutation: without the request's onChange, the stack stays put.
    @Test func aRevealRequestBringsInfoBack() async throws {
        let slot = PaneInfoSlot()
        let (window, _) = await mount(width: 640, path: ["a2", "b3"], room: PaneInfoRoom(width: 300, slot: slot))
        defer { _ = window }
        let stack = try #require(slot.stackScroller)
        // Scrolled back to the first column, until it holds: the mount's own reveal can still be
        // landing on a loaded machine and put the stack back. Bounded.
        var away = try #require(slot.room)
        for _ in 0..<40 {
            stack.contentView.scroll(to: .zero)
            stack.reflectScrolledClipView(stack.contentView)
            await pump(window, seconds: 0.25)
            away = try #require(slot.room)
            if let viewport = away.viewport, away.frame.maxX > viewport.maxX + 50 { break }
        }
        let viewport = try #require(away.viewport)
        try #require(away.frame.maxX > viewport.maxX + 50, "the stack never scrolled Info off (\(away.frame.maxX) vs \(viewport.maxX))")
        slot.requestReveal()
        await pump(window, seconds: 1.0)
        let back = try #require(slot.room)
        #expect(abs(back.frame.maxX - viewport.maxX) < 1.5, "Info stayed off at \(back.frame.maxX), edge \(viewport.maxX)")
    }

    /// Info finds the scroll view a swipe over it is handed to: the stack's, never a column's list,
    /// which would turn a sideways swipe over Info into a vertical scroll of some column.
    @Test func infoFindsTheStacksScrollView() async throws {
        let slot = PaneInfoSlot()
        let (window, _) = await mount(width: 640, path: ["a2", "b3"], room: PaneInfoRoom(width: 300, slot: slot))
        defer { _ = window }
        let stack = try #require(slot.stackScroller, "Info has no stack to hand its swipes to")
        #expect(!(stack.documentView is NSTableView), "Info would hand its swipes to a column's list")
        #expect(stack.window === window)
        // The fixture overflows, so the stack has somewhere to scroll and the claim is not vacuous.
        #expect((stack.documentView?.frame.width ?? 0) > stack.contentSize.width)
    }

    /// Taking the room away (Info closed, or become a drawer) withdraws it, so the app stops drawing
    /// Info where the room was.
    @Test func closingWithdrawsTheRoom() async throws {
        let slot = PaneInfoSlot()
        let (window, box) = await mount(width: 1200, path: ["a1"], room: PaneInfoRoom(width: 300, slot: slot))
        defer { _ = window }
        #expect(slot.room != nil)
        box.room = nil
        await pump(window, seconds: 0.5)
        #expect(slot.room == nil, "the room outlived Info")
    }

    /// No room, nothing reported: every surface that does not ask (Organize's lens, the tests) draws
    /// its stack as before.
    @Test func noRoomIsKeptUnlessAsked() async throws {
        let slot = PaneInfoSlot()
        let (window, _) = await mount(width: 1200, path: ["a1"], room: nil)
        defer { _ = window }
        #expect(slot.room == nil)
    }
}

/// Which wheel events over Info also go to the column stack (`PaneInfoWheelRouting`).
@Suite struct PaneInfoWheelRoutingTests {

    /// One event through the rule; `#expect` cannot call a mutating member itself.
    private func step(_ routing: inout PaneInfoWheelRouting, phase: NSEvent.Phase,
                      momentumPhase: NSEvent.Phase, overInfo: Bool) -> Bool {
        routing.forwards(phase: phase, momentumPhase: momentumPhase, overInfo: overInfo)
    }

    /// A trackpad gesture is claimed where it starts and keeps that answer through its momentum,
    /// though the pointer drifts off Info, as AppKit routes it. Mutation: deciding per event by the
    /// pointer drops the drifting half of a swipe.
    @Test func aGestureStartedOverInfoIsForwardedToTheEnd() {
        var routing = PaneInfoWheelRouting()
        #expect(step(&routing, phase: .mayBegin, momentumPhase: [], overInfo: true))
        #expect(step(&routing, phase: .began, momentumPhase: [], overInfo: true))
        #expect(step(&routing, phase: .changed, momentumPhase: [], overInfo: false))
        #expect(step(&routing, phase: .ended, momentumPhase: [], overInfo: false))
        #expect(step(&routing, phase: [], momentumPhase: .began, overInfo: false))
        #expect(step(&routing, phase: [], momentumPhase: .changed, overInfo: false))
        #expect(step(&routing, phase: [], momentumPhase: .ended, overInfo: false))
        #expect(!routing.claimed, "the claim outlived its gesture")
    }

    /// A gesture that starts over a column is the stack's already; drifting over Info forwards none
    /// of it, or the stack would get it twice.
    @Test func aGestureStartedElsewhereIsNeverForwarded() {
        var routing = PaneInfoWheelRouting()
        #expect(!step(&routing, phase: .began, momentumPhase: [], overInfo: false))
        #expect(!step(&routing, phase: .changed, momentumPhase: [], overInfo: true))
        #expect(!step(&routing, phase: [], momentumPhase: .changed, overInfo: true))
    }

    /// A plain wheel's clicks carry no phase: each is its own gesture, judged where it lands, and
    /// one never leaves a claim behind for the next.
    @Test func aPlainWheelIsJudgedClickByClick() {
        var routing = PaneInfoWheelRouting()
        #expect(step(&routing, phase: [], momentumPhase: [], overInfo: true))
        #expect(!step(&routing, phase: [], momentumPhase: [], overInfo: false))
        #expect(!routing.claimed)
    }

    /// Info scrolled past the stack's edge keeps its frame there, over the next pane: a swipe in
    /// that pane isn't over Info as seen, and is that pane's alone. Mutation: judging by Info's
    /// frame alone sends To File's swipes to the rail's columns.
    @Test func onlyTheInfoYouCanSeeClaimsASwipe() {
        let info = NSRect(x: 600, y: 0, width: 300, height: 500)
        let stack = NSRect(x: 0, y: 0, width: 700, height: 500)
        #expect(PaneInfoWheelRouting.isOverInfo(NSPoint(x: 650, y: 100), info: info, stack: stack))
        #expect(!PaneInfoWheelRouting.isOverInfo(NSPoint(x: 800, y: 100), info: info, stack: stack))
        #expect(!PaneInfoWheelRouting.isOverInfo(NSPoint(x: 100, y: 100), info: info, stack: stack))
        #expect(!PaneInfoWheelRouting.isOverInfo(NSPoint(x: 650, y: 100), info: info, stack: nil))
    }

    /// A cancelled gesture lets go.
    @Test func aCancelledGestureLetsGo() {
        var routing = PaneInfoWheelRouting()
        _ = step(&routing, phase: .began, momentumPhase: [], overInfo: true)
        #expect(step(&routing, phase: .cancelled, momentumPhase: [], overInfo: true))
        #expect(!routing.claimed)
    }
}
