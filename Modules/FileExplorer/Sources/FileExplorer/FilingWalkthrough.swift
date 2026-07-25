import Sync

/// The per-file "ask each time" filing cursor: which rows are being stepped through, where the
/// user is, and which ones they approved.
///
/// Extracted from `AutomationsLens`'s `@State` because this is the gate in front of
/// `applyAutomationFiling`, which MOVES files — the decision about what reaches a destructive
/// operation should not live in un-extracted view glue where no test can reach it. (The same
/// argument that got `CompareReviewReducer` and `DuplicateReviewCoordinator` pulled out of
/// `ContentView`, after two teardown bugs shipped from exactly that shape.)
///
/// Nothing moves until the walkthrough finishes: `advance` only accumulates, and `cancel`
/// discards everything, so abandoning a review mid-way files nothing.
struct FilingWalkthrough: Equatable {
    /// The rows to step through, in order. Empty when no walkthrough is running.
    private(set) var queue: [AutomationDryRunRow] = []
    /// The cursor into `queue`.
    private(set) var index: Int = 0
    /// The rows approved so far, in approval order.
    private(set) var approved: [AutomationDryRunRow] = []
    /// Whether a walkthrough is in progress.
    private(set) var isRunning: Bool = false

    /// The row awaiting a decision, or nil when nothing is running or the cursor has run off the
    /// end. An OPTIONAL rather than a subscript on purpose: the view read `queue[index]` behind a
    /// bounds check made separately by its caller, and a Swift array subscript out of range is a
    /// fatal trap, not a recoverable error — so any future drift between the two would crash the
    /// app rather than render nothing.
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

    /// Abandons the walkthrough. Approvals are discarded, so a cancel files nothing at all — the
    /// promise the review card makes by not moving anything until the last decision.
    mutating func cancel() {
        self = FilingWalkthrough()
    }
}
