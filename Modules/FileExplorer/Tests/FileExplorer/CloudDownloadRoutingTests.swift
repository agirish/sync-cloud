import Testing
import Foundation
@testable import FileExplorer

/// Pins the pane-scoping of `.cloudDownloadRequested`. Both panes default to the same provider, so
/// one path can be on screen twice; only the requesting pane may latch the download, or twin rows
/// both poll and the duplicate `forget` bumps the badge memo app-wide. These tests drive the routing
/// decision, `CloudDownloadRequest.accepted(from:paneToken:)`.
struct CloudDownloadRoutingTests {

    private func notification(_ request: CloudDownloadRequest) -> Notification {
        Notification(name: .cloudDownloadRequested, object: request)
    }

    /// The requesting pane latches its own post; the other pane, showing a twin row for the same
    /// path, must not.
    @Test func theOtherPaneIgnoresThePost() {
        let request = CloudDownloadRequest(path: "/iCloud/report.pdf", paneToken: .left)

        #expect(CloudDownloadRequest.accepted(from: notification(request), paneToken: .left) == request)
        #expect(CloudDownloadRequest.accepted(from: notification(request), paneToken: .right) == nil)
        #expect(CloudDownloadRequest.accepted(from: notification(request), paneToken: .singleSource) == nil)
    }

    /// A payload this build doesn't recognise, such as a bare path, routes nowhere rather than into
    /// every pane.
    @Test func anUnrecognisedPayloadRoutesNowhere() {
        let legacy = Notification(name: .cloudDownloadRequested, object: "/iCloud/report.pdf")

        #expect(CloudDownloadRequest.accepted(from: legacy, paneToken: .left) == nil)
        #expect(CloudDownloadRequest.accepted(from: legacy, paneToken: .right) == nil)
    }

    /// The round trip through `NotificationCenter`: what `post` sends, the posting pane accepts and
    /// every other pane declines. On a private channel, because an observer on `.default` hears
    /// other suites' posts and would fail on a stranger's request (`docs/flaky-tests.md`, "A mounted
    /// view is a live subscriber, in every suite at once"). `theDefaultChannelIsTheAppsOwn` pins
    /// `.default`.
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

    /// `post`'s default channel, which the app uses and no other test reaches: a default of
    /// `NotificationCenter()` would pass every other test while the Download button announced to
    /// nobody. The pane's half is
    /// `FileTreeViewPaneNameTests.testAPaneMountsOnTheAppsChannelByDefault`.
    /// Observing `.default` is safe only because the path is unique per run. This post is harmless
    /// only while no test mounts a pane on `.default`; one that did would arm a real watch on a
    /// missing path for the poll's whole budget, which is why every mounting test takes a private
    /// channel.
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

    /// The three pane surfaces map to three distinct tokens; the single-source rail isn't mistaken
    /// for the left pane just because both may pass `isLeft == true`.
    @Test func paneTokensAreDistinctPerSurface() {
        #expect(PaneToken(isLeft: true, isSingleSource: false) == .left)
        #expect(PaneToken(isLeft: false, isSingleSource: false) == .right)
        #expect(PaneToken(isLeft: true, isSingleSource: true) == .singleSource)
        #expect(PaneToken(isLeft: false, isSingleSource: true) == .singleSource)
    }

    /// A repeat download of the same file must re-key the row's badge task. `.task(id:)` re-runs
    /// exactly when its id compares unequal, so the key's `==` is the behaviour.
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

    /// A row the pane isn't watching keeps a stable key, so nothing re-stats while another file
    /// downloads, and only the requested file's row watches. `PaneDownloadWatch` is keyed by path,
    /// so the row's lookup is a dictionary hit, not a comparison a caller could get backwards.
    @MainActor @Test func onlyTheRequestedPathIsWatched() {
        // Returns at once without concluding, which keeps the slot: `begin` clears `requests` only
        // for a watch that reports `true`. A sleep would only hold the main actor after the test.
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
