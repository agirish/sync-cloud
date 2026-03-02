import SwiftUI

/// The main application layout for SyncCloud
/// Contains a two-pane NavigationSplitView managing source and destination FileTreeViews
/// Handles top-level file operation alert bindings through the FileOperationAlerts modifier
struct ContentView: View {
    @StateObject private var syncManager = DocumentSyncManager()
    @StateObject private var settings = SettingsManager()
    @State private var sourceProviderId: String = "iCloud"
    @State private var destinationProviderId: String = "iCloud"
    @State private var isScanning = false
    
    @State private var selectedSourcePaths: Set<String> = []
    @State private var selectedDestinationPaths: Set<String> = []
    @State private var sourceExpandedPaths: Set<String> = []
    @State private var destExpandedPaths: Set<String> = []
    
    @State private var showingSettings = false
    
    // File Action States
    @State private var renamingNode: FileNode?
    @State private var newName: String = ""
    @State private var creatingFolderInPath: String?
    @State private var newFolderName: String = ""
    @State private var nodesToDelete: [FileNode]? = nil

    var body: some View {
        NavigationSplitView {
            // Sidebar Navigation
            ProviderSidebarView(
                settings: settings,
                sourceProviderId: $sourceProviderId,
                destinationProviderId: $destinationProviderId
            )
        } detail: {
            // Main Content Area
            VStack(spacing: 0) {
                // Focus Navigation Toolbar
                NavigationToolbar(syncManager: syncManager, refreshAction: refreshAction)
                
                Divider()
                
                // Dashboard Header
                DashboardHeader(
                    sourceCount: syncManager.sourceItemCount,
                    destinationCount: syncManager.destinationItemCount,
                    differences: syncManager.differences
                )
                
                Divider()
                
                // File Trees Split View
                HSplitView {
                    // Left Pane (Source)
                    VStack(spacing: 0) {
                        PaneHeader(
                            title: "Source", 
                            provider: settings.availableProviders.first(where: { $0.id == sourceProviderId }), 
                            path: currentSourcePath
                        )
                        FileTreeView(
                            tree: syncManager.sourceTree, 
                            otherTree: syncManager.destinationTree,
                            isLoading: syncManager.isLoadingSourceTree, 
                            currentPath: currentSourcePath,
                            selection: $selectedSourcePaths,
                            expandedPaths: $sourceExpandedPaths,
                            otherSelection: selectedDestinationPaths,
                            onFocus: { node in focusFolder(node, isSource: true) },
                            onCopy: { nodes in copyItems(nodes, fromSource: true) },
                            onDelete: { nodes in confirmDelete(nodes) },
                            onCopyToClipboard: { nodes, isCut in 
                                syncManager.clipboardNodes = nodes
                                syncManager.clipboardIsCut = isCut
                            },
                            onPaste: { targetDir in pasteItems(to: targetDir) },
                            onPasteExplicit: { targetDir, nodes in pasteItems(nodes, to: targetDir) },
                            onRename: { node in beginRename(node) },
                            onCreateFolder: { path in beginCreateFolder(in: path) }
                        )
                    }
                    .frame(minWidth: 250)
                    
                    // Right Pane (Destination)
                    VStack(spacing: 0) {
                        PaneHeader(
                            title: "Destination", 
                            provider: settings.availableProviders.first(where: { $0.id == destinationProviderId }), 
                            path: currentDestinationPath
                        )
                        FileTreeView(
                            tree: syncManager.destinationTree, 
                            otherTree: syncManager.sourceTree,
                            isLoading: syncManager.isLoadingDestinationTree, 
                            currentPath: currentDestinationPath,
                            selection: $selectedDestinationPaths,
                            expandedPaths: $destExpandedPaths,
                            otherSelection: selectedSourcePaths,
                            onFocus: { node in focusFolder(node, isSource: false) },
                            onCopy: { nodes in copyItems(nodes, fromSource: false) },
                            onDelete: { nodes in confirmDelete(nodes) },
                            onCopyToClipboard: { nodes, isCut in 
                                syncManager.clipboardNodes = nodes
                                syncManager.clipboardIsCut = isCut
                            },
                            onPaste: { targetDir in pasteItems(to: targetDir) },
                            onPasteExplicit: { targetDir, nodes in pasteItems(nodes, to: targetDir) },
                            onRename: { node in beginRename(node) },
                            onCreateFolder: { path in beginCreateFolder(in: path) }
                        )
                    }
                    .frame(minWidth: 250)
                }
                
                // Differences Results Area
                if !syncManager.differences.isEmpty {
                    Divider()
                    DifferencesView(syncManager: syncManager, refreshAction: refreshAction)
                        .frame(maxHeight: 300)
                } else if syncManager.hasScanned {
                    Divider()
                    VStack {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.green)
                            .padding(.bottom, 8)
                        Text("Everything is in sync")
                            .font(.headline)
                        Text("No differences found between focused directories.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: 200)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                }
            }
            .background(Color(NSColor.windowBackgroundColor))
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(action: refreshAction) {
                        Label("Scan", systemImage: isScanning ? "hourglass" : "magnifyingglass")
                    }
                    .disabled(isScanning)
                }
                ToolbarItem(placement: .automatic) {
                    Button(action: { showingSettings = true }) {
                        Label("Settings", systemImage: "gear")
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(settings)
        }
        .modifier(FileOperationAlerts(
            syncManager: syncManager,
            refreshAction: refreshAction,
            renamingNode: $renamingNode,
            newName: $newName,
            creatingFolderInPath: $creatingFolderInPath,
            newFolderName: $newFolderName,
            nodesToDelete: $nodesToDelete
        ))
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
            withAnimation {
                isScanning = scanning
            }
        }
        .onAppear {
            if let first = settings.availableProviders.first?.id {
                sourceProviderId = first
                destinationProviderId = settings.availableProviders.dropFirst().first?.id ?? first
            }
            refreshAction()
        }
        .onChange(of: sourceProviderId) { _ in
            selectedSourcePaths = []
            syncManager.resetNavigation()
            refreshAction()
        }
        .onChange(of: destinationProviderId) { _ in
            selectedDestinationPaths = []
            syncManager.resetNavigation()
            refreshAction()
        }
        .onChange(of: settings.availableProviders) { _ in
            refreshAction()
        }
    }
    
    private var currentSourcePath: String {
        let root = settings.path(for: sourceProviderId)
        if syncManager.sourceRelativePath.isEmpty { return root }
        return (root as NSString).appendingPathComponent(syncManager.sourceRelativePath)
    }
    
    private var currentDestinationPath: String {
        let root = settings.path(for: destinationProviderId)
        if syncManager.destRelativePath.isEmpty { return root }
        return (root as NSString).appendingPathComponent(syncManager.destRelativePath)
    }
    
    private func focusFolder(_ node: FileNode, isSource: Bool) {
        let rootPath = isSource ? settings.path(for: sourceProviderId) : settings.path(for: destinationProviderId)
        let otherRootPath = isSource ? settings.path(for: destinationProviderId) : settings.path(for: sourceProviderId)
        
        let expandedRoot = (rootPath as NSString).expandingTildeInPath
        let nodePath = node.id // This is already absolute
        
        var relPath = nodePath.replacingOccurrences(of: expandedRoot, with: "")
        if relPath.hasPrefix("/") { relPath.removeFirst() }
        
        syncManager.focusOn(relativePath: relPath, isSource: isSource, otherProviderPath: otherRootPath)
        refreshAction()
    }
    
    private func copyItems(_ nodes: [FileNode], fromSource: Bool) {
        let sourceRoot = settings.path(for: sourceProviderId)
        let destRoot = settings.path(for: destinationProviderId)
        
        Task {
            await syncManager.copyItems(nodes: nodes, fromSource: fromSource, sourceRoot: sourceRoot, destinationRoot: destRoot)
            refreshAction()
        }
    }
    
    private func pasteItems(to targetFolder: FileNode) {
        let nodesToPaste = syncManager.clipboardNodes
        guard !nodesToPaste.isEmpty else { return }
        pasteItems(nodesToPaste, to: targetFolder)
    }
    
    private func pasteItems(_ nodes: [FileNode], to targetFolder: FileNode) {
        Task {
            if syncManager.clipboardIsCut {
                await syncManager.moveItems(nodes: nodes, toPath: targetFolder.id)
            } else {
                await syncManager.copyItems(nodes: nodes, toPath: targetFolder.id)
            }
            syncManager.clipboardNodes = []
            syncManager.clipboardIsCut = false
            refreshAction()
        }
    }
    
    // MARK: - File Operations Helpers
    
    private func beginRename(_ node: FileNode) {
        newName = node.name
        renamingNode = node
    }
    
    private func beginCreateFolder(in path: String) {
        newFolderName = ""
        creatingFolderInPath = path
    }
    
    private func confirmDelete(_ nodes: [FileNode]) {
        nodesToDelete = nodes
    }
    
    private func refreshAction() {
        guard let sourceProvider = settings.availableProviders.first(where: { $0.id == sourceProviderId }),
              let destProvider = settings.availableProviders.first(where: { $0.id == destinationProviderId }) else { return }
              
        Task {
            await syncManager.refreshTreesAndScan(source: sourceProvider, destination: destProvider)
        }
    }
}

