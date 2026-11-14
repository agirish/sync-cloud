import Foundation
import Sync
import Testing
@testable import FileExplorer

/// Pins the pure marker mapping behind the Duplicates card's keeper column: only rows the user can
/// actually pick draw a radio; groups without a keeper choice get a plain dot instead.
@Suite struct DuplicateKeeperMarkerTests {
    /// A radio only where it means something: a filled radio promises an empty one to click, so a
    /// group that allows no choice draws none, not even for its keeper. All four combinations,
    /// because the rule is one `guard`, and backwards it would make the pickable groups inert.
    @Test func aRadioIsDrawnOnlyWhereAKeeperCanBePicked() {
        #expect(DuplicateKeeperMarker.style(allowsKeeperChoice: true, isKeeper: true) == .keeper)
        #expect(DuplicateKeeperMarker.style(allowsKeeperChoice: true, isKeeper: false) == .selectable)
        // No choice: neither row advertises one.
        #expect(DuplicateKeeperMarker.style(allowsKeeperChoice: false, isKeeper: true) == .inert)
        #expect(DuplicateKeeperMarker.style(allowsKeeperChoice: false, isKeeper: false) == .inert)
    }

    /// The group kinds land on the right side: an overlapping group can't re-aim its keeper (which
    /// copy is "unique" comes from hashes the scan doesn't keep), so its rows are inert, while an
    /// identical group's are pickable.
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
/// really contains copies whose hash was skipped (cloud-only / unreadable), pluralizes
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
        // Both reasons stay, since a cloud-only copy and an unreadable one are fixed differently.
        // No size reason: the hasher skips nothing for size.
        #expect(one?.contains("unreadable") == true && one?.contains("not downloaded") == true)
        #expect(one?.contains("too large") == false)
    }
}

/// Pins the scan-level "skipped" pill tooltip: nil (pill hidden) for a clean scan, per-reason
/// breakdown listing only the reasons that occurred, singular/plural on the total.
@Suite struct DuplicateScanSkipNoteTests {
    private typealias Skips = FileSyncManager.DuplicateScanSkips

    /// The whole note for each reason alone and all three together. Hard links and files that
    /// could not be read (gone, unreadable, replaced between stat and open, rewritten mid-read) are
    /// skips like any other, or the results would just get smaller with no pill saying why. With
    /// nothing outside detection there is no pill, so the declined-text sentence has nowhere to
    /// hang: image-only scans not comparing by text is ordinary, not a warning.
    @Test(arguments: [
        (Skips(), nil),
        (Skips(cloudOnly: 3),
         "3 files outside duplicate detection: 3 cloud-only (not downloaded). Duplicates among them are not detected."),
        (Skips(multiLink: 2),
         "2 files outside duplicate detection: 2 hard-linked (trashing a link frees nothing). Duplicates among them are not detected."),
        (Skips(unverifiable: 4),
         "4 files outside duplicate detection: 4 unreadable or changed while being read. Duplicates among them are not detected."),
        (Skips(cloudOnly: 2, multiLink: 3, unverifiable: 1),
         "6 files outside duplicate detection: 2 cloud-only (not downloaded), 3 hard-linked (trashing a link frees nothing), 1 unreadable or changed while being read. Duplicates among them are not detected."),
        (Skips(textUnreadable: 853), nil),
    ] as [(FileSyncManager.DuplicateScanSkips, String?)])
    func theNoteListsOnlyTheReasonsThatOccurred(_ skips: FileSyncManager.DuplicateScanSkips, _ expected: String?) {
        #expect(DuplicateScanSkipNote.text(skips) == expected)
    }

    /// They are in the total, which counts files no duplicate claim of any kind could be made about.
    @Test func unreadableFilesAreInTheTotalUnlikeTheTextOnlyDeclines() {
        #expect(Skips(unverifiable: 4).total == 4)
        #expect(Skips(cloudOnly: 2, multiLink: 3, unverifiable: 4).total == 9)
        // A text-only decline is not in the total: those files were hashed and grouped normally.
        #expect(Skips(textUnreadable: 853).total == 0)
    }

