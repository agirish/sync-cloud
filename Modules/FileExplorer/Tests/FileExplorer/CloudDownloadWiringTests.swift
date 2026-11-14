import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// The half `CloudDownloadRoutingTests` can't see: that a mounted pane really routes through that
/// decision and clears its badge memo under the shown folder. Observed through the memo, the one
/// thing outside the pane it touches, on "ghost" paths under `/wiring` with no row (a row would
/// re-stat its path under the assertion). Every pane gets a private `NotificationCenter`, since a
/// token names a surface, not a test (`docs/flaky-tests.md`, "A mounted view is a live subscriber,
/// in every suite at once"). `.serialized` because the memo is process-wide.
@MainActor
@Suite(.serialized) struct CloudDownloadWiringTests {

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
        let channel: NotificationCenter

        var body: some View {
            FileTreeView(
                tree: box.tree,
                otherTree: PaneTree(side: isLeft ? .right : .left, version: 0, nodes: []),
                isLoading: false, currentPath: currentPath,
                selection: .constant([]), otherSelection: [],
                isLeft: isLeft, delegate: NoOpFileActionDelegate(),
                rootPath: rootPath,
                isSingleSource: isSingleSource,
                downloadChannel: channel
            )
        }
    }

    private static func tree(_ version: Int, root: String) -> PaneTree {
        PaneTree(side: .left, version: version,
                 nodes: [FileNode(id: "\(root)/row.bin", name: "row.bin", isDirectory: false)])
    }

    /// Mounts a pane on a channel of its own and returns it with its window and that channel, all
    /// kept alive by the caller. The channel makes this pane the only thing this test's posts reach.
    private func mount(isLeft: Bool, isSingleSource: Bool = false,
                       currentPath: String, rootPath: String? = nil) -> (NSWindow, Box, NotificationCenter) {
        let box = Box(Self.tree(1, root: currentPath))
        let channel = NotificationCenter()
        let host = NSHostingView(rootView: Harness(box: box, isLeft: isLeft,
                                                   isSingleSource: isSingleSource,
                                                   currentPath: currentPath, rootPath: rootPath,
                                                   channel: channel))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        return (window, box, channel)
    }

    /// Tears a mounted pane down at the end of its test. Left to ARC, the pane's live
    /// `.cloudDownloadRequested` subscription outlives the test; with a private channel per mount
    /// nobody can post to it, so this is belt and braces.
    private func teardown(_ window: NSWindow) {
        // Just the content view: `close()` releases a `.titled` window by default
        // (`isReleasedWhenClosed`), over-releasing the local reference and crashing the test
        // process. The hosting view is the last reference to the SwiftUI graph, so the subscription
        // goes with it.
        window.contentView = nil
    }

    // MARK: - Routing

    /// Both panes default to the same provider, so one path can be on screen twice; the pane that
    /// didn't ask must not start a second watch, nor a second `forget`, which invalidates every
    /// in-flight badge stat in both panes.
    @Test func aPaneIgnoresTheOtherPanesRequest() async {
        await expectIgnored(mounting: (isLeft: true, isSingleSource: false),
                            at: "/wiring/left", from: .right, whileTaking: .left)
    }

    /// The other direction, which tells a correct receiver from one hardcoded to `.left`.
    @Test func theRightPaneIgnoresTheLeftPanesRequest() async {
        await expectIgnored(mounting: (isLeft: false, isSingleSource: false),
                            at: "/wiring/right", from: .left, whileTaking: .right)
    }

    /// The single-source rail is a third surface, not the left pane: it passes `isLeft: true`, and
    /// taking the left pane's posts would watch downloads from a provider it isn't showing.
    @Test func theSingleSourceRailIgnoresTheLeftPanesRequest() async {
        await expectIgnored(mounting: (isLeft: true, isSingleSource: true),
                            at: "/wiring/rail", from: .left, whileTaking: .singleSource)
    }

    /// Mounts a pane at `root`, posts one request it must ignore and then one it must take, and
    /// asserts the first path is untouched once the second has been acted on.
    ///
    /// The absence is bounded by the second post, not a clock: under load a wrongly accepted
    /// `forget` could land after any settle and pass. Posts arrive in order and acceptance forgets
    /// synchronously in `PaneDownloadWatch.begin`, so once the second is seen the first had its
    /// chance. The taken post is the positive control, and on this mount's private channel only
    /// the pane under test can satisfy it, so a pane that drops every post fails here.
    private func expectIgnored(mounting surface: (isLeft: Bool, isSingleSource: Bool),
                               at root: String, from ignoredToken: PaneToken,
                               whileTaking takenToken: PaneToken) async {
        let ignored = "\(root)/ignored.bin"
        let taken = "\(root)/taken.bin"
        CloudOnlyBadgeCache.clear(underRoot: "/wiring")
        let (window, _, channel) = mount(isLeft: surface.isLeft,
                                         isSingleSource: surface.isSingleSource,
                                         currentPath: root)
        defer { teardown(window) }
        CloudOnlyBadgeCache.record(ignored, isCloudOnly: true)
        CloudOnlyBadgeCache.record(taken, isCloudOnly: true)

        CloudDownloadRequest.post(path: ignored, from: ignoredToken, through: channel)
        CloudDownloadRequest.post(path: taken, from: takenToken, through: channel)

        #expect(await LayoutPumpWait.pump(window, upTo: 3) { CloudOnlyBadgeCache.cached(taken) != true }.held,
                "the pane never acted on its OWN request — the absence below proves nothing")
        #expect(CloudOnlyBadgeCache.cached(ignored) == true,
                "the pane acted on \(ignoredToken)'s request")
    }

    // MARK: - Two downloads at once

    /// Two downloads in one pane are two watches. With a single latch, a second file queued from the
    /// row menu would cancel the first watch, and the first file's landing would go unrecorded
    /// until the next republish.
    ///
    /// Real files, not ghosts, because both watches must conclude: `MaterializationStatus` answers a
    /// definite "not cloud-only" for a file that is there, and only a definite answer is a landing.
    @Test func aSecondDownloadInThePaneDoesNotOrphanTheFirst() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CloudDownloadWiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("first.bin").path
        let second = dir.appendingPathComponent("second.bin").path
        try Data("a".utf8).write(to: URL(fileURLWithPath: first))
        try Data("b".utf8).write(to: URL(fileURLWithPath: second))

        CloudOnlyBadgeCache.clear(underRoot: dir.path)
        let (window, _, channel) = mount(isLeft: true, currentPath: dir.path)
        defer { teardown(window) }
        CloudOnlyBadgeCache.record(first, isCloudOnly: true)
        CloudOnlyBadgeCache.record(second, isCloudOnly: true)

        CloudDownloadRequest.post(path: first, from: .left, through: channel)
        CloudDownloadRequest.post(path: second, from: .left, through: channel)

        #expect(await LayoutPumpWait.pump(window, upTo: 20) {
            CloudOnlyBadgeCache.cached(first) == false && CloudOnlyBadgeCache.cached(second) == false
        }.held, "one of the two downloads was never watched to its end — first: \(String(describing: CloudOnlyBadgeCache.cached(first))), second: \(String(describing: CloudOnlyBadgeCache.cached(second)))")
    }

    /// The same file asked for twice is still one watch, the newer request. Keyed by request id
    /// rather than path, there would be two, and the older one's conclusion would clear the newer
    /// one's slot. (A repeat Download still costs a second forget, rightly: the memo's answer is
    /// stale again. See `PaneDownloadWatch`.)
    ///
    /// Driven directly, not through a pane: what the collection holds when the second request
    /// arrives is a synchronous fact the memo would show only after both watches end. Paths under
    /// a throwaway directory, so nothing another suite reads is touched.
    @Test func aSecondRequestForOneFileSupersedesRatherThanAdds() {
        let dir = "/cloud-download-watch/\(UUID().uuidString)"
        // Injected, returning at once without concluding, so the slot is held as a real poll would
        // hold it with nothing left running. The default, `CloudDownloadPoll.watch`, is a real poll
        // that would go on probing and holding the main actor after the verdict.
        let watch = PaneDownloadWatch { _, _ in false }
        let first = CloudDownloadRequest(path: "\(dir)/first.bin", paneToken: .left)
        let other = CloudDownloadRequest(path: "\(dir)/other.bin", paneToken: .left)
        let firstAgain = CloudDownloadRequest(path: first.path, paneToken: .left)

        watch.begin(first)
        watch.begin(other)
        #expect(watch.requests.count == 2, "two files are two watches")

        watch.begin(firstAgain)
        #expect(watch.requests.count == 2, "a repeat of one file added a second watch for it")
        #expect(watch.request(forPath: first.path)?.requestID == firstAgain.requestID,
                "the older request still holds the slot, so the new watch cannot conclude")
        #expect(watch.request(forPath: other.path)?.requestID == other.requestID,
                "the repeat disturbed the OTHER file's watch")
    }

    /// Superseding a path cancels the watch it replaces. A leaked watch shows neither in the
    /// collection (the new request holds the slot) nor in the memo (it records what the live one
    /// will), so the injected watch reports its own cancellation. Every wait is bounded; nothing
    /// spins.
    @Test func aRepeatRequestCancelsTheWatchItReplaces() async {
        let log = WatchLog()
        // Released on the way out, so the two watches this test doesn't cancel aren't still parked,
        // holding this watch and its log, while other suites run.
        let park = WatchPark()
        defer { park.release() }
        let watch = PaneDownloadWatch { request, _ in
            log.started.insert(request.requestID)
            if await park.park(upTo: 45) { log.cancelled.insert(request.requestID) }
            return false
        }
        let dir = "/cloud-download-watch/\(UUID().uuidString)"
        let first = CloudDownloadRequest(path: "\(dir)/first.bin", paneToken: .left)
        let firstAgain = CloudDownloadRequest(path: first.path, paneToken: .left)
        let other = CloudDownloadRequest(path: "\(dir)/other.bin", paneToken: .left)

        watch.begin(first)
        watch.begin(other)
        watch.begin(firstAgain)

        // Generous, because it waits for something to happen rather than bounding an absence: on a
        // contended main actor a short deadline would report starvation as a missing cancellation.
        #expect(await LayoutPumpWait.poll(upTo: 30) { log.cancelled.contains(first.requestID) }.held,
                "the superseded watch for \(first.path) is still running")
        #expect(log.started.contains(firstAgain.requestID), "the repeat request started no watch")
        #expect(!log.cancelled.contains(other.requestID),
                "superseding one path cancelled another path's watch")
        // The ended watch must not take the slot with it. A cancelled task still runs everything
        // after its last `await`, so it concludes after the new one took the path; only
        // `CloudDownloadRequest.concludes(latch:)` comparing request ids keeps it from clearing it.
        #expect(watch.request(forPath: first.path)?.requestID == firstAgain.requestID,
                "the superseded watch cleared the slot its replacement had taken")
    }

    /// What an injected watch reports back.
    @MainActor private final class WatchLog {
        var started: Set<UUID> = []
        var cancelled: Set<UUID> = []
    }

    /// Parks an injected watch until the test releases it, reporting cancellation as a real poll's
    /// interrupted sleep does. Sliced, not one long sleep: the ceiling bounds a watch nobody
    /// releases, and a released one ends within a slice instead of keeping its `PaneDownloadWatch`
    /// and captures alive on the main actor while other suites run.
    @MainActor private final class WatchPark {
        private var released = false

        func release() { released = true }

        /// Whether the watch was cancelled; `false` means released or out of time. A cancelled
        /// `Task.sleep` throws at once, which tells the two apart.
        func park(upTo seconds: Double) async -> Bool {
            let ceiling = Date().addingTimeInterval(seconds)
            while !released, Date() < ceiling {
                if (try? await Task.sleep(for: .milliseconds(20))) == nil { return true }
            }
            return false
        }
    }

    // MARK: - The republish clear's root

    /// A republish clears the memo under the folder the pane is showing. Focused on a subfolder,
    /// `currentPath` and `rootPath` differ, and clearing under `rootPath` would drop entries no row
    /// here can serve, including the other pane's on a shared root. The two ghosts tell them apart.
    @Test func aRepublishClearsUnderTheShownFolderNotTheProviderRoot() async {
        let inside = "/wiring/provider/sub/ghost.bin"
        let outside = "/wiring/provider/elsewhere/ghost.bin"
        CloudOnlyBadgeCache.clear(underRoot: "/wiring")
        let (window, box, _) = mount(isLeft: true, currentPath: "/wiring/provider/sub",
                                     rootPath: "/wiring/provider")
        defer { teardown(window) }
        CloudOnlyBadgeCache.record(inside, isCloudOnly: true)
        CloudOnlyBadgeCache.record(outside, isCloudOnly: true)

        box.tree = Self.tree(2, root: "/wiring/provider/sub")   // the republish

        #expect(await LayoutPumpWait.pump(window, upTo: 3) { CloudOnlyBadgeCache.cached(inside) == nil }.held)
        #expect(CloudOnlyBadgeCache.cached(outside) == true)
    }
}
