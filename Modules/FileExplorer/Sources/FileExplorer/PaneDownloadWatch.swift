import Foundation

/// Every download one pane is watching: one watch per path, not one per pane, so a second download
/// in the same pane never cancels the first and leaves its file with a stale cloud-only badge.
///
/// - Two paths are two independent watches; neither may disturb the other.
/// - The same path asked for twice is one live watch, and the newer request wins: the older is
///   cancelled so one path is never polled twice. Cancelling bounds watches, not forgets: `begin`
///   forgets every time, which is right, since a repeat request makes the memo stale again.
///
/// The identity guard in `CloudDownloadPoll.watch` still decides, by `requestID`: a cancelled watch
/// runs everything after its last `await`, and comparing ids stops it clearing the newer watch.
///
/// A watch outlives its pane by at most `attempts × interval`, by design: what a concluding watch
/// does (record into a process-wide memo, drop its entry) holds whichever pane is on screen, and a
/// watch tied to the view would die with a view that may never be realized.
@MainActor
final class PaneDownloadWatch: ObservableObject {
    /// The live watches, by path. This value, not the object, is handed down the view tree: a class
    /// reference compares identical on every render, so SwiftUI could skip a subview given one.
    @Published private(set) var requests: [String: CloudDownloadRequest] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]

    /// One request's whole watch, `CloudDownloadPoll.watch` in the app.
    ///
    /// Injectable so tests can see that superseding a path cancels the watch it replaces. A leaked
    /// watch leaves no trace in `requests` or the memo, so only a watch that reports its own
    /// cancellation makes it observable.
    typealias Watch = @MainActor (CloudDownloadRequest,
                                  @escaping @MainActor () -> CloudDownloadRequest?) async -> Bool

    private let watch: Watch

    init(watch: @escaping Watch = { await CloudDownloadPoll.watch($0, latch: $1) }) {
        self.watch = watch
    }

    /// Starts watching `request`, superseding any watch this pane already had for the same path.
    ///
    /// - Parameter channel: where to say the watch has ended (`.cloudDownloadWatchEnded`), for a view
    ///   that shows the download without watching it — the Info inspector's preview. `nil` says
    ///   nothing, for an owner nobody else follows (Compare Copies).
    ///
    /// The `forget` happens here, synchronously, before anything is published or scheduled. In the
    /// watch task it would rely on the main actor's job order, and a row re-keyed by the published
    /// `requests` could re-read the pre-download "cloud-only" answer from cache first.
    func begin(_ request: CloudDownloadRequest, announcingOn channel: NotificationCenter? = nil) {
        tasks[request.path]?.cancel()
        // On the way in, not the way out: the answer the memo holds is the pre-download one, and a
        // row recycling mid-download would otherwise read "cloud-only" back out of cache and undo
        // the watch's result.
        CloudOnlyBadgeCache.forget(request.path)
        requests[request.path] = request
        tasks[request.path] = Task { [weak self] in
            guard let self else { return }
            // The latch is read at the end: what matters is which request holds this path now,
            // after a wait in which the user may have asked again.
            let concludes = await watch(request, { [weak self] in self?.requests[request.path] })
            guard concludes else { return }
            requests[request.path] = nil
            tasks[request.path] = nil
            channel?.post(name: .cloudDownloadWatchEnded, object: request)
        }
    }

    /// The request watching `path`, if this pane is watching it.
    func request(forPath path: String) -> CloudDownloadRequest? { requests[path] }
}
