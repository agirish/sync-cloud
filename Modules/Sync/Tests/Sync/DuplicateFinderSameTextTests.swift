import Foundation
import Testing
@testable import Sync

/// The same-text pass: what it groups, what it refuses to group, and the promises it must not be
/// able to break.
@Suite struct DuplicateFinderSameTextTests {

    /// The measured case: one bill downloaded twice, re-stamped, so the byte hashes differ and the
    /// sizes may too. Parents each hold a unique file so the folders themselves are not duplicates.
    private var restampedPair: (tree: [FileNode], hashes: [String: String]) {
        let tree = [
            dir("/root/Utilities", [file("/root/Utilities/Jul 2023.pdf", size: 402_394),
                                    file("/root/Utilities/u-only.txt")]),
            dir("/root/Downloads", [file("/root/Downloads/9829custbill07182023.pdf", size: 402_401),
                                file("/root/Downloads/d-only.txt")]),
        ]
        let hashes = [
            "/root/Utilities/Jul 2023.pdf": "BYTES-A",
            "/root/Downloads/9829custbill07182023.pdf": "BYTES-B",
            "/root/Utilities/u-only.txt": "UA", "/root/Downloads/d-only.txt": "UB",
        ]
        return (tree, hashes)
    }

    // MARK: What it finds

    @Test func documentsWithMatchingTextButDifferentBytesGroup() {
        let (tree, hashes) = restampedPair
        let groups = DuplicateFinder.findGroups(
            tree: tree, fileHashes: hashes,
            textFingerprints: ["/root/Utilities/Jul 2023.pdf": "FP",
                               "/root/Downloads/9829custbill07182023.pdf": "FP"])

        #expect(groups.count == 1)
        #expect(groups[0].matchType == .sameText)
        #expect(groups[0].copies.count == 2)
        // The Downloads copy is the redundant one — "Utilities" is the less archive-like home,
        // which is `chooseKeeper`'s rule and not merely the alphabetically-earlier path.
        #expect(groups[0].keeper.path == "/root/Utilities/Jul 2023.pdf")
        #expect(groups[0].reclaimableBytes == 402_401)

        // The never-auto-trash rule. Text equality is weaker than byte equality (on a real tree,
        // 9 of 212 such groups were a signed copy beside its original or a visual revision), so
        // the batch must not act on it blind…
        #expect(groups[0].isRecommendedForBatch == false)
        // …but the user can still resolve it themselves once they have looked.
        #expect(groups[0].isFullyResolvableByRemoval)
        #expect(groups[0].allowsKeeperChoice)
        #expect(groups[0].recommendedRemovalPaths == ["/root/Downloads/9829custbill07182023.pdf"])
    }

