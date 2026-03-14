import SwiftUI
import Sync
import Events
import Settings
import FileExplorer
import Dashboard
import QuickLook
import Design

/// Main window content: provider sidebar, two file panes (left/right), toolbar, and bottom tab (Differences / Details).
struct ContentView: View {
    @ObservedObject var syncManager: FileSyncManager
    @EnvironmentObject var settings: SettingsManager
    
    @State private var leftProviderId: String = "iCloud"
    @State private var rightProviderId: String = "iCloud"
    @State private var isScanning = false
    
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    
    @State private var actionHandler: FileActionHandler?
    @State private var quickLookURL: URL? = nil
    @State private var showingBottomPane: Bool = true
    @State private var isBootstrappingProviders: Bool = true
    
    @AppStorage(LiquidGlass.intensityKey) private var glassIntensity: Double = 0.65
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    
    /// Represents the available tabs in the integrated bottom workspace.
    enum BottomTab: String, CaseIterable {
        /// Displays differential scanning results and sync actions.
        case differences = "Differences"
        /// Displays rich file metadata (size, dates, permissions).
        case details = "Details"
    }
    @State private var selectedBottomTab: BottomTab = .differences

    /// Resolves the left and right provider IDs from the current list (e.g. after provider list changes or bootstrap).
    /// - Parameter preferDistinctPair: If `true`, when both sides would be the same, pick a different provider for the right.
    /// - Returns: `(leftId, rightId)` or `nil` if there are no providers.
    static func resolvedProviderSelection(
        providers: [CloudProvider],
        currentLeftId: String,
        currentRightId: String,
        preferDistinctPair: Bool
    ) -> (leftId: String, rightId: String)? {
        guard let first = providers.first?.id else { return nil }

        var leftId = currentLeftId
        if !providers.contains(where: { $0.id == leftId }) {
            leftId = first
        }

        let fallbackRight = providers.first(where: { $0.id != leftId })?.id ?? leftId
        var rightId = currentRightId
        let rightExists = providers.contains(where: { $0.id == rightId })
        if !rightExists || (preferDistinctPair && rightId == leftId) {
            rightId = fallbackRight
        }

        return (leftId, rightId)
    }

