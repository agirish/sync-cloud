import Foundation

/// The scan lifecycle one Tidy lens publishes: the running flag and status line while a scan is
/// in flight, the has-completed flag that drives the lens's intro-vs-results state, and the root
/// the on-screen results were scanned from.
///
/// Before this type existed, each of the five lenses (Duplicates, Storage Lens, Names, Filing,
/// Automations preview) declared its own near-identical `@Published` cluster, and the copies had
/// drifted: status was `String?` in two and `String` in three, the root was `String?`/`URL?`, and
/// only the duplicate scan carried an epoch guard against stale progress hops. One value type per
/// lens keeps the five lifecycles structurally identical; the manager's `beginScan` /
/// `updateScan` / `endScan` / `completeScan` helpers (below) enforce one state machine for all of
/// them. The old per-lens property names live on as computed forwarders in `FileSyncManager`, so
/// existing app-side call sites read exactly what they always did.
public struct ScanLifecycle: Sendable {
    /// True while the lens's scan is running.
    public internal(set) var isRunning = false

    /// Human-readable progress for the running scan (e.g. "Hashing 340 candidates…").
    /// nil when no scan is running. Lenses whose legacy status property was a non-optional
    /// `String` surface this as `""` through their forwarder.
    public internal(set) var status: String?

    /// True once a scan has completed at least once (drives the empty-vs-results state).
    /// Set only on completion, so a cancelled scan leaves the prior state intact rather than
    /// flashing an empty result.
    public internal(set) var hasCompleted = false

    /// The root the current on-screen results were scanned from — set with the results, not at
    /// scan start, so a cancelled rescan of a different folder never relabels the previous
    /// results, and breadcrumbs stay correct if the user navigates elsewhere afterward.
    public internal(set) var root: URL?

    /// Bumped when a scan starts or ends, so main-actor status/progress hops scheduled by a
    /// finished or cancelled scan drop themselves (see `FileSyncManager.updateScan`) instead of
    /// republishing stale text or numbers.
    var epoch = 0

    public init() {}
}

extension FileSyncManager {

    /// Marks a lens's scan started: publishes the running flag and the initial status, and bumps
    /// the epoch. Returns the new epoch — every mid-scan status publish must present it to
    /// ``updateScan(_:epoch:status:)`` so an update from a superseded scan drops itself.
    ///
    /// Callers still guard re-entry (`guard !lifecycle.isRunning`) *before* calling this, exactly
    /// as the five hand-rolled lifecycles did.
    @discardableResult
    func beginScan(_ lens: ReferenceWritableKeyPath<FileSyncManager, ScanLifecycle>,
                   status: String) -> Int {
        self[keyPath: lens].isRunning = true
        self[keyPath: lens].status = status
        self[keyPath: lens].epoch += 1
        return self[keyPath: lens].epoch
    }

    /// Publishes a mid-scan status update, but ONLY while `epoch` is still the lens's current
    /// scan — an update scheduled by a scan that has since ended (or been superseded) drops
    /// itself instead of republishing stale status. Returns whether the epoch was current, so a
    /// caller with extra epoch-scoped state (the duplicate scan's numeric progress) can gate it
    /// on the same check.
    ///
    /// This guard is the protection the duplicate scan's unstructured hashing-progress hops
    /// always had; routing every lens's mid-scan writes through it extends that protection to
    /// the other four (a deliberate round-5 hardening — for those lenses every current write
    /// happens with the epoch still current, so nothing observable changes today).
    @discardableResult
    func updateScan(_ lens: ReferenceWritableKeyPath<FileSyncManager, ScanLifecycle>,
                    epoch: Int, status: String) -> Bool {
        guard self[keyPath: lens].epoch == epoch else { return false }
        self[keyPath: lens].status = status
        return true
    }

    /// Marks a lens's scan ended (however it ended — completed, cancelled, or failed): bumps the
    /// epoch FIRST so status hops still queued on the main actor can't republish after this scan
    /// has ended (or into the next scan), then clears the running flag and status. Call from the
    /// scan body's `defer`.
    func endScan(_ lens: ReferenceWritableKeyPath<FileSyncManager, ScanLifecycle>) {
        self[keyPath: lens].epoch += 1
        self[keyPath: lens].isRunning = false
        self[keyPath: lens].status = nil
    }

    /// Publishes a completed scan's labels: the root the results were scanned from and the
    /// has-completed flag. Called WITH the results (after the final `Task.isCancelled` check),
    /// never at scan start — the root labels what's on screen, not the in-flight scan.
    func completeScan(_ lens: ReferenceWritableKeyPath<FileSyncManager, ScanLifecycle>,
                      root: URL?) {
        self[keyPath: lens].root = root
        self[keyPath: lens].hasCompleted = true
    }

    /// Replaces a lens's in-flight scan task: cancels `previous` and returns a new task that runs
    /// `operation` only after the cancelled one has fully unwound — its `defer` must clear the
    /// lens's running flag first, or the new scan's re-entrancy guard would silently drop the
    /// restart. Assign the result back to the lens's task property.
    func restartedScanTask(replacing previous: Task<Void, Never>?,
                           operation: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        previous?.cancel()
        return Task {
            _ = await previous?.value
            await operation()
        }
    }
}