    /// The pair is not grouped: with no document read (the feature is off then, which is why the
    /// other grouping tests pass unchanged), with the option off, on different fingerprints, and
    /// on a fingerprint on one side only, which is not evidence.
    @Test(arguments: [
        (fingerprints: [String: String](), detectSameText: true),
        (["/root/Utilities/Jul 2023.pdf": "FP", "/root/Downloads/9829custbill07182023.pdf": "FP"], false),
        (["/root/Utilities/Jul 2023.pdf": "FP-A", "/root/Downloads/9829custbill07182023.pdf": "FP-B"], true),
        (["/root/Utilities/Jul 2023.pdf": "FP"], true),
    ])
    func theRestampedPairIsNotGrouped(fingerprints: [String: String], detectSameText: Bool) {
        let (tree, hashes) = restampedPair
        var options = DuplicateFinderOptions()
        options.detectSameText = detectSameText
        #expect(DuplicateFinder.findGroups(tree: tree, fileHashes: hashes, options: options,
                                           textFingerprints: fingerprints).isEmpty)
    }

    // MARK: What it refuses

    @Test func aBucketTheByteHashAlreadyExplainedIsNotReportedTwice() {
        // Same fingerprint and same content hash: `identicalFileGroups` already covers it, and two
        // groups over one pair could contradict each other. `groupedFilePaths` marks both members
        // and lets only the keeper back in, leaving one member and no group.
        let tree = [
            dir("/root/A", [file("/root/A/bill.pdf"), file("/root/A/a-only.txt")]),
            dir("/root/B", [file("/root/B/bill.pdf"), file("/root/B/b-only.txt")]),
        ]
        let hashes = ["/root/A/bill.pdf": "H", "/root/B/bill.pdf": "H",
                      "/root/A/a-only.txt": "UA", "/root/B/b-only.txt": "UB"]
        let groups = DuplicateFinder.findGroups(
            tree: tree, fileHashes: hashes,
            textFingerprints: ["/root/A/bill.pdf": "FP", "/root/B/bill.pdf": "FP"])

        #expect(groups.count == 1)
        #expect(groups[0].matchType == .identical)
    }

    @Test func filesBelowTheSizeFloorAreLeftAlone() {
        let tree = [
            dir("/root/A", [file("/root/A/bill.pdf", size: 100), file("/root/A/a-only.txt")]),
            dir("/root/B", [file("/root/B/other.pdf", size: 100), file("/root/B/b-only.txt")]),
        ]
        let hashes = ["/root/A/bill.pdf": "HA", "/root/B/other.pdf": "HB",
                      "/root/A/a-only.txt": "UA", "/root/B/b-only.txt": "UB"]
        let groups = DuplicateFinder.findGroups(
            tree: tree, fileHashes: hashes,
            textFingerprints: ["/root/A/bill.pdf": "FP", "/root/B/other.pdf": "FP"])
        #expect(groups.isEmpty)
    }

    // MARK: The promises

    @Test func itRunsBeforeVersionsSoARestampedCopyIsNotCalledANewerVersion() {
        // `All Pages.pdf` beside `All Pages copy.pdf` reduces to one version stem, and the versions
        // pass would offer "keep newest, trash older", a story about a document that changed. The
        // fingerprint knows it didn't: one is a re-compressed save of the other.
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let new = Date(timeIntervalSince1970: 1_700_000_000)
        let a = "/root/Passport/All Pages.pdf"
        let b = "/root/Passport/All Pages copy.pdf"
        let tree = [dir("/root/Passport", [file(a, modified: old), file(b, modified: new)])]
        let hashes = [a: "BYTES-A", b: "BYTES-B"]

        let withFingerprints = DuplicateFinder.findGroups(
            tree: tree, fileHashes: hashes, textFingerprints: [a: "FP", b: "FP"])
        #expect(withFingerprints.map(\.matchType) == [.sameText])

        // Without them the versions pass claims the pair — which is what this ordering displaces.
        #expect(DuplicateFinder.findGroups(tree: tree, fileHashes: hashes).map(\.matchType)
                == [.versions])
    }

    @Test func anIdenticalGroupsKeeperCanAnchorButIsNeverRemovedByThisPass() {
        // The mixed case: one document downloaded twice and copied once. `/root/A/bill.pdf` and
        // `/root/Copy/bill.pdf` are byte-identical; `/root/B/restamped.pdf` is the re-stamped
        // download. Dropping everything the identical pass touched would lose this group, so its
        // keeper anchors it, and must not be trashable here, or one batch would hollow out the copy
        // the other promised to keep.
        let tree = [
            dir("/root/A", [file("/root/A/bill.pdf"), file("/root/A/a-only.txt")]),
            dir("/root/Copy", [file("/root/Copy/bill.pdf"), file("/root/Copy/c-only.txt")]),
            dir("/root/B", [file("/root/B/restamped.pdf"), file("/root/B/b-only.txt")]),
        ]
        let hashes = [
            "/root/A/bill.pdf": "H", "/root/Copy/bill.pdf": "H", "/root/B/restamped.pdf": "H2",
            "/root/A/a-only.txt": "UA", "/root/Copy/c-only.txt": "UC", "/root/B/b-only.txt": "UB",
        ]
        let fingerprints = ["/root/A/bill.pdf": "FP", "/root/Copy/bill.pdf": "FP",
                            "/root/B/restamped.pdf": "FP"]

        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes,
                                                textFingerprints: fingerprints)
        let identical = groups.filter { $0.matchType == .identical }
        let sameText = groups.filter { $0.matchType == .sameText }
        #expect(identical.count == 1)
        #expect(sameText.count == 1)

        let anchor = identical[0].keeper.path
        #expect(sameText[0].keeper.path == anchor)
        #expect(sameText[0].recommendedRemovalPaths == ["/root/B/restamped.pdf"])
        // Disjoint removal sets: nothing one group trashes is something the other kept.
        #expect(Set(identical[0].recommendedRemovalPaths)
                .isDisjoint(with: Set(sameText[0].recommendedRemovalPaths)))

        // Re-aiming the keeper can't smuggle the anchor onto the removal list: `choosingKeeper`
        // relabels by id, and the protected flag is what stops it turning the identical group's
        // keeper into this group's removal candidate.
        let reAimed = sameText[0].choosingKeeper("/root/B/restamped.pdf")
        #expect(reAimed.keeper.path == "/root/B/restamped.pdf")
        #expect(reAimed.recommendedRemovalPaths.isEmpty)
        #expect(reAimed.copies.first { $0.path == anchor }?.isProtectedFromRemoval == true)
        #expect(reAimed.reclaimableBytes == 0)
    }

    @Test func aFileInsideAKeptFolderIsNotOfferedForRemoval() throws {
        // The folder-keeper invariant, from the same-text side: `/root/Backup` and `/root/Zzz` are
        // identical folders, so Zzz is kept whole (Backup carries the archive penalty), and a
        // same-text group must not trash `/root/Zzz/bill.pdf` out of it.
        //
        // The two loose copies matter: without the protection, `chooseKeeper` ranks `/root/Aaa`
        // first and Zzz's file lands on the removal list. With one loose copy Zzz wins the keeper
        // slot by ordering alone, and removing the protection would still pass.
        let tree = [
            dir("/root/Backup", [file("/root/Backup/bill.pdf")]),
            dir("/root/Zzz", [file("/root/Zzz/bill.pdf")]),
            dir("/root/Aaa", [file("/root/Aaa/restamped.pdf")]),
            dir("/root/Bbb", [file("/root/Bbb/restamped-2.pdf")]),
        ]
        let hashes = ["/root/Backup/bill.pdf": "H", "/root/Zzz/bill.pdf": "H",
                      "/root/Aaa/restamped.pdf": "H2", "/root/Bbb/restamped-2.pdf": "H3"]
        let groups = DuplicateFinder.findGroups(
            tree: tree, fileHashes: hashes,
            textFingerprints: ["/root/Backup/bill.pdf": "FP", "/root/Zzz/bill.pdf": "FP",
                               "/root/Aaa/restamped.pdf": "FP", "/root/Bbb/restamped-2.pdf": "FP"])

        let folderGroup = groups.first { $0.matchType == .identical && $0.isDirectory }
        #expect(folderGroup?.keeper.path == "/root/Zzz")
        let sameText = try #require(groups.first { $0.matchType == .sameText })
        #expect(sameText.keeper.path == "/root/Zzz/bill.pdf")
        #expect(sameText.copies.first { $0.path == "/root/Zzz/bill.pdf" }?.isProtectedFromRemoval == true)
        // The two loose copies are what this group can actually offer.
        #expect(Set(sameText.recommendedRemovalPaths)
                == ["/root/Aaa/restamped.pdf", "/root/Bbb/restamped-2.pdf"])
        // And nothing anywhere in the batch may take a file out of the folder being kept whole.
        #expect(groups.flatMap { $0.recommendedRemovalPaths }.contains("/root/Zzz/bill.pdf") == false)
    }

    @Test func aMemberThisGroupCouldNotOfferIsStillMarkedAgainstTheVersionsPass() throws {
        // Every member is marked as grouped, protected ones included, as `identicalFileGroups`
        // does. It matters for `/root/Zzz/bill copy.pdf`, which sits in the folder kept whole, so it
        // anchors the group and is never offered.
        //
        // Left unmarked, the versions pass would pool it with `/root/Loose/bill (1).pdf` (both
        // carry a version marker and are alone in their folders) and, as the newer, aim a "keep
        // newest, Trash older" offer at Loose's file: a different document sharing only a stem.
        // Two lone marker-bearers in different folders is the one shape where the missing mark
        // costs a file; the versions pass defends the others.
        let older = Date(timeIntervalSince1970: 1_000_000)
        let newer = Date(timeIntervalSince1970: 2_000_000)
        let tree = [
            dir("/root/Backup", [file("/root/Backup/bill copy.pdf")]),
            dir("/root/Zzz", [file("/root/Zzz/bill copy.pdf", modified: newer)]),
            dir("/root/Aaa", [file("/root/Aaa/restamped.pdf")]),
            dir("/root/Loose", [file("/root/Loose/bill (1).pdf", modified: older)]),
        ]
        let hashes = ["/root/Backup/bill copy.pdf": "H", "/root/Zzz/bill copy.pdf": "H",
                      "/root/Aaa/restamped.pdf": "H2", "/root/Loose/bill (1).pdf": "H4"]
        let groups = DuplicateFinder.findGroups(
            tree: tree, fileHashes: hashes,
            // The two identical copies read alike (they are the same bytes) and so does Aaa's
            // re-stamp. Loose's file is a different document.
            textFingerprints: ["/root/Backup/bill copy.pdf": "FP", "/root/Zzz/bill copy.pdf": "FP",
                               "/root/Aaa/restamped.pdf": "FP"])

        // The fixture is doing what it claims: Zzz is the kept folder, and its file anchors a
        // same-text group it can never be removed from.
        #expect(groups.first { $0.matchType == .identical && $0.isDirectory }?.keeper.path == "/root/Zzz")
        let sameText = try #require(groups.first { $0.matchType == .sameText })
        #expect(sameText.keeper.path == "/root/Zzz/bill copy.pdf")
        #expect(sameText.recommendedRemovalPaths == ["/root/Aaa/restamped.pdf"])

        // The rule itself: no versions group forms over a file this group already accounted for,
        // and nothing anywhere offers to trash the unrelated document that shares the stem.
        #expect(groups.contains { $0.matchType == .versions } == false)
        #expect(groups.flatMap { $0.recommendedRemovalPaths }.contains("/root/Loose/bill (1).pdf") == false)
    }

    @Test func aHardLinkNeverJoinsASameTextGroup() {
        // Hard links leave duplicate candidacy before any pass runs: trashing one directory entry
        // frees nothing, so no offer about one is truthful — a text match included.
        let tree = [
            dir("/root/A", [file("/root/A/bill.pdf"), file("/root/A/a-only.txt")]),
            dir("/root/B", [file("/root/B/restamped.pdf"), file("/root/B/b-only.txt")]),
        ]
        let hashes = ["/root/A/bill.pdf": "H1", "/root/B/restamped.pdf": "H2",
                      "/root/A/a-only.txt": "UA", "/root/B/b-only.txt": "UB"]
        let groups = DuplicateFinder.findGroups(
            tree: tree, fileHashes: hashes,
            multiLinkPaths: ["/root/B/restamped.pdf"],
            textFingerprints: ["/root/A/bill.pdf": "FP", "/root/B/restamped.pdf": "FP"])
        #expect(groups.isEmpty)
    }

    @Test func repeatedGroupingOfTheSameInputIsStable() {
        // This can't prove `buckets.keys.sorted()` in the pass: Swift seeds its hasher per process,
        // so one process can't observe the order the sort replaces, and removing it stays green.
        // Kept because the property is worth holding.
        let tree = [
            dir("/root/A", [file("/root/A/one.pdf"), file("/root/A/two.pdf")]),
            dir("/root/B", [file("/root/B/one-copy.pdf"), file("/root/B/two-copy.pdf")]),
        ]
        let hashes = ["/root/A/one.pdf": "H1", "/root/B/one-copy.pdf": "H2",
                      "/root/A/two.pdf": "H3", "/root/B/two-copy.pdf": "H4"]
        let fingerprints = ["/root/A/one.pdf": "FP-1", "/root/B/one-copy.pdf": "FP-1",
                            "/root/A/two.pdf": "FP-2", "/root/B/two-copy.pdf": "FP-2"]
        let first = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes,
                                               textFingerprints: fingerprints)
        #expect(first.filter { $0.matchType == .sameText }.count == 2)
        for _ in 0..<8 {
            let again = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes,
                                                   textFingerprints: fingerprints)
            #expect(again.map(\.ignoreKey) == first.map(\.ignoreKey))
        }
    }
}
