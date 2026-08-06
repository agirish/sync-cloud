import Foundation
import Sync

/// Filter for the differences list (by type / side). The selection is transient view
/// @State — nothing persists it, so the cases need no stable serialized identity.
public enum DifferenceFilter: CaseIterable {
    case all
    case missingOnLeft
    case missingOnRight
    case changedCopyToRight
    case changedCopyToLeft
    case nameConflicts
    /// The rows the last bulk transfer could not move.
    ///
    /// The odd one out, and deliberately so: every other case asks a question about the difference
    /// itself, while this one asks what happened to it. That is why it needs `failedIDs` passed in
    /// — the fact lives on the manager (`FileSyncManager.lastTransferFailures`), not on the row —
    /// and why the header hides it at zero instead of offering a filter that can only ever be
    /// empty. See ``TransferFailures``.
    case failed

    /// User-facing label using the panes' provider names.
    func displayName(leftName: String, rightName: String) -> String {
        switch self {
        case .all: return "All"
        case .missingOnLeft: return "Missing on \(leftName)"
        case .missingOnRight: return "Missing on \(rightName)"
        case .changedCopyToRight: return "Changed (\(leftName) newer)"
        case .changedCopyToLeft: return "Changed (\(rightName) newer)"
        case .nameConflicts: return "Name conflicts"
        case .failed: return "Failed to transfer"
        }
    }

    /// `failedIDs` has no default on purpose. A defaulted empty set would let a call site that
    /// forgot it compile and answer "nothing failed" — which is the same answer the feature gives
    /// when it is working, so the omission would be invisible.
    func matches(_ diff: FileDifference, failedIDs: Set<UUID>) -> Bool {
        switch self {
        case .all: return true
        case .missingOnLeft: return diff.type == .missingOnLeft
        case .missingOnRight: return diff.type == .missingOnRight
        case .changedCopyToRight: return diff.type == .differentDates && diff.action == .copyToRight
        case .changedCopyToLeft: return diff.type == .differentDates && diff.action == .copyToLeft
        case .nameConflicts: return diff.type == .nameConflict
        case .failed: return failedIDs.contains(diff.id)
        }
    }

    /// Whether this filter is worth offering right now.
    ///
    /// Only `.failed` is ever withheld, and only at zero: it names an event rather than a shape, so
    /// outside the minutes after a partial run there is nothing for it to show. Every other case
    /// stays listed at zero — "Name conflicts (0)" is an answer, and a menu whose entries come and
    /// go is harder to use than one with zeroes in it.
    func isOffered(failedCount: Int) -> Bool {
        self != .failed || failedCount > 0
    }
}
