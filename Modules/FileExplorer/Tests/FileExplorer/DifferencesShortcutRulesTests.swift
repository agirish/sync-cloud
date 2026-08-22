import Testing
import Foundation
import Sync
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

    // MARK: - Menu items hold ids, and read values when they fire

    private func row(_ path: String, _ action: FileDifference.SyncAction,
                     id: UUID = UUID(), size: Int? = nil) -> FileDifference {
        FileDifference(id: id, relativePath: path,
                       leftItemPath: "/l/" + path, rightItemPath: "/r/" + path,
                       type: .missingOnRight, action: action, description: "",
                       leftFileSize: size, rightFileSize: nil)
    }

    /// **The values come from the rows passed in, never from whatever the caller captured.**
    ///
    /// The point of resolving at fire time: a menu built when a row read 100 bytes must act on
    /// the row as it reads NOW. Same id, different contents, and what comes back is the new one.
    @Test func transferItemsReturnsTheCurrentRowNotTheOneTheCallerRemembers() {
        let id = UUID()
        let stale = row("a.txt", .copyToRight, id: id, size: 100)
        let fresh = row("a.txt", .copyToRight, id: id, size: 999)
        let got = DifferencesShortcutRules.transferItems(rows: [fresh], selection: [id],
                                                        direction: .copyToRight)
        #expect(got.count == 1)
        #expect(got.first?.leftFileSize == 999, "resolution handed back the caller's stale copy")
        #expect(stale.leftFileSize == 100, "fixture: the two rows really do differ")
    }

    /// A row whose action has since flipped is no longer this direction's to move — the case a
    /// captured array cannot notice, because the capture recorded the old action.
    @Test func aRowWhoseActionFlippedIsNoLongerInThatDirection() {
        let id = UUID()
        let flipped = row("a.txt", .copyToLeft, id: id)
        #expect(DifferencesShortcutRules.transferItems(rows: [flipped], selection: [id],
                                                       direction: .copyToRight).isEmpty)
    }

    /// Ids that match nothing resolve to nothing. A full rescan mints fresh `FileDifference.id`s,
    /// so this is what a menu outliving its table does — and doing nothing is the right answer.
    @Test func idsThatMatchNoLiveRowResolveToNothing() {
        let onScreen = row("a.txt", .copyToRight)
        #expect(DifferencesShortcutRules.transferItems(rows: [onScreen], selection: [UUID()],
                                                       direction: .copyToRight).isEmpty)
        #expect(DifferencesShortcutRules.rows([onScreen], matching: [UUID()]).isEmpty)
    }

    /// The direction-blind half, used by the menu's Ignore item, keeps the rows' own order.
    @Test func rowsMatchingKeepsTheRowsOrderAndDropsTheRest() {
        let a = row("a.txt", .copyToRight), b = row("b.txt", .copyToLeft), c = row("c.txt", .copyToRight)
        let got = DifferencesShortcutRules.rows([a, b, c], matching: [c.id, a.id])
        #expect(got.map(\.relativePath) == ["a.txt", "c.txt"])
    }

    @Test func rowsMatchingNothingSelectedIsEmpty() {
        #expect(DifferencesShortcutRules.rows([row("a.txt", .copyToRight)], matching: []).isEmpty)
    }
}
