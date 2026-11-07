import AppKit
import Events
import Foundation
import Sync

/// Which pane a download request came from, for notification scoping.
///
/// Both panes default to the same provider, so the same absolute path can be on screen twice. A
/// post carrying only the path would be latched by both panes: twin rows awaiting, twin download
/// polls, and a duplicate `CloudOnlyBadgeCache.forget` bumping the memo generation app-wide. The
/// token names the posting pane so the other pane's subscription ignores the notice. It is derived
/// from two facts every pane surface already carries (`isLeft`, `isSingleSource`), so the posting
/// menu and the receiving pane, separate views with no shared state, compute the same token.
///
/// The accepted cost: with both panes on the same folder, a twin row keeps its badge until the
/// next republish. A's watch records `isCloudOnly: false` into the memo when the content lands and
/// A's row re-reads it; nothing re-keys B's row, which keeps the `true` its own stat resolved.
/// Closing that would take either the un-scoped post or a badge key that depends on the memo's
/// generation, re-keying every realized row in both panes on every forget, so one download would
/// re-stat the whole visible list twice. Both cost more than a stale badge on the pane the user
/// isn't acting in, one republish from correct.
public enum PaneToken: Equatable, Sendable {
    /// The left comparison pane.
    case left
    /// The right comparison pane.
    case right
    /// The single-source rail, which has no opposite pane at all.
    case singleSource
    /// The Compare Copies overlay, which isn't a pane: it owns its own ``PaneDownloadWatch`` and
    /// never posts through `NotificationCenter`. The case lets the surface name itself rather than
    /// borrow a pane's identity, which would let a pane latch a download it didn't start. Appended
    /// last, per the case-add rule.
    case compareCopies

    /// Public so File ▸ Download's menu item, in the app target, can name the pane whose selection
    /// it acts on from the same two facts the row menu does.
    public init(isLeft: Bool, isSingleSource: Bool) {
        self = isSingleSource ? .singleSource : (isLeft ? .left : .right)
    }
}

/// The payload of a `.cloudDownloadRequested` post: which file, from which pane, and a fresh
/// identity per request.
public struct CloudDownloadRequest: Equatable, Sendable {
    /// Absolute path of the cloud-only file whose download was requested.
    let path: String
    /// The pane whose UI initiated the request; only that pane's rows should watch for the content
    /// landing.
    let paneToken: PaneToken
    /// Fresh per request, never reused. The row's watcher is keyed on this (`.task(id:)`), so a
    /// second download of the same file re-fires the poll; `.task(id:)` doesn't re-run on an
    /// identical value, so the path alone wouldn't.
    let requestID: UUID

    init(path: String, paneToken: PaneToken, requestID: UUID = UUID()) {
        self.path = path
        self.paneToken = paneToken
        self.requestID = requestID
    }

    /// Announces a download request from `paneToken`'s pane, and hands back what it posted.
    ///
    /// The one poster: the row menu's Download and the preview column's both go through here, so
    /// the payload can't drift between two call sites that must agree with
    /// `accepted(from:paneToken:)`, and a test has one place to drive the round trip from. Neither
    /// call site is reachable from a test: both sit behind a real `MaterializationStatus` call
    /// against a provider placeholder.
    ///
    /// - Parameter channel: which `NotificationCenter` to announce on. `.default` is the app's, and
    ///   the app never passes anything else; a test that mounts a pane gives it a private channel
    ///   (`FileTreeView.downloadChannel`) and posts through the same one, so no two mounted panes in
    ///   the process can hear each other (`docs/flaky-tests.md`, "A mounted view is a live
    ///   subscriber, in every suite at once").
    @discardableResult
    static func post(path: String, from paneToken: PaneToken,
                     through channel: NotificationCenter = .default) -> CloudDownloadRequest {
        let request = CloudDownloadRequest(path: path, paneToken: paneToken)
        channel.post(name: .cloudDownloadRequested, object: request)
        return request
    }

