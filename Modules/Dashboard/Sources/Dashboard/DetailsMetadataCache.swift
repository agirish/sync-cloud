import AppKit
import Events

/// Memoizes the metadata stat and NSWorkspace icon for the details sidebar's current path, plus
/// the two invalidation decisions, kept out of DetailsSidebar's view body so the rules are
/// unit-testable.
///
/// Both loads hit the filesystem, and on a cloud path they can block forever. So the lookup is
/// split: `cached(for:)` is pure memory and safe to call from anywhere, while `load(for:)` is
/// `async` and does the filesystem work on a private queue (see `ioQueue`). Nothing on the main
/// thread ever waits on a syscall.
///
/// It also rate-limits the stat's failure warning per path (see `warnedPaths`). The memo alone
/// cannot: every invalidation drops it, and file operations drive invalidations.
@MainActor
final class DetailsMetadataCache {
    /// The stat. `@Sendable`, and it returns its failure reason rather than logging it, because it
    /// runs on `ioQueue`, not the main actor. This cache is the one object that knows a re-stat is
    /// of the same path, so it owns the reporting (`reportOnce(_:for:)`).
    private let loadMetadata: @Sendable (String) -> DetailsSidebar.MetadataLoad
    /// Also `@Sendable` and run on `ioQueue`: a custom icon lives in the item's resource fork, so
    /// `NSWorkspace.icon(forFile:)` reads extended attributes too and wedges on exactly the paths
    /// the stat does. On the main actor it would hang the app.
    private let loadIcon: @Sendable (String) -> NSImage
    /// Where a surviving (non-suppressed) failure report goes. Injected so the rate limit is
    /// testable without reading `Logger.shared`'s asynchronous in-memory buffer.
    private let logWarning: @MainActor (String) -> Void

    private var path: String?
    private var metadata: DetailsSidebar.FileMetadata?
    private var icon: NSImage?

    /// The path of the most recent `load(for:)` request, not the most recent load to finish. Loads
    /// start in the order the selection changes, so this is the path the UI wants; a load that
    /// comes back to find it changed is stale and must not claim the memo.
    private var requestedPath: String?

    /// Paths whose stat failure has already been reported, so a re-stat of the same unreadable
    /// item stays quiet. The memo can't do this: `refreshOccurred()` drops it after every file
    /// operation, so a bulk run with an unreadable item selected would log one warning per
    /// operation, each a disk write.
    ///
    /// A path is forgotten once it stats successfully, so an item that becomes unreadable again
    /// later (a volume that came back and went away) is reported again: a real state change.
    private var warnedPaths: Set<String> = []

    /// Bound on `warnedPaths` so a session that browses through many unreadable items cannot grow
    /// it without limit. Clearing wholesale (rather than evicting one entry) keeps this O(1) and
    /// costs at most one repeated warning per path afterwards, the same trade the log writer's
    /// one-shot failure signal makes.
    private static let maxWarnedPaths = 64

    /// Monotonic count of invalidation events (refresh, scan completing). The sidebar keys its
    /// folder-size task on this, so the events that drop the memo also recompute the folder total;
    /// otherwise a copy or delete inside the selected folder would leave the old size on screen.
    private(set) var generation = 0

    /// Where the filesystem work runs. **Never** the Swift cooperative pool (`Task.detached`, or a
    /// `nonisolated async` function): `attributesOfItem` (via `getxattr`) and
    /// `NSWorkspace.icon(forFile:)` can block indefinitely on a wedged file provider. That pool is
    /// only core-count wide, so a handful of stuck loads would deadlock every `Task` in the
    /// process, SwiftUI's own included.
    ///
    /// A private queue caps the damage at one stuck thread per wedged path, each reached only by a
    /// deliberate selection. `.concurrent`, not serial: on a serial queue the first wedged path
    /// would block every later selection, healthy providers included. GCD's per-QoS thread
    /// ceiling is the backstop, and it degrades to that serial behaviour rather than to a crash.
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
    /// The only lookup a render pass may make. Pure memory: a miss returns nil rather than reaching
    /// for the filesystem, so a wedged provider can never block a caller. Filling a miss is
    /// `load(for:)`'s job, and that one suspends.
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
    /// If the load never comes back (a wedged provider), this never resumes. The awaiting task
    /// stays suspended, holding no thread and blocking nothing, and the card keeps rendering what
    /// the caller already had. That is the intended degradation.
    ///
    /// The caller always gets the result of *its own* load. What is conditional is whether that
    /// result is adopted into the memo — see `requestedPath`.
    func load(for path: String) async -> Entry {
        if let hit = cached(for: path) { return hit }

        // Claim the memo for this path before suspending. See `requestedPath`.
        requestedPath = path
        let startGeneration = generation

        // Captured as locals so the closure takes the two loaders and nothing else — capturing
        // `self` would pull a main-actor-isolated reference onto the queue.
        let loadMetadata = self.loadMetadata
        let loadIcon = self.loadIcon
        let result: (failure: String?, entry: Entry) = await withCheckedContinuation { continuation in
            Self.ioQueue.async {
                let load = loadMetadata(path)
                let icon = load.metadata.map { loadIcon($0.path) }
                continuation.resume(
                    returning: (load.failure, Entry(metadata: load.metadata, icon: icon)))
            }
        }

        // Reported whether or not the memo adopts this result: the stat really did fail, and
        // `reportOnce` collapses repeats per path.
        if let failure = result.failure { reportOnce(failure, for: path) }
        // A successful read, from any load, clears the path's warned mark, so the next failure is
        // news again rather than a suppressed repeat.
        if result.entry.metadata != nil { warnedPaths.remove(path) }

        // Last requested wins, not last to come back. A superseded load still runs to completion
        // (cancelling its Task doesn't stop the queue block), and on a `.concurrent` queue it can
        // land after its replacement. Committing it would memoize the previous selection while the
        // inspector shows the current one, or resurrect an entry `refreshOccurred()` just dropped.
        guard requestedPath == path, generation == startGeneration else { return result.entry }

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

    /// A completed scan is the "pick up external changes" gesture: the panes rebuild from fresh
    /// stats, so the memo must not survive it, or the sidebar would show pre-scan sizes and dates
    /// that contradict the trees. Only a scan finishing invalidates; one starting keeps the cache.
    func scanningChanged(_ isScanning: Bool) {
        if !isScanning {
            path = nil
            generation += 1
        }
    }
}
