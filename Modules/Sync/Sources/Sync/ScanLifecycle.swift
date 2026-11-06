import Foundation

/// The scan lifecycle one lens publishes: the running flag and status line while a scan is in
/// flight, the has-completed flag behind the lens's intro-vs-results state, and the root the
/// on-screen results were scanned from.
///
/// One value type for every lens, so they share one state machine, enforced by the manager's
/// `beginScan` / `updateScan` / `endScan` / `completeScan` helpers below. `FileSyncManager` keeps
/// computed forwarders for the per-lens running, has-completed and root names; status has none, and
/// readers ask the lifecycle itself.
public struct ScanLifecycle: Sendable {
    /// True while the lens's scan is running.
    public internal(set) var isRunning = false

    /// Human-readable progress for the running scan (e.g. "Hashing 340 candidates…"). nil when no
    /// scan is running: nil is the one spelling of "idle", for every lens.
    ///
    /// An empty or whitespace status is normalized to nil on write, the one boundary every writer
    /// passes, so the readers' `status ?? "Analyzing…"` never paints a blank line under a live
    /// spinner. No `precondition`: a blank status is cosmetic, and crashing on one would be worse.
    /// A non-empty string is stored verbatim.
    public internal(set) var status: String? {
        get { storedStatus }
        set { storedStatus = newValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? newValue : nil }
    }

    /// Backing store for ``status``. Private so the normalization above can't be bypassed.
    private var storedStatus: String?

    /// True once a scan has completed at least once (drives the empty-vs-results state). Set only
    /// on completion, so a cancelled scan leaves the prior state intact rather than flashing an
    /// empty result.
    public internal(set) var hasCompleted = false

    /// The root the on-screen results were scanned from. Set with the results, not at scan start,
    /// so a cancelled rescan of another folder never relabels the previous results, and breadcrumbs
    /// stay correct if the user navigates elsewhere.
    public internal(set) var root: URL?

    /// When the on-screen results were produced: set with them, like ``root``, and the clock the
    /// freshness readout counts from. For a restored lens this is the original scan's time, not the
    /// reload's, or every relaunch would claim the results were fresh.
    public internal(set) var completedAt: Date?

    /// True when the results came off disk rather than from a scan in this session. Drives the
    /// "from your last scan" wording; a lens that has since been rescanned clears it.
    public internal(set) var isRestored = false

    /// Bumped when a scan starts or ends, so main-actor status/progress hops scheduled by a
    /// finished or cancelled scan drop themselves (see `FileSyncManager.updateScan`) instead of
    /// republishing stale text or numbers.
    var epoch = 0

    public init() {}
}

extension FileSyncManager {

    /// Marks a lens's scan started: publishes the running flag and initial status, and bumps the
    /// epoch. Returns the new epoch, which every mid-scan status publish must present to
    /// ``updateScan(_:epoch:status:)`` so an update from a superseded scan drops itself. Callers
    /// still guard re-entry (`guard !lifecycle.isRunning`) before calling this.
    @discardableResult
    func beginScan(_ lens: ReferenceWritableKeyPath<FileSyncManager, ScanLifecycle>,
                   status: String) -> Int {
        self[keyPath: lens].isRunning = true
        self[keyPath: lens].status = status
        self[keyPath: lens].epoch += 1
        return self[keyPath: lens].epoch
    }

    /// Publishes a mid-scan status update only while `epoch` is still the lens's current scan, so
    /// an update scheduled by a scan that has ended or been superseded drops itself instead of
    /// republishing stale status. Returns whether the epoch was current, so a caller with more
    /// epoch-scoped state (the duplicate scan's numeric progress) can gate it on the same check.
    @discardableResult
    func updateScan(_ lens: ReferenceWritableKeyPath<FileSyncManager, ScanLifecycle>,
                    epoch: Int, status: String) -> Bool {
        guard self[keyPath: lens].epoch == epoch else { return false }
        self[keyPath: lens].status = status
        return true
    }

    /// Marks a lens's scan ended, however it ended: bumps the epoch first, so status hops still
    /// queued on the main actor can't republish after this scan (or into the next one), then clears
    /// the running flag and status. Call from the scan body's `defer`.
    func endScan(_ lens: ReferenceWritableKeyPath<FileSyncManager, ScanLifecycle>) {
        self[keyPath: lens].epoch += 1
        self[keyPath: lens].isRunning = false
        self[keyPath: lens].status = nil
    }

    /// Publishes a completed scan's labels: the root the results were scanned from and the
    /// has-completed flag. Call with the results (after the final `Task.isCancelled` check), never
    /// at scan start: the root labels what's on screen, not the scan in flight.
    func completeScan(_ lens: ReferenceWritableKeyPath<FileSyncManager, ScanLifecycle>,
                      root: URL?, at completedAt: Date = Date()) {
        self[keyPath: lens].root = root
        self[keyPath: lens].completedAt = completedAt
        self[keyPath: lens].isRestored = false
        self[keyPath: lens].hasCompleted = true
    }

    /// Publishes results that came off disk rather than from a scan. As
    /// ``completeScan(_:root:at:)``, except that `completedAt` is the original scan's time and the
    /// restored flag is set, so the UI can say how old the reading is and where it came from.
    func restoreScan(_ lens: ReferenceWritableKeyPath<FileSyncManager, ScanLifecycle>,
                     root: URL?, completedAt: Date) {
        self[keyPath: lens].root = root
        self[keyPath: lens].completedAt = completedAt
        self[keyPath: lens].isRestored = true
        self[keyPath: lens].hasCompleted = true
    }

    /// Replaces a lens's in-flight scan task: cancels `previous` and returns a task that runs
    /// `operation` only once the cancelled one has fully unwound. Its `defer` must clear the
    /// running flag first, or the new scan's re-entrancy guard would silently drop the restart.
    /// Assign the result back to the lens's task property.
    func restartedScanTask(replacing previous: Task<Void, Never>?,
                           operation: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        previous?.cancel()
        return Task {
            _ = await previous?.value
            await operation()
        }
    }
}
