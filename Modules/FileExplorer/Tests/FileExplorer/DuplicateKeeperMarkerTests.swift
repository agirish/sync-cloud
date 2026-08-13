import Sync
import Testing
@testable import FileExplorer

/// Pins the pure marker mapping behind the Tidy card's keeper column: only rows the user can
/// actually pick draw a radio; groups without a keeper choice get a plain dot instead.
@Suite struct DuplicateKeeperMarkerTests {
    @Test func keeperShowsFilledRadioRegardlessOfChoice() {
        #expect(DuplicateKeeperMarker.style(allowsKeeperChoice: true, isKeeper: true) == .keeper)
        #expect(DuplicateKeeperMarker.style(allowsKeeperChoice: false, isKeeper: true) == .keeper)
    }

    @Test func nonKeeperIsSelectableOnlyWhenGroupAllowsChoice() {
        #expect(DuplicateKeeperMarker.style(allowsKeeperChoice: true, isKeeper: false) == .selectable)
        #expect(DuplicateKeeperMarker.style(allowsKeeperChoice: false, isKeeper: false) == .inert)
    }

    @Test func accessibilityLabelsReadSensibly() {
        #expect(DuplicateKeeperMarker.keeper.accessibilityLabel == "Kept copy")
        #expect(DuplicateKeeperMarker.selectable.accessibilityLabel == "Keep this copy")
        #expect(DuplicateKeeperMarker.inert.accessibilityLabel == nil)
    }
}

/// Pins the wording gate for the card's unverified-content caveat: it appears only when a group
/// really contains copies whose hash was skipped (too large / cloud-only / unreadable), pluralizes
/// correctly, and never fires for a fully verified group.
@Suite struct DuplicateUnverifiedNoteTests {
    @Test func noNoteWhenEveryCopyIsVerified() {
        #expect(DuplicateUnverifiedNote.text(unverifiedCount: 0) == nil)
    }

    @Test func singularAndPluralWording() {
        let one = DuplicateUnverifiedNote.text(unverifiedCount: 1)
        #expect(one?.hasPrefix("1 copy couldn't be content-verified") == true)
        let three = DuplicateUnverifiedNote.text(unverifiedCount: 3)
        #expect(three?.hasPrefix("3 copies couldn't be content-verified") == true)
    }
}

/// Pins the scan-level "skipped" pill tooltip: nil (pill hidden) for a clean scan, per-reason
/// breakdown listing only the reasons that occurred, singular/plural on the total.
@Suite struct DuplicateScanSkipNoteTests {
    private typealias Skips = FileSyncManager.DuplicateScanSkips

    @Test func nilWhenNothingWasSkipped() {
        #expect(DuplicateScanSkipNote.text(Skips()) == nil)
    }

    @Test func listsOnlyTheReasonsThatOccurred() {
        let largeOnly = DuplicateScanSkipNote.text(Skips(tooLarge: 2, cloudOnly: 0))
        #expect(largeOnly == "2 files outside duplicate detection: 2 too large to hash. Duplicates among them are not detected.")
        let cloudOnly = DuplicateScanSkipNote.text(Skips(tooLarge: 0, cloudOnly: 3))
        #expect(cloudOnly == "3 files outside duplicate detection: 3 cloud-only (not downloaded). Duplicates among them are not detected.")
        // Hard links joined the ledger in round 6: dropped files must never just quietly
        // shrink the results ("over-report beats hide" applies to the accounting too).
        let links = DuplicateScanSkipNote.text(Skips(multiLink: 2))
        #expect(links == "2 files outside duplicate detection: 2 hard-linked (trashing a link frees nothing). Duplicates among them are not detected.")
    }

    @Test func combinesBothReasonsWithATotal() {
        let both = DuplicateScanSkipNote.text(Skips(tooLarge: 1, cloudOnly: 2, multiLink: 3))
        #expect(both == "6 files outside duplicate detection: 1 too large to hash, 2 cloud-only (not downloaded), 3 hard-linked (trashing a link frees nothing). Duplicates among them are not detected.")
    }

    @Test func singularTotalDropsThePluralS() {
        let one = DuplicateScanSkipNote.text(Skips(tooLarge: 1, cloudOnly: 0))
        #expect(one?.hasPrefix("1 file outside duplicate detection") == true)
    }

    @Test func documentsThatSaidTooLittleGetTheirOwnSentenceAndNoneOfTheCount() {
        // These files WERE hashed and grouped; only the weaker same-text comparison was declined.
        // Folding them into the total would make the pill claim a much larger blindness than the
        // scan actually has — 853 of 10,569 on the tree this was measured against.
        let note = DuplicateScanSkipNote.text(Skips(tooLarge: 1, textUnreadable: 853))
        #expect(note?.hasPrefix("1 file outside duplicate detection") == true)
        #expect(note?.contains("A further 853 documents were hashed but said too little") == true)
    }

