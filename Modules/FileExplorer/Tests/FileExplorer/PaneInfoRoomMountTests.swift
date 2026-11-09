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
