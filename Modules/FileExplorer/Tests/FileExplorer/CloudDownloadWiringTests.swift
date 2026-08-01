import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// The half `CloudDownloadRoutingTests` cannot see: that a mounted pane actually ROUTES through
/// the decision that file pins, and clears its badge memo under the root it claims to.
///
/// Every test in that file drives an extracted helper with tokens and roots the test made up. The
/// call sites — the pane's `.onReceive`, its republish clear — are three expressions inside SwiftUI
/// closures, and each of them passed green while mutated: accepting every post regardless of pane,
/// hardcoding the receiving pane's token, clearing under `rootPath` instead of `currentPath`.
///
/// The observation channel is the badge memo, because it is the only externally visible thing the
/// pane touches: accepting a request forgets that path (`CloudDownloadPoll.watch`), and a republish
/// clears under one root or the other. Fixtures live under `/wiring`, which nothing else uses, and
/// the paths asserted on are "ghosts" with no row in the tree — a realized row would re-stat its
/// own path and write the answer back underneath the assertion.
///
/// `.serialized` because the memo is process-wide.
@MainActor
@Suite(.serialized) struct CloudDownloadWiringTests {

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

    private final class Box: ObservableObject {
        @Published var tree: PaneTree
        init(_ tree: PaneTree) { self.tree = tree }
    }

    private struct Harness: View {
        @ObservedObject var box: Box
        let isLeft: Bool
        let isSingleSource: Bool
        let currentPath: String
        let rootPath: String?

        var body: some View {
            FileTreeView(
                tree: box.tree,
                otherTree: PaneTree(side: isLeft ? .right : .left, version: 0, nodes: []),
                isLoading: false, currentPath: currentPath,
                selection: .constant([]), otherSelection: [],
                isLeft: isLeft, delegate: StubDelegate(),
                rootPath: rootPath,
                isSingleSource: isSingleSource
            )
        }
    }

    private static func tree(_ version: Int, root: String) -> PaneTree {
        PaneTree(side: .left, version: version,
                 nodes: [FileNode(id: "\(root)/row.bin", name: "row.bin", isDirectory: false)])
    }

    /// Mounts a pane and returns it with its window, kept alive by the caller.
    private func mount(isLeft: Bool, isSingleSource: Bool = false,
                       currentPath: String, rootPath: String? = nil) -> (NSWindow, Box) {
        let box = Box(Self.tree(1, root: currentPath))
        let host = NSHostingView(rootView: Harness(box: box, isLeft: isLeft,
                                                   isSingleSource: isSingleSource,
                                                   currentPath: currentPath, rootPath: rootPath))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        return (window, box)
    }

    /// Turns the run loop until `condition` holds, or the timeout expires. Returns whether it held,
    /// so a caller asserts on the answer rather than assuming it.
    @discardableResult
    private func settle(_ window: NSWindow, timeout: Double = 3, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            window.layoutIfNeeded()
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        window.layoutIfNeeded()
        return condition()
    }

    /// The real poster both Download buttons use — so these tests exercise the payload the app
    /// actually sends, not one assembled here.
    private func post(_ path: String, from token: PaneToken) {
        CloudDownloadRequest.post(path: path, from: token)
    }

    // MARK: - Routing

    /// The positive control for the two ignore tests below: this harness, this timing, and a post
    /// the pane SHOULD take does reach the watch — which forgets the path on its way in.
    @Test func aPaneWatchesItsOwnRequest() async {
        let ghost = "/wiring/left/ghost.bin"
        CloudOnlyBadgeCache.clear(underRoot: "/wiring")
        let (window, _) = mount(isLeft: true, currentPath: "/wiring/left")
        CloudOnlyBadgeCache.record(ghost, isCloudOnly: true)

        post(ghost, from: .left)

        #expect(await settle(window) { CloudOnlyBadgeCache.cached(ghost) != true })
    }