    @Test func singularTotalDropsThePluralS() {
        let one = DuplicateScanSkipNote.text(Skips(cloudOnly: 1))
        #expect(one?.hasPrefix("1 file outside duplicate detection") == true)
    }

    @Test func documentsThatSaidTooLittleGetTheirOwnSentenceAndNoneOfTheCount() {
        // These files were hashed and grouped; only the weaker same-text comparison was declined.
        // Counting them would make the pill claim far more blindness than the scan has.
        let note = DuplicateScanSkipNote.text(Skips(cloudOnly: 1, textUnreadable: 853))
        #expect(note?.hasPrefix("1 file outside duplicate detection") == true)
        #expect(note?.contains("A further 853 documents were hashed but said too little") == true)
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

/// The destructive confirmation's wording, kept pure so it can be held to the claim the group
/// actually makes.
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

        // It doesn't lecture where the claim is byte identity.
        let identical = DuplicateRemovalPrompt.informativeText(
            kind: .identical, keeperName: "Jul 2023.pdf",
            keeperLocation: "Utilities ▸ PG&E", reclaimText: "402 KB")
        #expect(!identical.contains("weaker"))
        #expect(identical.hasSuffix("This can be undone with ⌘Z."))
    }

    /// The batch dialog's two pluralizations, at 1 and at many: the words a "clean up everything"
    /// confirmation is read on.
    @Test func theBatchQuestionCountsGroupsAndNamesTheProvider() {
        #expect(DuplicateRemovalPrompt.batchMessageText(groupCount: 1, providerName: "Dropbox")
                == "Clean up 1 group in Dropbox?")
        #expect(DuplicateRemovalPrompt.batchMessageText(groupCount: 12, providerName: "Dropbox")
                == "Clean up 12 groups in Dropbox?")
        // No provider name: never an empty gap in the sentence.
        #expect(DuplicateRemovalPrompt.batchMessageText(groupCount: 2, providerName: nil)
                == "Clean up 2 groups in this provider?")
    }

    @Test func theBatchLineCountsCopiesAndKeepsItsTwoPromises() {
        let one = DuplicateRemovalPrompt.batchInformativeText(copyCount: 1, reclaimText: "402 KB")
        #expect(one.hasPrefix("Moves 1 redundant copy to the Trash"))
        let many = DuplicateRemovalPrompt.batchInformativeText(copyCount: 9, reclaimText: "1.2 GB")
        #expect(many.hasPrefix("Moves 9 redundant copies to the Trash"))
        #expect(many.contains("1.2 GB"))
        // The claims that make the batch safe to agree to. `isRecommendedForBatch` admits only
        // `.identical`, so the dialog must name every other kind as excluded, or the unnamed ones
        // read as included.
        #expect(many.contains("Only byte-identical groups are included"))
        // The excluded kinds are derived from `Kind.allCases`, not listed, so a deleted kind's
        // name can't linger in the last sentence before a destructive batch.
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
        // A new match type must not fall through to a default that borrows another's words.
        for kind in DuplicateMatchType.Kind.allCases {
            let word = DuplicateRemovalPrompt.itemWord(for: kind, count: 1)
            #expect(!word.isEmpty)
            #expect(!word.hasSuffix("s"), "count 1 must read singular for \(kind)")
        }
    }
}


/// The breadcrumb under a copy's name is relative to the scanned folder and says so: the folder
/// itself is a crumb. Without it, a copy directly in the root reads as the provider alone, as if at
/// the top of the cloud, and looks unrelated to a neighbour deeper in the same trunk.
///
/// The call site isn't pinned (`crumbs(_:)` is a one-line forward, and a bitmap can't read text
/// back); the rule is.
@Suite struct DuplicateBreadcrumbTests {

    private func crumbs(_ path: String, root: String?, provider: String? = "iCloud") -> [String] {
        DuplicateGroupCard.crumbs(of: path, scanRoot: root, providerName: provider)
    }

    /// Two real paths: the first must not read as `iCloud` alone.
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

    /// A sibling whose name merely starts with the root's is not inside it, and must not be
    /// stripped into a false relative path.
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
