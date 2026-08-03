import Foundation
import Sync

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
///
/// **The accepted cost: a twin row keeps its badge until the next republish.** The very case that
/// motivates the scoping — both panes showing the same folder — is also the case where it shows.
/// Pane A requests a download, A's watch records `isCloudOnly: false` into the process-wide memo
/// when the content lands, and A's row re-reads it because the conclusion re-keys that row's badge
/// task. B ignored the request, so nothing re-keys B's row: it goes on rendering the `true` its own
/// stat resolved, and the two panes disagree on screen about one file until B republishes.
///
/// Left as is, deliberately. Closing it means either the un-scoped post this token replaced (twin
/// watches, twin forgets, a memo generation bump per download app-wide) or making the row's badge
/// key depend on the memo's generation — which re-keys EVERY realized row in both panes on every
/// forget, so one download would re-stat the whole visible list, twice over. Both cost more than a
/// stale badge on the pane the user is not acting in, and the badge is one republish from correct.
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

    /// Announces a download request from `paneToken`'s pane, and hands back what it posted.
    ///
    /// The one poster: the row context menu's Download and the preview column's both go through
    /// here, so the payload cannot drift between two call sites that must agree with
    /// `accepted(from:paneToken:)` — and the round trip through `NotificationCenter` has one place
    /// a test can drive it from. Neither call site can be reached by a test itself: both sit behind
    /// a real `MaterializationStatus` call against a provider placeholder.
    ///
    /// - Parameter channel: which `NotificationCenter` to announce on. `.default` is the app's, and
    ///   the app never passes anything else — a test that mounts a pane gives it a private channel
    ///   (`FileTreeView.downloadChannel`) and posts through the same one, so no two mounted panes in
    ///   the process can hear each other. See `docs/flaky-tests.md` mechanism 9.
    @discardableResult
    static func post(path: String, from paneToken: PaneToken,
                     through channel: NotificationCenter = .default) -> CloudDownloadRequest {
        let request = CloudDownloadRequest(path: path, paneToken: paneToken)
        channel.post(name: .cloudDownloadRequested, object: request)
        return request
    }

    /// The routing decision, extracted so it can be unit-tested: the request carried by
    /// `notification` if it belongs to the pane identified by `paneToken`, nil otherwise
    /// (another pane's request, or a payload this build does not recognise).
    static func accepted(from notification: Notification, paneToken: PaneToken) -> CloudDownloadRequest? {
        guard let request = notification.object as? CloudDownloadRequest else { return nil }
        return request.paneToken == paneToken ? request : nil
    }

    /// Whether a watch that has just finished for THIS request may drop the pane's latch.
    ///
    /// Identity, never path. A path can recur: the user clicks Download, the attempts run out, and
    /// they click Download on the SAME file again — which cancels the old watch and re-arms the
    /// latch with a fresh request for the identical path. A guard that compared paths would then
    /// let the finishing OLD watch clear the latch the NEW one had just taken, killing a watch that
    /// had barely started. Comparing `requestID` cannot be fooled by a repeat, and a cancelled
    /// watch (whose latch has already moved on) fails it for free.
    func concludes(latch: CloudDownloadRequest?) -> Bool {
        latch?.requestID == requestID
    }
}

/// The bounded poll that watches a requested download materialize.
///
/// **There is exactly one poller per download, and it is the pane** (`FileTreeView`). It briefly
/// was two — the row ran a 10 × 1 s poll and the preview column's Download button ran its own
/// 20 × 1.5 s one for the same request — which meant two `CloudOnlyBadgeCache.forget` calls, and
/// every forget bumps the memo generation, invalidating every in-flight badge stat in BOTH panes.
/// That is verbatim the harm the pane-scoped request payload exists to prevent.
///
/// The pane is the owner rather than the row because the row may never be realized: offscreen in a
/// long list, or scrolled off, or in a column the user navigated away from — and a preview-started
/// download does not need the row on screen at all. A watch owned by the row therefore had no
/// bound on its lifetime, so the pane's latch could stick forever and the poll could finally run
/// minutes late, for a download long since finished. Owned by the pane it always concludes within
/// `attempts × interval` of the request, whatever the list is showing.
///
/// Materialization has no public completion callback, so a short bounded poll is the cheap honest
/// option: the badge clears the moment the check says the content is local, and if it never does
/// (the download stalled or failed) the badge correctly stays.
enum CloudDownloadPoll {
    /// ~10 s of watching, which is the whole budget: a download that has not landed by then is one
    /// the next republish should report on, not one worth holding a poll open for.
    static let attempts = 10
    static let interval = Duration.seconds(1)

