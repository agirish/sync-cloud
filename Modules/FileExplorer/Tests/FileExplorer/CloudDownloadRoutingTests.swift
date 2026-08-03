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
    @Test func aPostedRequestIsAcceptedByItsOwnPaneAlone() async {
        let path = "/iCloud/posted.pdf"
        var received: Notification?
        let observer = NotificationCenter.default.addObserver(
            forName: .cloudDownloadRequested, object: nil, queue: nil) { received = $0 }
        defer { NotificationCenter.default.removeObserver(observer) }

        let posted = CloudDownloadRequest.post(path: path, from: .right)

        let notification = try! #require(received)
        #expect(CloudDownloadRequest.accepted(from: notification, paneToken: .right) == posted)
        #expect(CloudDownloadRequest.accepted(from: notification, paneToken: .left) == nil)
        #expect(CloudDownloadRequest.accepted(from: notification, paneToken: .singleSource) == nil)
    }

    /// The three pane surfaces map onto three distinct tokens — in particular the Tidy rail is not
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
        let watch = PaneDownloadWatch { _, _ in
            // Never concludes within this test; nothing here waits on it.
            _ = try? await Task.sleep(for: .seconds(5))
            return false
        }
        let request = CloudDownloadRequest(path: "/iCloud/report.pdf", paneToken: .right)
        watch.begin(request)

        #expect(watch.request(forPath: "/iCloud/report.pdf")?.requestID == request.requestID)
        #expect(watch.request(forPath: "/iCloud/other.pdf") == nil)
        #expect(FileRowView.BadgeID(path: "/iCloud/other.pdf",
                                    awaitingDownloadID: watch.request(forPath: "/iCloud/other.pdf")?.requestID)
                == FileRowView.BadgeID(path: "/iCloud/other.pdf", awaitingDownloadID: nil))
    }
}
