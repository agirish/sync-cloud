import Foundation
import Sync

/// Filter for the differences list, by type and side. Nothing persists the choice, so the cases
/// need no stable serialized identity.
public enum DifferenceFilter: CaseIterable {
    case all
    case missingOnLeft
    case missingOnRight
    case changedCopyToRight
    case changedCopyToLeft
    case nameConflicts
    /// The rows the last bulk transfer could not move. The odd one out: it asks what happened to a
    /// difference, not what it is, so it needs `failedIDs` from the manager
    /// (`FileSyncManager.lastTransferFailures`), and the header hides it at zero. See
    /// ``TransferFailures``.
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

    /// `failedIDs` has no default on purpose: a call site that forgot it would compile and answer
    /// "nothing failed", which looks exactly like the feature working.
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

    /// Whether this filter is worth offering now. Only `.failed` is withheld, and only at zero,
    /// since it names an event. Every other case stays listed at zero: "Name conflicts (0)" is an
    /// answer, and a menu whose entries come and go is harder to use.
    func isOffered(failedCount: Int) -> Bool {
        self != .failed || failedCount > 0
    }
}
