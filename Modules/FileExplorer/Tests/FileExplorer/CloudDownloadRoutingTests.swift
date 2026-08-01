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

    /// The three pane surfaces map onto three distinct tokens — in particular the Tidy rail is not
    /// confusable with the left pane just because both may pass `isLeft == true`.
    @Test func paneTokensAreDistinctPerSurface() {
        #expect(PaneToken(isLeft: true, isSingleSource: false) == .left)
        #expect(PaneToken(isLeft: false, isSingleSource: false) == .right)
        #expect(PaneToken(isLeft: true, isSingleSource: true) == .singleSource)
        #expect(PaneToken(isLeft: false, isSingleSource: true) == .singleSource)
    }

    /// Repeat downloads of the SAME file must re-key the row's `.task(id:)` — `id` is fresh per
    /// request, which is what un-wedged the "second download never re-triggers the poll" latch.
    @Test func repeatRequestsForTheSamePathCarryDistinctIdentity() {
        let first = CloudDownloadRequest(path: "/iCloud/big.mov", paneToken: .left)
        let second = CloudDownloadRequest(path: "/iCloud/big.mov", paneToken: .left)

        #expect(first.requestID != second.requestID)
        #expect(first.idIfWatching("/iCloud/big.mov") == first.requestID)
        #expect(second.idIfWatching("/iCloud/big.mov") == second.requestID)
    }

    /// Only the requested file's row watches; every other row sees nil.
    @Test func onlyTheRequestedPathIsWatched() {
        let request = CloudDownloadRequest(path: "/iCloud/report.pdf", paneToken: .right)

        #expect(request.idIfWatching("/iCloud/report.pdf") == request.requestID)
        #expect(request.idIfWatching("/iCloud/other.pdf") == nil)
    }
}
