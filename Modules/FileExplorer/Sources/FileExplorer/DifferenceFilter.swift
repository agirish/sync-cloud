import Sync

/// Filter for the differences list (by type / side).
public enum DifferenceFilter: String, CaseIterable {
    case all = "All"
    case missingOnLeft = "Missing on left"
    case missingOnRight = "Missing on right"
    case changedCopyToRight = "Changed (left newer)"
    case changedCopyToLeft = "Changed (right newer)"

    /// User-facing label using the panes' provider names; rawValue stays the stable case identity.
    func displayName(leftName: String, rightName: String) -> String {
        switch self {
        case .all: return "All"
        case .missingOnLeft: return "Missing on \(leftName)"
        case .missingOnRight: return "Missing on \(rightName)"
        case .changedCopyToRight: return "Changed (\(leftName) newer)"
        case .changedCopyToLeft: return "Changed (\(rightName) newer)"
        }
    }

    func matches(_ diff: FileDifference) -> Bool {
        switch self {
        case .all: return true
        case .missingOnLeft: return diff.type == .missingOnLeft
        case .missingOnRight: return diff.type == .missingOnRight
        case .changedCopyToRight: return diff.type == .differentDates && diff.action == .copyToRight
        case .changedCopyToLeft: return diff.type == .differentDates && diff.action == .copyToLeft
        }
    }
}
