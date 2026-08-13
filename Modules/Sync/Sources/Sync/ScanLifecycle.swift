import Foundation

/// The scan lifecycle one lens publishes: the running flag and status line while a scan is
/// in flight, the has-completed flag that drives the lens's intro-vs-results state, and the root
/// the on-screen results were scanned from.
///
/// Before this type existed, each of the five lenses it was extracted from (Duplicates, Storage
/// Lens, Names, Filing, Automations preview) declared its own near-identical `@Published` cluster,
/// and the copies had drifted: status was `String?` in two and `String` in three, the root was
/// `String?`/`URL?`, and only the duplicate scan carried an epoch guard against stale progress
/// hops. One value type per lens keeps them structurally identical, and a lens added since — the
/// filing re-survey, the sixth — got the same state machine for free rather than a seventh copy;
/// the manager's `beginScan` / `updateScan` / `endScan` / `completeScan` helpers (below) enforce
/// one state machine for all six. The heavily-used legacy per-lens property names (running/has-completed/root) live on as
/// computed forwarders in `FileSyncManager`; the per-lens status forwarders — where the idle
/// spelling had split into `""`-vs-nil — are gone, and every reader asks the lifecycle itself.
public struct ScanLifecycle: Sendable {
    /// True while the lens's scan is running.
    public internal(set) var isRunning = false

    /// Human-readable progress for the running scan (e.g. "Hashing 340 candidates…").
    /// nil when no scan is running — nil is the ONE spelling of "idle", for every lens; the
    /// legacy `?? ""` forwarders that let three lenses spell it as `""` are gone.
    ///
    /// **An empty status is normalized to nil here, at the one boundary every writer goes
    /// through.** Every reader now spells the fallback `status ?? "Analyzing…"`, where it used to
    /// ask `isEmpty` as well; with a plain stored property a writer that passed `""` — through
    /// ``FileSyncManager/beginScan(_:status:)``, ``FileSyncManager/updateScan(_:epoch:status:)``,
    /// or a direct assignment, since the setter is `internal` to the whole module — would paint a
    /// blank line under a live spinner instead of the fallback. Normalizing on write keeps that
    /// unbuildable rather than merely unbuilt, and does it without a `precondition`: a blank
    /// status is a cosmetic defect, and crashing on one would be the worse outcome.
    /// A non-empty string is stored verbatim; only empty-or-whitespace collapses to nil.
    public internal(set) var status: String? {
        get { storedStatus }
        set { storedStatus = newValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? newValue : nil }
    }

    /// Backing store for ``status``. Private so the normalization above cannot be bypassed —
    /// nothing outside this declaration can write the field.
    private var storedStatus: String?

    /// True once a scan has completed at least once (drives the empty-vs-results state).
    /// Set only on completion, so a cancelled scan leaves the prior state intact rather than
    /// flashing an empty result.
    public internal(set) var hasCompleted = false

    /// The root the current on-screen results were scanned from — set with the results, not at
    /// scan start, so a cancelled rescan of a different folder never relabels the previous
    /// results, and breadcrumbs stay correct if the user navigates elsewhere afterward.
    public internal(set) var root: URL?

    /// When the results currently on screen were produced. Set with them, like ``root``, and the
    /// clock the freshness readout counts from.
    ///
    /// For a restored lens this is the ORIGINAL scan's time, not the time it was reloaded — the
    /// whole point of showing an age is to say how old the reading is, and stamping it at load
    /// would make every relaunch claim the results were fresh.
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

    /// Marks a lens's scan started: publishes the running flag and the initial status, and bumps
    /// the epoch. Returns the new epoch — every mid-scan status publish must present it to
    /// ``updateScan(_:epoch:status:)`` so an update from a superseded scan drops itself.
    ///
    /// Callers still guard re-entry (`guard !lifecycle.isRunning`) *before* calling this, exactly
    /// as the five hand-rolled lifecycles this type replaced did.
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
                      root: URL?, at completedAt: Date = Date()) {
        self[keyPath: lens].root = root
        self[keyPath: lens].completedAt = completedAt
        self[keyPath: lens].isRestored = false
        self[keyPath: lens].hasCompleted = true
    }

    /// Publishes results that came off disk rather than from a scan. Identical to
    /// ``completeScan(_:root:at:)`` except that `completedAt` is the ORIGINAL scan's time and the
    /// restored flag is set, so the UI can say how old the reading is and where it came from.
    func restoreScan(_ lens: ReferenceWritableKeyPath<FileSyncManager, ScanLifecycle>,
                     root: URL?, completedAt: Date) {
        self[keyPath: lens].root = root
        self[keyPath: lens].completedAt = completedAt
        self[keyPath: lens].isRestored = true
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
