import Testing
import Foundation
@testable import Sync

/// **`redundantCopies` must never name the path the keeper itself names** — the second lock on a
/// list that feeds a Trash.
///
/// Independent of whatever builds the group. The old filter compared against a `fallbackKeeperID`
/// that was nil whenever ANY copy carried the keeper flag, so it guarded only the no-flag case; a
/// group holding two copies at ONE path, one flagged and one not, walked straight through it and
/// recommended trashing the keeper's own path. That shape was reachable — see
/// `CoveredElsewhereTests` for the walk that produced it — and this suite holds the line whether or
/// not anything upstream ever builds one again.
@Suite struct RedundantCopiesSelfPairTests {

    static let size = 5_000_000
    static let home = "/H"

    /// **`redundantCopies` must never name the keeper's own path**, whatever produced the group.
    ///
    /// The walk fix above removes the one shape known to reach this, and this is the second lock:
    /// the list feeds a Trash, so it should refuse a self-pair on its own rather than relying on
    /// nothing upstream ever building one again. The old filter compared against a fallback id that
    /// was nil whenever any copy carried the keeper flag, so exactly this group walked through it.
    @Test func aGroupHoldingOnePathTwiceRecommendsRemovingNeither() {
        func copy(_ path: String, keeper: Bool) -> DuplicateCopy {
            DuplicateCopy(id: path, name: "Documents", isDirectory: true, size: Self.size,
                          itemCount: 1, modificationDate: nil, uniqueItemCount: 0, depth: 1,
                          isRecommendedKeeper: keeper)
        }
        let path = Self.home + "/Documents"
        let group = DuplicateGroup(matchType: .identical, name: "Documents", isDirectory: true,
                                   copies: [copy(path, keeper: true), copy(path, keeper: false)],
                                   reclaimableBytes: Self.size)
        #expect(group.recommendedRemovalPaths.isEmpty,
                "the removal list names the keeper's own path: \(group.recommendedRemovalPaths)")
        #expect(group.redundantCopies.isEmpty)
    }

    /// And the ordinary two-path group is untouched — the guard must not stop removing real copies.
    @Test func aRealDuplicatePairStillRecommendsRemovingTheCopy() {
        func copy(_ path: String, keeper: Bool) -> DuplicateCopy {
            DuplicateCopy(id: path, name: "report.pdf", isDirectory: false, size: Self.size,
                          itemCount: 1, modificationDate: nil, uniqueItemCount: 0, depth: 1,
                          isRecommendedKeeper: keeper)
        }
        let group = DuplicateGroup(matchType: .identical, name: "report.pdf", isDirectory: false,
                                   copies: [copy("/H/a/report.pdf", keeper: true),
                                            copy("/H/b/report.pdf", keeper: false)],
                                   reclaimableBytes: Self.size)
        #expect(group.recommendedRemovalPaths == ["/H/b/report.pdf"])
    }
}
