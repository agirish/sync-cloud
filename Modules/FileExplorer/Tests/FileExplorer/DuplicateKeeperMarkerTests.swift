import Foundation
import Sync
import Testing
@testable import FileExplorer

/// Pins the pure marker mapping behind the Duplicates card's keeper column: only rows the user can
/// actually pick draw a radio; groups without a keeper choice get a plain dot instead.
@Suite struct DuplicateKeeperMarkerTests {
    /// **A radio only where a radio means something.** A filled radio is a promise that an empty
    /// one exists to click, and this returned one for the keeper of every group — including the
    /// kinds that allow no choice at all. His report on a merge card: "Why is there a checkbox,
    /// especially if we can't choose among the rows?"
    ///
    /// All four combinations, because the fix is one `guard` and getting it backwards would make
    /// the pickable groups the inert ones.
    @Test func aRadioIsDrawnOnlyWhereAKeeperCanBePicked() {
        #expect(DuplicateKeeperMarker.style(allowsKeeperChoice: true, isKeeper: true) == .keeper)
        #expect(DuplicateKeeperMarker.style(allowsKeeperChoice: true, isKeeper: false) == .selectable)
        // No choice: neither row advertises one, which is what this type's doc always claimed.
        #expect(DuplicateKeeperMarker.style(allowsKeeperChoice: false, isKeeper: true) == .inert)
        #expect(DuplicateKeeperMarker.style(allowsKeeperChoice: false, isKeeper: false) == .inert)
    }

