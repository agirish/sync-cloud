import Foundation
import Sync

/// "Find duplicates of this" from a pane row: the file the Duplicates workspace has been asked to
/// show, and what it should do about it.
///
/// A request rather than a path so a REPEAT ask re-fires. The user right-clicking the same file
/// twice — after a rescan, or after clearing the search — is asking again, and a bare `String?`
/// compares equal to itself and moves nothing.
public struct DuplicateRevealRequest: Equatable, Identifiable, Sendable {
    public let id: UUID
    /// The absolute path of the file whose group to reveal.
    public let path: String

    /// What the empty state calls it when the file turns out to be in no group.
    public var name: String { (path as NSString).lastPathComponent }

    public init(id: UUID = UUID(), path: String) {
        self.id = id
        self.path = path
    }
}

/// What the Duplicates workspace does with a `DuplicateRevealRequest`, as pure functions over the
/// scan state — so the whole handoff is decided somewhere a test can reach, and `TidyView` only
/// applies the answer.
///
/// The two halves are separate on purpose. `outcome` asks *what is true* (is the scan still
/// running, is the file in a group); `plan` says *what to change* about the lens. Keeping them
/// apart is what lets the "no duplicates of X" case be asserted as a decision rather than inferred
/// from an empty list — an empty list is exactly what this must never quietly become.
public enum DuplicateReveal {

    /// What the current scan state says about the requested file.
    public enum Outcome: Equatable, Sendable {
        /// A scan is running. The request stands; this resolves again when the results land.
        case waiting
        /// The file is in this group — expand it, scroll to it, mark it.
        case reveal(groupID: UUID)
        /// The scan covered this file and it is in no group. Not an empty list: a named answer.
        case notFound(name: String)
        /// The results on screen were scanned from somewhere else, so they say NOTHING about this
        /// file — see `outcome(for:groups:isScanning:scannedRoot:)`.
        case outsideScan(name: String)
    }

    /// The named answer a lens shows when its list is empty.
    public enum NamedEmptyState: Equatable, Sendable {
        /// The scan looked at this file and found no other copy of it.
        case noDuplicates(name: String)
        /// The scan never looked at this file. A different claim entirely, and the one that must
        /// not be collapsed into the other.
        case notScanned(name: String)

        public var name: String {
            switch self {
            case .noDuplicates(let n), .notScanned(let n): return n
            }
        }
    }

    /// The outcome for a request against the scan state, or nil when nothing has been asked.
    ///
    /// **`isScanning` is checked before the group lookup, not after.** The groups array during a
    /// scan is the PREVIOUS scan's, still on screen (`findDuplicates` publishes results only on
    /// completion, so a cancelled scan leaves the prior state intact). Looking there first would
    /// answer from stale results a moment before the real answer arrived.
    ///
    /// **"In no group" is only an ANSWER if the scan looked at the file**, which is what
    /// `scannedRoot` establishes. Without that check the lens says *No duplicates of “x.txt”* on
    /// the strength of results that never saw `x.txt` — the most confident possible way to be
    /// wrong, and precisely the claim this feature exists not to make. Three ways to reach it, all
    /// real:
    ///
    /// - A scan of a *different* folder was already running when the user asked.
    ///   `DuplicateRevealCoordinator.decide` cannot tell: `duplicateScanRoot` is published on
    ///   completion, so an in-flight scan has no root to compare against. It waits, and this is
    ///   the check that makes waiting safe.
    /// - The user cancelled the scan. `isFindingDuplicates` goes false with the previous scan's
    ///   results — or none — still on screen.
    /// - Any future caller that reveals against whatever happens to be loaded.
    ///
    /// Being IN a group needs no such check: membership is itself proof the file was scanned.
    public static func outcome(
        for request: DuplicateRevealRequest?,
        groups: [DuplicateGroup],
        isScanning: Bool,
        scannedRoot: String?
    ) -> Outcome? {
        guard let request else { return nil }
        if isScanning { return .waiting }
        if let group = groups.first(where: { $0.copies.contains { $0.path == request.path } }) {
            return .reveal(groupID: group.id)
        }
        guard let scannedRoot, !scannedRoot.isEmpty,
              PathBoundary.contains(request.path, under: scannedRoot)
        else { return .outsideScan(name: request.name) }
        return .notFound(name: request.name)
    }

    /// A named answer on screen, and the query it was written to describe.
    ///
    /// The query travels with the answer because the answer is only true *of that query's
    /// results*. Holding it here is what lets `namedAnswer(for:currentQuery:listIsEmpty:)` be a
    /// pure test of whether the answer still applies, instead of a set of clearing rules spread
    /// across every place the query can be written.
    public struct Landing: Equatable, Sendable {
        public let state: NamedEmptyState
        public let query: String

