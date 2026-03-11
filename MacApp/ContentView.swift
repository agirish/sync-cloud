import SwiftUI
import Sync
import Events
import Settings
import FileExplorer
import Dashboard
import QuickLook

/// The main application layout for SyncCloud.
/// Implements a stable 2-column `NavigationSplitView` with:
/// - Sidebar: Cloud provider selection.
/// - Detail: Two-pane file explorer with an integrated bottom tabbed workspace for differences and metadata.
struct ContentView: View {
    @ObservedObject var syncManager: FileSyncManager
    @StateObject private var settings = SettingsManager()
    
    @State private var sourceProviderId: String = "iCloud"
    @State private var destinationProviderId: String = "iCloud"
    @State private var isScanning = false
    
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    
    @State private var showingSettings = false
    @State private var actionHandler: FileActionHandler?
    @State private var quickLookURL: URL? = nil
    @State private var showingBottomPane: Bool = true
    @State private var isBootstrappingProviders: Bool = true
    
    /// Represents the available tabs in the integrated bottom workspace.
    enum BottomTab: String, CaseIterable {
        /// Displays differential scanning results and sync actions.
        case differences = "Differences"
        /// Displays rich file metadata (size, dates, permissions).
        case details = "Details"
    }
    @State private var selectedBottomTab: BottomTab = .differences

    static func resolvedProviderSelection(
        providers: [CloudProvider],
        currentSourceId: String,
        currentDestinationId: String,
        preferDistinctPair: Bool
    ) -> (sourceId: String, destinationId: String)? {
        guard let first = providers.first?.id else { return nil }

        var sourceId = currentSourceId
        if !providers.contains(where: { $0.id == sourceId }) {
            sourceId = first
        }

        let fallbackDestination = providers.first(where: { $0.id != sourceId })?.id ?? sourceId
        var destinationId = currentDestinationId
        let destinationExists = providers.contains(where: { $0.id == destinationId })
        if !destinationExists || (preferDistinctPair && destinationId == sourceId) {
            destinationId = fallbackDestination
        }

        return (sourceId, destinationId)
    }

