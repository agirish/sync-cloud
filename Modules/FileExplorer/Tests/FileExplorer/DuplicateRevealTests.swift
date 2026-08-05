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

    /// Every fixture below scans `/a` (or `/b`), so the file it asks about is inside the scanned
    /// root unless a case is deliberately about the opposite.
    private static let scanned = "/"

    @Test func noRequestDecidesNothing() {
        #expect(DuplicateReveal.outcome(for: nil, groups: [Self.group(["/a/x"])],
                                        isScanning: false, scannedRoot: Self.scanned) == nil)
    }

    /// The file's OWN group, not merely some group. Two groups are present and only one holds the
    /// requested path — a resolver that took the first would pass a single-group fixture.
    @Test func theGroupHoldingTheFileIsTheOneRevealed() {
        let other = Self.group(["/a/other.txt", "/b/other.txt"], name: "other.txt")
        let mine = Self.group(["/a/x.txt", "/b/x.txt"], name: "x.txt")
        let outcome = DuplicateReveal.outcome(
            for: DuplicateRevealRequest(path: "/b/x.txt"),
            groups: [other, mine], isScanning: false, scannedRoot: Self.scanned)
        #expect(outcome == .reveal(groupID: mine.id))
    }

    /// A non-keeper copy is as good an anchor as the keeper — the user clicked the file they
    /// clicked, and it is usually not the one the scan would keep.
    @Test func aNonKeeperCopyRevealsItsGroupToo() {
        let mine = Self.group(["/a/x.txt", "/b/x.txt"], name: "x.txt")
        #expect(DuplicateReveal.outcome(for: DuplicateRevealRequest(path: "/b/x.txt"),
                                        groups: [mine], isScanning: false,
                                        scannedRoot: Self.scanned)
                == .reveal(groupID: mine.id))
    }

    @Test func aFileInNoGroupIsNamedRatherThanShrugged() {
        let outcome = DuplicateReveal.outcome(
            for: DuplicateRevealRequest(path: "/a/lonely.txt"),
            groups: [Self.group(["/a/x.txt", "/b/x.txt"])], isScanning: false,
            scannedRoot: "/a")
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
            isScanning: true, scannedRoot: Self.scanned)
        #expect(outcome == .waiting)
    }

    /// …and the same inputs with the scan finished do NOT answer `.waiting` — otherwise the test
    /// above passes against a resolver that never answers anything else.
    @Test func theSameInputsResolveOnceTheScanEnds() {
        let request = DuplicateRevealRequest(path: "/a/x.txt")
        let groups = [Self.group(["/a/old.txt", "/b/old.txt"], name: "old.txt")]
        #expect(DuplicateReveal.outcome(for: request, groups: groups, isScanning: true,
                                        scannedRoot: Self.scanned) == .waiting)
        #expect(DuplicateReveal.outcome(for: request, groups: groups, isScanning: false,
                                        scannedRoot: Self.scanned) == .notFound(name: "x.txt"))
    }

    // MARK: "In no group" is only an answer if the scan looked

    /// **The false-confidence bug this check exists for.** A scan of somewhere else says nothing
    /// about this file, so answering `notFound` from it puts *No duplicates of “x.txt”* on screen
    /// on the strength of results that never saw `x.txt`.
    ///
    /// Reachable in shipping code: `DuplicateRevealCoordinator.decide` waits for an already-running
    /// scan, and cannot know its root — `duplicateScanRoot` is published on completion, not at
    /// start. So the wait lands here, and this is what makes waiting safe.
    @Test func aFileOutsideTheScannedRootIsNotAnswered() {
        let outcome = DuplicateReveal.outcome(
            for: DuplicateRevealRequest(path: "/Users/u/Projects/x.txt"),
            groups: [Self.group(["/Users/u/Documents/a.txt", "/Users/u/Documents/b.txt"])],
            isScanning: false, scannedRoot: "/Users/u/Documents")
        #expect(outcome == .outsideScan(name: "x.txt"))
    }

    /// The same file under a scan that DID cover it answers for real — otherwise the case above
    /// would pass against a resolver that never answers `notFound` at all.
    @Test func theSameFileInsideTheScannedRootIsAnswered() {
        let outcome = DuplicateReveal.outcome(
            for: DuplicateRevealRequest(path: "/Users/u/Projects/x.txt"),
            groups: [], isScanning: false, scannedRoot: "/Users/u/Projects")
        #expect(outcome == .notFound(name: "x.txt"))
    }

    /// A CANCELLED scan is the second way in, and the current code got it wrong too:
    /// `isFindingDuplicates` goes false with no root published, and the previous results (or none)
    /// still on screen.
    @Test func aCancelledScanLeavesNothingToAnswerFrom() {
        #expect(DuplicateReveal.outcome(for: DuplicateRevealRequest(path: "/a/x.txt"),
                                        groups: [], isScanning: false, scannedRoot: nil)
                == .outsideScan(name: "x.txt"))
        #expect(DuplicateReveal.outcome(for: DuplicateRevealRequest(path: "/a/x.txt"),
                                        groups: [], isScanning: false, scannedRoot: "")
                == .outsideScan(name: "x.txt"))
    }

    /// The boundary rule, which a `hasPrefix` would get wrong: `/Users/u/Projects-old` is not
    /// inside `/Users/u/Projects`.
    @Test func aSiblingSharingAStringPrefixIsOutsideTheScan() {
        #expect(DuplicateReveal.outcome(
            for: DuplicateRevealRequest(path: "/Users/u/Projects-old/x.txt"),
            groups: [], isScanning: false, scannedRoot: "/Users/u/Projects")
                == .outsideScan(name: "x.txt"))
    }

    /// **Membership is its own proof.** A file found IN a group was demonstrably scanned, whatever
    /// root is recorded — so the coverage check must not suppress a real reveal.
    @Test func aFileInAGroupRevealsEvenWhenTheRootLooksWrong() {
        let mine = Self.group(["/a/x.txt", "/b/x.txt"], name: "x.txt")
        #expect(DuplicateReveal.outcome(for: DuplicateRevealRequest(path: "/b/x.txt"),
                                        groups: [mine], isScanning: false, scannedRoot: nil)
                == .reveal(groupID: mine.id))
    }

    /// `outsideScan` claims nothing about the file, so it must not pre-fill the field with its
    /// name: filtering results that never covered it by its name surfaces whatever else shares
    /// that name, dressing a non-answer up as one.
    @Test func outsideScanClearsTheFieldRatherThanFilteringByName() {
        let plan = DuplicateReveal.plan(for: .outsideScan(name: "x.txt"))
        #expect(plan.searchQuery == "")
        #expect(plan.landing == DuplicateReveal.Landing(state: .notScanned(name: "x.txt"),
                                                        query: ""))
        #expect(plan.expandsGroupID == nil)
    }

    /// The two answers stay apart — collapsing "was not looked at" into "has no duplicates" is the
    /// whole failure.
    @Test func theTwoNamedAnswersAreDistinct() {
        #expect(DuplicateReveal.NamedEmptyState.noDuplicates(name: "x")
                != DuplicateReveal.NamedEmptyState.notScanned(name: "x"))
    }

    // MARK: The named answer only applies while its query does

    private static let landing = DuplicateReveal.Landing(
        state: .noDuplicates(name: "lonely.txt"), query: "lonely.txt")

    @Test func theNamedAnswerShowsForItsOwnQueryOnAnEmptyList() {
        #expect(DuplicateReveal.namedAnswer(for: Self.landing, currentQuery: "lonely.txt",
                                            listIsEmpty: true) == .noDuplicates(name: "lonely.txt"))
    }

    /// **The gate.** Someone who lands on *No duplicates of “lonely.txt”* and then types something
    /// else must be told THEIR query matched nothing — not handed an answer about the file they
    /// clicked earlier. Written as a gate rather than as clearing rules because clearing needs one
    /// at every write path, and the chip-removal path was in fact missed.
    @Test func aQueryTheHandoffDidNotWriteRetiresTheAnswer() {
        #expect(DuplicateReveal.namedAnswer(for: Self.landing, currentQuery: "something else",
                                            listIsEmpty: true) == nil)
        // …including the empty query, which is what the ✕ and a chip removal can leave behind.
        #expect(DuplicateReveal.namedAnswer(for: Self.landing, currentQuery: "",
                                            listIsEmpty: true) == nil)
    }

    /// A non-empty list is the ordinary case and shows the results, not an answer about emptiness.
    @Test func aNonEmptyListShowsNoNamedAnswer() {
        #expect(DuplicateReveal.namedAnswer(for: Self.landing, currentQuery: "lonely.txt",
                                            listIsEmpty: false) == nil)
    }

    @Test func noLandingShowsNoNamedAnswer() {
        #expect(DuplicateReveal.namedAnswer(for: nil, currentQuery: "", listIsEmpty: true) == nil)
    }

    /// `outsideScan` writes an EMPTY query, so its answer has to survive one — a gate written as
    /// "a blank field retires the answer" would delete this one the instant it appeared.
    @Test func theNotScannedAnswerSurvivesItsOwnEmptyQuery() {
        let landing = DuplicateReveal.Landing(state: .notScanned(name: "x.txt"), query: "")
        #expect(DuplicateReveal.namedAnswer(for: landing, currentQuery: "", listIsEmpty: true)
                == .notScanned(name: "x.txt"))
        #expect(DuplicateReveal.namedAnswer(for: landing, currentQuery: "typed",
                                            listIsEmpty: true) == nil)
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
        #expect(plan.landing == nil)
    }

    /// Not-found fills the field with the file's name and records the name for the empty state.
    /// The name in BOTH places is what makes the landing self-explaining: the query says what was
    /// asked, the empty state says what came back.
    @Test func notFoundNamesTheFileInTheFieldAndInTheAnswer() {
        let plan = DuplicateReveal.plan(for: .notFound(name: "lonely.txt"))
        #expect(plan.searchQuery == "lonely.txt")
        #expect(plan.landing == DuplicateReveal.Landing(state: .noDuplicates(name: "lonely.txt"),
                                                        query: "lonely.txt"))
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
