import Testing
import Foundation
@testable import Sync

/// **The comparison that reports fewer differences than exist**, and the sentence that says so.
///
/// A side whose root came back unread — because it could not be listed, or because the walk stopped
/// at `paneNodeBudget` — mints no Missing row at all in `FileDiffEngine.compare`. That is the right
/// treatment (it cannot tell an absence from something it never read) and it is invisible: the table
/// looks normal and the count reads as a total. Until this, the only signal was a log line.
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

    /// **The root key, not any directory.** An ordinary unreadable folder deep in a tree is common,
    /// and `compare` already suppresses exactly the rows under it — precisely, and without losing
    /// anything else. A banner on every scan of a disk holding one locked folder is a banner people
    /// learn to stop reading.
    @Test func anUnreadableFolderInsideTheTreeIsNotAPartialComparison() {
        let coverage = PartialComparison.of(left: ["Locked": info(unexplored: true)], right: [:])
        #expect(coverage.isComplete, "a folder deep in the tree is suppressed row by row, not side-wide")
    }

    @Test func anUnreadRootOnOneSideIsNamedBySource() throws {
        let coverage = PartialComparison.of(left: ["": info(unexplored: true)], right: [:])
        #expect(!coverage.isComplete)
        let message = try #require(coverage.message(leftName: "iCloud", rightName: "Dropbox"))
        #expect(message.contains("iCloud"))
        #expect(!message.contains("Dropbox"), "the readable side must not be named as a problem")
    }

    /// The side matters: naming the wrong one sends the reader to check the wrong account.
    @Test func theRightSideIsNamedWhenItIsTheRightSide() throws {
        let coverage = PartialComparison.of(left: [:], right: ["": info(unexplored: true)])
        let message = try #require(coverage.message(leftName: "iCloud", rightName: "Dropbox"))
        #expect(message.contains("Dropbox"))
        #expect(!message.contains("iCloud"))
    }

    /// Both sides partial is one sentence, not two — and it has to read as English.
    @Test func bothSidesReadAsOneSentence() throws {
        let coverage = PartialComparison.of(left: ["": info(unexplored: true)],
                                            right: ["": info(unexplored: true)])
        let message = try #require(coverage.message(leftName: "iCloud", rightName: "Dropbox"))
        #expect(message.contains("iCloud and Dropbox"))
        #expect(message.contains("were"), "two sources take a plural verb")
    }

    /// **`isUnexplored` false at the root key is not partial.** The key can exist for other reasons;
    /// only the mark means the side is unknown.
    @Test func aRootKeyWithoutTheMarkIsComplete() {
        #expect(PartialComparison.of(left: ["": info(unexplored: false)], right: [:]).isComplete)
    }

    /// The sentence says what is missing from the RESULT, which is the thing being acted on — not
    /// merely that something went wrong.
    @Test func theSentenceSaysWhatIsNotListed() throws {
        let coverage = PartialComparison.of(left: ["": info(unexplored: true)], right: [:])
        let message = try #require(coverage.message(leftName: "iCloud", rightName: "Dropbox"))
        #expect(message.contains("incomplete"))
    }

    /// **Both losses, not one.** The sentence used to name only the suppression — "anything present
    /// only on the other side is not listed" — which is a precise claim about one direction and a
    /// promise the result cannot keep: a walk stopped by the node budget never recorded the entries
    /// past it, so those files are in neither map and produce no row in EITHER direction. A reader
    /// who takes the narrow wording literally concludes that what the partial side holds uniquely
    /// IS listed, and it is not.
    @Test func theSentenceNamesTheUnreadEntriesToo() throws {
        let coverage = PartialComparison.of(left: ["": info(unexplored: true)], right: [:])
        let message = try #require(coverage.message(leftName: "iCloud", rightName: "Dropbox"))
        #expect(message.contains("nothing is reported as missing on that side"),
                "the suppression — no Missing row is minted against a side whose view is unknown")
        #expect(message.contains("not compared"),
                "the quieter loss: entries the walk never reached are in no map at all")
    }

    /// Two partial sides say "either side", not "that side" — the singular reads as a claim about
    /// one of the two and leaves the reader deciding which.
    @Test func bothSidesPartialNamesBoth() throws {
        let coverage = PartialComparison.of(left: ["": info(unexplored: true)],
                                            right: ["": info(unexplored: true)])
        let message = try #require(coverage.message(leftName: "iCloud", rightName: "Dropbox"))
        #expect(message.contains("either side"))
        #expect(!message.contains("that side"))
    }

    /// **The sentence must not name a cause, because the value it is built from does not carry
    /// one.** `of(left:right:)` reads a single boolean per side, and `FileDiffEngine.compare` mints
    /// that same `""` record both for a root it could not LIST (permission denied) and for a walk it
    /// had to STOP at the node budget. The wording was "too large to read in full", which is true of
    /// the second and false of the first — and false in the direction that matters, since a reader
    /// told their locked folder is "too large" will go looking for a size problem. Asserted as an
    /// absence of size words rather than as an exact string so a later rewording still has to keep
    /// the claim honest.
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
