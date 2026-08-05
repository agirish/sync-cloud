import SwiftUI
import AppKit
import Sync
import Dashboard
import FileExplorer
import Design

/// The window toolbar, extracted from ContentView.swift for size. An extension (not a
/// separate View) because the toolbar reads ContentView's selection/provider state and
/// action handler directly; the members it touches are internal rather than private so
/// this file can live outside ContentView.swift.
extension ContentView {

    var activePane: PaneLogic.ActivePane? {
        PaneLogic.activePane(
            leftSelection: syncManager.selectedLeftPaths,
            rightSelection: syncManager.selectedRightPaths
        )
    }

    /// The selected nodes in whichever pane is active. Resolves paths via the sync manager's cached
    /// path→node index (O(selection)), so — unlike the old per-render tree walk — it's cheap to read
    /// and no longer gates the action bar's appearance on a ~40k-node traversal.
    var activeSelectionNodes: [FileNode] {
        switch activePane {
        case .left?:
            return syncManager.leftNodes(for: syncManager.selectedLeftPaths)
        case .right?:
            return syncManager.rightNodes(for: syncManager.selectedRightPaths)
        case nil:
            return []
        }
    }

    // MARK: - Contextual pane action bar

    /// Whether the selection-driven action bar could show on this pane: this is the compare layout
    /// and this is the active (selected) side. This is only a coarse gate — the caller still
    /// requires a non-empty *resolved* selection (`barSelectionNodes`) before showing the bar, so a
    /// stale selected path that no longer resolves to a node keeps the bar hidden (matching the old
    /// `!activeSelectionNodes.isEmpty` check). Keeping the node walk out of here means the bar's
    /// visibility and its "N selected" count come from a single resolve, not two. Only the
    /// comparison panes have an "other pane" to copy/move to, so it never shows on the Tidy rail.
    func paneActionBarSideActive(isLeft: Bool) -> Bool {
        guard layoutMode == .compare else { return false }
        let side: PaneLogic.ActivePane = isLeft ? .left : .right
        return activePane == side
    }

    /// The nodes the action bar acts on: resolved once here (a tree walk) so `paneColumn` can pass
    /// the same array to both the bar's visibility gate and its contents. Empty when this side
    /// isn't the active pane, so the inactive column never walks its tree.
    func barSelectionNodes(isLeft: Bool) -> [FileNode] {
        paneActionBarSideActive(isLeft: isLeft) ? activeSelectionNodes : []
    }

    /// The selection-driven file-action bar, docked at the bottom of the active pane. These are the
    /// actions that used to sit in the titlebar (Compare / Copy / Move / Delete), now scoped to —
    /// and naming — the pane whose selection they act on. `selectionNodes` is resolved by the caller
    /// (once) rather than re-read here, so the tree isn't walked twice per render.
    ///
    /// The bar itself lives in `FileExplorer` so its layout can be rendered and asserted; this
    /// supplies the strings and the handlers, which are the only parts that need the app's state.
    @ViewBuilder
    func paneActionBar(isLeft: Bool, selectionNodes: [FileNode]) -> some View {
        let copyTarget = PaneLogic.copyTargetName(activePane: activePane, paneNames: paneNames)
        let actionSymbols = PaneLogic.actionBarSymbols(activePane: activePane)
        PaneActionBar(
            summaryText: SelectionSummary.text(for: selectionNodes),
            showsCompare: selectionNodes.count == 1 && selectionNodes[0].isDirectory,
            copyTitle: copyTarget.map { "Copy to \($0)" } ?? "Copy",
            moveTitle: copyTarget.map { "Move to \($0)" } ?? "Move",
            copySymbol: actionSymbols.copy,
            moveSymbol: actionSymbols.move,
            // The titles name a side, which is true of every folder over there. The rule that
            // decides WHICH folder — each item's own path, re-rooted — appears nowhere else in
            // the window, and not knowing it is what makes a transfer into an already-matching
            // location look like a dead click.
            transferHelp: copyTarget.map {
                "Puts each item where its counterpart belongs in \($0), creating folders as needed"
            },
            onCompare: {
                guard let folder = selectionNodes.first else { return }
                actionHandler?.focusFolder(folder, isLeft: isLeft,
                                           leftProviderId: leftProviderId, rightProviderId: rightProviderId)
            },
            onCopy: {
                actionHandler?.copyItems(selectionNodes, fromLeft: isLeft,
                                         leftProviderId: leftProviderId, rightProviderId: rightProviderId)
            },
            onMove: {
                Task {
                    _ = await actionHandler?.moveItems(selectionNodes, fromLeft: isLeft,
                                                       leftProviderId: leftProviderId, rightProviderId: rightProviderId)
                }
            },
            onDelete: { actionHandler?.confirmDelete(selectionNodes) },
            onClear: { clearSelection(isLeft: isLeft) }
        )
    }

