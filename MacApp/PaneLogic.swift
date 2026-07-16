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

    /// SF Symbols for the action bar's Copy/Move buttons, drawn from the shared `TransferGlyph`
    /// vocabulary so the toolbar, the Differences header, and the right-click menus can't drift.
    /// Copy is the universal duplicate glyph in every state — instantly recognizable, with its
    /// direction carried in the "Copy to <pane>" label since SF Symbols has no left-pointing copy
    /// glyph to pair with the right one. Move stays directional: a box-with-arrow pointing toward
    /// the pane the operation targets (opposite the selection), falling back to right-pointing
    /// when there is no selection yet.
    static func actionBarSymbols(activePane: ActivePane?) -> (copy: String, move: String) {
        switch activePane {
        case .left: return (copy: TransferGlyph.copy, move: TransferGlyph.move(toRight: true))
        case .right: return (copy: TransferGlyph.copy, move: TransferGlyph.move(toRight: false))
        case nil: return (copy: TransferGlyph.copy, move: TransferGlyph.move(toRight: true))
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
    /// the historical behavior of the details/actions targeting). The selection bindings
    /// enforce exclusivity via `reconciledSelections`, clearing the other pane one runloop
    /// tick after a pick lands, so a both-non-empty state can exist for at most a single
    /// frame — this left-wins tiebreak keeps that frame pointing at a real pane.
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

    /// Which pane a single-source Tidy scan/inspect should target. The Tidy rail is always the LEFT
    /// pane, so in single-source mode the answer is always "left" — even when a selection lingers in
    /// the (hidden) right pane from a prior Compare session, which would otherwise make `activePane`
    /// resolve to `.right` and silently aim Tidy's scans (Find Duplicates / Organize / Rename /
    /// Storage) at the wrong provider while the rail shows the left one. In compare mode the focused
    /// pane still wins, so a Tidy scan launched from a Compare menu targets the pane the user is in.
    static func tidyTargetsRightPane(isCompare: Bool, activePane: ActivePane?) -> Bool {
        isCompare && activePane == .right
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

    // The "Ignore in comparison" toggle semantics moved to
    // `FileSyncManager.toggleIgnored(focusRelativePaths:)`, which also reconciles the
    // durable ignore store; its behavior is pinned by Sync's PersistentIgnoresTests.

    // MARK: - Window bootstrap

    /// One step of ContentView's `onAppear` bootstrap. The app is single-window, but closing
    /// the window and reopening it from the Dock recreates the ContentView, so `onAppear` runs
    /// again mid-session. Each step is therefore classified once-per-session vs per-window;
    /// `bootstrapSteps(isFirstAppearance:)` is the single source of that classification (pinned
    /// by tests), and the view executes whatever list it returns so the two can't drift.
    enum BootstrapStep: Equatable {
        /// Session: seed `showHiddenFiles` from the General default. Re-running on a window
        /// reopen would discard a mid-session toggle.
        case resetShowHiddenFilesFromDefault
        /// Session: the `openSettingsOnLaunch` diagnostic is a launch hook; a window reopen
        /// must not re-open the Settings overlay.
        case honorOpenSettingsOnLaunch
        /// Window: `FileActionHandler` lives in view `@State`, so every fresh ContentView
        /// starts with nil and needs its own.
        case createActionHandler
        /// Window: each window brings a fresh `UndoManager`; the shared sync manager must
        /// register undos with the one actually on screen.
        case rewireUndoManager
        /// Session: seeds the manager from Settings once; the `onChange(of:)` observer keeps
        /// it current afterwards (both objects outlive the window).
        case syncProviderQuirkSettings
        /// Session: provider discovery, the distinct-pair pane selection, and the initial
        /// scan. Re-running would silently flip a deliberately-same right pane to a different
        /// provider and redo discovery + rescan over live state. Clears the view's
        /// provider-bootstrap guard when the discovery task finishes.
        case discoverProvidersAndApplyInitialSelection
        /// Window, re-appearance only: a recreated view's `isBootstrappingProviders` `@State`
        /// starts true, but no discovery is pending — clear it immediately, or provider
        /// switches and pane swaps stay refused for the rest of the session.
        case endProviderBootstrapGuard
    }

    /// The bootstrap steps to run for an appearance of ContentView, in execution order.
    static func bootstrapSteps(isFirstAppearance: Bool) -> [BootstrapStep] {
        if isFirstAppearance {
            return [
                .resetShowHiddenFilesFromDefault,
                .honorOpenSettingsOnLaunch,
                .createActionHandler,
                .rewireUndoManager,
                .syncProviderQuirkSettings,
                .discoverProvidersAndApplyInitialSelection,
            ]
        }
        return [
            .createActionHandler,
            .rewireUndoManager,
            .endProviderBootstrapGuard,
        ]
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

    /// The Info inspector's minimum width — matches `DetailsSidebar`'s own `minWidth: 200` content
    /// floor, below which the metadata rows stop reflowing cleanly.
    static let inspectorMinWidth: Double = 200
    /// The inspector's maximum width, so a drag can't let the panel swallow the whole window and
    /// starve the comparison panes. A fixed cap (rather than a window-relative one) keeps the math
    /// pure and geometry-free; the flexible panes absorb whatever is left.
    static let inspectorMaxWidth: Double = 600

    /// The inspector width during a resize drag. The handle sits on the panel's leading (left)
    /// edge, so dragging left (`translation` negative) widens it. `base` is the width at drag start
    /// — held constant for the whole gesture since it's only committed to storage on release — and
    /// `translation` is the gesture's cumulative horizontal translation. Clamped to
    /// `[inspectorMinWidth, inspectorMaxWidth]` so the same guard runs in tests, not only live.
    static func inspectorDragWidth(base: Double, translation: CGFloat) -> Double {
        min(max(base - Double(translation), inspectorMinWidth), inspectorMaxWidth)
    }

    /// Whether the kept LEFT copy of a duplicate review is still where — AND what — the scan
    /// saw it, mirroring the engine's `keeperStillExists` gate (FileSyncManager+Duplicates)
    /// that every other duplicate-removal path honors: existence, plus for FILES a byte-size
    /// comparison against the scan snapshot. An in-place edit or replacement changes the size,
    /// and the "redundant" right copy is then no longer provably identical to the keeper —
    /// trashing it could trash the last copy of the original content. Folders keep the
    /// existence-only check (a folder's stat size isn't its recursive content size).
    ///
    /// `statSucceeded: false` (the attributes read threw) refuses for a file, exactly like the
    /// engine's failed-attributes guard; `currentSize` nil with a successful stat (never happens
    /// on the real FS) falls back to the existence check rather than over-refuse — also like
    /// the engine.
    static func duplicateKeeperMatchesScan(
        exists: Bool,
        isDirectory: Bool,
        statSucceeded: Bool,
        currentSize: Int?,
        scannedSize: Int
    ) -> Bool {
        guard exists else { return false }
        guard !isDirectory else { return true }
        guard statSucceeded else { return false }
        if let currentSize, currentSize != scannedSize { return false }
        return true
    }
}
