import Foundation
import Sync

/// "Find duplicates of this" from a pane row: the file the Duplicates lens has been asked to
/// show, and what it should do about it.
///
/// A request rather than a path so a repeat ask re-fires: right-clicking the same file again, after
/// a rescan or a cleared search, is asking again, and a bare `String?` equals itself.
public struct DuplicateRevealRequest: Equatable, Identifiable, Sendable {
    public let id: UUID
    /// The absolute path of the file whose group to reveal.
    public let path: String
    /// Set when the ask started a scan (`Decision.scanThenReveal`): the completed scan root at that
    /// moment, so `outcome` can tell "my scan hasn't landed yet" from "no scan is running".
    ///
    /// `isScanning` alone can't: the coordinator starts the scan in the same turn it sets this
    /// request, but the flag flips only on the scan task's first hop, after `restartedScanTask`
    /// awaits the previous task. The lens's resolve task can run in that gap, see `isScanning ==
    /// false` over the previous results, answer `.outsideScan` and consume the request, so the scan
    /// lands with nobody to reveal for. Until a new completion publishes, `scannedRoot` still
    /// equals this snapshot and the request keeps waiting; afterwards they can't be equal, because
    /// `scanThenReveal` is chosen only when the old root doesn't contain the file. Nil for the
    /// other two decisions.
    public let awaitsScanReplacing: ScannedRootSnapshot?

    /// The root, wrapped so the two layers of optionality can't collapse: "not waiting on a scan"
    /// and "waiting, and no scan had ever completed" are different facts, and `String??` flattens.
    public struct ScannedRootSnapshot: Equatable, Sendable {
        public let root: String?
        public init(root: String?) { self.root = root }
    }

    /// What the empty state calls it when the file turns out to be in no group.
    public var name: String { (path as NSString).lastPathComponent }

    public init(id: UUID = UUID(), path: String, awaitsScanReplacing: ScannedRootSnapshot? = nil) {
        self.id = id
        self.path = path
        self.awaitsScanReplacing = awaitsScanReplacing
    }
}

/// What the Duplicates lens does with a `DuplicateRevealRequest`, as pure functions over the scan
/// state, so the handoff is decided where a test can reach it and `LensWorkspaceView` only applies
/// the answer.
///
/// `outcome` asks what is true (is the scan running, is the file in a group); `plan` says what to
/// change about the lens. Kept apart so "no duplicates of X" is asserted as a decision, never
/// inferred from an empty list.
public enum DuplicateReveal {

    /// What the current scan state says about the requested file.
    public enum Outcome: Equatable, Sendable {
        /// A scan is running. The request stands; this resolves again when the results land.
        case waiting
        /// The file is in this group — expand it, scroll to it, mark it.
        case reveal(groupID: UUID)
        /// The scan covered this file and it is in no group. Not an empty list: a named answer.
        case notFound(name: String)
        /// The results on screen were scanned from somewhere else, so they say nothing about this
        /// file; see `outcome(for:groups:isScanning:scannedRoot:)`.
        case outsideScan(name: String)
    }

    /// The named answer a lens shows when its list is empty.
    public enum NamedEmptyState: Equatable, Sendable {
        /// The scan looked at this file and found no other copy of it.
        case noDuplicates(name: String)
        /// The scan never looked at this file. A different claim, and one that must never be
        /// collapsed into the other.
        case notScanned(name: String)

        public var name: String {
            switch self {
            case .noDuplicates(let n), .notScanned(let n): return n
            }
        }
    }

