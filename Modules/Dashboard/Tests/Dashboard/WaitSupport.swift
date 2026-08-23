import Foundation
import Testing

/// Polls until `condition` holds, and **fails, at the caller, when it never does.**
///
/// The third copy of this helper. `Modules/Sync/Tests/Sync/TestSupport.swift` and
/// `SyncCloudTests/TestSupport.swift` carry the other two, and all three bodies are identical on
/// purpose: a test target cannot import another target's test code, so the choice is a duplicate or
/// a per-suite reinvention — and the reinvention is what this file exists to retire.
///
/// **What it replaces, and why that mattered.** `FileActionHandlerOperationTests` had its own
/// `waitUntil` that polled 200 × 20 ms and then simply **returned**. Nothing read the outcome, so
/// "the thing happened" and "I stopped waiting" were the same result, and a contended run fell
/// through to the assertions and reported *those* instead. On 2026-08-22
/// `testCopyItemsFromLeftCopiesToRightPane` failed CI on a banner's `message` and `isUndoable`,
/// both `nil`, 19.7 seconds in, with nothing in either message about waiting — while the same suite
/// was green locally and green on the next CI run. It is recorded under "Fixed pumps and fixed
/// sleeps" in `docs/flaky-tests.md`.
///
/// **The poll floor is the part that is easy to leave out.** A deadline in seconds is a throughput
/// bet: measured on 2026-08-08 a poll costs its nominal 10 ms idle and **223 ms** under load, 22×,
/// so five seconds buys ~500 evaluations on a quiet machine and ~22 on a busy one — the budget
/// shrinks exactly when the wait needs it most. The loop therefore runs at least `waitPollFloor`
/// times whatever the clock says, and the poll count goes in the failure because **the count is the
/// diagnosis**: a handful means the wait was starved, hundreds means the condition was genuinely
/// disproved.
@MainActor
func waitUntil(
    _ what: Comment,
    timeout: TimeInterval = 5,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async {
    var polls = 0
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while polls < waitPollFloor || ContinuousClock.now < deadline {
        polls += 1
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    // The poll count IS the diagnosis: a handful means starved, hundreds means disproved.
    #expect(condition(), "\(what.rawValue) — still false after \(polls) polls",
            sourceLocation: sourceLocation)
}

/// The fewest polls `waitUntil` will make before it may give up, however little of its deadline is
/// left. Same number, and the same reason, as the copies in `Modules/Sync/Tests/Sync/TestSupport
/// .swift` and `SyncCloudTests/TestSupport.swift`.
let waitPollFloor = 50

/// Polls like ``waitUntil(_:timeout:sourceLocation:_:)`` but **asserts nothing when it gives up**.
///
/// For cleanup that runs *after* every assertion and genuinely does not care — restoring a file
/// from the Trash so a run does not leave litter behind. A failure here would be noise about
/// hygiene, reported against a test whose subject already passed.
///
/// It exists so that "this wait may expire" is a decision written at the call site rather than a
/// property of the helper. That is the whole lesson of the entry above: the old helper let every
/// caller expire in silence, including the ten that could not afford to.
@MainActor
func waitBestEffort(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
    var polls = 0
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while polls < waitPollFloor || ContinuousClock.now < deadline {
        polls += 1
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}
