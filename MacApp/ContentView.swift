import SwiftUI
import Sync
import Events
import Settings
import FileExplorer
import Dashboard
import QuickLook

/// The main application layout for SyncCloud.
/// Contains a two-pane `NavigationSplitView` managing source and destination `FileTreeView`s.
struct ContentView: View {
    /// The global synchronization engine tracking tree structures and differences.
    @StateObject private var syncManager = FileSyncManager()
    /// The unmanaged configuration logic responsible for available providers.
    @StateObject private var settings = SettingsManager()
    
    /// The currently selected CloudProvider ID driving the left Source pane.
    @State private var sourceProviderId: String = "iCloud"
    /// The currently selected CloudProvider ID driving the right Destination pane.
    @State private var destinationProviderId: String = "iCloud"
    
    /// Tracks visual animation states when scanning directories.
    @State private var isScanning = false
    
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    
    /// Controls the presentation of the User Preferences sheet.
    @State private var showingSettings = false
    /// Controls the presentation of the Logger Activity inspector pane.
    @State private var showingLogs = false
    
    /// Extractable handler for native file actions (rename, copy, delete, etc.)
    @State private var actionHandler: FileActionHandler?
    
    // MARK: - File Action UI States
    
    /// Target file URL bound to the native macOS Quick Look panel.
    @State private var quickLookURL: URL? = nil

    var body: some View {
        NavigationSplitView {
            // Sidebar Navigation
            ProviderSidebar(
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
                .onChange(of: syncManager.differences) {
                    isScanning = false
                }
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
                        sourceTreeView
                    }
                    .frame(minWidth: 250)
                    
                    // Right Pane (Destination)
                    VStack(spacing: 0) {
                        PaneHeader(
                            title: "Destination", 
                            provider: settings.availableProviders.first(where: { $0.id == destinationProviderId }), 
                            path: currentDestinationPath
                        )
                        destinationTreeView
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
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(action: refreshAction) {
                        Label("Scan", systemImage: isScanning ? "hourglass" : "magnifyingglass")
                    }
                    .disabled(isScanning)
                }
                ToolbarItem(placement: .automatic) {
                    Button(action: { openWindow(id: "activity-log") }) {
                        Label("Logs", systemImage: "list.bullet.rectangle")
                    }
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
        .onReceive(syncManager.refreshSubject) { _ in
            refreshAction()
        }
        .onAppear {
            actionHandler = FileActionHandler(syncManager: syncManager, settings: settings)
            syncManager.undoManager = undoManager
            if let first = settings.availableProviders.first?.id {
                sourceProviderId = first
                destinationProviderId = settings.availableProviders.dropFirst().first?.id ?? first
            }
            refreshAction()
        }
        .onChange(of: sourceProviderId) {
            syncManager.selectedSourcePaths = []
            syncManager.resetNavigation()
            refreshAction()
        }
        .onChange(of: destinationProviderId) {
            syncManager.selectedDestinationPaths = []
            syncManager.resetNavigation()
            refreshAction()
        }
        .onChange(of: settings.availableProviders) {
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

    
    /// Triggers an immediate refresh cycle: scanning files and rebuilding the view-model trees from disk.
    private func refreshAction() {
        guard let sourceProvider = settings.availableProviders.first(where: { $0.id == sourceProviderId }),
              let destProvider = settings.availableProviders.first(where: { $0.id == destinationProviderId }) else { 
            return 
        }
              
        Task {
            await syncManager.refreshTreesAndScan(source: sourceProvider, destination: destProvider)
        }
    }
    
    // MARK: - Extracted Subviews
    
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
            onFocus: { node in actionHandler?.focusFolder(node, isSource: true, sourceProviderId: sourceProviderId, destProviderId: destinationProviderId) },
            onCopy: { nodes in actionHandler?.copyItems(nodes, fromSource: true, sourceProviderId: sourceProviderId, destProviderId: destinationProviderId) },
            onDelete: { nodes in actionHandler?.confirmDelete(nodes) },
            onCopyToClipboard: { nodes, isCut in 
                syncManager.clipboardNodes = nodes
                syncManager.clipboardIsCut = isCut
            },
            onPaste: { targetDir in actionHandler?.pasteClipboard(to: targetDir) },
            onPasteExplicit: { targetDir, nodes in actionHandler?.pasteItems(nodes, to: targetDir, isCut: false) },
            onPasteToPath: { path in actionHandler?.pasteClipboard(toPath: path) },
            onRename: { node in actionHandler?.beginRename(node) },
            onCreateFolder: { path in actionHandler?.beginCreateFolder(in: path) },
            onGetInfo: { path in actionHandler?.openGetInfo(for: path) },
            onSort: { option in syncManager.sortOption = option }
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
            onFocus: { node in actionHandler?.focusFolder(node, isSource: false, sourceProviderId: sourceProviderId, destProviderId: destinationProviderId) },
            onCopy: { nodes in actionHandler?.copyItems(nodes, fromSource: false, sourceProviderId: sourceProviderId, destProviderId: destinationProviderId) },
            onDelete: { nodes in actionHandler?.confirmDelete(nodes) },
            onCopyToClipboard: { nodes, isCut in 
                syncManager.clipboardNodes = nodes
                syncManager.clipboardIsCut = isCut
            },
            onPaste: { targetDir in actionHandler?.pasteClipboard(to: targetDir) },
            onPasteExplicit: { targetDir, nodes in actionHandler?.pasteItems(nodes, to: targetDir, isCut: false) },
            onPasteToPath: { path in actionHandler?.pasteClipboard(toPath: path) },
            onRename: { node in actionHandler?.beginRename(node) },
            onCreateFolder: { path in actionHandler?.beginCreateFolder(in: path) },
            onGetInfo: { path in actionHandler?.openGetInfo(for: path) },
            onSort: { option in syncManager.sortOption = option }
        )
    }
}

