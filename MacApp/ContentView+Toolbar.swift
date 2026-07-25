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

    var activePanePath: String? {
        switch activePane {
        case .left?: return currentLeftPath
        case .right?: return currentRightPath
        case nil: return nil
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
                actionBarButton("Compare", systemImage: PaneGlyph.compare, accent: accent, isPrimary: true) {
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
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            .buttonStyle(.plain)
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

    /// One button in the pane action bar: solid accent chrome with an on-fill label — the same look
    /// as the differences header's prominent Copy buttons — on the bar's subtle glass. Delete goes
    /// red. The label color is paired to the fill here (not hardcoded white inside the button): the
    /// hue's own luminance decides it, so Amber and Cyan get dark text instead of an unreadable
    /// ~2.2:1 white.
    @ViewBuilder
    private func actionBarButton(_ title: String, systemImage: String, accent: Color,
                                 isPrimary: Bool = false, role: ButtonRole? = nil,
                                 action: @escaping () -> Void) -> some View {
        let isDestructive = role == .destructive
        PaneActionButton(title: title, systemImage: systemImage,
                         tint: isDestructive ? .red : accent,
                         onTint: isDestructive ? .onFillLabel(.red) : glassHue.onAccentLabelColor,
                         isPrimary: isPrimary, role: role, action: action)
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
        let accentFill = glassHue.accentColor
        // Paired to the fill's luminance, never a flat `.white`: this pill fills with the RAW
        // accent, so on Amber/Cyan/Green white text lands at ~2.1–2.7:1 — under WCAG's 3:1 floor.
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
                .buttonStyle(.plain)
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

/// A single pill in the pane action bar: a solid accent (or red, for Delete) capsule with an
/// on-fill label — the differences header's prominent-button look. Split out of the `ContentView`
/// extension because it needs its own `@State` for the hover brightening.
private struct PaneActionButton: View {
    let title: String
    let systemImage: String
    /// The pill's fill (app hue, or red for the destructive Delete).
    let tint: Color
    /// The label color paired to `tint` by the caller (via `LiquidGlassHue.onAccentLabelColor`).
    /// Passed in rather than assumed white: the light hues need dark text to stay legible, and this
    /// view can't see the hue to work that out for itself.
    let onTint: Color
    /// The headline action (Compare): a white hairline so it reads first among equals.
    var isPrimary: Bool = false
    var role: ButtonRole? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(onTint)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(tint.opacity(isHovering ? 1.0 : 0.9)))
            // The primary hairline is the label color too, not a flat white — on a light hue a
            // white ring on a near-white fill is invisible, which is the same bug as the label.
            .overlay(Capsule().strokeBorder(onTint.opacity(isPrimary ? 0.45 : 0), lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
