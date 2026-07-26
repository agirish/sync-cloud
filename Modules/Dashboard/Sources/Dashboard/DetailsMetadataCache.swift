import AppKit
import Events

/// Memoizes the metadata stat and NSWorkspace icon for the details sidebar's current path,
/// plus the two invalidation decisions, extracted from DetailsSidebar's view body so the
/// rules are unit-testable.
///
/// Both loads hit the filesystem (slow on cloud paths), and the sidebar re-renders on every
/// syncManager change during bulk operations. A reference type held in @State: mutating it
/// during body is a cache fill, not a state write, so it cannot re-trigger rendering.
///
/// It also rate-limits the stat's failure WARNING per path — see `warnedPaths`. The memo alone
/// cannot: every invalidation drops it, and invalidations are driven by file operations.
@MainActor
final class DetailsMetadataCache {
    /// The stat, plus the sink it reports an unreadable item through. The sink is a parameter
    /// rather than baked into the loader so this cache — the one object that knows a re-stat is a
    /// re-stat of the SAME path — can filter it; see `reportOnce(_:for:)`.
    private let loadMetadata: @MainActor (String, @MainActor (String) -> Void) -> DetailsSidebar.FileMetadata?
    private let loadIcon: @MainActor (String) -> NSImage
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

    init(
        // Wrapped in a closure rather than referenced as `DetailsSidebar.loadMetadata(for:)`: the
        // loader now takes injectable FileManager/log hooks, and its defaults belong to it.
        loadMetadata: @escaping @MainActor (String, @MainActor (String) -> Void) -> DetailsSidebar.FileMetadata?
            = { DetailsSidebar.loadMetadata(for: $0, logError: $1) },
        loadIcon: @escaping @MainActor (String) -> NSImage = { NSWorkspace.shared.icon(forFile: $0) },
        logWarning: @escaping @MainActor (String) -> Void = { _ = Logger.shared.warning($0) }
    ) {
        self.loadMetadata = loadMetadata
        self.loadIcon = loadIcon
        self.logWarning = logWarning
    }

    /// Returns the memoized metadata/icon for `path`, refreshing the cache if the path changed
    /// or the cache was invalidated. A nil stat result (missing path) is memoized too, so an
    /// unavailable item doesn't get re-statted on every render.
    func data(for path: String) -> (metadata: DetailsSidebar.FileMetadata?, icon: NSImage?) {
        if self.path != path {
            metadata = loadMetadata(path) { [self] message in reportOnce(message, for: path) }
            // A successful read clears the path's warned mark: whatever made it unreadable is
            // over, so the NEXT failure is news again rather than a suppressed repeat.
            if metadata != nil { warnedPaths.remove(path) }
            icon = metadata.map { loadIcon($0.path) }
            self.path = path
        }
        return (metadata, icon)
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
