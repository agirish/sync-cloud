import Testing
import Foundation
@testable import FileExplorer

/// Pins the pane-scoping of `.cloudDownloadRequested` (C10).
///
/// Both panes default to the same provider, so the same absolute path can be on screen twice. The
/// notification used to carry only the path, and both panes latched it: twin rows entered the
/// awaiting state, both ran the bounded download poll, and the duplicate `forget` bumped the badge
/// memo's generation app-wide. `CloudDownloadRequest.accepted(from:paneToken:)` is the extracted
/// routing decision these tests drive.
struct CloudDownloadRoutingTests {

    private func notification(_ request: CloudDownloadRequest) -> Notification {
        Notification(name: .cloudDownloadRequested, object: request)
    }

    @Test func theRequestingPaneAcceptsItsOwnPost() {
        let request = CloudDownloadRequest(path: "/iCloud/report.pdf", paneToken: .left)

        let accepted = CloudDownloadRequest.accepted(from: notification(request), paneToken: .left)

        #expect(accepted == request)
    }

    /// The defect: the other pane, showing a twin row for the very same path, must NOT latch it.
    @Test func theOtherPaneIgnoresThePost() {
        let request = CloudDownloadRequest(path: "/iCloud/report.pdf", paneToken: .left)

        #expect(CloudDownloadRequest.accepted(from: notification(request), paneToken: .right) == nil)
        #expect(CloudDownloadRequest.accepted(from: notification(request), paneToken: .singleSource) == nil)
    }

    /// A payload this build does not recognise (e.g. the old bare-path post) routes nowhere at
    /// all rather than into every pane.
    @Test func anUnrecognisedPayloadRoutesNowhere() {
        let legacy = Notification(name: .cloudDownloadRequested, object: "/iCloud/report.pdf")

        #expect(CloudDownloadRequest.accepted(from: legacy, paneToken: .left) == nil)
        #expect(CloudDownloadRequest.accepted(from: legacy, paneToken: .right) == nil)
    }

    /// The round trip through `NotificationCenter`, from the one poster both Download buttons use
    /// to the routing decision every pane applies: what `post` sends is exactly what the posting
    /// pane accepts, and what every other pane declines.
    ///
    /// Through a channel of this test's own, not `.default`: an observer on `.default` picks up
    /// whatever any suite running in parallel posts, and `received` would then be somebody else's
    /// request — the assertions below would fail naming a routing defect that was never there. The
    /// `.default` the app actually runs on is pinned by `theDefaultChannelIsTheAppsOwn` below. See
    /// `docs/flaky-tests.md` mechanism 9.
    @Test func aPostedRequestIsAcceptedByItsOwnPaneAlone() async {
        let path = "/iCloud/posted.pdf"
        var received: Notification?
        let channel = NotificationCenter()
        let observer = channel.addObserver(
            forName: .cloudDownloadRequested, object: nil, queue: nil) { received = $0 }
        defer { channel.removeObserver(observer) }

        let posted = CloudDownloadRequest.post(path: path, from: .right, through: channel)

        let notification = try! #require(received)
        #expect(CloudDownloadRequest.accepted(from: notification, paneToken: .right) == posted)
        #expect(CloudDownloadRequest.accepted(from: notification, paneToken: .left) == nil)
        #expect(CloudDownloadRequest.accepted(from: notification, paneToken: .singleSource) == nil)
    }

