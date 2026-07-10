import CoreGraphics
import FileExplorer
import Foundation
import Sync

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

    /// SF Symbols for the action bar's Copy/Move buttons. Copy uses the universal duplicate
    /// glyph (`doc.on.doc`) in every state — instantly recognizable as "copy" — and carries
    /// its direction in the button's "Copy to <pane>" label rather than a directional arrow,
    /// since SF Symbols has no left-pointing copy glyph to pair with the right one. Move stays
    /// directional: a box-with-arrow that points toward the pane the operation targets (the one
    /// opposite the selection), falling back to right-pointing when there is no selection yet.
    static func actionBarSymbols(activePane: ActivePane?) -> (copy: String, move: String) {
        switch activePane {
        case .left: return (copy: "doc.on.doc", move: "arrow.right.square")
        case .right: return (copy: "doc.on.doc", move: "arrow.left.square")
        case nil: return (copy: "doc.on.doc", move: "arrow.right.square")
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
    /// would otherwise preview a different file on every launch. `min()` is the allocation-free
    /// equivalent of `sorted().first` (both take the least element by `<`).
    static func primarySelectionPath(leftSelection: Set<String>, rightSelection: Set<String>) -> String? {
        leftSelection.min() ?? rightSelection.min()
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
    /// Paths outside `basePath` are passed through unchanged. Stripping happens only at a
    /// path-component boundary — "/root/ab" is not a base of "/root/abc/x", so a sibling
    /// root that merely shares a string prefix can never alias into relative targets.
    static func relativeIgnoreTargets(nodeIds: [String], basePath: String) -> [String] {
        let base = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        return nodeIds.map { id in
            if id == base { return "" }
            guard id.hasPrefix(base + "/") else { return id }
            return String(id.dropFirst(base.count + 1))
        }
    }

    /// The provider ids the two panes should show after a left↔right swap: each id moves to
    /// the opposite side. Pure so ContentView's swap action and its test agree on the mapping
    /// without a running view. This is only the @AppStorage half of a pane swap; the manager's
    /// focused relative paths, selections, and navigation histories are swapped in lockstep by
    /// `FileSyncManager.swapPanes()`.
    static func swappedProviderIds(
        leftProviderId: String,
        rightProviderId: String
    ) -> (leftProviderId: String, rightProviderId: String) {
        (leftProviderId: rightProviderId, rightProviderId: leftProviderId)
    }

    /// Toggle semantics of the "Ignore in comparison" menu item: when every target is
    /// already ignored the action un-ignores them all, otherwise it ignores them all
    /// (including any already-ignored ones, which stay ignored).
    ///
    /// "Already ignored" uses `FileSyncManager.isIgnoredPath` — the same effective
    /// (ancestor-covering) predicate that drives the menu's Ignore/Include label and the
    /// differences filter — so the action always does what the label says. Un-ignoring a
    /// target covered only by an ancestor entry ("docs" ignored, target "docs/report.txt")
    /// therefore removes the covering "docs" entry too: the clicked item becomes visible
    /// again, like Finder's un-hide, rather than the toggle silently doing nothing.
    static func toggledIgnoredPaths(targets: [String], ignoredPaths: Set<String>) -> Set<String> {
        let allIgnored = targets.allSatisfy { FileSyncManager.isIgnoredPath($0, ignored: ignoredPaths) }
        var updated = ignoredPaths
        if allIgnored {
            for target in targets {
                updated = updated.filter { entry in
                    !(target == entry || target.hasPrefix(entry + "/"))
                }
            }
        } else {
            updated.formUnion(targets)
        }
        return updated
    }

    // MARK: - Resize split layout

    /// Math for the two invisible resize dividers (the left↔right pane split and the panes↔bottom
    /// split). Kept pure and out of the `GeometryReader` view builders so the clamp guards — which
    /// are what stop a too-small window from inverting the split — are exercised by tests instead
    /// of only ever running against live geometry.

    /// The horizontal pane split's minimum fraction: the smallest share the left pane may take so
    /// it never shrinks below `minPane` points. Capped at 0.5 so a window narrower than 2×minPane
    /// degrades to an even split rather than demanding an impossible width — which would push the
    /// minimum past `1 - minFraction` and invert the clamp bounds — and 0 for a degenerate
    /// zero-width window so the arithmetic stays finite.
    static func horizontalMinFraction(totalWidth: CGFloat, minPane: CGFloat) -> Double {
        totalWidth > 0 ? min(0.5, Double(minPane / totalWidth)) : 0
    }

    /// The bottom (Differences/Details) pane's laid-out area: the total content height less the
    /// 1pt divider, floored at 0 so a collapsed window never yields a negative height.
    static func verticalPanesHeight(totalHeight: CGFloat, dividerHeight: CGFloat) -> CGFloat {
        max(0, totalHeight - dividerHeight)
    }

    /// The vertical split's minimum fraction — the bottom pane's smallest share, so it never drops
    /// below `minBottom` points. Capped at 0.85 (mirroring the horizontal rule) and 0 for a
    /// zero-height area.
    static func verticalMinFraction(panesHeight: CGFloat, minBottom: CGFloat) -> Double {
        panesHeight > 0 ? min(0.85, Double(minBottom / panesHeight)) : 0
    }

    /// The vertical split's maximum fraction so the top panes never drop below `minTop` points.
    /// The `max(minFraction, …)` floor is the important guard: when the window is too short to
    /// honor both mins at once, `1 - minTop/panesHeight` can fall below `minFraction`, which would
    /// invert the clamp bounds; keeping the upper bound at or above the lower one means the bottom
    /// pane's minimum wins that tie and the clamp still resolves to a sane fraction.
    static func verticalMaxFraction(panesHeight: CGFloat, minTop: CGFloat, minFraction: Double) -> Double {
        panesHeight > 0 ? max(minFraction, 1 - Double(minTop / panesHeight)) : 1
    }

    /// Clamps a desired split fraction into `[lower, upper]`. One shared helper so the laid-out
    /// fraction and the live drag gesture clamp identically. If the bounds are ever inverted
    /// (`upper < lower`, an over-constrained window) the outer `min` wins and the result pins to
    /// `upper` — the larger section's minimum is the one sacrificed.
    static func clampedFraction(_ desired: Double, lower: Double, upper: Double) -> Double {
        min(max(desired, lower), upper)
    }

    /// The split fraction implied by the cursor's absolute x within the pane row during a
    /// horizontal divider drag. The caller guards `totalWidth > 0` before calling.
    static func horizontalDragFraction(locationX: CGFloat, totalWidth: CGFloat) -> Double {
        Double(locationX / totalWidth)
    }

    /// The bottom-pane fraction implied by the cursor's absolute y during a vertical divider drag.
    /// The bottom pane grows as the cursor moves up, so the fraction is the cursor's distance from
    /// the bottom of the pane area, not its distance from the top. The caller guards
    /// `panesHeight > 0` before calling.
    static func verticalDragFraction(locationY: CGFloat, panesHeight: CGFloat) -> Double {
        Double((panesHeight - locationY) / panesHeight)
    }
}
