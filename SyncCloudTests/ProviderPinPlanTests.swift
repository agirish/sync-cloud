import Testing
@testable import SyncCloud

/// Pins ``ProviderPinPlan`` — the pure half of the `pendingSwapProviderChanges` suppression
/// protocol. The invariant every writer relies on: `suppressCount` equals the number of id
/// writes that REALLY change a stored value (SwiftUI fires `onChange` only for a real change),
/// so seeding the counter with it can neither strand a leftover unit (which would swallow the
/// user's next real provider switch) nor under-count (which would let the onChange wipe the
/// lens results the retarget is protecting).
@Suite struct ProviderPinPlanTests {

    /// `(current left, current right, target left, target right, the writes)`; the suppression
    /// count is the number of writes, every time.
    @Test(arguments: [
        // Both sides change: the distinct-provider pane swap.
        ("icloud", "dropbox", "dropbox", "icloud", [PinAssignment(side: .left, providerId: "dropbox"),
                                                    PinAssignment(side: .right, providerId: "icloud")]),
        // An equal-provider swap: the swapped ids equal the current ones, so no write happens and
        // no onChange fires, and the swap must NOT seed the counter (a stranded unit would swallow
        // the next real provider switch).
        ("icloud", "icloud", "icloud", "icloud", []),
        // One side changes: compareCopies pins both panes to the lens provider, and the left pane
        // is usually already showing it, so only the right id write fires an onChange.
        ("icloud", "dropbox", "icloud", "icloud", [PinAssignment(side: .right, providerId: "icloud")]),
        ("dropbox", "icloud", "icloud", "icloud", [PinAssignment(side: .left, providerId: "icloud")]),
        // A full no-op: ending a duplicate review that never had to re-pin either pane, so the
        // restore must not seed any suppression.
        ("icloud", "dropbox", "icloud", "dropbox", []),
        // restoreCompareState after a cross-provider review: both sides to different targets.
        ("gdrive", "gdrive", "icloud", "dropbox", [PinAssignment(side: .left, providerId: "icloud"),
                                                   PinAssignment(side: .right, providerId: "dropbox")]),
    ] as [(String, String, String, String, [PinAssignment])])
    func eachRealChangeIsOneWriteAndOneSuppressedOnChange(currentLeft: String, currentRight: String,
                                                         targetLeft: String, targetRight: String,
                                                         writes: [PinAssignment]) {
        let plan = ProviderPinPlan.make(currentLeft: currentLeft, currentRight: currentRight,
                                        targetLeft: targetLeft, targetRight: targetRight)
        #expect(plan.assignments == writes)
        #expect(plan.suppressCount == writes.count)
    }
}

typealias PinAssignment = ProviderPinPlan.Assignment
