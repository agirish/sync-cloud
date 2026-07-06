import Foundation

/// Pure pane-related decision rules extracted from ContentView and its pane delegates so
/// they are unit-testable (the views delegate here and keep only state plumbing).
enum PaneLogic {

    /// Which pane owns the current selection.
    enum ActivePane {
        case left
        case right
    }

    /// The left pane wins when both panes have selections (it is checked first, matching
    /// the historical behavior of the details/actions targeting).
    static func activePane(leftSelection: Set<String>, rightSelection: Set<String>) -> ActivePane? {
        if !leftSelection.isEmpty { return .left }
        if !rightSelection.isEmpty { return .right }
        return nil
    }

    /// The path Quick Look (and similar single-item consumers) should target for the current
    /// selection: alphabetically first path, left pane taking priority — the same ordering
    /// DetailsSidebar uses. `Set.first` is arbitrary per hash seed, so a multi-item selection
    /// would otherwise preview a different file on every launch.
    static func primarySelectionPath(leftSelection: Set<String>, rightSelection: Set<String>) -> String? {
        leftSelection.sorted().first ?? rightSelection.sorted().first
    }

    /// Builds a pane's full path from its provider root and in-pane relative path.
    /// An empty or absolute "relative" path yields just the root, so a stale or
    /// cross-provider relative path can never escape the pane's root.
    static func fullPath(root: String, relativePath: String) -> String {
        let expandedRoot = (root as NSString).expandingTildeInPath
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return expandedRoot }
        return (expandedRoot as NSString).appendingPathComponent(relativePath)
    }

    /// Reduces absolute node paths to ignore targets relative to the pane's focal path,
    /// so an ignore set applies to both panes regardless of provider roots.
    /// Paths outside `basePath` are passed through unchanged.
    static func relativeIgnoreTargets(nodeIds: [String], basePath: String) -> [String] {
        nodeIds.map { id in
            var rPath = id
            if rPath.hasPrefix(basePath) {
                rPath = String(rPath.dropFirst(basePath.count))
                if rPath.hasPrefix("/") { rPath.removeFirst() }
            }
            return rPath
        }
    }

    /// Toggle semantics of the "Ignore in comparison" menu item: when every target is
    /// already ignored the action un-ignores them all, otherwise it ignores them all
    /// (including any already-ignored ones, which stay ignored).
    static func toggledIgnoredPaths(targets: [String], ignoredPaths: Set<String>) -> Set<String> {
        let allIgnored = targets.allSatisfy { ignoredPaths.contains($0) }
        var updated = ignoredPaths
        for target in targets {
            if allIgnored {
                updated.remove(target)
            } else {
                updated.insert(target)
            }
        }
        return updated
    }
}