    var body: some View {
        NavigationSplitView {
            ProviderSidebar(
                settings: settings,
                leftProviderId: $leftProviderId,
                rightProviderId: $rightProviderId
            )
        } detail: {
            mainContentView
                .frame(minWidth: 600)
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
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
                            
                            Button(action: { openWindow(id: "settings") }) {
                                Label("Settings", systemImage: "gear")
                            }
                        }
                    }
                }
        }
        .quickLookPreview($quickLookURL)
        .background(
            Button(action: {
                if let targetPath = syncManager.selectedLeftPaths.first ?? syncManager.selectedRightPaths.first {
                    quickLookURL = URL(fileURLWithPath: targetPath)
                }
            }) { EmptyView() }
            .keyboardShortcut(.space, modifiers: [])
            .opacity(0)
        )
        .liquidGlassAppBackground(intensity: glassIntensity, hue: LiquidGlassHue(rawValue: glassHueRaw) ?? .blue)
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
        .onChange(of: leftProviderId) { _, newId in
            guard !isBootstrappingProviders else { return }
            Logger.shared.info("User switched left provider to \(newId)")
            syncManager.resetNavigation()
            refreshAction()
        }
        .onChange(of: rightProviderId) { _, newId in
            guard !isBootstrappingProviders else { return }
            Logger.shared.info("User switched right provider to \(newId)")
            syncManager.resetNavigation()
            refreshAction()
        }
        .onChange(of: syncManager.selectedLeftPaths) { _, paths in
            guard !paths.isEmpty, showingBottomPane, selectedBottomTab != .details else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000)
                guard showingBottomPane else { return }
                selectedBottomTab = .details
            }
        }
        .onChange(of: syncManager.selectedRightPaths) { _, paths in
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
    
    private var currentLeftPath: String {
        let root = (settings.path(for: leftProviderId) as NSString).expandingTildeInPath
        if syncManager.leftRelativePath.isEmpty { return root }
        return (root as NSString).appendingPathComponent(syncManager.leftRelativePath)
    }
    
    private var currentRightPath: String {
        let root = (settings.path(for: rightProviderId) as NSString).expandingTildeInPath
        if syncManager.rightRelativePath.isEmpty { return root }
        return (root as NSString).appendingPathComponent(syncManager.rightRelativePath)
    }

    private func applyProviderSelection(preferDistinctPair: Bool) {
        guard let resolved = Self.resolvedProviderSelection(
            providers: settings.availableProviders,
            currentLeftId: leftProviderId,
            currentRightId: rightProviderId,
            preferDistinctPair: preferDistinctPair
        ) else {
            return
        }

        if leftProviderId != resolved.leftId {
            leftProviderId = resolved.leftId
        }
        if rightProviderId != resolved.rightId {
            rightProviderId = resolved.rightId
        }
    }

    /// Reloads both pane trees and runs a diff scan (with re-entrancy and cancellation handled by the manager).
    private func refreshAction() {
        guard let leftProvider = settings.availableProviders.first(where: { $0.id == leftProviderId }),
              let rightProvider = settings.availableProviders.first(where: { $0.id == rightProviderId }) else { 
            return 
        }
        
        Logger.shared.info("Internal scan comparing \(leftProvider.displayName) and \(rightProvider.displayName)")
        Task {
            await syncManager.refreshTreesAndScan(left: leftProvider, right: rightProvider)
        }
    }

    /// User-triggered refresh: clears prefetch cache so new files on disk appear immediately.
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
                            PaneHeader(title: "Left", provider: settings.availableProviders.first(where: { $0.id == leftProviderId }), path: currentLeftPath)
                            leftTreeView
                        }
                        .frame(minWidth: 250)
                        
                        VStack(spacing: 0) {
                            PaneHeader(title: "Right", provider: settings.availableProviders.first(where: { $0.id == rightProviderId }), path: currentRightPath)
                            rightTreeView
                        }
                        .frame(minWidth: 250)
                    }
                    Divider()
                    DashboardHeader(leftCount: syncManager.leftItemCount, rightCount: syncManager.rightItemCount, differences: syncManager.differences)
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
                    
                    ProgressDialog(progress: progress)
                        .padding()
                        .transition(AnyTransition.move(edge: Edge.top).combined(with: AnyTransition.opacity))
                }
                .animation(.spring(), value: progress)
            }
        }
        .overlay(alignment: .top) {
            if let banner = syncManager.bannerMessage {
                OperationBannerView(message: banner)
                    .padding(.top, 8)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: syncManager.bannerMessage)
        .onChange(of: syncManager.bannerMessage) { _, newValue in
            guard let current = newValue else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if syncManager.bannerMessage == current {
                    syncManager.bannerMessage = nil
                }
            }
        }
    }

    private enum ActivePane {
        case left
        case right
    }

    private var activePane: ActivePane? {
        if !syncManager.selectedLeftPaths.isEmpty { return .left }
        if !syncManager.selectedRightPaths.isEmpty { return .right }
        return nil
    }

    private var activeSelectionNodes: [FileNode] {
        switch activePane {
        case .left?:
            return syncManager.leftTree.findNodes(at: syncManager.selectedLeftPaths)
        case .right?:
            return syncManager.rightTree.findNodes(at: syncManager.selectedRightPaths)
        case nil:
            return []
        }
    }

    private var activePanePath: String? {
        switch activePane {
        case .left?: return currentLeftPath
        case .right?: return currentRightPath
        case nil: return nil
        }
    }

    /// Lightweight in-app banner used for bulk operation completion notifications.
    @ViewBuilder
    private func OperationBannerView(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .glassCardStyle(material: .ultraThickMaterial, intensity: glassIntensity)
    }

    @ViewBuilder
    private var paneActionBar: some View {
        HStack(spacing: 10) {
            Button(action: {
                guard let node = activeSelectionNodes.first, node.isDirectory else { return }
                let isLeft = (activePane == .left)
                actionHandler?.focusFolder(node, isLeft: isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId)
            }) {
                Label("Compare", systemImage: "scope")
            }
            .disabled(activeSelectionNodes.count != 1 || !activeSelectionNodes[0].isDirectory)

            Button(action: {
                let nodes = activeSelectionNodes
                guard !nodes.isEmpty, let activePane else { return }
                let fromLeft = (activePane == .left)
                actionHandler?.copyItems(nodes, fromLeft: fromLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId)
            }) {
                Label("Copy", systemImage: "arrow.right.doc.on.clipboard")
            }
            .disabled(activeSelectionNodes.isEmpty)

            Button(action: {
                let nodes = activeSelectionNodes
                guard !nodes.isEmpty, let activePane else { return }
                let fromLeft = (activePane == .left)
                Task {
                    _ = await actionHandler?.moveItems(nodes, fromLeft: fromLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId)
                }
            }) {
                Label("Move", systemImage: "arrow.right.square")
            }
            .disabled(activeSelectionNodes.isEmpty)

            Button(action: {
                guard let path = activePanePath else { return }
                actionHandler?.beginCreateFolder(in: path)
            }) {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .disabled(activePane == nil)

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
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .glassBarStyle(intensity: glassIntensity)
    }
    
    @ViewBuilder
    private var leftTreeView: some View {
        FileTreeView(
            tree: syncManager.leftTree,
            otherTree: syncManager.rightTree,
            isLoading: syncManager.isLoadingLeftTree,
            currentPath: currentLeftPath,
            selection: $syncManager.selectedLeftPaths,
            expandedPaths: $syncManager.leftExpandedPaths,
            otherSelection: syncManager.selectedRightPaths,
            isLeft: true,
            delegate: PaneActionDelegate(handler: actionHandler, syncManager: syncManager, settings: settings, isLeft: true, leftProviderId: leftProviderId, rightProviderId: rightProviderId, forceRefreshAction: forceRefreshAction),
            ignoredPaths: syncManager.ignoredPaths
        )
    }
    
    @ViewBuilder
    private var rightTreeView: some View {
        FileTreeView(
            tree: syncManager.rightTree, 
            otherTree: syncManager.leftTree,
            isLoading: syncManager.isLoadingRightTree, 
            currentPath: currentRightPath,
            selection: $syncManager.selectedRightPaths,
            expandedPaths: $syncManager.rightExpandedPaths,
            otherSelection: syncManager.selectedLeftPaths,
            isLeft: false,
            delegate: PaneActionDelegate(handler: actionHandler, syncManager: syncManager, settings: settings, isLeft: false, leftProviderId: leftProviderId, rightProviderId: rightProviderId, forceRefreshAction: forceRefreshAction),
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
                .frame(width: 220)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                
                Spacer()
            }
            .frame(height: 44)
            .layoutPriority(1)
            .background(.ultraThinMaterial)
            
            Divider()
                .opacity(0.6)
            
            ZStack {
                if selectedBottomTab == .differences {
                    if !syncManager.differences.isEmpty {
                        DifferencesView(syncManager: syncManager)
                            .frame(minHeight: 0)
                    } else if syncManager.hasScanned {
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.green)
                            Text("Everything is in sync")
                                .font(.title3.weight(.semibold))
                            Text("No differences found between focused directories.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.regularMaterial.opacity(0.5))
                    } else {
                        VStack(spacing: 8) {
                            Text("No Scan Performed")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Text("Click Scan to compare directories.")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    DetailsSidebar(syncManager: syncManager, leftPath: currentLeftPath, rightPath: currentRightPath)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(minHeight: 0)
                }
            }
            .frame(minHeight: 0)
            .background(.regularMaterial.opacity(0.4))
        }
        .glassCardStyle(material: .regularMaterial, intensity: glassIntensity)
        .overlay(
            RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
    }
}
    
/// Connects a single pane’s `FileTreeView` to `FileActionHandler` (focus, copy, move, delete, rename, etc.).
@MainActor
struct PaneActionDelegate: FileActionDelegate {
    let handler: FileActionHandler?
    let syncManager: FileSyncManager
    let settings: SettingsManager
    let isLeft: Bool
    let leftProviderId: String
    let rightProviderId: String
    let forceRefreshAction: () -> Void
    
    func handleRefresh() {
        forceRefreshAction()
    }
    func handleFocus(_ node: FileNode) { handler?.focusFolder(node, isLeft: isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId) }
    func handleCopy(_ nodes: [FileNode]) { handler?.copyItems(nodes, fromLeft: isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId) }
    func handleMove(_ nodes: [FileNode]) { 
        Task {
            _ = await handler?.moveItems(nodes, fromLeft: isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId) 
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
        let rootPath = isLeft ? settings.path(for: leftProviderId) : settings.path(for: rightProviderId)
        let expandedRoot = (rootPath as NSString).expandingTildeInPath
        let relPrefix = isLeft ? syncManager.leftRelativePath : syncManager.rightRelativePath
        
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
