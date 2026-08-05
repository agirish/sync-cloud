import Testing
import Foundation
import Sync
@testable import FileExplorer

/// The "Find duplicates of this" landing: what the Duplicates lens decides about a request, and
/// what it changes to show it.
///
/// Every assertion here is about the REASON, not the container. "The workspace switched" is the
/// coordinator's business (`DuplicateRevealCoordinatorTests`); what matters here is that the group
/// holding the file is the one opened and marked, and that a file in no group lands on an answer
/// that names it rather than on a list that is quietly empty.
@Suite struct DuplicateRevealTests {

    // MARK: Fixtures

    private static func copy(_ path: String, keeper: Bool = false) -> DuplicateCopy {
        DuplicateCopy(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                      size: 10, itemCount: 1, modificationDate: nil, uniqueItemCount: 0,
                      depth: 1, isRecommendedKeeper: keeper)
    }

    private static func group(_ paths: [String], name: String = "a.txt") -> DuplicateGroup {
        DuplicateGroup(matchType: .identical, name: name, isDirectory: false,
                       copies: paths.enumerated().map { copy($1, keeper: $0 == 0) },
                       reclaimableBytes: 10)
    }

    // MARK: Outcome

    @Test func noRequestDecidesNothing() {
        #expect(DuplicateReveal.outcome(for: nil, groups: [Self.group(["/a/x"])],
                                        isScanning: false) == nil)
    }

    /// The file's OWN group, not merely some group. Two groups are present and only one holds the
    /// requested path — a resolver that took the first would pass a single-group fixture.
    @Test func theGroupHoldingTheFileIsTheOneRevealed() {
        let other = Self.group(["/a/other.txt", "/b/other.txt"], name: "other.txt")
        let mine = Self.group(["/a/x.txt", "/b/x.txt"], name: "x.txt")
        let outcome = DuplicateReveal.outcome(
            for: DuplicateRevealRequest(path: "/b/x.txt"),
            groups: [other, mine], isScanning: false)
        #expect(outcome == .reveal(groupID: mine.id))
    }

    /// A non-keeper copy is as good an anchor as the keeper — the user clicked the file they
    /// clicked, and it is usually not the one the scan would keep.
    @Test func aNonKeeperCopyRevealsItsGroupToo() {
        let mine = Self.group(["/a/x.txt", "/b/x.txt"], name: "x.txt")
        #expect(DuplicateReveal.outcome(for: DuplicateRevealRequest(path: "/b/x.txt"),
                                        groups: [mine], isScanning: false)
                == .reveal(groupID: mine.id))
    }

    @Test func aFileInNoGroupIsNamedRatherThanShrugged() {
        let outcome = DuplicateReveal.outcome(
            for: DuplicateRevealRequest(path: "/a/lonely.txt"),
            groups: [Self.group(["/a/x.txt", "/b/x.txt"])], isScanning: false)
        #expect(outcome == .notFound(name: "lonely.txt"))
    }

    /// **`isScanning` is checked BEFORE the groups are searched.** During a scan the groups on
    /// screen are the previous scan's, so looking there first answers `notFound` from results that
    /// never saw this file — and `notFound` writes a search query, which would then filter the
    /// results as they arrive.
    ///
    /// The fixture makes that concrete: the file IS absent from the stale groups, so a resolver
    /// that searched first would confidently answer `notFound`.
    @Test func aRunningScanWaitsRatherThanAnsweringFromStaleResults() {
        let outcome = DuplicateReveal.outcome(
            for: DuplicateRevealRequest(path: "/a/x.txt"),
            groups: [Self.group(["/a/old.txt", "/b/old.txt"], name: "old.txt")],
            isScanning: true)
        #expect(outcome == .waiting)
    }

    /// …and the same inputs with the scan finished do NOT answer `.waiting` — otherwise the test
    /// above passes against a resolver that never answers anything else.
    @Test func theSameInputsResolveOnceTheScanEnds() {
        let request = DuplicateRevealRequest(path: "/a/x.txt")
        let groups = [Self.group(["/a/old.txt", "/b/old.txt"], name: "old.txt")]
        #expect(DuplicateReveal.outcome(for: request, groups: groups, isScanning: true) == .waiting)
        #expect(DuplicateReveal.outcome(for: request, groups: groups, isScanning: false)
                == .notFound(name: "x.txt"))
    }

    // MARK: Plan

    /// A reveal opens the group, marks it, and clears anything that could be hiding it. A landing
    /// behind a parked filter has not landed.
    @Test func aRevealOpensMarksAndUnhides() {
        let id = UUID()
        let plan = DuplicateReveal.plan(for: .reveal(groupID: id))
        #expect(plan.expandsGroupID == id)
        #expect(plan.revealedGroupID == id)
        #expect(plan.clearsFilterAndQuery)
        #expect(plan.searchQuery == "")
        #expect(plan.unmatchedName == nil)
    }

    /// Not-found fills the field with the file's name and records the name for the empty state.
    /// The name in BOTH places is what makes the landing self-explaining: the query says what was
    /// asked, the empty state says what came back.
    @Test func notFoundNamesTheFileInTheFieldAndInTheAnswer() {
        let plan = DuplicateReveal.plan(for: .notFound(name: "lonely.txt"))
        #expect(plan.searchQuery == "lonely.txt")
        #expect(plan.unmatchedName == "lonely.txt")
        #expect(plan.expandsGroupID == nil)
        #expect(plan.revealedGroupID == nil)
    }

    /// Waiting changes nothing at all — including not clearing a previous landing's mark. What is
    /// on screen during a scan is the previous scan's results, and the previous landing is still
    /// the truthful thing to be showing.
    @Test func waitingPlansNothing() {
        #expect(DuplicateReveal.plan(for: .waiting) == DuplicateReveal.Plan())
    }

    /// A repeat ask about the same file is a new request. A bare path would compare equal to
    /// itself and move nothing — so right-clicking the same file again after clearing the search
    /// would do visibly nothing.
    @Test func twoRequestsForOneFileAreNotEqual() {
        #expect(DuplicateRevealRequest(path: "/a/x.txt") != DuplicateRevealRequest(path: "/a/x.txt"))
    }

    @Test func theRequestNamesTheFileForTheEmptyState() {
        #expect(DuplicateRevealRequest(path: "/a/b/Q3 Forecast.numbers").name == "Q3 Forecast.numbers")
    }
}
