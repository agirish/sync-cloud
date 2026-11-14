import Testing
import Foundation
@testable import Sync

/// The comparison that reports fewer differences than exist, and the sentence that says so. A side
/// whose root came back unread (unlistable, or the walk stopped at `paneNodeBudget`) mints no
/// Missing row in `FileDiffEngine.compare`, since it can't tell an absence from something it never
/// read. Without the sentence that is invisible: the table looks normal and the count reads as a
/// total.
@Suite struct PartialComparisonTests {

    private func info(unexplored: Bool, isDirectory: Bool = true) -> FileDiffEngine.FileInfo {
        FileDiffEngine.FileInfo(url: URL(fileURLWithPath: "/x"), modificationDate: nil,
                                fileSize: nil, isDirectory: isDirectory, isUnexplored: unexplored)
    }

    @Test func acompleteScanSaysNothing() {
        let coverage = PartialComparison.of(left: ["a": info(unexplored: false)],
                                            right: ["b": info(unexplored: false)])
        #expect(coverage.isComplete)
        #expect(coverage.message(leftName: "iCloud", rightName: "Dropbox") == nil)
    }

    /// The sentence says what is missing from the result, the thing being acted on, not merely that
    /// something went wrong. Both losses, not one: besides the suppressed Missing rows, a walk
    /// stopped by the node budget never recorded the entries past it, so those are in neither map
    /// and produce no row in either direction. Naming only the suppression would imply the partial
    /// side's unique files are listed.
    @Test func anUnreadRootOnOneSideIsNamedBySource() throws {
        let coverage = PartialComparison.of(left: ["": info(unexplored: true)], right: [:])
        #expect(!coverage.isComplete)
        let message = try #require(coverage.message(leftName: "iCloud", rightName: "Dropbox"))
        #expect(message.contains("iCloud"))
        #expect(!message.contains("Dropbox"), "the readable side must not be named as a problem")
        #expect(message.contains("incomplete"))
        #expect(message.contains("nothing is reported as missing on that side"),
                "the suppression — no Missing row is minted against a side whose view is unknown")
        #expect(message.contains("not compared"),
                "the quieter loss: entries the walk never reached are in no map at all")
    }

    /// The side matters: naming the wrong one sends the reader to check the wrong account.
    @Test func theRightSideIsNamedWhenItIsTheRightSide() throws {
        let coverage = PartialComparison.of(left: [:], right: ["": info(unexplored: true)])
        let message = try #require(coverage.message(leftName: "iCloud", rightName: "Dropbox"))
        #expect(message.contains("Dropbox"))
        #expect(!message.contains("iCloud"))
    }

    /// Both sides partial is one sentence, not two, and it has to read as English. It says "either
    /// side", not "that side", which would leave the reader guessing which one.
    @Test func bothSidesReadAsOneSentence() throws {
        let coverage = PartialComparison.of(left: ["": info(unexplored: true)],
                                            right: ["": info(unexplored: true)])
        let message = try #require(coverage.message(leftName: "iCloud", rightName: "Dropbox"))
        #expect(message.contains("iCloud and Dropbox"))
        #expect(message.contains("were"), "two sources take a plural verb")
        #expect(message.contains("either side"))
        #expect(!message.contains("that side"))
    }

    /// `isUnexplored` false at the root key is not partial: the key can exist for other reasons, and
    /// only the mark means the side is unknown.
    @Test func aRootKeyWithoutTheMarkIsComplete() {
        #expect(PartialComparison.of(left: ["": info(unexplored: false)], right: [:]).isComplete)
    }

    // MARK: - The warm-branch overload, whose conjunction is load-bearing in both directions

    /// The bit plus a surviving unexplored directory is partial. This is the warm scan of a
    /// budget-stopped tree: the root was readable, so no `""` record exists, and the truncation
    /// lives only in per-directory marks an ordinary locked folder also wears. The provenance bit
    /// lets the overload read those marks as coverage rather than noise.
    @Test func aStoppedWalkWithASurvivingUnexploredDirectoryIsPartial() {
        let coverage = PartialComparison.of(left: ["Deep": info(unexplored: true)], right: [:],
                                            leftWalkStopped: true, rightWalkStopped: false)
        #expect(coverage.left, "the cached tree's stopped walk left directories unread and the banner stayed down")
        #expect(!coverage.right, "the right side inherited the left's provenance")
    }

    /// The bit alone is not partial. A stopped walk whose every unexplored directory has since been
    /// grafted in (columns opened them) covers everything, and a banner would claim suppressed rows
    /// that aren't.
    @Test func aStoppedWalkWhoseGapsWereAllGraftedInIsComplete() {
        let coverage = PartialComparison.of(left: ["Deep": info(unexplored: false)], right: [:],
                                            leftWalkStopped: true, rightWalkStopped: false)
        #expect(coverage.isComplete,
                "the provenance bit alone bannered a comparison whose every directory was read")
    }

    /// The marks alone are not partial either. An unexplored directory with no stopped walk behind
    /// it is an ordinary locked folder, which the plain overload refuses to banner; this one must
    /// not undo that.
    @Test func anOrdinaryLockedFolderStillDoesNotBanner() {
        let coverage = PartialComparison.of(left: ["Locked": info(unexplored: true)], right: [:],
                                            leftWalkStopped: false, rightWalkStopped: false)
        #expect(coverage.isComplete,
                "a locked folder deep in the tree bannered without a stopped walk — the warning people learn to stop reading")
    }

    /// An unexplored file does not arm the conjunction: only a directory can hold unwalked rows,
    /// and the walk never marks a file.
    @Test func anUnexploredFileDoesNotArmTheStoppedWalk() {
        let coverage = PartialComparison.of(left: ["odd.txt": info(unexplored: true, isDirectory: false)],
                                            right: [:],
                                            leftWalkStopped: true, rightWalkStopped: false)
        #expect(coverage.isComplete)
    }

    /// The `""` record wins whatever the bit: an unlistable root is partial either way. The
    /// overload extends the plain rule, never replaces it.
    @Test func theRootRecordWinsWhateverTheBitSays() {
        for stopped in [false, true] {
            let coverage = PartialComparison.of(left: ["": info(unexplored: true)], right: [:],
                                                leftWalkStopped: stopped, rightWalkStopped: false)
            #expect(coverage.left,
                    "an unread root stopped bannering when leftWalkStopped == \(stopped)")
        }
    }

    /// Each side reads its own bit and its own map, or the sentence names the wrong account.
    @Test func theSidesDoNotShareProvenance() {
        let coverage = PartialComparison.of(left: [:],
                                            right: ["Deep": info(unexplored: true)],
                                            leftWalkStopped: true, rightWalkStopped: true)
        #expect(!coverage.left, "the left has no unexplored directory and bannered anyway")
        #expect(coverage.right)
    }

    /// The sentence must not name a cause: `FileDiffEngine.compare` mints the same `""` record for
    /// a root it couldn't list (permission denied) and for a walk stopped at the node budget, and a
    /// reader told a locked folder is "too large" would look for a size problem. Asserted as an
    /// absence of size words, so any rewording must stay honest.
    @Test func theSentenceDoesNotBlameSize() throws {
        for coverage in [PartialComparison(left: true, right: false),
                         PartialComparison(left: false, right: true),
                         PartialComparison(left: true, right: true)] {
            let message = try #require(coverage.message(leftName: "iCloud", rightName: "Dropbox"))
            for word in ["too large", "too big", "size", "large to read"] {
                #expect(!message.lowercased().contains(word),
                        "an unlistable root mints the same record as a stopped walk, so the sentence cannot claim size: “\(message)”")
            }
        }
    }
}