        public init(state: NamedEmptyState, query: String) {
            self.state = state
            self.query = query
        }
    }

    /// The named answer to show now, or nil to show the ordinary states.
    ///
    /// **Declarative, and that is the point.** The answer names one file and describes one query's
    /// results, so it must disappear the moment either stops being current. Written as clearing
    /// rules instead, it needs one at every path that can write the field — typing, the ✕, chip
    /// removal, a scan reset, another handoff — and the chip-removal path was in fact missed. A
    /// gate cannot be missed: a query the handoff did not write simply is not this query.
    public static func namedAnswer(
        for landing: Landing?,
        currentQuery: String,
        listIsEmpty: Bool
    ) -> NamedEmptyState? {
        guard let landing, listIsEmpty, landing.query == currentQuery else { return nil }
        return landing.state
    }

    /// The changes a lens makes to show that outcome.
    public struct Plan: Equatable, Sendable {
        /// The group to add to the expanded set, so its copies are on screen.
        public var expandsGroupID: UUID?
        /// The group to scroll to and mark. Same id as `expandsGroupID` today; separate fields
        /// because "which row is open" and "which row was I sent to" are different questions, and
        /// the mark is what makes a reveal into a landing rather than a scroll.
        public var revealedGroupID: UUID?
        /// Whether to drop the lens's match-type filter and its parked query.
        ///
        /// **A reveal that lands behind a filter has not revealed anything.** The Duplicates lens
        /// keeps a per-lens query and a match-type filter across workspace switches, deliberately;
        /// either can hide the group this request names, and the user did not type them in
        /// response to this question.
        public var clearsFilterAndQuery: Bool = false
        /// What to put in the search field, or nil to leave it alone.
        public var searchQuery: String?
        /// The named answer to put on screen, with the query it describes. Nil in every other
        /// outcome, so a stale answer cannot outlive the request that produced it.
        public var landing: Landing?

        public init(expandsGroupID: UUID? = nil, revealedGroupID: UUID? = nil,
                    clearsFilterAndQuery: Bool = false, searchQuery: String? = nil,
                    landing: Landing? = nil) {
            self.expandsGroupID = expandsGroupID
            self.revealedGroupID = revealedGroupID
            self.clearsFilterAndQuery = clearsFilterAndQuery
            self.searchQuery = searchQuery
            self.landing = landing
        }
    }

    /// What to change about the lens to show `outcome`.
    ///
    /// `waiting` plans no NAVIGATION — no filter change, no query, no expansion; the results on
    /// screen during a scan are the previous scan's and are still the truthful thing to show. What
    /// it does carry is the absence of a landing and of a mark, and applying that clears both,
    /// because a request that cannot be answered yet names a different file than whatever answer is
    /// on screen. (A request already answered never reaches here — the caller's applied-id guard
    /// returns first — so waiting on one's OWN scan does not flicker the answer away.)
    ///
    /// That clearing used to be hand-written in `TidyView.applyRevealRequest` alongside an early
    /// return, which made this branch unreachable and left this doc describing behaviour that never
    /// ran. Every outcome now goes through the same apply; only whether the request is RECORDED as
    /// applied differs, which is the caller's bookkeeping rather than a decision about the lens.
    public static func plan(for outcome: Outcome) -> Plan {
        switch outcome {
        case .waiting:
            return Plan()
        case .reveal(let groupID):
            return Plan(expandsGroupID: groupID, revealedGroupID: groupID,
                        clearsFilterAndQuery: true, searchQuery: "")
        case .notFound(let name):
            // The field is filled with the file's name rather than left empty: the answer is about
            // one file, and a list of every other group with the query blank would read as though
            // the question had been dropped. What comes back is either nothing — the named empty
            // state below — or the groups that genuinely share that name, under a query the user
            // can see and clear.
            return Plan(clearsFilterAndQuery: true, searchQuery: name,
                        landing: Landing(state: .noDuplicates(name: name), query: name))
        case .outsideScan(let name):
            // The query is CLEARED here, not filled with the name. Filtering results that never
            // covered this file by its name would surface whatever else happens to share it, under
            // a question about a file the scan never saw — dressing a non-answer up as one. The
            // real results are shown instead, and the named state below explains why they do not
            // answer the question when the list turns out to be empty.
            return Plan(clearsFilterAndQuery: true, searchQuery: "",
                        landing: Landing(state: .notScanned(name: name), query: ""))
        }
    }
}