    /// The Download verb, whole: ask the system to fetch the placeholder and, only if it agreed,
    /// announce the request so the posting pane starts watching for the content to land. One body
    /// for the row menu and File ▸ Download, so the try, the log lines and the post can't drift on
    /// the path that decides whether a badge ever clears.
    ///
    /// Not iCloud-only: on a real Google Drive placeholder `startDownloadingUbiquitousItem` returns
    /// without throwing and the file lands within a second. Dropbox and OneDrive are unmeasured.
    ///
    /// When it throws, the click isn't silent: it reveals the file in Finder, which reaches the
    /// provider's own extension, as the preview's Download and Compare Copies do. Nothing is posted
    /// then: a watch for a download nobody started would poll for ten seconds and conclude nothing.
    ///
    /// - Parameter channel: the channel the posting pane listens on. `.default` in the app; a test
    ///   that mounts a pane hands both sides its own.
    /// - Parameter whenUnavailable: what a refused request does instead: reveals the file in
    ///   Finder in the app; a test passes a recorder so no Finder window opens.
    /// - Returns: whether the download was requested.
    @MainActor
    @discardableResult
    public static func requestDownload(path: String, name: String, from paneToken: PaneToken,
                                       through channel: NotificationCenter = .default,
                                       whenUnavailable: @MainActor (URL) -> Void = revealInFinder) -> Bool {
        do {
            try MaterializationStatus.download(atPath: path)
            Logger.shared.info("Requested download of cloud-only file: \(path)")
            post(path: path, from: paneToken, through: channel)
            return true
        } catch {
            Logger.shared.warning("Download unavailable for “\(name)” — revealing it in Finder, which can fetch it (\(error.localizedDescription))")
            whenUnavailable(URL(fileURLWithPath: path))
            return false
        }
    }

    /// The fallback the app uses: Finder reaches the provider's own extension.
    @MainActor
    public static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// How many of one Download All's files the pane watches, so their badges clear as they land.
    /// Each watch is a ten-second poll of one `lstat` a second; a folder past this many files takes
    /// longer than any watch lasts anyway, and its rows are one republish from correct.
    static let folderWatchCap = 200