    var body: some View {
        NavigationSplitView {
            ProviderSidebar(
                settings: settings,
                sourceProviderId: $sourceProviderId,
                destinationProviderId: $destinationProviderId
            )
        } detail: {
            mainContentView
                .frame(minWidth: 600)
                .toolbar {
                    ToolbarItemGroup(placement: .principal) {
                        ControlGroup {
                            Button(action: forceRefreshAction) {
                                Label("Scan", systemImage: isScanning ? "hourglass" : "arrow.clockwise")
                            }
                            .disabled(isScanning)
                            
                            Button(action: {
                                withAnimation { showingBottomPane.toggle() }
                            }) {
                                Label("Toggle Bottom Pane", systemImage: "rectangle.bottomthird.inset.filled")
                                    .foregroundColor(showingBottomPane ? .accentColor : .primary)
                            }
                            
                            Button(action: { openWindow(id: "activity-log") }) {
                                Label("Logs", systemImage: "list.bullet.rectangle")
                            }
                            
                            Button(action: { showingSettings = true }) {
                                Label("Settings", systemImage: "gear")
                            }
                        }
                    }
                }
        }
        .quickLookPreview($quickLookURL)
        .background(
            Button(action: {
                if let targetPath = syncManager.selectedSourcePaths.first ?? syncManager.selectedDestinationPaths.first {
                    quickLookURL = URL(fileURLWithPath: targetPath)
                }
            }) { EmptyView() }
            .keyboardShortcut(.space, modifiers: [])
            .opacity(0)
        )
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(settings)
        }
        .alert("Error", isPresented: Binding(
            get: { syncManager.currentError != nil },
            set: { _ in syncManager.currentError = nil }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            if let errorMsg = syncManager.currentError {
                Text(errorMsg)
            }
        }
        .onReceive(syncManager.$isScanning) { scanning in
            withAnimation { isScanning = scanning }
        }
        .onReceive(syncManager.refreshSubject) { _ in
            refreshAction()
        }
        .onAppear {
            actionHandler = FileActionHandler(syncManager: syncManager, settings: settings)
            syncManager.undoManager = undoManager
            Task { @MainActor in
                await settings.discoverProviders()
                applyProviderSelection(preferDistinctPair: true)
                
                // Start prefetching in the background without blocking the initial UI load
                Task.detached(priority: .background) {
                    await syncManager.prefetch(providers: settings.availableProviders)
                }
                
                if !settings.availableProviders.isEmpty {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    refreshAction()
                }
                isBootstrappingProviders = false
            }
        }
        .onChange(of: sourceProviderId) { _, newId in
            guard !isBootstrappingProviders else { return }
            Logger.shared.info("User switched source provider to \(newId)")
            syncManager.resetNavigation()
            refreshAction()
        }
        .onChange(of: destinationProviderId) { _, newId in
            guard !isBootstrappingProviders else { return }
            Logger.shared.info("User switched destination provider to \(newId)")
            syncManager.resetNavigation()
            refreshAction()
        }
        .onChange(of: syncManager.selectedSourcePaths) { _, paths in
            guard !paths.isEmpty, showingBottomPane, selectedBottomTab != .details else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000)
                guard showingBottomPane else { return }
                selectedBottomTab = .details
            }
        }
        .onChange(of: syncManager.selectedDestinationPaths) { _, paths in
            guard !paths.isEmpty, showingBottomPane, selectedBottomTab != .details else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000)
                guard showingBottomPane else { return }
                selectedBottomTab = .details
            }
        }
        .onChange(of: settings.availableProviders) { _, _ in
            Task {
                await syncManager.prefetch(providers: settings.availableProviders)
            }
            applyProviderSelection(preferDistinctPair: isBootstrappingProviders)
            guard !isBootstrappingProviders else { return }
            refreshAction()
        }
    }
    
    private var currentSourcePath: String {
        let root = (settings.path(for: sourceProviderId) as NSString).expandingTildeInPath
        if syncManager.sourceRelativePath.isEmpty { return root }
        return (root as NSString).appendingPathComponent(syncManager.sourceRelativePath)
    }
    
    private var currentDestinationPath: String {
        let root = (settings.path(for: destinationProviderId) as NSString).expandingTildeInPath
        if syncManager.destRelativePath.isEmpty { return root }
        return (root as NSString).appendingPathComponent(syncManager.destRelativePath)
    }

    private func applyProviderSelection(preferDistinctPair: Bool) {
        guard let resolved = Self.resolvedProviderSelection(
            providers: settings.availableProviders,
            currentSourceId: sourceProviderId,
            currentDestinationId: destinationProviderId,
            preferDistinctPair: preferDistinctPair
        ) else {
            return
        }

        if sourceProviderId != resolved.sourceId {
            sourceProviderId = resolved.sourceId
        }
        if destinationProviderId != resolved.destinationId {
            destinationProviderId = resolved.destinationId
        }
    }

    /// Refreshes the directory trees and performs a differential scan.
    /// This utilizes `syncManager.refreshTreesAndScan` which includes re-entrancy and cancellation protection.
    /// Used heavily for internal navigation changes where cache-hits are desired.
    private func refreshAction() {
        guard let sourceProvider = settings.availableProviders.first(where: { $0.id == sourceProviderId }),
              let destProvider = settings.availableProviders.first(where: { $0.id == destinationProviderId }) else { 
            return 
        }
        
        Logger.shared.info("Internal scan comparing \(sourceProvider.displayName) and \(destProvider.displayName)")
        Task {
            await syncManager.refreshTreesAndScan(source: sourceProvider, destination: destProvider)
        }
    }

    /// Explicit refresh triggered by the user. Bypasses the prefetch cache to ensure newly added
    /// files on the disk manifest in the UI, even when currently browsing the root directory.
    private func forceRefreshAction() {
        Logger.shared.info("User requested a force refresh")
        syncManager.prefetchedTrees.removeAll()
        refreshAction()
    }

    @ViewBuilder
    private var mainContentView: some View {
        VStack(spacing: 0) {
            NavigationToolbar(syncManager: syncManager, refreshAction: refreshAction)
            Divider()
            paneActionBar
            Divider()
            VSplitView {
                VStack(spacing: 0) {
                    HSplitView {
                        VStack(spacing: 0) {
                            PaneHeader(title: "Source", provider: settings.availableProviders.first(where: { $0.id == sourceProviderId }), path: currentSourcePath)
                            sourceTreeView
                        }
                        .frame(minWidth: 250)
                        
                        VStack(spacing: 0) {
                            PaneHeader(title: "Destination", provider: settings.availableProviders.first(where: { $0.id == destinationProviderId }), path: currentDestinationPath)
                            destinationTreeView
                        }
                        .frame(minWidth: 250)
                    }
                    Divider()
                    DashboardHeader(sourceCount: syncManager.sourceItemCount, destinationCount: syncManager.destinationItemCount, differences: syncManager.differences)
                }
                if showingBottomPane {
                    bottomPaneView
                        .frame(minHeight: 150)
                }
            }
        }
        .overlay {
            if let progress = syncManager.activeProgress {
                ZStack {
                    Color.black.opacity(0.1)
                        .edgesIgnoringSafeArea(.all)
                    
                    ProgressDialogView(progress: progress)
                        .padding()
                        .transition(AnyTransition.move(edge: Edge.top).combined(with: AnyTransition.opacity))
                }
                .animation(.spring(), value: progress)
            }
        }
    }

    private enum ActivePane {
        case source
        case destination
    }

    private var activePane: ActivePane? {
        if !syncManager.selectedSourcePaths.isEmpty { return .source }
        if !syncManager.selectedDestinationPaths.isEmpty { return .destination }
        return nil
    }

    private var activeSelectionNodes: [FileNode] {
        switch activePane {
        case .source?:
            return syncManager.sourceTree.findNodes(at: syncManager.selectedSourcePaths)
        case .destination?:
            return syncManager.destinationTree.findNodes(at: syncManager.selectedDestinationPaths)
        case nil:
            return []
        }
    }

    private var activePanePath: String? {
        switch activePane {
        case .source?: return currentSourcePath
        case .destination?: return currentDestinationPath
        case nil: return nil
        }
    }

    @ViewBuilder
    private var paneActionBar: some View {
        HStack(spacing: 10) {
            Button(action: forceRefreshAction) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            Button(action: {
                guard let path = activePanePath else { return }
                actionHandler?.beginCreateFolder(in: path)
            }) {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .disabled(activePane == nil)

            Button(action: {
                guard let node = activeSelectionNodes.first, node.isDirectory else { return }
                let isSource = (activePane == .source)
                actionHandler?.focusFolder(node, isSource: isSource, sourceProviderId: sourceProviderId, destProviderId: destinationProviderId)
            }) {
                Label("Compare", systemImage: "scope")
            }
            .disabled(activeSelectionNodes.count != 1 || !activeSelectionNodes[0].isDirectory)

            Button(role: .destructive, action: {
                let nodes = activeSelectionNodes
                guard !nodes.isEmpty else { return }
                actionHandler?.confirmDelete(nodes)
            }) {
                Label("Delete", systemImage: "trash")
            }
            .disabled(activeSelectionNodes.isEmpty)

            Menu {
                Button("Name") { syncManager.sortOption = .name }
                Button("Kind") { syncManager.sortOption = .kind }
                Button("Date Modified") { syncManager.sortOption = .dateModified }
                Button("Size") { syncManager.sortOption = .size }
                Button("Tags") { syncManager.sortOption = .tags }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }

            Spacer()
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
    
    @ViewBuilder
    private var sourceTreeView: some View {
        FileTreeView(
            tree: syncManager.sourceTree,
            otherTree: syncManager.destinationTree,
            isLoading: syncManager.isLoadingSourceTree,
            currentPath: currentSourcePath,
            selection: $syncManager.selectedSourcePaths,
            expandedPaths: $syncManager.sourceExpandedPaths,
            otherSelection: syncManager.selectedDestinationPaths,
            isSource: true,
            delegate: PaneActionDelegate(handler: actionHandler, syncManager: syncManager, settings: settings, isSource: true, sourceProviderId: sourceProviderId, destProviderId: destinationProviderId, forceRefreshAction: forceRefreshAction),
            ignoredPaths: syncManager.ignoredPaths
        )
    }
    
    @ViewBuilder
    private var destinationTreeView: some View {
        FileTreeView(
            tree: syncManager.destinationTree, 
            otherTree: syncManager.sourceTree,
            isLoading: syncManager.isLoadingDestinationTree, 
            currentPath: currentDestinationPath,
            selection: $syncManager.selectedDestinationPaths,
            expandedPaths: $syncManager.destExpandedPaths,
            otherSelection: syncManager.selectedSourcePaths,
            isSource: false,
            delegate: PaneActionDelegate(handler: actionHandler, syncManager: syncManager, settings: settings, isSource: false, sourceProviderId: sourceProviderId, destProviderId: destinationProviderId, forceRefreshAction: forceRefreshAction),
            ignoredPaths: syncManager.ignoredPaths
        )
    }
    
    /// The tabbed workspace at the bottom of the file explorer.
    /// It dynamically switches between `DifferencesView` and `DetailsSidebar`.
    @ViewBuilder
    private var bottomPaneView: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $selectedBottomTab) {
                    ForEach(BottomTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                
                Spacer()
            }
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            ZStack {
                if selectedBottomTab == .differences {
                    if !syncManager.differences.isEmpty {
                        DifferencesView(syncManager: syncManager)
                    } else if syncManager.hasScanned {
                        VStack {
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 40)).foregroundColor(.green).padding(.bottom, 8)
                            Text("Everything is in sync").font(.headline)
                            Text("No differences found between focused directories.").font(.subheadline).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                    } else {
                        VStack {
                            Text("No Scan Performed").font(.headline).foregroundColor(.secondary)
                            Text("Click Scan to compare directories.").font(.subheadline).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    DetailsSidebar(syncManager: syncManager, sourcePath: currentSourcePath, destPath: currentDestinationPath)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}
    
/// A delegate that bridges `FileTreeView` interactions to the central `FileActionHandler`.
/// Manages actions like focus, copy, delete, and rename for a specific tree pane.
@MainActor
struct PaneActionDelegate: FileActionDelegate {
    let handler: FileActionHandler?
    let syncManager: FileSyncManager
    let settings: SettingsManager
    let isSource: Bool
    let sourceProviderId: String
    let destProviderId: String
    let forceRefreshAction: () -> Void
    
    func handleRefresh() {
        forceRefreshAction()
    }
    func handleFocus(_ node: FileNode) { handler?.focusFolder(node, isSource: isSource, sourceProviderId: sourceProviderId, destProviderId: destProviderId) }
    func handleCopy(_ nodes: [FileNode]) { handler?.copyItems(nodes, fromSource: isSource, sourceProviderId: sourceProviderId, destProviderId: destProviderId) }
    func handleMove(_ nodes: [FileNode]) { 
        Task {
            _ = await handler?.moveItems(nodes, fromSource: isSource, sourceProviderId: sourceProviderId, destProviderId: destProviderId) 
        }
    }
    func handleDelete(_ nodes: [FileNode]) { handler?.confirmDelete(nodes) }
    func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) { 
        handler?.handleCopyToClipboard(nodes, isCut: isCut)
    }
    func handlePaste(_ targetDir: FileNode) { handler?.pasteClipboard(to: targetDir) }
    func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode]) { handler?.pasteItems(nodes, to: targetDir, isCut: false) }
    func handlePasteToPath(_ path: String) { handler?.pasteClipboard(toPath: path) }
    func handleRename(_ node: FileNode) { handler?.beginRename(node) }
    func handleCreateFolder(at path: String) { handler?.beginCreateFolder(in: path) }
    func handleGetInfo(for path: String) { handler?.openGetInfo(for: path) }
    func handleSort(_ option: SortOption) { 
        Logger.shared.info("User changed sort option to \(option)")
        syncManager.sortOption = option 
    }
    func handleIgnore(_ nodes: [FileNode]) {
        let rootPath = isSource ? settings.path(for: sourceProviderId) : settings.path(for: destProviderId)
        let expandedRoot = (rootPath as NSString).expandingTildeInPath
        let relPrefix = isSource ? syncManager.sourceRelativePath : syncManager.destRelativePath
        
        let basePath = relPrefix.isEmpty ? expandedRoot : (expandedRoot as NSString).appendingPathComponent(relPrefix)
        
        // Convert to relative paths from current focal point so they sync across panes seamlessly
        let relativeTargets: [String] = nodes.map { node in
            var rPath = node.id
            if rPath.hasPrefix(basePath) {
                rPath = String(rPath.dropFirst(basePath.count))
                if rPath.hasPrefix("/") { rPath.removeFirst() }
            }
            return rPath
        }
        
        let allIgnored = relativeTargets.allSatisfy { syncManager.ignoredPaths.contains($0) }
        
        for relPath in relativeTargets {
            if allIgnored {
                syncManager.ignoredPaths.remove(relPath)
            } else {
                syncManager.ignoredPaths.insert(relPath)
            }
        }
    }
    func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool {
        syncManager.isNodeIgnored(node, currentPath: currentPath)
    }
}