    /// The watch as the pane runs it: poll, record the landed answer, and decide whether the latch
    /// may be dropped. Returns that decision.
    ///
    /// Extracted from `FileTreeView` — which is left holding two lines — because the properties
    /// that regressed here are properties of the SEQUENCE, not of any one step: that a watch which
    /// found nothing leaves the memo alone, and that only the request the latch still holds may
    /// clear it. Neither is observable from a view, and both are one edit away from silently
    /// coming back.
    ///
    /// The memo's pre-download answer is dropped by `PaneDownloadWatch.begin`, not here — before
    /// this task exists, so "exactly one `forget` per download" is a synchronous property of
    /// arming a watch rather than one that depends on the main actor draining equal-priority jobs
    /// in FIFO order (true in practice, guaranteed nowhere).
    ///
    /// - Parameter latch: read at the END, deliberately: it is the pane's live latch, and what
    ///   matters is which request it holds *now* — after ten seconds in which the user may have
    ///   asked for the same file again.
    @MainActor
    static func watch(
        _ request: CloudDownloadRequest,
        attempts: Int = attempts,
        interval: Duration = interval,
        isCloudOnly: @Sendable (String) async -> Bool? = { path in
            await Task.detached { MaterializationStatus.isCloudOnlyIfKnown(atPath: path) }.value
        },
        latch: @MainActor () -> CloudDownloadRequest?
    ) async -> Bool {
        let landed = await run(path: request.path, attempts: attempts, interval: interval,
                               isCloudOnly: isCloudOnly)
        // Only on landing, and landing means a DEFINITE "not a placeholder" — see `run`. A watch
        // that ran out of attempts observed nothing new, and writing anything there would claim the
        // file had materialized when the badge should stay.
        if landed { CloudOnlyBadgeCache.record(request.path, isCloudOnly: false) }
        return request.concludes(latch: latch())
    }

    /// Polls until the content lands or the attempts run out. Returns whether it landed.
    ///
    /// **Landed means a DEFINITE "not a placeholder".** The probe answers nil when the path cannot
    /// be statted at all, and that is not an arrival — a file deleted mid-download reads exactly
    /// that way, and treating it as materialized had the watch record local content for a path with
    /// no file behind it. A nil keeps polling (the provider may be momentarily unreachable) and, if
    /// every attempt is nil, the watch ends having observed nothing, which is the honest result: the
    /// badge stays and the memo is left alone.
    ///
    /// `isCloudOnly` is injectable for the same reason `CloudOnlyBadgeCache.isCloudOnly`'s stat is:
    /// the real one is a detached `lstat` against a provider, and a test needs the loop without the
    /// filesystem. `nonisolated` so the sleeps do not park the main actor.
    nonisolated static func run(
        path: String,
        attempts: Int = attempts,
        interval: Duration = interval,
        isCloudOnly: @Sendable (String) async -> Bool? = { path in
            await Task.detached { MaterializationStatus.isCloudOnlyIfKnown(atPath: path) }.value
        }
    ) async -> Bool {
        for _ in 0..<attempts {
            // Cancel-safe: `Task.sleep` throws on cancellation, and the check after the probe
            // catches a cancellation that landed while it was out.
            guard (try? await Task.sleep(for: interval)) != nil else { return false }
            let stillCloudOnly = await isCloudOnly(path)
            if Task.isCancelled { return false }
            if stillCloudOnly == false { return true }
        }
        return false
    }
}
