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
    public enum Outcome: Equatable {
        /// A scan is running. The request stands; this resolves again when the results land.
        case waiting
        /// The file is in this group — expand it, scroll to it, mark it.
        case reveal(groupID: UUID)
        /// The scan is done and the file is in no group. Not an empty list: a named answer.
        case notFound(name: String)
    }

    /// The outcome for a request against the scan state, or nil when nothing has been asked.
    ///
    /// **`isScanning` is checked before the group lookup, not after.** The groups array during a
    /// scan is the PREVIOUS scan's, still on screen (`findDuplicates` publishes results only on
    /// completion, so a cancelled scan leaves the prior state intact). Looking there first would
    /// answer `notFound` from stale results and land the user in the named empty state a moment
    /// before the real answer arrived — and `notFound` writes a search query, so the arriving
    /// results would then be filtered by it.
    public static func outcome(
        for request: DuplicateRevealRequest?,
        groups: [DuplicateGroup],
        isScanning: Bool
    ) -> Outcome? {
        guard let request else { return nil }
        if isScanning { return .waiting }
        if let group = groups.first(where: { $0.copies.contains { $0.path == request.path } }) {
            return .reveal(groupID: group.id)
        }
        return .notFound(name: request.name)
    }

    /// The changes a lens makes to show that outcome.
    public struct Plan: Equatable {
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
        /// The file the lens found nothing for — drives the named empty state. Nil in every other
        /// outcome, so a stale name cannot outlive the request that produced it.
        public var unmatchedName: String?

        public init(expandsGroupID: UUID? = nil, revealedGroupID: UUID? = nil,
                    clearsFilterAndQuery: Bool = false, searchQuery: String? = nil,
                    unmatchedName: String? = nil) {
            self.expandsGroupID = expandsGroupID
            self.revealedGroupID = revealedGroupID
            self.clearsFilterAndQuery = clearsFilterAndQuery
            self.searchQuery = searchQuery
            self.unmatchedName = unmatchedName
        }
    }

    /// What to change about the lens to show `outcome`.
    ///
    /// `waiting` plans nothing at all — not even clearing the mark from a previous reveal. The
    /// results on screen during a scan are the previous scan's, and the previous landing is still
    /// the truthful thing to be showing until new ones arrive.
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
            return Plan(clearsFilterAndQuery: true, searchQuery: name, unmatchedName: name)
        }
    }
}
