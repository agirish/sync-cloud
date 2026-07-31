import AppKit
import Events

/// Memoizes the metadata stat and NSWorkspace icon for the details sidebar's current path,
/// plus the two invalidation decisions, extracted from DetailsSidebar's view body so the
/// rules are unit-testable.
///
/// Both loads hit the filesystem, and on a cloud path "slow" understates it: they can block
/// *forever*. So the lookup is split in two, and the split is the whole point —
/// `cached(for:)` is pure memory and safe to call from anywhere, while `load(for:)` is `async`
/// and does the filesystem work on a private queue. Nothing on the main thread ever waits on a
/// syscall. See `ioQueue` and `DetailsSidebar.loadMetadata(for:fileManager:)` for the measured
/// hang that forced this.
///
/// It also rate-limits the stat's failure WARNING per path — see `warnedPaths`. The memo alone
/// cannot: every invalidation drops it, and invalidations are driven by file operations.
@MainActor
final class DetailsMetadataCache {
    /// The stat. `@Sendable`, and it returns its failure reason rather than logging it, because it
    /// runs on `ioQueue` and not on the main actor — see `load(for:)`. This cache is the one object
    /// that knows a re-stat is a re-stat of the SAME path, so it owns the reporting; see
    /// `reportOnce(_:for:)`.
    private let loadMetadata: @Sendable (String) -> DetailsSidebar.MetadataLoad
    /// Also `@Sendable` and also run on `ioQueue`: a custom icon lives in the item's resource fork,
    /// so `NSWorkspace.icon(forFile:)` reads extended attributes too and wedges on exactly the
    /// paths the stat does. Leaving it on the main actor would have left half the hang in place.
    private let loadIcon: @Sendable (String) -> NSImage
    /// Where a surviving (non-suppressed) failure report goes. Injected so the rate limit is
    /// testable without reading `Logger.shared`'s asynchronous in-memory buffer.
    private let logWarning: @MainActor (String) -> Void

    private var path: String?
    private var metadata: DetailsSidebar.FileMetadata?
    private var icon: NSImage?

    /// Paths whose stat failure has already been reported, so a re-stat of the same unreadable
    /// item stays quiet.
    ///
    /// The warning's doc used to claim "once per path" and rest that claim on the memo — but the
    /// memo is dropped by `refreshOccurred()`, which fires after EVERY file operation. A bulk run
    /// of N operations with an unreadable item selected therefore wrote N identical warnings, each
    /// costing a real disk write in the log writer. The set makes the claim true: the failure is
    /// news once, and the invalidations that follow are not.
    ///
    /// A path is FORGOTTEN once it stats successfully, so an item that becomes unreadable again
    /// later (a volume that came back and went away again) is reported again — that is a genuine
    /// state change, not the same news repeated.
    private var warnedPaths: Set<String> = []

    /// Bound on `warnedPaths` so a session that browses through many unreadable items cannot grow
    /// it without limit. Clearing wholesale (rather than evicting one entry) keeps this O(1) and
    /// costs at most one repeated warning per path afterwards — the same trade the log writer's
    /// one-shot failure signal makes.
    private static let maxWarnedPaths = 64

    /// Monotonic count of invalidation events (refresh, scan completing). The sidebar keys its
    /// computed-directory-size task on this so the same events that drop the memoized metadata
    /// also clear the computed folder total and trigger a recompute — otherwise a copy/delete
    /// inside the selected folder would leave the pre-operation size on screen until the
    /// selection changed.
    private(set) var generation = 0

    /// Where the filesystem work runs. **Not** the Swift cooperative pool (`Task.detached`, or a
    /// `nonisolated async` function): the calls it makes — `attributesOfItem`, which reaches
    /// `getxattr`, and `NSWorkspace.icon(forFile:)` — can block *indefinitely* on a wedged file
    /// provider, and blocking a cooperative thread is unsafe. That pool is only core-count wide, so
    /// a handful of stuck loads would deadlock every `Task` in the process, SwiftUI's own included
    /// — trading a frozen inspector for a frozen app, which is the bug we are here to fix.
    ///
    /// A private queue caps the damage at one permanently-stuck thread per wedged path, and
    /// requires a deliberate selection to reach each one. It is `.concurrent` rather than serial on
    /// purpose: serial would be cheaper (one stuck thread, ever) but the first wedged path would
    /// sit at the head of the line forever and every later selection — including files on healthy
    /// providers — would queue behind it and never render. GCD's own per-QoS thread ceiling is the
    /// backstop, and it degrades to exactly that serial behaviour rather than to a crash.
    private static let ioQueue = DispatchQueue(
        label: "com.synccloud.details-metadata", qos: .userInitiated, attributes: .concurrent)

