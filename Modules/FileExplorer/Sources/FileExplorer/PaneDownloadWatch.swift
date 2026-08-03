import Foundation

/// Every download one pane is currently watching — **one watch per PATH, not one per pane**.
///
/// The pane used to hold a single latch, watched by a `.task(id: awaitingDownload?.requestID)`. That
/// keyed the watch on the request, so a second download in the same pane — a different file, queued
/// back to back from the row menu, which is an ordinary thing to do — changed the id and CANCELLED
/// the first one. Request A's content then landed with nothing observing it: the memo still held the
/// `true` its arming re-stat had recorded, so `cached()` served a stale cloud-only badge for a file
/// that was on disk, until the next republish happened to clear it.
///
/// Keyed by path rather than by request id, deliberately, because supersession is per FILE:
///
/// - Two paths are two independent watches. Neither may disturb the other; that is the whole defect
///   above.
/// - The SAME path asked for twice is one watch, and the newer request wins. Two watches on one path
///   would mean two `CloudOnlyBadgeCache.forget` calls, and every forget bumps the memo generation,
///   invalidating every in-flight badge stat in BOTH panes — verbatim the harm the pane-scoped
///   request payload was added to remove. Cancelling the older one keeps it at one.
///
/// The identity guard inside `CloudDownloadPoll.watch` still does the deciding, and still by
/// `requestID`: a cancelled watch runs everything after its last `await`, so the superseded watch
/// for a path reaches its conclusion after the new one has taken the slot, and comparing ids is what
/// stops it clearing a watch that had barely started.
///
/// **A watch outlives its pane by at most `attempts × interval`.** The old `.task` was torn down
/// with the view; these are detached from it. That is the bound and it is deliberate — everything a
/// concluding watch does (record the landed answer into a process-wide memo, drop its own entry) is
/// true regardless of which pane is on screen, and the alternative is the defect the pane-owned
/// watch was introduced to fix: a watch whose lifetime is tied to a view that may never be realized
/// at all.
@MainActor
final class PaneDownloadWatch: ObservableObject {
    /// The live watches, by path. A dictionary rather than the object itself is what gets handed
    /// down the view tree: a class reference compares identical on every render, so a subview given
    /// one can be skipped by SwiftUI's diffing entirely, while a `[String: CloudDownloadRequest]` is
    /// a value that changes when the watches do.
    @Published private(set) var requests: [String: CloudDownloadRequest] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]

    /// One request's whole watch, `CloudDownloadPoll.watch` in the app.
    ///
    /// Injectable for one property this class owns and that class does not: that superseding a path
    /// CANCELS the watch it replaces. A leaked watch is invisible in `requests` — the new one has
    /// already taken the slot — and it leaves no trace in the memo either: it forgot nothing (that
    /// happens in `begin`) and, if it ever lands, it records the same answer the live watch will.
    /// A watch that reports its own cancellation is what makes it observable at all.
    typealias Watch = @MainActor (CloudDownloadRequest,
                                  @escaping @MainActor () -> CloudDownloadRequest?) async -> Bool

    private let watch: Watch

    init(watch: @escaping Watch = { await CloudDownloadPoll.watch($0, latch: $1) }) {
        self.watch = watch
    }

    /// Starts watching `request`, superseding any watch this pane already had for the same path.
    ///
    /// **The `forget` happens here, synchronously, before anything is published or scheduled.** It
    /// used to be the first line of the watch task, which made "exactly one forget per download"
    /// — the property the single-owner design exists for — depend on the main actor draining
    /// equal-priority jobs in FIFO order: true in practice, guaranteed by nothing. Done here it is
    /// a property of arming a watch, and it also closes a window the old order left open: arming
    /// publishes `requests`, which re-keys the badge task of the row showing that file, and a row
    /// that re-read the memo before the task's first line ran got the pre-download "cloud-only"
    /// answer straight back out of cache.
    func begin(_ request: CloudDownloadRequest) {
        tasks[request.path]?.cancel()
        // On the way in, not the way out: the answer the memo holds is the pre-download one, and a
        // row recycling mid-download would otherwise read "cloud-only" back out of cache and undo
        // the watch's result.
        CloudOnlyBadgeCache.forget(request.path)
        requests[request.path] = request
        tasks[request.path] = Task { [weak self] in
            guard let self else { return }
            // The latch is read at the END, as it always was: what matters is which request holds
            // this path *now*, after ten seconds in which the user may have asked for it again.
            let concludes = await watch(request, { [weak self] in self?.requests[request.path] })
            guard concludes else { return }
            requests[request.path] = nil
            tasks[request.path] = nil
        }
    }

    /// The request watching `path`, if this pane is watching it.
    func request(forPath path: String) -> CloudDownloadRequest? { requests[path] }
}
