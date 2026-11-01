import FileExplorer
import SwiftUI
import Sync

/// Filter by Type (RD70): the host's half — what each pane's Filter button, rows, empty state and
/// status bar are handed. The filter itself is `FileSyncManager.leftTypeFilter`/`rightTypeFilter`,
/// applied inside the manager's filter pass, so everything that reads a pane's tree already agrees
/// with what the pane shows.
extension ContentView {

    /// The pane's filter as a binding, for the type list, the menus and the status chip.
    func typeFilterBinding(isLeft: Bool) -> Binding<PaneTypeFilter?> {
        isLeft ? $syncManager.leftTypeFilter : $syncManager.rightTypeFilter
    }

    /// The counts the type list is built from: the pass's facts while a filter is on, otherwise the
    /// host's own count of the published tree (`typeFilterCensusTask`).
    func typeFilterFacts(isLeft: Bool) -> PaneTypeFilterFacts? {
        let filterOn = (isLeft ? syncManager.leftTypeFilter : syncManager.rightTypeFilter) != nil
        if filterOn { return isLeft ? syncManager.leftTypeFilterFacts : syncManager.rightTypeFilterFacts }
        return isLeft ? leftTypeCensus : rightTypeCensus
    }

    /// What the type list and the empty state call the pane's folder: its own name, or the source's
    /// name at the source's root, where the last path component is a container name.
    func typeFilterFolderName(isLeft: Bool) -> String {
        let relative = isLeft ? syncManager.leftRelativePath : syncManager.rightRelativePath
        if relative.isEmpty {
            let id = isLeft ? leftProviderId : rightProviderId
            if let name = settings.availableProviders.first(where: { $0.id == id })?.displayName { return name }
        }
        return ((isLeft ? currentLeftPath : currentRightPath) as NSString).lastPathComponent
    }

    /// Everything the header's Filter button needs.
    func typeFilterControl(isLeft: Bool) -> PaneTypeFilterControl {
        PaneTypeFilterControl(
            filter: typeFilterBinding(isLeft: isLeft),
            facts: typeFilterFacts(isLeft: isLeft),
            folderName: typeFilterFolderName(isLeft: isLeft),
            isListing: isLeft ? syncManager.isLoadingLeftTree : syncManager.isLoadingRightTree,
            // Compare only: each pane keeps its own filter, and this copies one across (FI).
            onUseOnBothPanes: layoutMode != .compare ? nil : {
                let value = isLeft ? syncManager.leftTypeFilter : syncManager.rightTypeFilter
                if isLeft { syncManager.rightTypeFilter = value } else { syncManager.leftTypeFilter = value }
            })
    }

    /// The rows' folder counts, or nil with no filter.
    func typeFilterDecor(isLeft: Bool) -> PaneTypeFilterDecor? {
        guard let filter = isLeft ? syncManager.leftTypeFilter : syncManager.rightTypeFilter,
              let facts = isLeft ? syncManager.leftTypeFilterFacts : syncManager.rightTypeFilterFacts
        else { return nil }
        return PaneTypeFilterDecor(stamp: (isLeft ? syncManager.leftPaneTree : syncManager.rightPaneTree).version,
                                   filter: filter, matchCounts: facts.matchCounts)
    }

    /// The filter that left this pane showing nothing, for its empty state (TE274).
    func typeFilterEmptied(isLeft: Bool) -> PaneTypeFilter? {
        guard isLeft ? syncManager.leftTreeIsEmptiedByTypeFilter : syncManager.rightTreeIsEmptiedByTypeFilter
        else { return nil }
        return isLeft ? syncManager.leftTypeFilter : syncManager.rightTypeFilter
    }

    /// Browse's status bar: "28 of 52 items" and its chip (TE271).
    func typeFilterStatus(isLeft: Bool) -> PaneStatusFacts.TypeFilter? {
        guard let filter = isLeft ? syncManager.leftTypeFilter : syncManager.rightTypeFilter,
              let facts = isLeft ? syncManager.leftTypeFilterFacts : syncManager.rightTypeFilterFacts
        else { return nil }
        return PaneStatusFacts.TypeFilter(totalCount: facts.itemCountBeforeFilter, summary: filter.summary)
    }

    /// The folders open in a pane, for its type filter to keep in place while they are open (his
    /// call GQ): the column stack in Columns, the expanded folders in Tree. Empty with no filter, so
    /// an unfiltered pane's expanding and drilling never reach the manager.
    func typeFilterOpenFolders(_ pane: PaneContext) -> Set<String> {
        guard (pane.isLeft ? syncManager.leftTypeFilter : syncManager.rightTypeFilter) != nil else { return [] }
        if pane.viewMode == .columns {
            let path = pane.isLeft ? syncManager.leftBrowsePath : syncManager.rightBrowsePath
            return Set(path.columnDirectories(treeRoot: pane.currentPath).dropFirst())
        }
        return pane.isLeft ? leftTreeExpanded : rightTreeExpanded
    }

    /// Counts the published tree's file types while the pane has no filter, so the type list opens
    /// on real numbers. Once per publish, off the main actor; with a filter on, the manager's pass
    /// counts instead and this stands down.
    func typeFilterCensusTask(isLeft: Bool) async {
        let filterOn = (isLeft ? syncManager.leftTypeFilter : syncManager.rightTypeFilter) != nil
        guard !filterOn else { return }
        let nodes = isLeft ? syncManager.leftTree : syncManager.rightTree
        let facts = await Task.detached(priority: .utility) { PaneTypeFilterPass.census(of: nodes) }.value
        guard !Task.isCancelled else { return }
        if isLeft { leftTypeCensus = facts } else { rightTypeCensus = facts }
    }
}

/// What the census task re-runs on: a new publish of the pane's tree, or the filter turning off.
struct TypeFilterCensusKey: Equatable {
    var version: Int
    var filterOn: Bool
}