    /// The memoized pair. Also the hand-off from `ioQueue` back to the main actor: `NSImage` is not
    /// `Sendable`, and this one is built on the queue, handed over, and never touched there again.
    struct Entry: @unchecked Sendable {
        let metadata: DetailsSidebar.FileMetadata?
        let icon: NSImage?
    }

    init(
        // Wrapped in a closure rather than referenced as `DetailsSidebar.loadMetadata(for:)`: the
        // loader takes an injectable FileManager, and its default belongs to it.
        loadMetadata: @escaping @Sendable (String) -> DetailsSidebar.MetadataLoad
            = { DetailsSidebar.loadMetadata(for: $0) },
        loadIcon: @escaping @Sendable (String) -> NSImage = { NSWorkspace.shared.icon(forFile: $0) },
        logWarning: @escaping @MainActor (String) -> Void = { _ = Logger.shared.warning($0) }
    ) {
        self.loadMetadata = loadMetadata
        self.loadIcon = loadIcon
        self.logWarning = logWarning
    }

    /// The memoized entry for `path`, or nil if this path is not the one memoized.
    ///
    /// **The only lookup a render pass may make.** It is pure memory: a miss returns nil rather
    /// than reaching for the filesystem, so no caller of this can be made to block by a wedged
    /// provider no matter how slow the underlying item is. Filling a miss is `load(for:)`'s job,
    /// and that one suspends.
    func cached(for path: String) -> Entry? {
        guard self.path == path else { return nil }
        return Entry(metadata: metadata, icon: icon)
    }

    /// Fills the memo for `path`, running the stat and the icon fetch on `ioQueue`, and returns the
    /// result. Serves the memo without suspending when `path` is already the memoized one.
    ///
    /// An empty result (missing path) is memoized too, so an unavailable item doesn't get
    /// re-statted on every render.
    ///
    /// If the load never comes back — the wedged-provider case — this simply never resumes. The
    /// awaiting task stays suspended, holding no thread and blocking nothing; the card keeps
    /// rendering whatever the caller already had. That is the intended degradation.
    func load(for path: String) async -> Entry {
        if let hit = cached(for: path) { return hit }

        // Captured as locals so the closure takes the two loaders and nothing else — capturing
        // `self` would pull a main-actor-isolated reference onto the queue.
        let loadMetadata = self.loadMetadata
        let loadIcon = self.loadIcon
        let result: (load: DetailsSidebar.MetadataLoad, entry: Entry) = await withCheckedContinuation { continuation in
            Self.ioQueue.async {
                let load = loadMetadata(path)
                let icon = load.metadata.map { loadIcon($0.path) }
                continuation.resume(returning: (load, Entry(metadata: load.metadata, icon: icon)))
            }
        }

        if let failure = result.load.failure { reportOnce(failure, for: path) }
        // A successful read clears the path's warned mark: whatever made it unreadable is
        // over, so the NEXT failure is news again rather than a suppressed repeat.
        if result.entry.metadata != nil { warnedPaths.remove(path) }

        metadata = result.entry.metadata
        icon = result.entry.icon
        self.path = path
        return result.entry
    }

    /// Forwards the stat's failure report the first time it names `path`, and swallows it after.
    /// See `warnedPaths` for why the memo cannot carry this itself.
    private func reportOnce(_ message: String, for path: String) {
        guard !warnedPaths.contains(path) else { return }
        if warnedPaths.count >= Self.maxWarnedPaths { warnedPaths.removeAll() }
        warnedPaths.insert(path)
        logWarning(message)
    }

    /// A file operation may have changed the current item's attributes in place; drop the
    /// memoized metadata so the next lookup re-stats it.
    func refreshOccurred() {
        path = nil
        generation += 1
    }

    /// A completed scan is the "pick up external changes" gesture: the panes rebuild from
    /// fresh stats, so the memoized metadata must not survive it — the sidebar would keep
    /// showing pre-scan size/dates and contradict the trees. Only `isScanning == false`
    /// invalidates; a scan *starting* keeps the cache.
    func scanningChanged(_ isScanning: Bool) {
        if !isScanning {
            path = nil
            generation += 1
        }
    }
}
