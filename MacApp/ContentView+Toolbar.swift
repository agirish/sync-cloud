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
    /// actions that used to sit in the titlebar (Compare / Copy / Move / New Folder / Delete), now
    /// scoped to — and naming — the pane whose selection they act on. `selectionNodes` is resolved
    /// by the caller (once) rather than re-read here, so the tree isn't walked twice per render.
    @ViewBuilder
    func paneActionBar(isLeft: Bool, selectionNodes: [FileNode]) -> some View {
        let copyTarget = PaneLogic.copyTargetName(activePane: activePane, paneNames: paneNames)
        let actionSymbols = PaneLogic.actionBarSymbols(activePane: activePane)
        let accent = glassHue.accentColor
        return HStack(spacing: 8) {
            // Selection summary — the "what's selected" half of the bar, in the accent on the
            // subtle bar. Its ✕ (clear selection) lives at the far trailing edge, past Delete:
            // right next to the ✓ summary the two circular glyphs read as one confusing pair.
            Label(SelectionSummary.text(for: selectionNodes), systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
                .fixedSize()
                .padding(.trailing, 4)

            if selectionNodes.count == 1, selectionNodes[0].isDirectory {
                actionBarButton("Compare", systemImage: PaneGlyph.compare, accent: accent) {
                    actionHandler?.focusFolder(selectionNodes[0], isLeft: isLeft,
                                               leftProviderId: leftProviderId, rightProviderId: rightProviderId)
                }
            }
            actionBarButton(copyTarget.map { "Copy to \($0)" } ?? "Copy", systemImage: actionSymbols.copy, accent: accent) {
                actionHandler?.copyItems(selectionNodes, fromLeft: isLeft,
                                         leftProviderId: leftProviderId, rightProviderId: rightProviderId)
            }
            actionBarButton(copyTarget.map { "Move to \($0)" } ?? "Move", systemImage: actionSymbols.move, accent: accent) {
                Task {
                    _ = await actionHandler?.moveItems(selectionNodes, fromLeft: isLeft,
                                                       leftProviderId: leftProviderId, rightProviderId: rightProviderId)
                }
            }
            // New Folder is intentionally omitted here to keep the bar compact — it stays on the
            // pane's right-click menu (SharedFileMenuItems.newFolder) for now.
            Spacer(minLength: 6)
            actionBarButton("Delete", systemImage: "trash", accent: accent, role: .destructive) {
                actionHandler?.confirmDelete(selectionNodes)
            }

            // ✕ dismisses the selection (the file lists offer no deselect gesture; Escape does the
            // same). At the trailing edge, separated from the actions, so it reads as "close this
            // bar" rather than pairing visually with the ✓ in the summary.
            Button {
                clearSelection(isLeft: isLeft)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .hoverInk()
                    .padding(.leading, 4)
            }
            .buttonStyle(.hoverAffordance(.inline))
            .help("Clear selection (Esc)")
            .accessibilityLabel("Clear selection")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // A subtle, transparent-ish accent-tinted glass — not a gray material and not a solid slab.
        // The buttons carry the accent chrome (below); the bar itself just whispers the hue.
        .accentGlassCapsule(accent, strength: 0.12)
        .overlay(Capsule().strokeBorder(accent.opacity(0.35), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// One button in the pane action bar — the same `ActionBarButtonStyle` the differences header
    /// uses, at `.primary`. It used to be a private lookalike (`PaneActionButton`) with its own
    /// capsule, metrics and fill, which is how the two drifted: `ActionBarWeight.primary` fills at
    /// opacity 1, the lookalike filled at 0.9 while resting, and `AccentFill` leaves NO headroom for
    /// that — the deepened colour sits exactly on the 4.55:1 ceiling, so any alpha below 1 composites
    /// the surface behind it back in and puts the white label under the floor. One implementation
    /// now, so the fill rule can only be stated once.
    ///
    /// `isPrimary` is gone with it: `.primary` carries no resting hairline (a stroke on a
    /// full-strength fill only muddies its edge), and Compare's leading position already reads as
    /// the headline.
    ///
    /// The destructive red needs no deepening — it already carries white — but goes through the same
    /// call so there is one rule here instead of a special case.
    private func actionBarButton(_ title: String, systemImage: String, accent: Color,
                                 role: ButtonRole? = nil,
                                 action: @escaping () -> Void) -> some View {
        let isDestructive = role == .destructive
        return Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.actionBar(.primary,
                                tint: AccentFill.deepened(isDestructive ? .red : accent),
                                onTint: isDestructive ? .onFillLabel(.red) : glassHue.onAccentLabelColor))
    }

    /// The primary tabs — a boxed segmented control. It rides the toolbar's leading region, which
    /// `.hiddenTitleBar` leaves empty save for the traffic lights, so the tabs cost no content
    /// height at all. Narrow enough (~120pt) that it and the trailing utility pill clear the
    /// window's 600pt `minWidth` together; the Tidy lens tabs deliberately stay out of here, since
    /// adding their ~300pt would overflow that minimum and macOS would silently collapse them
    /// behind an overflow chevron.
    var primaryTabPicker: some View {
        // A custom two-button segmented control rather than `Picker(.segmented)`: the native control
        // renders neutral inside a macOS 26 glass toolbar group and ignores `.tint`, so the selected
        // tab could never carry the app accent. These plain buttons draw their own accent fill, which
        // the glass group leaves alone. The binding's setter still runs (it opens the Tidy rail).
        let selection = primaryTabSelection
        // The DEEPENED accent, which is what makes the white label below legible: filled with the
        // raw accent this pill stranded white text at ~2.1–2.7:1 on Amber/Cyan/Green.
        let accentFill = glassHue.accentFillColor
        let onAccent = glassHue.onAccentLabelColor
        return HStack(spacing: 4) {
            ForEach(BottomTab.allCases, id: \.self) { tab in
                let isSelected = selection.wrappedValue == tab
                Button {
                    selection.wrappedValue = tab
                } label: {
                    Text(tab.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? AnyShapeStyle(onAccent) : AnyShapeStyle(Color.secondary))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(
                            isSelected ? AnyShapeStyle(accentFill) : AnyShapeStyle(Color.clear),
                            in: Capsule()
                        )
                        .contentShape(Capsule())
                }
                // The selected segment already carries the accent fill, so it takes the ring;
                // the unselected one washes the capsule it would fill if you clicked it.
                .buttonStyle(.hoverAffordance(isSelected ? .filled : .segment, tint: accentFill))
                // These two Buttons stand in for a `Picker(.segmented)` (which renders neutral in a
                // macOS 26 glass toolbar group), so they have to restate the selected-state semantics
                // the Picker gave VoiceOver for free. No `.help`: it would only echo the visible label.
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace")
        // Inset the segments inside an outer container capsule so the selected pill floats within it
        // with a gap on every side, instead of filling the control edge-to-edge.
        .padding(3)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
        .fixedSize()
    }

    /// The window toolbar — the window-level controls, and only those: which workspace you're in
    /// (Compare | Tidy), and the three utilities (Info, Logs, Settings). Everything else lives where
    /// it acts: Scan is in each pane header, Find Duplicates in the Tidy ▸ Duplicates lens, the file
    /// actions are the panes' contextual action bar, and the Tidy lens tabs head the Tidy workspace.
    @ToolbarContentBuilder
    var mainToolbar: some ToolbarContent {
        // `.navigation` puts the tabs immediately after the traffic lights. There's no window title
        // competing for the space — the window is `.hiddenTitleBar`.
        ToolbarItem(placement: .navigation) {
            primaryTabPicker
        }

        // A leading flexible spacer keeps the utility pill trailing (macOS 26's grouped toolbar no
        // longer trails `.primaryAction` on its own).
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            // Info inspector toggle — available on every tab (Compare shows both-sides status; Tidy
            // shows the single source), so opening Info never yanks the Tidy rail over to Compare.
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
            }
            .help("Settings")
        }
    }
}