    /// The outcome for a request against the scan state, or nil when nothing has been asked.
    ///
    /// `isScanning` is checked before the group lookup: during a scan the groups are the previous
    /// scan's, still on screen (`findDuplicates` publishes only on completion, so a cancelled scan
    /// leaves the prior state intact), and looking there first would answer from stale results.
    ///
    /// "In no group" is an answer only if the scan looked at the file, which `scannedRoot`
    /// establishes. Without that check the lens would say *No duplicates of “x.txt”* from results
    /// that never saw it. Ways to reach that state:
    ///
    /// - A scan of a different folder was already running when the user asked.
    ///   `DuplicateRevealCoordinator.decide` can't tell, since `duplicateScanRoot` is published on
    ///   completion; it waits, and this check makes waiting safe.
    /// - The user cancelled the scan. `isFindingDuplicates` goes false with the previous results,
    ///   or none, still on screen.
    /// - Any future caller that reveals against whatever is loaded.
    ///
    /// Being in a group needs no such check: membership proves the file was scanned.
    public static func outcome(
        for request: DuplicateRevealRequest?,
        groups: [DuplicateGroup],
        isScanning: Bool,
        scannedRoot: String?
    ) -> Outcome? {
        guard let request else { return nil }
        if isScanning { return .waiting }
        // A request that started its own scan waits until a new completion publishes; `isScanning`
        // misses the turn before the scan task flips it. See `awaitsScanReplacing`.
        if let snapshot = request.awaitsScanReplacing, scannedRoot == snapshot.root {
            return .waiting
        }
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
    /// The query travels with the answer because the answer is true only of that query's results.
    /// That lets `namedAnswer(for:currentQuery:listIsEmpty:)` be a pure test of whether it still
    /// applies, instead of clearing rules spread across every place the query is written.
    public struct Landing: Equatable, Sendable {
        public let state: NamedEmptyState
        public let query: String
        /// The absolute path of the file the answer is about. The `notScanned` state's recovery
        /// button scans this file's folder, and by then the request is consumed, so the landing
        /// carries it.
        public let path: String

        public init(state: NamedEmptyState, query: String, path: String) {
            self.state = state
            self.query = query
            self.path = path
        }
    }

    /// Whether a freshly planned landing is worth keeping, given whether the visible list is
    /// empty at the moment it is applied.
    ///
    /// A landing with a named query shows whenever that query is in the field, and its claim (the
    /// scan covered this file and found no other copy) stays true however the list changes. An
    /// empty-query landing can show only when the whole list is empty, so if the list has rows at
    /// apply time it is dropped: kept, it would surface "«X» wasn't in the last scan" over the
    /// all-clear once the last group is resolved, answering a question asked long before.
    public static func landingToStore(_ landing: Landing?, listIsEmpty: Bool) -> Landing? {
        guard let landing else { return nil }
        guard landing.query.isEmpty else { return landing }
        return listIsEmpty ? landing : nil
    }

    /// The named answer to show now, or nil to show the ordinary states.
    ///
    /// Declarative on purpose. The answer names one file and describes one query's results, so it
    /// must disappear once either stops being current. Clearing rules would need one at every path
    /// that writes the field (typing, the ✕, chip removal, a scan reset, another handoff); a gate
    /// can't be missed, because a query the handoff didn't write is simply not this query.
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
        /// The group to scroll to and mark. Same id as `expandsGroupID` today; separate because
        /// "which row is open" and "which row was I sent to" are different questions, and the mark
        /// is what makes a reveal a landing rather than a scroll.
        public var revealedGroupID: UUID?
        /// Whether to drop the lens's match-type filter and its parked query. Both survive
        /// workspace switches, either can hide the group this request names, and the user didn't
        /// set them in answer to this question; a reveal behind a filter reveals nothing.
        public var clearsFilterAndQuery: Bool = false
        /// What to put in the search field, or nil to leave it alone.
        public var searchQuery: String?
        /// The named answer to put on screen, with the query it describes. Nil for every other
        /// outcome, so a stale answer can't outlive its request.
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
    /// `waiting` plans no navigation: no filter change, query or expansion, since the results on
    /// screen during a scan are the previous scan's and still the truthful thing to show. Applying
    /// it clears the landing and the mark, because a request not yet answerable names a different
    /// file than any answer on screen. A request already answered never reaches here (the caller's
    /// applied-id guard returns first), so waiting on its own scan doesn't flicker the answer away.
    ///
    /// Every outcome goes through the same apply; only whether the request is recorded as applied
    /// differs, and that is the caller's bookkeeping. `path` is the request's file, carried by the
    /// landings so the `notScanned` recovery button can name a folder after the request is
    /// consumed.
    public static func plan(for outcome: Outcome, path: String) -> Plan {
        switch outcome {
        case .waiting:
            return Plan()
        case .reveal(let groupID):
            return Plan(expandsGroupID: groupID, revealedGroupID: groupID,
                        clearsFilterAndQuery: true, searchQuery: "")
        case .notFound(let name):
            // The field gets the file's name, not blank: the answer is about one file, and every
            // other group under a blank query would read as though the question was dropped. What
            // comes back is the named empty state, or the groups that really share that name under
            // a visible query.
            return Plan(clearsFilterAndQuery: true, searchQuery: name,
                        landing: Landing(state: .noDuplicates(name: name), query: name, path: path))
        case .outsideScan(let name):
            // The query is cleared, not filled with the name: filtering results that never covered
            // this file by its name would pass off whatever else shares it as an answer. The real
            // results show instead, and the named state explains why they don't answer when the
            // list is empty.
            return Plan(clearsFilterAndQuery: true, searchQuery: "",
                        landing: Landing(state: .notScanned(name: name), query: "", path: path))
        }
    }
}
