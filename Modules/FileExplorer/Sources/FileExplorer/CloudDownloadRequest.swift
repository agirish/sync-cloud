import Foundation

/// Which pane a download request came from, for notification scoping.
///
/// Both panes default to the same provider, so the SAME absolute path can be on screen twice. A
/// `.cloudDownloadRequested` post that carried only the path was latched by BOTH panes: twin rows
/// entered the awaiting state, both ran the bounded download poll, and the duplicate
/// `CloudOnlyBadgeCache.forget` bumped the memo generation app-wide. The token names the posting
/// pane so the other pane's subscription can ignore the notice.
///
/// Derived from the two facts a pane surface already carries (`isLeft` / `isSingleSource`) rather
/// than a fresh identity object, so the posting context menu and the receiving pane — separate
/// views with no shared state — compute the same token from the same inputs.
enum PaneToken: Equatable, Sendable {
    /// The left comparison pane.
    case left
    /// The right comparison pane.
    case right
    /// The Tidy single-source rail, which has no opposite pane at all.
    case singleSource

    init(isLeft: Bool, isSingleSource: Bool) {
        self = isSingleSource ? .singleSource : (isLeft ? .left : .right)
    }
}

/// The payload of a `.cloudDownloadRequested` post: which file, from which pane, and a fresh
/// identity per request.
struct CloudDownloadRequest: Equatable, Sendable {
    /// Absolute path of the cloud-only file whose download was requested.
    let path: String
    /// The pane whose UI initiated the request — only that pane's rows should watch for the
    /// content landing.
    let paneToken: PaneToken
    /// Fresh per request, never reused. The row's watcher is keyed on this (`.task(id:)`), so a
    /// SECOND download of the same file re-fires the poll — keyed on the path alone it never did,
    /// because `.task(id:)` does not re-run on an identical value.
    let requestID: UUID

    init(path: String, paneToken: PaneToken, requestID: UUID = UUID()) {
        self.path = path
        self.paneToken = paneToken
        self.requestID = requestID
    }

    /// The routing decision, extracted so it can be unit-tested: the request carried by
    /// `notification` if it belongs to the pane identified by `paneToken`, nil otherwise
    /// (another pane's request, or a payload this build does not recognise).
    static func accepted(from notification: Notification, paneToken: PaneToken) -> CloudDownloadRequest? {
        guard let request = notification.object as? CloudDownloadRequest else { return nil }
        return request.paneToken == paneToken ? request : nil
    }

    /// This request's identity if it is watching `path`, nil otherwise — what a row hands its
    /// poll task as the task id.
    func idIfWatching(_ path: String) -> UUID? {
        self.path == path ? requestID : nil
    }
}
