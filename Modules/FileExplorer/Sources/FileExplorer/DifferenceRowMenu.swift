import Foundation
import Sync

/// Pure logic behind `DifferenceRow`'s context menu: which per-side items to offer
/// (only sides that exist on disk) and how the ignore toggle resolves.
public enum DifferenceRowMenu {
    /// One side of a difference that actually exists on disk, ready for per-side
    /// menu items (Reveal in Finder, Quick Look, Copy Path).
    public struct Side: Equatable, Sendable {
        /// Pane's provider display name, already disambiguated by `PaneProviderNames`
        /// when both panes show the same provider — safe to use as a ForEach id.
        public let paneName: String
        /// Absolute filesystem path of the item on this side.
        public let path: String

        public init(paneName: String, path: String) {
            self.paneName = paneName
            self.path = path
        }
    }

    /// The sides of a difference that exist on disk, left first. A "missing on X"
    /// difference has no item on X, so only the opposite side is returned.
    public static func existingSides(for difference: FileDifference, paneNames: PaneProviderNames) -> [Side] {
        var sides: [Side] = []
        if difference.type != .missingOnLeft {
            sides.append(Side(paneName: paneNames.left, path: difference.leftItemPath))
        }
        if difference.type != .missingOnRight {
            sides.append(Side(paneName: paneNames.right, path: difference.rightItemPath))
        }
        return sides
    }

    /// Whether this difference is hidden by the current ignore set. Uses the same
    /// predicate the differences filter applies (`FileSyncManager.isIgnoredPath` over
    /// `relativePath`), so the menu label always agrees with list membership.
    public static func isIgnored(_ difference: FileDifference, ignoredPaths: Set<String>) -> Bool {
        FileSyncManager.isIgnoredPath(difference.relativePath, ignored: ignoredPaths)
    }

    /// Toggles the difference's ignore entry. The target is `relativePath` — the exact
    /// value `FileSyncManager.applyFilters()` matches differences against, and the same
    /// focal-point-relative form the tree panes' ignore produces — so ignoring here
    /// removes the row from the list and strikes it through in both trees.
    public static func toggledIgnoredPaths(for difference: FileDifference, ignoredPaths: Set<String>) -> Set<String> {
        var updated = ignoredPaths
        if updated.contains(difference.relativePath) {
            updated.remove(difference.relativePath)
        } else {
            updated.insert(difference.relativePath)
        }
        return updated
    }
}
