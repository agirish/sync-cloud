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

    var activeSelectionNodes: [FileNode] {
        switch activePane {
        case .left?:
            return syncManager.leftTree.findNodes(at: syncManager.selectedLeftPaths)
        case .right?:
            return syncManager.rightTree.findNodes(at: syncManager.selectedRightPaths)
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

    /// Whether the selection-driven action bar shows on this pane: it's the active (selected) pane
    /// and there's at least one selected item. Only the comparison panes have an "other pane" to
    /// copy/move to, so it never shows on the single-source Tidy rail.
    func paneActionBarVisible(isLeft: Bool) -> Bool {
        guard layoutMode == .compare else { return false }
        let side: PaneLogic.ActivePane = isLeft ? .left : .right
        return activePane == side && !activeSelectionNodes.isEmpty
    }

    /// The selection-driven file-action bar, docked at the bottom of the active pane. These are the
    /// actions that used to sit in the titlebar (Compare / Copy / Move / New Folder / Delete), now
    /// scoped to — and naming — the pane whose selection they act on.
    @ViewBuilder
    func paneActionBar(isLeft: Bool) -> some View {
        let selectionNodes = activeSelectionNodes
        let copyTarget = PaneLogic.copyTargetName(activePane: activePane, paneNames: paneNames)
        let actionSymbols = PaneLogic.actionBarSymbols(activePane: activePane)
        HStack(spacing: 8) {
            Text("\(selectionNodes.count) selected")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()

            if selectionNodes.count == 1, selectionNodes[0].isDirectory {
                actionBarButton("Compare", systemImage: PaneGlyph.compare) {
                    actionHandler?.focusFolder(selectionNodes[0], isLeft: isLeft,
                                               leftProviderId: leftProviderId, rightProviderId: rightProviderId)
                }
            }
            actionBarButton(copyTarget.map { "Copy to \($0)" } ?? "Copy", systemImage: actionSymbols.copy) {
                actionHandler?.copyItems(selectionNodes, fromLeft: isLeft,
                                         leftProviderId: leftProviderId, rightProviderId: rightProviderId)
            }
            actionBarButton(copyTarget.map { "Move to \($0)" } ?? "Move", systemImage: actionSymbols.move) {
                Task {
                    _ = await actionHandler?.moveItems(selectionNodes, fromLeft: isLeft,
                                                       leftProviderId: leftProviderId, rightProviderId: rightProviderId)
                }
            }
            actionBarButton("New Folder", systemImage: "folder.badge.plus") {
                if let path = activePanePath { actionHandler?.beginCreateFolder(in: path) }
            }
            Spacer(minLength: 4)
            actionBarButton("Delete", systemImage: "trash", role: .destructive) {
                actionHandler?.confirmDelete(selectionNodes)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func actionBarButton(_ title: String, systemImage: String, role: ButtonRole? = nil,
                                 action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    /// The window toolbar — pared down to the two window-level utilities: Logs and Settings.
    /// Everything else moved to where it acts: Scan is in each pane header (next to its nav
    /// controls), Find Duplicates lives in the Tidy ▸ Duplicates lens, the file actions are the
    /// panes' contextual action bar, and the pane toggles are gone — the Tidy rail collapses via its
    /// own header control, and the comparison panes resize with the draggable divider.
    @ToolbarContentBuilder
    var mainToolbar: some ToolbarContent {
        // A leading flexible spacer keeps the utility pill trailing (macOS 26's grouped toolbar no
        // longer trails `.primaryAction` on its own).
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }

        ToolbarItemGroup(placement: .primaryAction) {
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
