import SwiftUI

struct ContentView: View {
    @StateObject private var syncManager = DocumentSyncManager()
    @StateObject private var settings = SettingsManager()
    @State private var sourceProviderId: String = "iCloud"
    @State private var destinationProviderId: String = "iCloud"
    @State private var isScanning = false
    
    @State private var selectedSourcePaths: Set<String> = []
    @State private var selectedDestinationPaths: Set<String> = []
    
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView {
            // Sidebar Navigation
            List {
                Section("Source Provider") {
                    ForEach(settings.availableProviders) { provider in
                        Button(action: { sourceProviderId = provider.id }) {
                            HStack {
                                Image(provider.imageName)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 20)
                                Text(provider.displayName)
                                Spacer()
                                if sourceProviderId == provider.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                }
                
                Section("Destination Provider") {
                    ForEach(settings.availableProviders) { provider in
                        Button(action: { destinationProviderId = provider.id }) {
                            HStack {
                                Image(provider.imageName)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 20)
                                Text(provider.displayName)
                                Spacer()
                                if destinationProviderId == provider.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Providers")
            .frame(minWidth: 200)
            
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
                            selection: $selectedSourcePaths,
                            otherSelection: selectedDestinationPaths,
                            onFocus: { node in focusFolder(node, isSource: true) },
                            onCopy: { nodes in copyItems(nodes, fromSource: true) },
                            onDelete: { nodes in deleteItems(nodes) },
                            onCopyToClipboard: { nodes in syncManager.clipboardNodes = nodes },
                            onPaste: { targetDir in pasteItems(to: targetDir) },
                            onPasteExplicit: { targetDir, nodes in pasteItems(nodes, to: targetDir) }
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
                            selection: $selectedDestinationPaths,
                            otherSelection: selectedSourcePaths,
                            onFocus: { node in focusFolder(node, isSource: false) },
                            onCopy: { nodes in copyItems(nodes, fromSource: false) },
                            onDelete: { nodes in deleteItems(nodes) },
                            onCopyToClipboard: { nodes in syncManager.clipboardNodes = nodes },
                            onPaste: { targetDir in pasteItems(to: targetDir) },
                            onPasteExplicit: { targetDir, nodes in pasteItems(nodes, to: targetDir) }
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
    
    private func deleteItems(_ nodes: [FileNode]) {
        Task {
            await syncManager.deleteItems(at: nodes.map { $0.id })
            refreshAction()
        }
    }
    
    private func pasteItems(to targetFolder: FileNode) {
        let nodesToPaste = syncManager.clipboardNodes
        guard !nodesToPaste.isEmpty else { return }
        pasteItems(nodesToPaste, to: targetFolder)
        syncManager.clipboardNodes = [] // Clear clipboard after paste
    }
    
    private func pasteItems(_ nodes: [FileNode], to targetFolder: FileNode) {
        Task {
            await syncManager.copyItems(nodes: nodes, toPath: targetFolder.id)
            refreshAction()
        }
    }
    
    private func refreshAction() {
        guard let sourceProvider = settings.availableProviders.first(where: { $0.id == sourceProviderId }),
              let destProvider = settings.availableProviders.first(where: { $0.id == destinationProviderId }) else { return }
              
        Task {
            await syncManager.refreshTreesAndScan(source: sourceProvider, destination: destProvider)
        }
    }
}