    /// The right pane derives its OWN token: it must take a `.right` post. A receiver hardcoded to
    /// `.left` — the mutation this exists for — routes the whole app's downloads to one pane and
    /// passes every other test in the suite.
    @Test func theRightPaneWatchesItsOwnRequest() async {
        let ghost = "/wiring/right/ghost.bin"
        CloudOnlyBadgeCache.clear(underRoot: "/wiring")
        let (window, _) = mount(isLeft: false, currentPath: "/wiring/right")
        CloudOnlyBadgeCache.record(ghost, isCloudOnly: true)

        post(ghost, from: .right)

        #expect(await settle(window) { CloudOnlyBadgeCache.cached(ghost) != true })
    }

    /// The defect the scoping exists for: both panes default to the same provider, so the same
    /// absolute path can be on screen twice, and the pane that did NOT ask must not start a second
    /// watch (nor a second `forget`, which invalidates every in-flight badge stat in both panes).
    @Test func aPaneIgnoresTheOtherPanesRequest() async {
        let ghost = "/wiring/left/ignored.bin"
        CloudOnlyBadgeCache.clear(underRoot: "/wiring")
        let (window, _) = mount(isLeft: true, currentPath: "/wiring/left")
        CloudOnlyBadgeCache.record(ghost, isCloudOnly: true)

        post(ghost, from: .right)

        // Given the positive control above, "still holding after a full settle window" means the
        // post was ignored rather than merely slow.
        await settle(window, timeout: 1) { CloudOnlyBadgeCache.cached(ghost) != true }
        #expect(CloudOnlyBadgeCache.cached(ghost) == true)
    }

    /// And in the other direction, which is what tells a correct receiver apart from one hardcoded
    /// to `.left`.
    @Test func theRightPaneIgnoresTheLeftPanesRequest() async {
        let ghost = "/wiring/right/ignored.bin"
        CloudOnlyBadgeCache.clear(underRoot: "/wiring")
        let (window, _) = mount(isLeft: false, currentPath: "/wiring/right")
        CloudOnlyBadgeCache.record(ghost, isCloudOnly: true)

        post(ghost, from: .left)

        await settle(window, timeout: 1) { CloudOnlyBadgeCache.cached(ghost) != true }
        #expect(CloudOnlyBadgeCache.cached(ghost) == true)
    }

    /// The Tidy rail is a third surface, not the left pane: it passes `isLeft: true`, and taking
    /// the left pane's posts would have it watch downloads from a provider it is not showing.
    @Test func theSingleSourceRailIgnoresTheLeftPanesRequest() async {
        let ghost = "/wiring/rail/ignored.bin"
        CloudOnlyBadgeCache.clear(underRoot: "/wiring")
        let (window, _) = mount(isLeft: true, isSingleSource: true, currentPath: "/wiring/rail")
        CloudOnlyBadgeCache.record(ghost, isCloudOnly: true)

        post(ghost, from: .left)

        await settle(window, timeout: 1) { CloudOnlyBadgeCache.cached(ghost) != true }
        #expect(CloudOnlyBadgeCache.cached(ghost) == true)
    }

    // MARK: - The republish clear's root

    /// A republish clears the memo under the folder the pane is SHOWING. With the pane focused on
    /// a subfolder, `currentPath` and `rootPath` diverge, and clearing under `rootPath` would drop
    /// entries no row of this pane can serve — including, on a shared provider root, the other
    /// pane's. The two ghosts are what tell those apart.
    @Test func aRepublishClearsUnderTheShownFolderNotTheProviderRoot() async {
        let inside = "/wiring/provider/sub/ghost.bin"
        let outside = "/wiring/provider/elsewhere/ghost.bin"
        CloudOnlyBadgeCache.clear(underRoot: "/wiring")
        let (window, box) = mount(isLeft: true, currentPath: "/wiring/provider/sub",
                                  rootPath: "/wiring/provider")
        CloudOnlyBadgeCache.record(inside, isCloudOnly: true)
        CloudOnlyBadgeCache.record(outside, isCloudOnly: true)

        box.tree = Self.tree(2, root: "/wiring/provider/sub")   // the republish

        #expect(await settle(window) { CloudOnlyBadgeCache.cached(inside) == nil })
        #expect(CloudOnlyBadgeCache.cached(outside) == true)
    }
}