    /// The channel argument every test above supplies is the one thing the APP never passes, so its
    /// default is the only part of `post` no other test can reach.
    ///
    /// That default used to be covered incidentally: while `ColumnPreviewDownloadWiringTests`
    /// mounted its pane on `.default`, a default post really did travel to a default-channel pane
    /// once per run. Every mounting suite now carries a channel of its own (mechanism 9), so
    /// nothing exercised `.default` at all — and `post(…, through: NotificationCenter())` would
    /// have gone on satisfying every other test in this file while the app's own Download button
    /// announced into a void nothing subscribes to. The pane's half of the same default is pinned
    /// by `FileTreeViewPaneNameTests.testAPaneMountsOnTheAppsChannelByDefault`.
    ///
    /// **Observing `.default` is safe here only because of the path filter.** Suites run in
    /// parallel and any of them may post; a bare `received = $0` would latch a stranger's request
    /// and this test would pass on it. The path is unique per run, so what arrives under it can
    /// only have come from the call below, and the observer is removed on the way out.
    ///
    /// **The post is the half that needs the rule, and it runs the other way.** This test cannot
    /// pin the default without putting a real `.cloudDownloadRequested` on `.default`, which makes
    /// it the only thing in the target that does. Nothing hears it: `FileTreeView`'s `.onReceive`
    /// is the sole subscriber to that name anywhere in the codebase, and no test mounts a pane on
    /// `.default` any more (mechanism 9). So the two depend on each other — mount a pane on
    /// `.default` again and this post arms a real `.left` watch inside it, on a path with no file
    /// behind it, for the poll's full ten-second budget. That is the same collision from the
    /// posting side, and the reason the rule is stated as *every* mounting test.
    @Test func theDefaultChannelIsTheAppsOwn() {
        let path = "/iCloud/default-channel-\(UUID().uuidString).pdf"
        var received: CloudDownloadRequest?
        let observer = NotificationCenter.default.addObserver(
            forName: .cloudDownloadRequested, object: nil, queue: nil) { note in
                guard let request = note.object as? CloudDownloadRequest,
                      request.path == path else { return }
                received = request
            }
        defer { NotificationCenter.default.removeObserver(observer) }

        // No `through:` — exactly what `CloudDownloadRequest.post`'s two real call sites pass.
        let posted = CloudDownloadRequest.post(path: path, from: .left)

        // Synchronous: `NotificationCenter.post` delivers to a `queue: nil` observer inline, so a
        // nil here is a post that never reached `.default` rather than one still in flight.
        #expect(received == posted, "a default post did not arrive on the channel the app runs on")
    }

    /// The three pane surfaces map onto three distinct tokens — in particular the single-source rail is not
    /// confusable with the left pane just because both may pass `isLeft == true`.
    @Test func paneTokensAreDistinctPerSurface() {
        #expect(PaneToken(isLeft: true, isSingleSource: false) == .left)
        #expect(PaneToken(isLeft: false, isSingleSource: false) == .right)
        #expect(PaneToken(isLeft: true, isSingleSource: true) == .singleSource)
        #expect(PaneToken(isLeft: false, isSingleSource: true) == .singleSource)
    }

    /// Repeat downloads of the SAME file must re-key the row's badge task, and this pins that
    /// claim where `.task(id:)` can actually be reasoned about: it re-runs exactly when its id
    /// compares unequal, so the key's `==` IS the behaviour.
    ///
    /// (It replaces an assertion that two fresh `UUID()`s differ, which was true of `UUID` rather
    /// than of anything this code does.)
    @Test func aRepeatDownloadReKeysTheRowsBadgeTask() {
        let path = "/iCloud/big.mov"
        let first = CloudDownloadRequest(path: path, paneToken: .left)
        let second = CloudDownloadRequest(path: path, paneToken: .left)

        let idle = FileRowView.BadgeID(path: path, awaitingDownloadID: nil)
        let watchingFirst = FileRowView.BadgeID(path: path, awaitingDownloadID: first.requestID)
        let watchingSecond = FileRowView.BadgeID(path: path, awaitingDownloadID: second.requestID)

        // Arming the watch re-resolves the badge, and so does concluding it (idle → watching → idle).
        #expect(idle != watchingFirst)
        // The case a Bool could not express: a second download arriving while the first is still in
        // flight moves the latch straight from one request to the next, with no idle in between.
        #expect(watchingFirst != watchingSecond)
    }

    /// A row the pane is not watching keeps a stable key, so nothing re-stats while another file
    /// downloads — and only the requested file's row watches.
    ///
    /// The lookup is the pane's own: `PaneDownloadWatch` is keyed by path, and the row is handed
    /// `requests[node.id]?.requestID`, so "is this row's file being downloaded" is a dictionary hit
    /// rather than a comparison a caller could get backwards.
    @MainActor @Test func onlyTheRequestedPathIsWatched() {
        // Returns at once WITHOUT concluding, which is what keeps the slot: `begin` clears
        // `requests` only for a watch that reports `true`. A sleep here would hold the same slot
        // the same way and go on occupying the main actor for five seconds after this test had
        // finished — every assertion below is synchronous bookkeeping, so it bought nothing.
        let watch = PaneDownloadWatch { _, _ in false }
        let request = CloudDownloadRequest(path: "/iCloud/report.pdf", paneToken: .right)
        watch.begin(request)

        #expect(watch.request(forPath: "/iCloud/report.pdf")?.requestID == request.requestID)
        #expect(watch.request(forPath: "/iCloud/other.pdf") == nil)
        #expect(FileRowView.BadgeID(path: "/iCloud/other.pdf",
                                    awaitingDownloadID: watch.request(forPath: "/iCloud/other.pdf")?.requestID)
                == FileRowView.BadgeID(path: "/iCloud/other.pdf", awaitingDownloadID: nil))
    }
}
