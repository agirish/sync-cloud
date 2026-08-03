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
/// **Every pane this suite mounts gets its own `NotificationCenter`, and every post goes through
/// that same one.** A mounted `FileTreeView` is a live subscriber and `.default` is process-wide, so
/// a token — which names a SURFACE, not a test — cannot separate this suite's panes from the ones
/// other suites mount in parallel. That cut both ways: a foreign left pane accepted the `.left`
/// posts made here to prove a right pane ignores them (mechanism 9), and, worse, a foreign pane on
/// the surface a routing test uses as its POSITIVE control forgot that path for it — so the test
/// went green with the pane under test completely deaf. Neither is reachable through a channel
/// nobody else holds. See `docs/flaky-tests.md` mechanism 9.
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
        let channel: NotificationCenter

        var body: some View {
            FileTreeView(
                tree: box.tree,
                otherTree: PaneTree(side: isLeft ? .right : .left, version: 0, nodes: []),
                isLoading: false, currentPath: currentPath,
                selection: .constant([]), otherSelection: [],
                isLeft: isLeft, delegate: StubDelegate(),
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
    /// kept alive by the caller.
    ///
    /// The channel is what makes this pane the ONLY thing a post from this test can reach, and the
    /// only thing that can reach it — see the suite comment.
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

    /// Tears a mounted pane down at the end of the test that made it.
    ///
    /// **The pane holds a live `.cloudDownloadRequested` subscription**, and left to ARC it goes on
    /// holding it well past the test that made it. Since `mount` gives every pane a channel of its
    /// own, that afterlife can no longer be heard — a later post goes through a later channel — so
    /// this is now belt and braces rather than the load-bearing part. It was load-bearing while the
    /// panes shared `.default`: `theRightPaneIgnoresTheLeftPanesRequest` failed with
    /// `cached(ghost) == nil` in a full run and passed under `--filter`, for a `forget` a pane from
    /// an earlier test had run.
    private func teardown(_ window: NSWindow) {
        // Just the content view. `close()` releases a `.titled` window by default
        // (`isReleasedWhenClosed`), which over-releases the local reference and takes the whole test
        // process down with no verdict at all. Dropping the hosting view is what actually matters:
        // it is the last reference to the SwiftUI graph, so the subscription goes with it.
        window.contentView = nil
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
    /// actually sends, not one assembled here. `through` is the only argument the app leaves at its
    /// default; the routing decision the pane then makes is the same one either way.
    private func post(_ path: String, from token: PaneToken, through channel: NotificationCenter) {
        CloudDownloadRequest.post(path: path, from: token, through: channel)
    }

    // MARK: - Routing

    /// The positive control for the two ignore tests below: this harness, this timing, and a post
    /// the pane SHOULD take does reach the watch — which forgets the path on its way in.
    @Test func aPaneWatchesItsOwnRequest() async {
        let ghost = "/wiring/left/ghost.bin"
        CloudOnlyBadgeCache.clear(underRoot: "/wiring")
        let (window, _, channel) = mount(isLeft: true, currentPath: "/wiring/left")
        defer { teardown(window) }
        CloudOnlyBadgeCache.record(ghost, isCloudOnly: true)

        post(ghost, from: .left, through: channel)

        #expect(await settle(window) { CloudOnlyBadgeCache.cached(ghost) != true })
    }

    /// The right pane derives its OWN token: it must take a `.right` post. A receiver hardcoded to
    /// `.left` — the mutation this exists for — routes the whole app's downloads to one pane and
    /// passes every other test in the suite.
    @Test func theRightPaneWatchesItsOwnRequest() async {
        let ghost = "/wiring/right/ghost.bin"
        CloudOnlyBadgeCache.clear(underRoot: "/wiring")
        let (window, _, channel) = mount(isLeft: false, currentPath: "/wiring/right")
        defer { teardown(window) }
        CloudOnlyBadgeCache.record(ghost, isCloudOnly: true)

        post(ghost, from: .right, through: channel)

        #expect(await settle(window) { CloudOnlyBadgeCache.cached(ghost) != true })
    }

    /// The defect the scoping exists for: both panes default to the same provider, so the same
    /// absolute path can be on screen twice, and the pane that did NOT ask must not start a second
    /// watch (nor a second `forget`, which invalidates every in-flight badge stat in both panes).
    @Test func aPaneIgnoresTheOtherPanesRequest() async {
        await expectIgnored(mounting: (isLeft: true, isSingleSource: false),
                            at: "/wiring/left", from: .right, whileTaking: .left)
    }

    /// And in the other direction, which is what tells a correct receiver apart from one hardcoded
    /// to `.left`.
    @Test func theRightPaneIgnoresTheLeftPanesRequest() async {
        await expectIgnored(mounting: (isLeft: false, isSingleSource: false),
                            at: "/wiring/right", from: .left, whileTaking: .right)
    }

    /// The Tidy rail is a third surface, not the left pane: it passes `isLeft: true`, and taking
    /// the left pane's posts would have it watch downloads from a provider it is not showing.
    @Test func theSingleSourceRailIgnoresTheLeftPanesRequest() async {
        await expectIgnored(mounting: (isLeft: true, isSingleSource: true),
                            at: "/wiring/rail", from: .left, whileTaking: .singleSource)
    }

    /// Mounts a pane at `root`, posts one request it must IGNORE and then one it must TAKE, and
    /// asserts the first path is untouched once the second has been acted on.
    ///
    /// **The absence is bounded by the second post, not by a clock.** It used to be a 1s settle,
    /// which is the trap this repo has documented repeatedly: under the loads recorded here —
    /// deferred main-queue work landing 13s late — a wrongly ACCEPTED post whose `forget` arrives
    /// after the window closes passes the test with the defect fully present, and nothing would ever
    /// flag it. The two posts are delivered in order and accepting one forgets its path
    /// SYNCHRONOUSLY, inside `PaneDownloadWatch.begin` (which is why the forget lives there and not
    /// in the watch task), so a `forget` for the ignored path would necessarily have happened
    /// BEFORE the one this waits for. Seeing the second means the first has had its chance.
    ///
    /// **The taken post is the positive control, and only the pane under test can satisfy it.** It
    /// goes through this mount's own channel, which nothing else in the process holds — so a pane
    /// that had stopped watching its own requests altogether fails here rather than passing the
    /// absence vacuously. That was not true while every pane shared `.default`: with
    /// `takenToken == .singleSource` another suite's mounted rail forgot the path for us, and
    /// mutating the pane's `.onReceive` to drop EVERY post left this whole helper green.
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

        post(ignored, from: ignoredToken, through: channel)
        post(taken, from: takenToken, through: channel)

        #expect(await settle(window) { CloudOnlyBadgeCache.cached(taken) != true },
                "the pane never acted on its OWN request — the absence below proves nothing")
        #expect(CloudOnlyBadgeCache.cached(ignored) == true,
                "the pane acted on \(ignoredToken)'s request")
    }

    // MARK: - Two downloads at once

    /// Two downloads in ONE pane are two watches, not one.
    ///
    /// The pane held a single latch, watched by a `.task(id: awaitingDownload?.requestID)`, so a
    /// second request — a different file, queued back to back from the row menu — changed the id and
    /// cancelled the first watch. Request A's content then landed with nothing observing it: nobody
    /// recorded the landed answer, and the memo went on serving whatever the arming re-stat had left
    /// there until the next republish.
    ///
    /// Real files, not the ghosts the routing tests use, because this one needs both watches to
    /// CONCLUDE: `MaterializationStatus` answers a definite "not cloud-only" for a file that is
    /// there, and only a definite answer counts as landed.
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

        post(first, from: .left, through: channel)
        post(second, from: .left, through: channel)

        #expect(await settle(window, timeout: 20) {
            CloudOnlyBadgeCache.cached(first) == false && CloudOnlyBadgeCache.cached(second) == false
        }, "one of the two downloads was never watched to its end — first: \(String(describing: CloudOnlyBadgeCache.cached(first))), second: \(String(describing: CloudOnlyBadgeCache.cached(second)))")
    }

    /// The same file asked for twice is still ONE watch, and it is the NEWER request.
    ///
    /// Two watches on one path would mean two `CloudOnlyBadgeCache.forget` calls, and every forget
    /// bumps the memo generation, invalidating every in-flight badge stat in BOTH panes — verbatim
    /// the harm the pane-scoped payload exists to prevent. Keyed by request id instead of by path,
    /// that is exactly what a repeat Download would produce.
    ///
    /// Driven directly rather than through a mounted pane: the question is what the collection holds
    /// the instant the second request arrives, which is a synchronous fact, and reading it through
    /// the badge memo could only see it long after both watches had concluded. Paths under a
    /// throwaway directory so the bounded polls these start touch nothing another suite reads.
    @Test func aSecondRequestForOneFileSupersedesRatherThanAdds() {
        let dir = "/cloud-download-watch/\(UUID().uuidString)"
        let watch = PaneDownloadWatch()
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

    /// Superseding a path CANCELS the watch it replaces, rather than leaving it running.
    ///
    /// A leaked watch is invisible in the collection — the new request has already taken the slot —
    /// and its only trace in the app is a second `CloudOnlyBadgeCache.forget`, which nothing counts.
    /// So the watch is injected here and reports its own cancellation. Every wait below is bounded
    /// by a deadline the watch itself enforces; nothing spins.
    @Test func aRepeatRequestCancelsTheWatchItReplaces() async {
        let log = WatchLog()
        let watch = PaneDownloadWatch { request, _ in
            log.started.insert(request.requestID)
            // A cancelled task's sleep throws at once, so this both parks the watch and detects the
            // cancellation — with a ceiling, so a watch nobody cancels ends on its own.
            if (try? await Task.sleep(for: .seconds(45))) == nil {
                log.cancelled.insert(request.requestID)
            }
            return false
        }
        let dir = "/cloud-download-watch/\(UUID().uuidString)"
        let first = CloudDownloadRequest(path: "\(dir)/first.bin", paneToken: .left)
        let firstAgain = CloudDownloadRequest(path: first.path, paneToken: .left)
        let other = CloudDownloadRequest(path: "\(dir)/other.bin", paneToken: .left)

        watch.begin(first)
        watch.begin(other)
        watch.begin(firstAgain)

        // A generous ceiling, because this waits for something to HAPPEN rather than bounding an
        // absence: the watch task is main-actor isolated, and in a full parallel run the main actor
        // is contended enough that this repo has measured deferred work landing 13s late. A short
        // deadline here would report starvation as a missing cancellation.
        #expect(await hold(upTo: 30) { log.cancelled.contains(first.requestID) },
                "the superseded watch for \(first.path) is still running")
        #expect(log.started.contains(firstAgain.requestID), "the repeat request started no watch")
        #expect(!log.cancelled.contains(other.requestID),
                "superseding one path cancelled another path's watch")
        // And the watch that just ended must not take the slot with it. A cancelled task still runs
        // everything after its last `await`, so the superseded watch reaches its conclusion AFTER
        // the new one took the path — `CloudDownloadRequest.concludes(latch:)` comparing request ids
        // is the only thing between that and a watch being killed a moment after it started.
        #expect(watch.request(forPath: first.path)?.requestID == firstAgain.requestID,
                "the superseded watch cleared the slot its replacement had taken")
    }

    /// What an injected watch reports back.
    @MainActor private final class WatchLog {
        var started: Set<UUID> = []
        var cancelled: Set<UUID> = []
    }

    /// Yields until `condition` holds or the deadline passes — no window to pump here, since nothing
    /// is mounted. Returns whether it held.
    private func hold(upTo seconds: Double, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
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
        let (window, box, _) = mount(isLeft: true, currentPath: "/wiring/provider/sub",
                                     rootPath: "/wiring/provider")
        defer { teardown(window) }
        CloudOnlyBadgeCache.record(inside, isCloudOnly: true)
        CloudOnlyBadgeCache.record(outside, isCloudOnly: true)

        box.tree = Self.tree(2, root: "/wiring/provider/sub")   // the republish

        #expect(await settle(window) { CloudOnlyBadgeCache.cached(inside) == nil })
        #expect(CloudOnlyBadgeCache.cached(outside) == true)
    }
}