    @Test func nothingSkippedStaysSilentEvenWhenDocumentsSaidTooLittle() {
        // The pill counts files outside detection, and there are none — so no pill, and the
        // declined-text sentence has nowhere to hang. Deliberate: an image-only scan not being
        // comparable by text is the ordinary state of a tree full of scans, not a warning.
        #expect(DuplicateScanSkipNote.text(Skips(textUnreadable: 853)) == nil)
    }

    @Test func oneDeclinedDocumentReadsSingular() {
        let note = DuplicateScanSkipNote.text(Skips(cloudOnly: 1, textUnreadable: 1))
        #expect(note?.contains("A further 1 document was hashed but said too little") == true)
        #expect(note?.contains("a re-downloaded copy of it is not detected") == true)
    }
}

/// Pins the cursor-stack bookkeeping behind the selectable radio's hover effect: NSCursor's
/// stack is global, so a push must happen exactly once per hovered state and a pop only for a
/// push we made — even when SwiftUI repeats an onHover callback without a state change.
@Suite struct HoverCursorTransitionTests {
    @Test func pushesOnlyOnEnterTransition() {
        #expect(HoverCursorTransition.decide(wasHovering: false, isNowInside: true) == .push)
        // Repeated onHover(true) without an intervening false must not double-push.
        #expect(HoverCursorTransition.decide(wasHovering: true, isNowInside: true) == .none)
    }

    @Test func popsOnlyOnExitTransition() {
        #expect(HoverCursorTransition.decide(wasHovering: true, isNowInside: false) == .pop)
        // Repeated onHover(false) must not pop a cursor someone else pushed.
        #expect(HoverCursorTransition.decide(wasHovering: false, isNowInside: false) == .none)
    }
}

/// The destructive confirmation's wording. Pure, so it can be held to the claim the group actually
/// makes — which is the whole reason it was lifted out of the view.
@Suite struct DuplicateRemovalPromptTests {

    @Test func aSameTextCopyIsNeverCalledRedundant() {
        // The card refuses that word (badge, subtitle, thumbnail caption); the confirmation is the
        // point of no return and must refuse it too.
        let one = DuplicateRemovalPrompt.itemWord(for: .sameText, count: 1)
        let many = DuplicateRemovalPrompt.itemWord(for: .sameText, count: 3)
        #expect(one == "matching copy")
        #expect(many == "matching copies")
        #expect(!one.contains("redundant"))
        #expect(!many.contains("redundant"))
    }

    @Test func theOtherKindsKeepTheirOwnWords() {
        #expect(DuplicateRemovalPrompt.itemWord(for: .identical, count: 1) == "redundant copy")
        #expect(DuplicateRemovalPrompt.itemWord(for: .identical, count: 2) == "redundant copies")
        #expect(DuplicateRemovalPrompt.itemWord(for: .versions, count: 1) == "older version")
        #expect(DuplicateRemovalPrompt.itemWord(for: .versions, count: 2) == "older versions")
    }

    @Test func theSameTextConfirmationSaysWhatIsBeingAgreedTo() {
        let sameText = DuplicateRemovalPrompt.informativeText(
            kind: .sameText, keeperName: "Jul 2023.pdf",
            keeperLocation: "Utilities ▸ PG&E", reclaimText: "402 KB")
        #expect(sameText.contains("weaker than a byte-for-byte match"))
        #expect(sameText.contains("402 KB"))
        #expect(sameText.hasSuffix("This can be undone with ⌘Z."))

        // …and does not lecture where the claim IS byte-identity.
        let identical = DuplicateRemovalPrompt.informativeText(
            kind: .identical, keeperName: "Jul 2023.pdf",
            keeperLocation: "Utilities ▸ PG&E", reclaimText: "402 KB")
        #expect(!identical.contains("weaker"))
        #expect(identical.hasSuffix("This can be undone with ⌘Z."))
    }

    @Test func everyMatchKindHasAWordAndNoneSaysNothing() {
        // A new match type must not fall through to a default that borrows another's vocabulary —
        // the failure this whole helper exists to prevent.
        for kind in DuplicateMatchType.Kind.allCases {
            let word = DuplicateRemovalPrompt.itemWord(for: kind, count: 1)
            #expect(!word.isEmpty)
            #expect(!word.hasSuffix("s"), "count 1 must read singular for \(kind)")
        }
    }
}

