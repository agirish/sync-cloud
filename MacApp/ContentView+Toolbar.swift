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

    /// The window toolbar: file actions in a leading group (right after the sidebar toggle),
    /// utility actions trailing. Lives in the native toolbar so it fills the titlebar band.
    @ToolbarContentBuilder
    var mainToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            // Resolve the active selection once; @Published changes refresh these.
            let selectionNodes = activeSelectionNodes
            let copyTarget = PaneLogic.copyTargetName(activePane: activePane, paneNames: paneNames)
            let actionSymbols = PaneLogic.actionBarSymbols(activePane: activePane)

            Button(action: {
                guard let node = selectionNodes.first, node.isDirectory else { return }
                let isLeft = (activePane == .left)
                actionHandler?.focusFolder(node, isLeft: isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId)
            }) {
                Label("Compare", systemImage: PaneGlyph.compare)
            }
            .labelStyle(.titleAndIcon)
            .disabled(selectionNodes.count != 1 || !selectionNodes[0].isDirectory)
            .help("Open the selected folder in both panes to compare them")

            Button(action: {
                guard !selectionNodes.isEmpty, let activePane else { return }
                let fromLeft = (activePane == .left)
                actionHandler?.copyItems(selectionNodes, fromLeft: fromLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId)
            }) {
                Label(copyTarget.map { "Copy to \($0)" } ?? "Copy", systemImage: actionSymbols.copy)
            }
            .labelStyle(.titleAndIcon)
            .disabled(selectionNodes.isEmpty)
            .help(copyTarget.map { "Copy the selected items to \($0)" } ?? "Copy the selected items to the other pane")

            Button(action: {
                guard !selectionNodes.isEmpty, let activePane else { return }
                let fromLeft = (activePane == .left)
                Task {
                    _ = await actionHandler?.moveItems(selectionNodes, fromLeft: fromLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId)
                }
            }) {
                Label(copyTarget.map { "Move to \($0)" } ?? "Move", systemImage: actionSymbols.move)
            }
            .labelStyle(.titleAndIcon)
            .disabled(selectionNodes.isEmpty)
            .help(copyTarget.map { "Move the selected items to \($0)" } ?? "Move the selected items to the other pane")

            Button(action: {
                guard let path = activePanePath else { return }
                actionHandler?.beginCreateFolder(in: path)
            }) {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .labelStyle(.titleAndIcon)
            .disabled(activePane == nil)
            .help("Create a new folder in the active pane")

            Button(role: .destructive, action: {
                guard !selectionNodes.isEmpty else { return }
                actionHandler?.confirmDelete(selectionNodes)
            }) {
                Label("Delete", systemImage: "trash")
            }
            .labelStyle(.titleAndIcon)
            .disabled(selectionNodes.isEmpty)
            .help("Delete the selected items")

            Menu {
                // A Picker inside a Menu gets the native menu check column; the previous
                // per-row `systemImage: isSelected ? "checkmark" : ""` faked it and logged
                // "No symbol named ''" for every unselected row on every open.
                Picker("Sort By", selection: $syncManager.sortOption) {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .labelStyle(.titleAndIcon)
            .help("Choose how items are sorted")
            // The hidden-files toggle now lives in each pane header, next to its nav buttons.
        }

        // Push the utility actions to the trailing edge of the titlebar. macOS 26's grouped
        // toolbar no longer trails `.primaryAction` on its own, so a flexible spacer separates
        // the file actions from the utility pill; earlier systems trail primaryAction natively.
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

            Button(action: { withAnimation { toggleTopPanesForCurrentTab() } }) {
                let topVisible = !topPanesHiddenForCurrentTab
                Label(TopPaneVisibility.title(topVisible: topVisible),
                      systemImage: TopPaneVisibility.symbol)
                    // Mirrors the bottom-pane toggle's tint-for-state so the two read as a pair:
                    // accent while the panes are up, dimmed when they're collapsed.
                    .foregroundStyle(topVisible
                        ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(.secondary))
            }
            // Only the single-provider workspaces (Tidy, Storage Lens) can hide the comparison
            // panes; on Differences/Details the panes are essential, so the toggle is inert.
            .disabled(!canHideTopPanesForCurrentTab)
            .help(canHideTopPanesForCurrentTab
                  ? TopPaneVisibility.helpText(topVisible: !topPanesHiddenForCurrentTab)
                  : TopPaneVisibility.disabledHelpText)
            .accessibilityLabel(TopPaneVisibility.title(topVisible: !topPanesHiddenForCurrentTab))

            Button(action: { withAnimation { showingBottomPane.toggle() } }) {
                Label(BottomPaneToggle.title(paneVisible: showingBottomPane),
                      systemImage: BottomPaneToggle.symbol)
                    // SF Symbols has no un-filled sibling of this glyph (see BottomPaneToggle),
                    // so state reads through tint: accent while the pane is up, dimmed when hidden.
                    .foregroundStyle(showingBottomPane
                        ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(.secondary))
            }
            // When the top panes are hidden the workspace is the only content; hiding the
            // bottom too would empty the window, so the toggle is disabled there.
            .disabled(topPanesHiddenForCurrentTab)
            .help(topPanesHiddenForCurrentTab
                  ? "Show the top panes first to hide the bottom pane"
                  : BottomPaneToggle.helpText(paneVisible: showingBottomPane))
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
