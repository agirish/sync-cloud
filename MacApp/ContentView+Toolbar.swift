import SwiftUI
import AppKit
import Sync
import Dashboard
import FileExplorer
import Design

/// State→presentation mapping for the bottom-pane toolbar toggle, kept out of the view
/// builder so tests can pin the strings and the symbol name.
///
/// SF Symbols ships no outline sibling of `rectangle.bottomthird.inset.filled`
/// (`rectangle.bottomthird.inset` does not resolve via NSImage(systemSymbolName:)),
/// so the button conveys state with tint instead of a filled/outline symbol swap.
enum BottomPaneToggle {
    static let symbol = "rectangle.bottomthird.inset.filled"

    static func title(paneVisible: Bool) -> String {
        paneVisible ? "Hide Bottom Pane" : "Show Bottom Pane"
    }

    static func helpText(paneVisible: Bool) -> String {
        paneVisible ? "Hide the bottom pane" : "Show the bottom pane"
    }
}

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

    /// The window toolbar — only window-level actions now: Find Duplicates, Scan, the pane
    /// visibility toggles, Logs, and Settings. The file actions moved onto the panes as a
    /// contextual action bar (`paneActionBar`), Sort moved into each pane header, and there's no
    /// sidebar toggle because there's no sidebar.
    @ToolbarContentBuilder
    var mainToolbar: some ToolbarContent {
        // A leading flexible spacer keeps the utility pill trailing now that no leading group
        // precedes it (macOS 26's grouped toolbar no longer trails `.primaryAction` on its own).
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: findDuplicatesAction) {
                // Keep the wand glyph and shimmer its stars while searching, rather than
                // swapping to a static hourglass that reads as "hung". `.variableColor`
                // sequences color across the wand's star layers for a distinct busy motion.
                Label("Find Duplicates", systemImage: "wand.and.stars")
                    .symbolEffect(.variableColor, options: .repeating, isActive: syncManager.isFindingDuplicates)
            }
            .disabled(syncManager.isFindingDuplicates)
            .help("Find duplicate folders & files in \(tidyProviderName)")

            Button(action: forceRefreshAction) {
                // Keep the refresh arrow and spin it while scanning — its own motion, and
                // visibly distinct from Find Duplicates' shimmer. `.rotate` honors
                // reduced-motion automatically.
                Label("Scan", systemImage: "arrow.clockwise")
                    .symbolEffect(.rotate, options: .repeating, isActive: isScanning)
            }
            .disabled(isScanning)
            .help("Scan for changes")

            Button(action: { withAnimation { togglePanesForCurrentTab() } }) {
                let panesVisible = !panesHiddenForCurrentTab
                Label(TopPaneVisibility.title(panesVisible: panesVisible, mode: layoutMode),
                      systemImage: TopPaneVisibility.symbol)
                    // Mirrors the bottom-pane toggle's tint-for-state so the two read as a pair:
                    // accent while the panes are up, dimmed when they're collapsed.
                    .foregroundStyle(panesVisible
                        ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(.secondary))
            }
            // Every tab's panes are freely hideable now (compare: both panes; single-source: the
            // rail) — the persistent tab strip keeps the window from ever emptying.
            .help(TopPaneVisibility.helpText(panesVisible: !panesHiddenForCurrentTab, mode: layoutMode))
            .accessibilityLabel(TopPaneVisibility.title(panesVisible: !panesHiddenForCurrentTab, mode: layoutMode))

            Button(action: { withAnimation { showingBottomPane.toggle() } }) {
                Label(BottomPaneToggle.title(paneVisible: showingBottomPane),
                      systemImage: BottomPaneToggle.symbol)
                    // SF Symbols has no un-filled sibling of this glyph (see BottomPaneToggle),
                    // so state reads through tint: accent while the pane is up, dimmed when hidden.
                    .foregroundStyle(showingBottomPane
                        ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(.secondary))
            }
            // On a single-source tab the workspace is the only region, so hiding it is meaningless —
            // the toggle is inert there. On comparison tabs it independently collapses the workspace.
            .disabled(!canHideWorkspaceForCurrentTab)
            .help(canHideWorkspaceForCurrentTab
                  ? BottomPaneToggle.helpText(paneVisible: showingBottomPane)
                  : "The workspace is the only pane on this tab")
            .accessibilityLabel(BottomPaneToggle.title(paneVisible: showingBottomPane))

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
