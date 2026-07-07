import FileExplorer
import Foundation

/// Pure pane-related decision rules extracted from ContentView and its pane delegates so
/// they are unit-testable (the views delegate here and keep only state plumbing).
enum PaneLogic {

    /// Which pane owns the current selection.
    enum ActivePane {
        case left
        case right
    }

    /// The provider the action bar's Copy/Move buttons target: the pane opposite the one
    /// holding the selection. `nil` when nothing is selected — there is no direction yet,
    /// so the buttons fall back to a neutral label.
    static func copyTargetName(activePane: ActivePane?, paneNames: PaneProviderNames) -> String? {
        activePane.map { paneNames.other(isLeft: $0 == .left) }
    }

    /// SF Symbols for the action bar's Copy/Move buttons, pointing toward the pane the
    /// operation targets (the one opposite the selection). SF Symbols has no left-pointing
    /// counterpart of `arrow.right.doc.on.clipboard`, so the directional states use the
    /// symmetric circle/square arrow pairs instead of mismatched glyphs; with no selection
    /// the buttons keep their neutral right-pointing defaults.
    static func actionBarSymbols(activePane: ActivePane?) -> (copy: String, move: String) {
        switch activePane {
        case .left: return (copy: "arrow.right.circle", move: "arrow.right.square")
        case .right: return (copy: "arrow.left.circle", move: "arrow.left.square")
        case nil: return (copy: "arrow.right.doc.on.clipboard", move: "arrow.right.square")
        }
    }

    /// Reconciles a pane-selection write with the one-pane-selected invariant: setting a
    /// non-empty selection in one pane clears the other pane in the same update, so no
    /// consumer ever observes both panes selected. Setting an empty selection (a deselect,
    /// or SwiftUI re-writing an unchanged empty set) leaves the other pane alone — this is
    /// what keeps right-click context menus working, since right-click never sets selection
    /// and "Copy N items from other pane" needs the other pane's selection to survive.
    /// Only the FileTreeView selection bindings route through this; selection pruning and
    /// navigation resets write the manager's properties directly.
    static func reconciledSelections(
        settingSelection newSelection: Set<String>,
        isLeft: Bool,
        currentLeft: Set<String>,
        currentRight: Set<String>
    ) -> (left: Set<String>, right: Set<String>) {
        if isLeft {
            return (left: newSelection, right: newSelection.isEmpty ? currentRight : [])
        } else {
            return (left: newSelection.isEmpty ? currentLeft : [], right: newSelection)
        }
    }

    /// The left pane wins when both panes have selections (it is checked first, matching
    /// the historical behavior of the details/actions targeting). Since the selection
    /// bindings enforce exclusivity synchronously via `reconciledSelections`, the
    /// both-non-empty tie can no longer occur in the app; the rule remains as a safe default.
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

    /// Whether a pane selection change should switch the bottom pane to the Details tab.
    /// A manual Differences pick is sticky: once the user has chosen Differences via the
    /// Picker, selection changes never steal the tab (they may be clicking tree files while
    /// working through the differences list). Manually picking Details re-arms the
    /// auto-switch — the caller clears `differencesPickedManually` in the Picker's setter.
    static func shouldAutoSwitchToDetails(
        hasSelection: Bool,
        bottomPaneVisible: Bool,
        currentTabIsDetails: Bool,
        differencesPickedManually: Bool
    ) -> Bool {
        hasSelection && bottomPaneVisible && !currentTabIsDetails && !differencesPickedManually
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
