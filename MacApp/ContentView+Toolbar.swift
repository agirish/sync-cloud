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
        // The bar is a near-solid accent glass tile now, so all its content is the on-accent label
        // color (white for most hues) — like the prominent bulk-copy buttons.
        let onAccent = Color.onFillLabel(accent)
        return HStack(spacing: 6) {
            // Selection summary, tinted with the app accent — the "what's selected" half of the bar,
            // fenced off from the "what you can do" half by a hairline divider. A ✕ dismisses the
            // selection (the file lists offer no deselect gesture; Escape does the same).
            Button {
                clearSelection(isLeft: isLeft)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(onAccent.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("Clear selection (Esc)")
            .accessibilityLabel("Clear selection")

            Label(SelectionSummary.text(for: selectionNodes), systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(onAccent)
                .fixedSize()
                .padding(.trailing, 4)

            if selectionNodes.count == 1, selectionNodes[0].isDirectory {
                actionBarButton("Compare", systemImage: PaneGlyph.compare, accent: onAccent, isPrimary: true) {
                    actionHandler?.focusFolder(selectionNodes[0], isLeft: isLeft,
                                               leftProviderId: leftProviderId, rightProviderId: rightProviderId)
                }
            }
            actionBarButton(copyTarget.map { "Copy to \($0)" } ?? "Copy", systemImage: actionSymbols.copy, accent: onAccent) {
                actionHandler?.copyItems(selectionNodes, fromLeft: isLeft,
                                         leftProviderId: leftProviderId, rightProviderId: rightProviderId)
            }
            actionBarButton(copyTarget.map { "Move to \($0)" } ?? "Move", systemImage: actionSymbols.move, accent: onAccent) {
                Task {
                    _ = await actionHandler?.moveItems(selectionNodes, fromLeft: isLeft,
                                                       leftProviderId: leftProviderId, rightProviderId: rightProviderId)
                }
            }
            // New Folder is intentionally omitted here to keep the bar compact — it stays on the
            // pane's right-click menu (SharedFileMenuItems.newFolder) for now.
            Spacer(minLength: 6)
            actionBarButton("Delete", systemImage: "trash", accent: onAccent) {
                actionHandler?.confirmDelete(selectionNodes)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // A near-solid accent glass tile (like the prominent bulk-copy buttons), so its white
        // content reads cleanly — not a faint tint that would swallow white text.
        .accentGlassCapsule(accent, strength: 0.9)
        .overlay(Capsule().strokeBorder(onAccent.opacity(0.25), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 2)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// One pill in the pane action bar. The icon carries the app accent hue (destructive stays red);
    /// `isPrimary` fills the pill with a soft accent wash so the headline action (Compare) reads
    /// first. Bigger tap target and a hover fill replace the old bare `.borderless` gray labels.
    @ViewBuilder
    private func actionBarButton(_ title: String, systemImage: String, accent: Color,
                                 isPrimary: Bool = false, role: ButtonRole? = nil,
                                 action: @escaping () -> Void) -> some View {
        // `accent` is the on-accent content color (white) — the bar itself is the accent surface, so
        // buttons draw their icon/label in white and wash white on hover, not their own hue.
        PaneActionButton(title: title, systemImage: systemImage, tint: accent,
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
        return HStack(spacing: 4) {
            ForEach(BottomTab.allCases, id: \.self) { tab in
                let isSelected = selection.wrappedValue == tab
                Button {
                    selection.wrappedValue = tab
                } label: {
                    Text(tab.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? AnyShapeStyle(glassHue.accentColor) : AnyShapeStyle(Color.secondary))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(
                            isSelected ? AnyShapeStyle(glassHue.accentColor.opacity(0.16)) : AnyShapeStyle(Color.clear),
                            in: Capsule()
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
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

/// A single pill in the pane action bar. Split out of the `ContentView` extension because it needs
/// its own `@State` for the hover fill — the accent-tinted icon, primary wash, and hover feedback
/// are what replace the old flat gray `.borderless` labels.
private struct PaneActionButton: View {
    let title: String
    let systemImage: String
    /// The pill's accent (app hue, or red for the destructive Delete). Colors the icon, the
    /// primary wash, and the hover fill.
    let tint: Color
    /// The headline action (Compare): a persistent soft wash + hairline so it reads first.
    var isPrimary: Bool = false
    var role: ButtonRole? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint)
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(fillOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tint.opacity(isPrimary ? 0.40 : 0), lineWidth: 0.75)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    /// Persistent wash for the primary action; a lighter wash appears on hover for the rest.
    private var fillOpacity: Double {
        if isPrimary { return isHovering ? 0.22 : 0.14 }
        return isHovering ? 0.14 : 0
    }
}