    /// And the group kinds land on the right side of it: an overlapping group cannot re-aim its
    /// keeper (which copy is "unique" comes from hashes the scan does not retain), so its rows are
    /// inert — while an identical group's are pickable.
    @Test func theKindsThatAllowAChoiceAreTheOnesWithRadios() {
        func marker(_ type: DuplicateMatchType, keeper: Bool) -> DuplicateKeeperMarker {
            let g = DuplicateGroup(matchType: type, name: "x", isDirectory: true, copies: [],
                                   reclaimableBytes: 0)
            return DuplicateKeeperMarker.style(allowsKeeperChoice: g.allowsKeeperChoice,
                                               isKeeper: keeper)
        }
        #expect(marker(.overlapping(sharedFraction: 0.9), keeper: true) == .inert)
        #expect(marker(.overlapping(sharedFraction: 0.9), keeper: false) == .inert)
        #expect(marker(.identical, keeper: true) == .keeper)
        #expect(marker(.identical, keeper: false) == .selectable)
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
        #expect(one?.hasPrefix("1 not content-verified") == true)
        let three = DuplicateUnverifiedNote.text(unverifiedCount: 3)
        #expect(three?.hasPrefix("3 not content-verified") == true)
        // Both reasons stay: a cloud-only copy and a too-large one are fixed by different things.
        #expect(one?.contains("too large") == true && one?.contains("not downloaded") == true)
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

    /// **The verdict that used to fall through a bare `break`.** A file that was gone, unreadable,
    /// replaced between the stat and the open, or rewritten mid-read left the scan counted by
    /// nothing: no pill, no note, no log — the results simply got smaller. The mid-read coherence
    /// check then added two more ways to reach it, widening a drain nobody could see. It is a skip
    /// like every other skip, so it says so.
    @Test func filesThatCouldNotBeReadAreCountedLikeEveryOtherSkip() {
        let note = DuplicateScanSkipNote.text(Skips(unverifiable: 4))
        #expect(note == "4 files outside duplicate detection: 4 unreadable or changed while being read. Duplicates among them are not detected.")
    }

    /// And it is in the total, because the total is defined as "files no duplicate claim of any kind
    /// could be made about" — which is exactly what these are.
    @Test func unreadableFilesAreInTheTotalUnlikeTheTextOnlyDeclines() {
        #expect(Skips(unverifiable: 4).total == 4)
        #expect(Skips(tooLarge: 1, cloudOnly: 2, multiLink: 3, unverifiable: 4).total == 10)
        // The contrast that makes the rule legible: a text-only decline is NOT in the total,
        // because those files were hashed and grouped normally.
        #expect(Skips(textUnreadable: 853).total == 0)
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

    /// The batch dialog's two pluralizations, at 1 and at many. They are the words a "clean up
    /// everything" confirmation is read on, and until this pair moved into the prompt type they
    /// were interpolated inline in the view where nothing could reach them.
    @Test func theBatchQuestionCountsGroupsAndNamesTheProvider() {
        #expect(DuplicateRemovalPrompt.batchMessageText(groupCount: 1, providerName: "Dropbox")
                == "Clean up 1 group in Dropbox?")
        #expect(DuplicateRemovalPrompt.batchMessageText(groupCount: 12, providerName: "Dropbox")
                == "Clean up 12 groups in Dropbox?")
        // No provider name to say — never an empty gap in the sentence.
        #expect(DuplicateRemovalPrompt.batchMessageText(groupCount: 2, providerName: nil)
                == "Clean up 2 groups in this provider?")
    }

    @Test func theBatchLineCountsCopiesAndKeepsItsTwoPromises() {
        let one = DuplicateRemovalPrompt.batchInformativeText(copyCount: 1, reclaimText: "402 KB")
        #expect(one.hasPrefix("Moves 1 redundant copy to the Trash"))
        let many = DuplicateRemovalPrompt.batchInformativeText(copyCount: 9, reclaimText: "1.2 GB")
        #expect(many.hasPrefix("Moves 9 redundant copies to the Trash"))
        #expect(many.contains("1.2 GB"))
        // The two claims that make the batch safe to agree to. **The exclusion list used to name
        // two of the four kinds it excludes**: `isRecommendedForBatch` admits only `.identical`,
        // so versions and same-text groups are left untouched as well, and a dialog that listed
        // half of them read as if the other half were included.
        #expect(many.contains("Only byte-identical groups are included"))
        // **Every kind the batch excludes, derived rather than listed.** The hand-written list
        // said four and kept saying "name-only" after that kind was deleted — a stale word in the
        // last sentence before a destructive batch, held there by this very assertion.
        let excluded = DuplicateMatchType.Kind.allCases.filter { kind in
            let g = DuplicateGroup(matchType: DuplicateSections.representative(kind), name: "x",
                                   isDirectory: false, copies: [], reclaimableBytes: 0)
            return !g.isRecommendedForBatch
        }
        #expect(excluded.count == 3, "identical is the only kind the batch includes")
        for kind in excluded {
            let word = ["versions": "versions", "sameText": "same-text",
                        "overlapping": "overlapping"]["\(kind)"] ?? "\(kind)"
            #expect(many.contains(word), "\(kind) is excluded and the dialog must say so")
        }
        #expect(!many.contains("name-only"), "a kind that no longer exists must not be named")
        #expect(many.hasSuffix("Everything can be undone with ⌘Z."))
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


/// The breadcrumb under a copy's name — his report: "the 2 paths aren't correctly listed; rather
/// it's relative to selected directory to organize, but that should be indicated clearly."
///
/// Stripping the scanned root silently made a folder sitting directly in it read as the provider
/// alone, as though it lived at the top of the cloud, while its neighbour six levels down read as
/// a full path. The pair looked unrelated when in fact they share a trunk.
///
/// **The call site is not pinned** — `crumbs(_:)` is a one-line forward to this, and a bitmap
/// cannot read text back. What is pinned is the rule.
@Suite struct DuplicateBreadcrumbTests {

    private func crumbs(_ path: String, root: String?, provider: String? = "iCloud") -> [String] {
        DuplicateGroupCard.crumbs(of: path, scanRoot: root, providerName: provider)
    }

    /// His two paths. Before, the first was `iCloud` alone.
    @Test func theScannedFolderIsACrumb() {
        let root = "/Users/x/Documents/Immigration"
        #expect(crumbs("\(root)/Visa", root: root) == ["iCloud", "Immigration", "Visa"])
        #expect(crumbs("\(root)/Authorization/H-1B/Petition/Visa", root: root)
                == ["iCloud", "Immigration", "Authorization", "H-1B", "Petition", "Visa"])
    }

    /// A root whose own name says nothing the reader chose adds no crumb: a whole volume, or the
    /// home directory, where "Immigration" would have been the point.
    @Test func aVolumeOrHomeRootAddsNoCrumb() {
        #expect(crumbs("/Files/a.pdf", root: "/") == ["iCloud", "Files", "a.pdf"])
        let home = NSHomeDirectory()
        #expect(crumbs("\(home)/a.pdf", root: home) == ["iCloud", "a.pdf"])
    }

    /// The boundary rule the root-stripping has always carried: a sibling whose name merely starts
    /// with the root's is not inside it, and must not be stripped into a false relative path.
    @Test func aSiblingWithASharedPrefixIsNotInsideTheRoot() {
        let out = crumbs("/data/DocsBackup/a.pdf", root: "/data/Docs")
        #expect(!out.contains("Docs"), "stripped as though it were inside: \(out)")
        #expect(out.contains("DocsBackup"))
    }

    /// No provider and no root: the plain tilde-abbreviated path, unchanged.
    @Test func withoutARootItIsJustThePath() {
        let out = crumbs("\(NSHomeDirectory())/Docs/a.pdf", root: nil, provider: nil)
        #expect(out == ["~", "Docs", "a.pdf"])
    }
}
