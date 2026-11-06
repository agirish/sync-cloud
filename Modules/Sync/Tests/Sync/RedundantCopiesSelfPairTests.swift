import Testing
import Foundation
@testable import Sync

/// `redundantCopies` must never name the keeper's own path: a second lock on a list that feeds a
/// Trash, whatever builds the group. A group with two copies at one path, one flagged as keeper
/// and one not, would otherwise recommend trashing the keeper. `CoveredElsewhereTests` covers the
/// walk that can produce that shape.
@Suite struct RedundantCopiesSelfPairTests {

    static let size = 5_000_000
    static let home = "/H"

    /// Two copies at one path, one flagged as keeper: neither is recommended for removal. A filter
    /// comparing only against a fallback keeper id, nil whenever a copy is flagged, would let it by.
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

    /// The ordinary two-path group is untouched: the guard must not stop removing real copies.
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
