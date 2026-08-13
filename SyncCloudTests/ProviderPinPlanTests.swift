import Testing
@testable import SyncCloud

/// Pins ``ProviderPinPlan`` — the pure half of the `pendingSwapProviderChanges` suppression
/// protocol. The invariant every writer relies on: `suppressCount` equals the number of id
/// writes that REALLY change a stored value (SwiftUI fires `onChange` only for a real change),
/// so seeding the counter with it can neither strand a leftover unit (which would swallow the
/// user's next real provider switch) nor under-count (which would let the onChange wipe the
/// lens results the retarget is protecting).
@Suite struct ProviderPinPlanTests {

    // MARK: Both sides change — the distinct-provider pane swap

    @Test func swappingDistinctProvidersChangesBothSides() {
        let plan = ProviderPinPlan.make(
            currentLeft: "icloud", currentRight: "dropbox",
            targetLeft: "dropbox", targetRight: "icloud")
        #expect(plan.assignments == [
            ProviderPinPlan.Assignment(side: .left, providerId: "dropbox"),
            ProviderPinPlan.Assignment(side: .right, providerId: "icloud"),
        ])
        #expect(plan.suppressCount == 2)
    }

    // MARK: Equal-provider swap — nothing changes, nothing to suppress

    @Test func swappingASharedProviderIsANoOp() {
        // Both panes on the same provider: the swapped ids equal the current ones, so no write
        // happens and no onChange fires — the swap action must NOT seed the counter (a stranded
        // unit would swallow the next real provider switch).
        let plan = ProviderPinPlan.make(
            currentLeft: "icloud", currentRight: "icloud",
            targetLeft: "icloud", targetRight: "icloud")
        #expect(plan.assignments.isEmpty)
        #expect(plan.suppressCount == 0)
    }

    // MARK: One side changes — compareCopies pinning both panes to the lens provider

    @Test func pinningWhenLeftAlreadyMatchesWritesOnlyRight() {
        // compareCopies targets one provider for BOTH panes; the left pane is usually already
        // showing it, so only the right id write fires an onChange.
        let plan = ProviderPinPlan.make(
            currentLeft: "icloud", currentRight: "dropbox",
            targetLeft: "icloud", targetRight: "icloud")
        #expect(plan.assignments == [
            ProviderPinPlan.Assignment(side: .right, providerId: "icloud"),
        ])
        #expect(plan.suppressCount == 1)
    }

    @Test func pinningWhenRightAlreadyMatchesWritesOnlyLeft() {
        let plan = ProviderPinPlan.make(
            currentLeft: "dropbox", currentRight: "icloud",
            targetLeft: "icloud", targetRight: "icloud")
        #expect(plan.assignments == [
            ProviderPinPlan.Assignment(side: .left, providerId: "icloud"),
        ])
        #expect(plan.suppressCount == 1)
    }

    // MARK: Full no-op — restoreCompareState when nothing moved

    @Test func restoringAnUnchangedSetupChangesNothing() {
        // Ending a duplicate review that never had to re-pin either pane: the saved ids equal
        // the current ones, so the restore must not seed any suppression.
        let plan = ProviderPinPlan.make(
            currentLeft: "icloud", currentRight: "dropbox",
            targetLeft: "icloud", targetRight: "dropbox")
        #expect(plan.assignments.isEmpty)
        #expect(plan.suppressCount == 0)
    }

    // MARK: Both sides to different targets — restoreCompareState after a cross-provider review

    @Test func restoringTwoDifferentProvidersWritesBothSides() {
        let plan = ProviderPinPlan.make(
            currentLeft: "gdrive", currentRight: "gdrive",
            targetLeft: "icloud", targetRight: "dropbox")
        #expect(plan.assignments == [
            ProviderPinPlan.Assignment(side: .left, providerId: "icloud"),
            ProviderPinPlan.Assignment(side: .right, providerId: "dropbox"),
        ])
        #expect(plan.suppressCount == 2)
    }
}