    /// Download All, whole: request every cloud-only file among `files` and below `folders`, then
    /// announce the first `folderWatchCap` of them so the posting pane watches them land, as one
    /// file's Download does. A single folder is `folders: [it]`; a selection is both lists.
    ///
    /// The walk blocks its thread (a cloud-only folder inside is waited on for up to
    /// `DatalessFolderReads`' deadline), so it runs on a dispatch queue, never the main actor or
    /// the cooperative pool. When the provider refused every file, the selection is revealed in
    /// Finder, as a refused Download is.
    ///
    /// - Parameter fetch: the walk and the requests; the app's is
    ///   `MaterializationStatus.downloadAll`, and a test passes its own answer.
    @MainActor
    @discardableResult
    public static func requestDownloads(
        files: [String], folders: [String], from paneToken: PaneToken,
        through channel: NotificationCenter = .default,
        fetch: @escaping @Sendable ([String], [String]) -> MaterializationStatus.FolderDownload = {
            MaterializationStatus.downloadAll(files: $0, folders: $1)
        },
        whenUnavailable: @MainActor ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    ) async -> MaterializationStatus.FolderDownload {
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: fetch(files, folders))
            }
        }
        let asked = folders.count == 1 && files.isEmpty
            ? "in “\((folders[0] as NSString).lastPathComponent)”"
            : "over \(files.count + folders.count) items"
        Logger.shared.info("Download All \(asked): requested \(result.requested.count), refused \(result.refused.count), unreadable folders \(result.unreadable)")
        // Which files the provider refused: the count alone can't say which one never came.
        for line in LogNames.lines("Download All \(asked): refused", result.refused) { Logger.shared.info(line) }
        if result.requested.isEmpty, !result.refused.isEmpty {
            whenUnavailable((folders + files).map { URL(fileURLWithPath: $0) })
        }
        for file in result.requested.prefix(folderWatchCap) {
            post(path: file, from: paneToken, through: channel)
        }
        return result
    }

    /// What a Download offer does: one file through
    /// ``requestDownload(path:name:from:through:whenUnavailable:)``, anything else through
    /// ``requestDownloads(files:folders:from:through:fetch:whenUnavailable:)``. The one act behind
    /// the row menu's item and File ▸ Download, so the two can't drift.
    @MainActor
    public static func request(_ offer: CloudDownloadOffer, from paneToken: PaneToken,
                               through channel: NotificationCenter = .default) {
        switch offer {
        case .file(let path, let name):
            requestDownload(path: path, name: name, from: paneToken, through: channel)
        case .all(let files, let folders):
            Task { await requestDownloads(files: files, folders: folders, from: paneToken, through: channel) }
        }
    }

    /// Keep Downloaded, toggled over `nodes`: pin or unpin each one whose own pin decides it (a
    /// node kept by a folder above is left alone, since unpinning it would change nothing), and on
    /// pinning also request the downloads. The provider would fetch them anyway, but only a request
    /// through this pane starts the watch that clears a row's cloud badge.
    ///
    /// The reads and pins run on `keepQueue`, never the main actor the click arrives on: each is a
    /// `getxattr`, `setxattr` or `lstat` inside iCloud Drive, microseconds when healthy and seconds
    /// when a wedged File Provider holds them. Unlike a menu's offer the click isn't abandoned at a
    /// deadline: it is an act, so it finishes whenever the provider lets it. Serial, so two clicks
    /// land in order. Only the download request comes back to the main actor.
    ///
    /// - Parameter home: whose iCloud Drive, `~/Desktop` and `~/Documents` decide the state: the
    ///   menu's `cloudHome`, so a test's scratch home is the one asked.
    /// - Parameter state: what each node's pin is now; nil reads the attribute below `home`, and a
    ///   test passes its own.
    @MainActor
    public static func setKeepDownloaded(
        _ kept: Bool, for nodes: [FileNode], from paneToken: PaneToken,
        through channel: NotificationCenter = .default,
        home: String = NSHomeDirectory(),
        state: (@Sendable (String) -> KeepDownloaded.State)? = nil,
        pin: @escaping @Sendable (Bool, String) throws -> Void = { try KeepDownloaded.set($0, atPath: $1) },
        isCloudOnly: @escaping @Sendable (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) },
        download: (@MainActor (CloudDownloadOffer) -> Void)? = nil
    ) async {
        let state = state ?? { KeepDownloaded.state(ofPath: $0, home: home) }
        let offer = await withCheckedContinuation { continuation in
            keepQueue.async {
                continuation.resume(returning: pinning(kept, nodes, state: state, pin: pin, isCloudOnly: isCloudOnly))
            }
        }
        guard let offer else { return }
        // Through this pane, so its watch is the one that hears it, never a default pane's.
        if let download { download(offer) } else { request(offer, from: paneToken, through: channel) }
    }

    /// Where Keep Downloaded's clicks read and write, one after another.
    private static let keepQueue = DispatchQueue(label: "com.synccloud.keep-downloaded", qos: .userInitiated)

    /// The click's filesystem half: the pins, and what to download after; nil when nothing was
    /// pinned or it is an unpin.
    private static func pinning(
        _ kept: Bool, _ nodes: [FileNode], state: (String) -> KeepDownloaded.State,
        pin: (Bool, String) throws -> Void, isCloudOnly: (String) -> Bool
    ) -> CloudDownloadOffer? {
        let changing = nodes.filter { state($0.id) == (kept ? .off : .on) }
        var pinned: [FileNode] = []
        for node in changing {
            do {
                try pin(kept, node.id)
                pinned.append(node)
                Logger.shared.info("\(kept ? "Keeping" : "Stopped keeping") “\(node.name)” downloaded")
            } catch {
                Logger.shared.warning("Could not \(kept ? "keep" : "stop keeping") “\(node.name)” downloaded (\(error.localizedDescription))")
            }
        }
        guard kept else { return nil }
        return CloudDownloadOffer.forSelection(pinned, isCloudOnly: isCloudOnly, isInCloudLocation: { _ in true })
    }

    /// The routing decision, extracted so it can be unit-tested: the request carried by
    /// `notification` if it belongs to the pane identified by `paneToken`, nil otherwise
    /// (another pane's request, or a payload this build doesn't recognise).
    static func accepted(from notification: Notification, paneToken: PaneToken) -> CloudDownloadRequest? {
        guard let request = notification.object as? CloudDownloadRequest else { return nil }
        return request.paneToken == paneToken ? request : nil
    }

    /// Whether a watch that has just finished for this request may drop the pane's latch.
    ///
    /// Identity, never path. A path can recur: the attempts run out and the user clicks Download on
    /// the same file again, which cancels the old watch and re-arms the latch with a fresh request.
    /// Comparing paths would let the finishing old watch clear the latch the new one just took.
    /// `requestID` can't be fooled by a repeat, and a cancelled watch (whose latch has moved on)
    /// fails it for free.
    func concludes(latch: CloudDownloadRequest?) -> Bool {
        latch?.requestID == requestID
    }
}

