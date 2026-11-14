import Testing
import Foundation
import Sync
@testable import FileExplorer

/// The "Find duplicates of this" landing: what the Duplicates lens decides about a request, and
/// what it changes to show it. The workspace switch is `DuplicateRevealCoordinatorTests`' business.
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

    /// The scanned root for cases not about coverage: `/`, so every requested file is inside it.
    private static let scanned = "/"

    @Test func noRequestDecidesNothing() {
        #expect(DuplicateReveal.outcome(for: nil, groups: [Self.group(["/a/x"])],
                                        isScanning: false, scannedRoot: Self.scanned) == nil)
    }

    /// The file's own group, not just some group: of two groups only one holds the path, so a
    /// resolver that took the first fails. The path is a non-keeper copy, as the file clicked
    /// usually is.
    @Test func theGroupHoldingTheFileIsTheOneRevealed() {
        let other = Self.group(["/a/other.txt", "/b/other.txt"], name: "other.txt")
        let mine = Self.group(["/a/x.txt", "/b/x.txt"], name: "x.txt")
        let outcome = DuplicateReveal.outcome(
            for: DuplicateRevealRequest(path: "/b/x.txt"),
            groups: [other, mine], isScanning: false, scannedRoot: Self.scanned)
        #expect(outcome == .reveal(groupID: mine.id))
    }

    @Test func aFileInNoGroupIsNamedRatherThanShrugged() {
        let outcome = DuplicateReveal.outcome(
            for: DuplicateRevealRequest(path: "/a/lonely.txt"),
            groups: [Self.group(["/a/x.txt", "/b/x.txt"])], isScanning: false,
            scannedRoot: "/a")
        #expect(outcome == .notFound(name: "lonely.txt"))
    }

    /// `isScanning` is checked before the groups are searched. During a scan the groups on screen
    /// are the previous scan's, so searching first would answer `notFound` from results that never
    /// saw the file; the same inputs with the scan finished resolve.
    @Test func theSameInputsResolveOnceTheScanEnds() {
        let request = DuplicateRevealRequest(path: "/a/x.txt")
        let groups = [Self.group(["/a/old.txt", "/b/old.txt"], name: "old.txt")]
        #expect(DuplicateReveal.outcome(for: request, groups: groups, isScanning: true,
                                        scannedRoot: Self.scanned) == .waiting)
        #expect(DuplicateReveal.outcome(for: request, groups: groups, isScanning: false,
                                        scannedRoot: Self.scanned) == .notFound(name: "x.txt"))
    }

    // MARK: "In no group" is only an answer if the scan looked

    /// A scan of somewhere else says nothing about this file, so `notFound` from it would put "No
    /// duplicates of “x.txt”" on screen from results that never saw it. Reachable:
    /// `DuplicateRevealCoordinator.decide` waits for a running scan whose root it can't know until
    /// `duplicateScanRoot` publishes on completion, so this check is what makes waiting safe.
    @Test func aFileOutsideTheScannedRootIsNotAnswered() {
        let outcome = DuplicateReveal.outcome(
            for: DuplicateRevealRequest(path: "/Users/u/Projects/x.txt"),
            groups: [Self.group(["/Users/u/Documents/a.txt", "/Users/u/Documents/b.txt"])],
            isScanning: false, scannedRoot: "/Users/u/Documents")
        #expect(outcome == .outsideScan(name: "x.txt"))
    }

    /// The same file under a scan that covered it answers for real, or the case above would pass
    /// against a resolver that never answers `notFound`.
    @Test func theSameFileInsideTheScannedRootIsAnswered() {
        let outcome = DuplicateReveal.outcome(
            for: DuplicateRevealRequest(path: "/Users/u/Projects/x.txt"),
            groups: [], isScanning: false, scannedRoot: "/Users/u/Projects")
        #expect(outcome == .notFound(name: "x.txt"))
    }

    /// A cancelled scan is the second way in: `isFindingDuplicates` goes false with no root
    /// published and the previous results (or none) still on screen.
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

    /// Membership is its own proof: a file found in a group was scanned, whatever root is recorded,
    /// so the coverage check must not suppress a real reveal.
    @Test func aFileInAGroupRevealsEvenWhenTheRootLooksWrong() {
        let mine = Self.group(["/a/x.txt", "/b/x.txt"], name: "x.txt")
        #expect(DuplicateReveal.outcome(for: DuplicateRevealRequest(path: "/b/x.txt"),
                                        groups: [mine], isScanning: false, scannedRoot: nil)
                == .reveal(groupID: mine.id))
    }

    /// `outsideScan` claims nothing about the file, so it doesn't pre-fill the field with its name,
    /// which would surface whatever else shares that name and dress a non-answer up as one.
    @Test func outsideScanClearsTheFieldRatherThanFilteringByName() {
        let plan = DuplicateReveal.plan(for: .outsideScan(name: "x.txt"), path: "/pane/x.txt")
        #expect(plan.searchQuery == "")
        #expect(plan.landing == DuplicateReveal.Landing(state: .notScanned(name: "x.txt"),
                                                        query: "", path: "/pane/x.txt"))
        #expect(plan.expandsGroupID == nil)
    }

    /// The two answers stay apart: "was not looked at" is not "has no duplicates".
    @Test func theTwoNamedAnswersAreDistinct() {
        #expect(DuplicateReveal.NamedEmptyState.noDuplicates(name: "x")
                != DuplicateReveal.NamedEmptyState.notScanned(name: "x"))
    }

    // MARK: The named answer only applies while its query does

    private static let landing = DuplicateReveal.Landing(
        state: .noDuplicates(name: "lonely.txt"), query: "lonely.txt", path: "/pane/lonely.txt")

    @Test func theNamedAnswerShowsForItsOwnQueryOnAnEmptyList() {
        #expect(DuplicateReveal.namedAnswer(for: Self.landing, currentQuery: "lonely.txt",
                                            listIsEmpty: true) == .noDuplicates(name: "lonely.txt"))
    }

    /// After landing on "No duplicates of “lonely.txt”", typing something else must say that query
    /// matched nothing, not answer about the earlier file. A gate rather than clearing rules,
    /// because clearing needs a rule at every write path and one is easily missed.
    @Test func aQueryTheHandoffDidNotWriteRetiresTheAnswer() {
        #expect(DuplicateReveal.namedAnswer(for: Self.landing, currentQuery: "something else",
                                            listIsEmpty: true) == nil)
        // Including the empty query, which the ✕ and a chip removal can leave behind.
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

    /// `outsideScan` writes an empty query, so its answer must survive one; "a blank field retires
    /// the answer" would delete it the instant it appeared.
    @Test func theNotScannedAnswerSurvivesItsOwnEmptyQuery() {
        let landing = DuplicateReveal.Landing(state: .notScanned(name: "x.txt"), query: "", path: "/pane/x.txt")
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
        let plan = DuplicateReveal.plan(for: .reveal(groupID: id), path: "/pane/x.txt")
        #expect(plan.expandsGroupID == id)
        #expect(plan.revealedGroupID == id)
        #expect(plan.clearsFilterAndQuery)
        #expect(plan.searchQuery == "")
        #expect(plan.landing == nil)
    }

    /// Not-found puts the file's name in the field and in the empty state, so the landing explains
    /// itself: the query says what was asked, the empty state what came back.
    @Test func notFoundNamesTheFileInTheFieldAndInTheAnswer() {
        let plan = DuplicateReveal.plan(for: .notFound(name: "lonely.txt"), path: "/pane/lonely.txt")
        #expect(plan.searchQuery == "lonely.txt")
        #expect(plan.landing == DuplicateReveal.Landing(state: .noDuplicates(name: "lonely.txt"),
                                                        query: "lonely.txt", path: "/pane/lonely.txt"))
        #expect(plan.expandsGroupID == nil)
        #expect(plan.revealedGroupID == nil)
    }

    /// Waiting navigates nowhere (the previous scan's results stay put) but retires the named
    /// answer and the mark, which are about some other file.
    @Test func waitingRetiresTheAnswerAndNavigatesNowhere() {
        let plan = DuplicateReveal.plan(for: .waiting, path: "/pane/x.txt")
        // Retires the previous answer: `LensWorkspaceView.applyRevealPlan` assigns both unconditionally.
        #expect(plan.landing == nil)
        #expect(plan.revealedGroupID == nil)
        // It moves nothing the user set up.
        #expect(plan.clearsFilterAndQuery == false)
        #expect(plan.searchQuery == nil)
        #expect(plan.expandsGroupID == nil)
    }

    // MARK: A request that started its own scan

    /// `isScanning` alone leaves a one-turn gap: the coordinator sets the request and starts the
    /// scan together, but the flag flips in the scan task's first hop, after awaiting any previous
    /// scan task. A resolve in that gap would answer `.outsideScan` from the previous results and
    /// consume the request, leaving the new scan nothing to reveal for.
    @Test func aRequestThatStartedAScanWaitsUntilANewCompletionPublishes() {
        let request = DuplicateRevealRequest(path: "/pane/x.txt",
                                             awaitsScanReplacing: .init(root: "/old"))
        // The window: flag not yet flipped, old results still published.
        #expect(DuplicateReveal.outcome(for: request, groups: [], isScanning: false,
                                        scannedRoot: "/old") == .waiting)
        // A new completion publishes (the started scan, or any later one): the request resolves.
        #expect(DuplicateReveal.outcome(for: request, groups: [], isScanning: false,
                                        scannedRoot: "/pane") == .notFound(name: "x.txt"))
    }

    /// The never-scanned variant of the same window: `nil == nil` must read as "my scan has not
    /// landed", not as a match on nothing.
    @Test func aFirstEverScanIsAlsoWaitedFor() {
        let request = DuplicateRevealRequest(path: "/pane/x.txt",
                                             awaitsScanReplacing: .init(root: nil))
        #expect(DuplicateReveal.outcome(for: request, groups: [], isScanning: false,
                                        scannedRoot: nil) == .waiting)
        #expect(DuplicateReveal.outcome(for: request, groups: [], isScanning: false,
                                        scannedRoot: "/pane") == .notFound(name: "x.txt"))
    }

    // MARK: Which landings are worth keeping

    /// An empty-query landing shows only while the whole list is empty, so one applied over a
    /// populated list is dropped. Kept, it would surface "wasn't in the last scan" over the
    /// all-clear once the last group resolved, about a file asked about long before.
    @Test func anEmptyQueryLandingIsDroppedWhenTheListHasRows() {
        let latent = DuplicateReveal.Landing(state: .notScanned(name: "x.txt"), query: "",
                                             path: "/pane/x.txt")
        #expect(DuplicateReveal.landingToStore(latent, listIsEmpty: false) == nil)
        #expect(DuplicateReveal.landingToStore(latent, listIsEmpty: true) == latent)
    }

    /// A named-query landing is kept either way: it shows once its query takes effect, and its
    /// claim is a scan-level fact that stays true however the list changes.
    @Test func aNamedQueryLandingIsKeptRegardlessOfTheList() {
        let named = DuplicateReveal.Landing(state: .noDuplicates(name: "x.txt"), query: "x.txt",
                                            path: "/pane/x.txt")
        #expect(DuplicateReveal.landingToStore(named, listIsEmpty: false) == named)
        #expect(DuplicateReveal.landingToStore(named, listIsEmpty: true) == named)
        #expect(DuplicateReveal.landingToStore(nil, listIsEmpty: true) == nil)
    }

    /// A repeat ask about the same file is a new request; a bare path would compare equal, so
    /// asking again after clearing the search would do nothing.
    @Test func twoRequestsForOneFileAreNotEqual() {
        #expect(DuplicateRevealRequest(path: "/a/x.txt") != DuplicateRevealRequest(path: "/a/x.txt"))
    }

    @Test func theRequestNamesTheFileForTheEmptyState() {
        #expect(DuplicateRevealRequest(path: "/a/b/Q3 Forecast.numbers").name == "Q3 Forecast.numbers")
    }
}
