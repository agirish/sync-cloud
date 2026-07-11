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

    /// User-facing label using the panes' provider names.
    func displayName(leftName: String, rightName: String) -> String {
        switch self {
        case .all: return "All"
        case .missingOnLeft: return "Missing on \(leftName)"
        case .missingOnRight: return "Missing on \(rightName)"
        case .changedCopyToRight: return "Changed (\(leftName) newer)"
        case .changedCopyToLeft: return "Changed (\(rightName) newer)"
        case .nameConflicts: return "Name conflicts"
        }
    }

    func matches(_ diff: FileDifference) -> Bool {
        switch self {
        case .all: return true
        case .missingOnLeft: return diff.type == .missingOnLeft
        case .missingOnRight: return diff.type == .missingOnRight
        case .changedCopyToRight: return diff.type == .differentDates && diff.action == .copyToRight
        case .changedCopyToLeft: return diff.type == .differentDates && diff.action == .copyToLeft
        case .nameConflicts: return diff.type == .nameConflict
        }
    }
}