/// The bounded poll that watches a requested download materialize.
///
/// There is exactly one poller per download, and it is the pane (`FileTreeView`). A second poller
/// for the same request would mean two `CloudOnlyBadgeCache.forget` calls, and every forget bumps
/// the memo generation, invalidating every in-flight badge stat in both panes: the harm the
/// pane-scoped request exists to prevent.
///
/// The pane owns it, not the row, because the row may never be realized (offscreen in a long list,
/// scrolled off, in a column navigated away from), and a preview-started download needs no row on
/// screen. A row-owned watch would have no bound on its lifetime, so the latch could stick and the
/// poll run minutes late. Owned by the pane it always concludes within `attempts × interval`.
///
/// Materialization has no public completion callback, so a short bounded poll is the cheap honest
/// option: the badge clears the moment the check says the content is local, and if it never does
/// (the download stalled or failed) the badge rightly stays.
enum CloudDownloadPoll {
    /// ~10 s of watching, the whole budget: a download that hasn't landed by then is one for the
    /// next republish to report, not worth holding a poll open for.
    static let attempts = 10
    static let interval = Duration.seconds(1)

    /// The watch as the pane runs it: poll, record the landed answer, and decide whether the latch
    /// may be dropped. Returns that decision.
    ///
    /// Extracted from `FileTreeView` because what matters here are properties of the sequence, not
    /// of any one step: a watch that found nothing leaves the memo alone, and only the request the
    /// latch still holds may clear it. Neither is observable from a view.
    ///
    /// The memo's pre-download answer is dropped by `PaneDownloadWatch.begin`, before this task
    /// exists, so "exactly one `forget` per download" is a synchronous property of arming a watch,
    /// not one that depends on the main actor draining equal-priority jobs in FIFO order (true in
    /// practice, guaranteed nowhere).
    ///
    /// - Parameter latch: read at the end, on purpose: it is the pane's live latch, and what
    ///   matters is which request it holds now, after ten seconds in which the user may have asked
    ///   for the same file again.
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
        // Only on landing, and landing means a definite "not a placeholder" (`run`). A watch that
        // ran out of attempts observed nothing new, and writing anything would claim the file had
        // materialized when the badge should stay.
        if landed { CloudOnlyBadgeCache.record(request.path, isCloudOnly: false) }
        return request.concludes(latch: latch())
    }

    /// Polls until the content lands or the attempts run out. Returns whether it landed.
    ///
    /// Landed means a definite "not a placeholder". The probe answers nil when the path can't be
    /// statted at all, which isn't an arrival: a file deleted mid-download reads that way, and
    /// treating it as landed would record local content for a path with no file. A nil keeps
    /// polling (the provider may be briefly unreachable), and if every attempt is nil the watch
    /// ends having observed nothing: the badge stays and the memo is left alone.
    ///
    /// `isCloudOnly` is injectable for the reason `CloudOnlyBadgeCache.isCloudOnly`'s stat is: the
    /// real one is a detached `lstat` against a provider, and a test needs the loop without the
    /// filesystem. `nonisolated` so the sleeps don't park the main actor.
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
