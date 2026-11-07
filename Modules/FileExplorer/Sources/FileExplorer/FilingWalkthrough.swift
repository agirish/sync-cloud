import Events
import Sync

/// The per-file "ask each time" filing cursor: which rows are being stepped through, where the
/// user is, and which ones they approved.
///
/// Kept out of `AutomationsLens`'s view state so tests can reach it: it is the gate in front of
/// `applyAutomationFiling`, which moves files. Nothing moves until the walkthrough finishes:
/// `advance` only accumulates and `cancel` discards everything, so abandoning a review files
/// nothing.
struct FilingWalkthrough: Equatable {
    /// The rows to step through, in order. Empty when no walkthrough is running.
    private(set) var queue: [AutomationDryRunRow] = []
    /// The cursor into `queue`.
    private(set) var index: Int = 0
    /// The rows approved so far, in approval order.
    private(set) var approved: [AutomationDryRunRow] = []
    /// Whether a walkthrough is in progress.
    private(set) var isRunning: Bool = false

    /// The row awaiting a decision, or nil when nothing is running or the cursor is past the end.
    /// Optional rather than a subscript because an out-of-range array subscript traps: a caller's
    /// bounds check drifting from the index would crash the app instead of rendering nothing.
    var current: AutomationDryRunRow? {
        guard isRunning, queue.indices.contains(index) else { return nil }
        return queue[index]
    }

    /// One-based position for the "File N of M" label, clamped so it can never read past the end.
    var displayPosition: Int { min(index + 1, max(queue.count, 1)) }

    /// Begins a walkthrough over `rows`. An empty set starts nothing, so the caller can hand over
    /// a filtered list without checking it first.
    mutating func start(_ rows: [AutomationDryRunRow]) {
        guard !rows.isEmpty else { return }
        queue = rows
        index = 0
        approved = []
        isRunning = true
    }

    /// Records the decision for the current row and moves on.
    /// - Returns: The rows to file when this was the LAST row, otherwise nil. Non-nil means the
    ///   walkthrough is over — the caller applies exactly these and nothing else.
    @discardableResult
    mutating func advance(approved didApprove: Bool) -> [AutomationDryRunRow]? {
        guard isRunning else { return nil }
        if didApprove, let row = current { approved.append(row) }
        index += 1
        guard index >= queue.count else { return nil }
        return finish()
    }

    /// Ends the walkthrough and hands back what the user approved, clearing state either way.
    /// Empty when nothing was approved — the caller must not treat that as "file everything".
    mutating func finish() -> [AutomationDryRunRow] {
        let result = approved
        self = FilingWalkthrough()
        return result
    }

    /// Why an in-progress walkthrough went away. Each retirement logs its cause to
    /// `~/sync-cloud.log`, since to the user both look the same: the walkthrough vanished.
    enum RetirementCause {
        /// The user dismissed it — esc, or the Cancel button (one closure serves both).
        case dismissed
        /// A new rules preview started underneath it ("Preview all" mid-review) and the queue's
        /// rows belong to the superseded report — see `dryRunRunningChanged`.
        case newDryRun

        fileprivate var described: String {
            switch self {
            case .dismissed: return "dismissed (esc or Cancel)"
            case .newDryRun: return "retired by a new rules preview"
            }
        }
    }

    /// Abandons the walkthrough, discarding approvals, so a cancel files nothing: the review card
    /// moves nothing until the last decision. `cause` has no default so every call site says why.
    mutating func cancel(because cause: RetirementCause) {
        if isRunning {
            Logger.shared.info("Filing walkthrough \(cause.described) at file \(displayPosition) "
                + "of \(queue.count) — \(approved.count) approval(s) discarded, nothing filed")
        }
        self = FilingWalkthrough()
    }

    /// Tracks the dry-run preview's running flag, retiring an in-progress walkthrough when a new
    /// preview starts. The queue's rows carry the destinations of the report they came from, so
    /// carrying on over a superseded report would file into folders the new preview no longer
    /// proposes. Retiring moves nothing; the user re-enters from the new report.
    ///
    /// Only the rising edge retires: the flag also drops when the run finishes, and clearing then
    /// would wipe a walkthrough the user started meanwhile.
    mutating func dryRunRunningChanged(to isRunningDryRun: Bool) {
        guard isRunningDryRun else { return }
        cancel(because: .newDryRun)
    }
}
