import SwiftUI
import AppKit
import Sync
import Dashboard
import FileExplorer

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
                Label("Compare", systemImage: "rectangle.split.2x1")
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

            Button(action: { withAnimation { showingBottomPane.toggle() } }) {
                Label("Toggle Bottom Pane", systemImage: "rectangle.bottomthird.inset.filled")
            }
            .help("Toggle the bottom pane")

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
