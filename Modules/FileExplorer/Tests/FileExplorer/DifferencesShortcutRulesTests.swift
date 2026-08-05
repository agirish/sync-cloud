import Testing
@testable import FileExplorer

/// The availability rules behind the ⇧⌘R / ⇧⌘V / ⇧⌘F menu items. Each test starts from the
/// one all-good fixture and flips a SINGLE axis, so every parameter is proven to matter — a
/// parameter the view stopped passing correctly would otherwise go quiet without a failure
/// (the published value itself is unreadable without a scene).
@Suite struct DifferencesShortcutRulesTests {

    // MARK: ⇧⌘R Review

    @Test func reviewIsAvailableInTheQuietState() {
        #expect(DifferencesShortcutRules.reviewAvailable(
            sessionActive: false, targetCount: 3, blocked: false, suspended: false))
    }

    @Test func aRunningSessionWithholdsReview() {
        #expect(!DifferencesShortcutRules.reviewAvailable(
            sessionActive: true, targetCount: 3, blocked: false, suspended: false))
    }

    @Test func nothingToReviewWithholdsReview() {
        #expect(!DifferencesShortcutRules.reviewAvailable(
            sessionActive: false, targetCount: 0, blocked: false, suspended: false))
    }

    @Test func aBlockingSyncWithholdsReview() {
        #expect(!DifferencesShortcutRules.reviewAvailable(
            sessionActive: false, targetCount: 3, blocked: true, suspended: false))
    }

    @Test func aDestinationPickWithholdsReview() {
        #expect(!DifferencesShortcutRules.reviewAvailable(
            sessionActive: false, targetCount: 3, blocked: false, suspended: true))
    }

    // MARK: ⇧⌘V Verify

    @Test func verifyIsAvailableInTheQuietState() {
        #expect(DifferencesShortcutRules.verifyAvailable(
            sessionActive: false, verifiableCount: 1, blocked: false, collapsed: false,
            suspended: false))
    }

    @Test func aRunningSessionWithholdsVerify() {
        #expect(!DifferencesShortcutRules.verifyAvailable(
            sessionActive: true, verifiableCount: 1, blocked: false, collapsed: false,
            suspended: false))
    }

    @Test func nothingVerifiableWithholdsVerify() {
        #expect(!DifferencesShortcutRules.verifyAvailable(
            sessionActive: false, verifiableCount: 0, blocked: false, collapsed: false,
            suspended: false))
    }

    @Test func aBlockingSyncWithholdsVerify() {
        #expect(!DifferencesShortcutRules.verifyAvailable(
            sessionActive: false, verifiableCount: 1, blocked: true, collapsed: false,
            suspended: false))
    }

    @Test func aDestinationPickWithholdsVerify() {
        #expect(!DifferencesShortcutRules.verifyAvailable(
            sessionActive: false, verifiableCount: 1, blocked: false, collapsed: false,
            suspended: true))
    }

    /// Verify's progress strip renders inside the pane; collapsed to the header strip it would
    /// be a background run with hidden feedback. (Review deliberately has NO collapse gate —
    /// starting one re-opens the pane, so the same axis there would gate nothing.)
    @Test func aCollapsedPaneWithholdsVerify() {
        #expect(!DifferencesShortcutRules.verifyAvailable(
            sessionActive: false, verifiableCount: 1, blocked: false, collapsed: true,
            suspended: false))
    }

    // MARK: ⇧⌘F fold

    @Test func foldIsAvailableInTheQuietState() {
        #expect(DifferencesShortcutRules.foldAvailable(
            sessionActive: false, collapsed: false, sectionCount: 2, suspended: false))
    }

    @Test func aRunningSessionWithholdsFold() {
        #expect(!DifferencesShortcutRules.foldAvailable(
            sessionActive: true, collapsed: false, sectionCount: 2, suspended: false))
    }

    @Test func aCollapsedPaneWithholdsFold() {
        #expect(!DifferencesShortcutRules.foldAvailable(
            sessionActive: false, collapsed: true, sectionCount: 2, suspended: false))
    }

    @Test func anUnsectionedTableWithholdsFold() {
        #expect(!DifferencesShortcutRules.foldAvailable(
            sessionActive: false, collapsed: false, sectionCount: 0, suspended: false))
    }

    @Test func aDestinationPickWithholdsFold() {
        #expect(!DifferencesShortcutRules.foldAvailable(
            sessionActive: false, collapsed: false, sectionCount: 2, suspended: true))
    }
}