    /// The workspace bar — one flat row of every workspace, riding the toolbar's leading region,
    /// which `.hiddenTitleBar` leaves empty save for the traffic lights, so it costs no content
    /// height at all.
    ///
    /// This replaces the two-level `Compare | Tidy` picker plus the lens tabs that used to head
    /// the Tidy workspace. The old arrangement kept the lens tabs *out* of here deliberately —
    /// their ~300pt would have overflowed the window's 600pt `minWidth` and macOS would have
    /// folded them behind a chevron. Flattening does not repeal that constraint, it inherits it,
    /// which is what ``WorkspaceBarMetrics`` is for: below the width where six labels fit, every
    /// segment sheds its label at once and the glyphs carry the bar.
    var workspaceBar: some View {
        // Custom buttons rather than `Picker(.segmented)`: the native control renders neutral
        // inside a macOS 26 glass toolbar group and ignores `.tint`, so the selected segment could
        // never carry the app accent. These draw their own accent fill, which the group leaves
        // alone. The binding's setter still runs (it opens the source rail).
        let selection = workspaceSelection
        // The DEEPENED accent, which is what makes the white label legible: filled with the raw
        // accent this pill stranded white text at ~2.1–2.7:1 on Amber/Cyan/Green.
        let accentFill = glassHue.accentFillColor
        let onAccent = glassHue.onAccentLabelColor
        let style = workspaceBarStyle
        return HStack(spacing: WorkspaceBarMetrics.segmentGap) {
            ForEach(Array(Workspace.allCases.enumerated()), id: \.element) { index, workspace in
                // Compare is the only workspace with two panes; the rest put a lens where its
                // second provider goes. The rule says so — it is the one real grouping in the bar.
                if index == 1 {
                    Divider().frame(height: 14).padding(.horizontal, 4)
                }
                workspaceSegment(workspace, selection: selection, style: style,
                                 accentFill: accentFill, onAccent: onAccent)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace")
        // Inset the segments inside an outer container capsule so the selected pill floats within
        // it with a gap on every side, instead of filling the control edge-to-edge.
        .padding(3)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
        .fixedSize()
    }

    @ViewBuilder
    private func workspaceSegment(
        _ workspace: Workspace,
        selection: Binding<Workspace>,
        style: WorkspaceBarStyle,
        accentFill: Color,
        onAccent: Color
    ) -> some View {
        let isSelected = selection.wrappedValue == workspace
        Button {
            selection.wrappedValue = workspace
        } label: {
            HStack(spacing: 6) {
                Image(systemName: workspace.symbol)
                    .font(.system(size: 12, weight: .medium))
                if style == .full {
                    Text(workspace.title)
                        .scaledFont(.system(size: 12, weight: isSelected ? .semibold : .medium))
                }
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(onAccent) : AnyShapeStyle(Color.secondary))
            .padding(.horizontal, style == .full ? 12 : 10)
            .padding(.vertical, 4)
            .background(
                isSelected ? AnyShapeStyle(accentFill) : AnyShapeStyle(Color.clear),
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        // The selected segment already carries the accent fill, so it takes the ring; the
        // unselected ones wash the capsule they would fill if you clicked them.
        .buttonStyle(.hoverAffordance(isSelected ? .filled : .segment, tint: accentFill))
        // Once the label is shed the glyph is the only thing naming this workspace, so the name
        // has to survive somewhere reachable — the tooltip for a mouse, the a11y label otherwise.
        .help(workspace.title)
        .accessibilityLabel(workspace.title)
        // These Buttons stand in for a `Picker(.segmented)` (which renders neutral in a macOS 26
        // glass toolbar group), so they restate the selected-state semantics the Picker gave
        // VoiceOver for free.
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Each segment's rendered label width, at the app's current text scale.
    ///
    /// Measured, not tabulated: a constant would be right at exactly one Settings ▸ Text size and
    /// would silently overflow at the larger ones — and overflow here does not truncate, it hides
    /// the whole control behind macOS's overflow chevron. Semibold because that is the selected
    /// segment's weight, and the widest; sizing on `.medium` would under-measure the one segment
    /// that is always bold.
    static func workspaceLabelWidths(scale: CGFloat) -> [CGFloat] {
        let font = NSFont.systemFont(ofSize: 12 * scale, weight: .semibold)
        return Workspace.allCases.map {
            ($0.title as NSString).size(withAttributes: [.font: font]).width
        }
    }

    /// The window toolbar — the window-level controls, and only those: which workspace you're in,
    /// and the three utilities (Info, Logs, Settings). Everything else lives where it acts: Scan is
    /// in each pane header, Find Duplicates in the Duplicates workspace, and the file actions are
    /// the panes' contextual action bar.
    @ToolbarContentBuilder
    var mainToolbar: some ToolbarContent {
        // `.navigation` puts the bar immediately after the traffic lights. There's no window title
        // competing for the space — the window is `.hiddenTitleBar`.
        ToolbarItem(placement: .navigation) {
            workspaceBar
        }

        // A leading flexible spacer keeps the utility pill trailing (macOS 26's grouped toolbar no
        // longer trails `.primaryAction` on its own).
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            // Info inspector toggle — available on every workspace (Compare shows both-sides
            // status; a lens shows the single source), so opening Info never yanks the rail over
            // to Compare.
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showInspector.toggle() }
            } label: {
                Label("Info", systemImage: "sidebar.right")
                    // Accent-tinted when the inspector is open, so the toggle reads as a state and
                    // not just an action. Closed, it renders as a normal enabled toolbar button.
                    .foregroundStyle(showInspector ? AnyShapeStyle(glassHue.accentColor) : AnyShapeStyle(.primary))
            }
            .help(showInspector ? "Hide the Info inspector" : "Show details for the selected item")
            .accessibilityLabel(showInspector ? "Hide inspector" : "Show inspector")

            Button(action: { openWindow(id: "activity-log") }) {
                Label("Logs", systemImage: "list.bullet.rectangle")
            }
            .help("Activity log")

            Button(action: { showSettings = true }) {
                Label("Settings", systemImage: "gear")
                    // On the LABEL, not the Button: a toolbar item's own bounds are AppKit's, and
                    // an overlay hung outside the SwiftUI content is the one that gets clipped.
                    // Centred for the same reason as the pane magnifier — the keycap is wider
                    // than the gear.
                    .shortcutKeycap("⌘,")
            }
            .help(ShortcutHint.tooltip("Settings", "⌘,"))
        }
    }
}
