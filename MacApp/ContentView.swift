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
    
    /// Represents the available tabs in the integrated bottom workspace.
    enum BottomTab: String, CaseIterable {
        /// Displays differential scanning results and sync actions.
        case differences = "Differences"
        /// Displays rich file metadata (size, dates, permissions).
        case details = "Details"
    }
    @State private var selectedBottomTab: BottomTab = .differences

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
                            Button(action: refreshAction) {
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
            if let first = settings.availableProviders.first?.id {
                sourceProviderId = first
                destinationProviderId = settings.availableProviders.dropFirst().first?.id ?? first
            }
            Task {
                await syncManager.prefetch(providers: settings.availableProviders)
            }
            refreshAction()
        }
        .onChange(of: sourceProviderId) { _, _ in
            syncManager.selectedSourcePaths = []
            syncManager.sourceRelativePath = ""
            syncManager.resetNavigation()
            refreshAction()
        }
        .onChange(of: destinationProviderId) { _, _ in
            syncManager.selectedDestinationPaths = []
            syncManager.destRelativePath = ""
            syncManager.resetNavigation()
            refreshAction()
        }
        .onChange(of: syncManager.selectedSourcePaths) { _, paths in
            if !paths.isEmpty && showingBottomPane {
                withAnimation { selectedBottomTab = .details }
            }
        }
        .onChange(of: syncManager.selectedDestinationPaths) { _, paths in
            if !paths.isEmpty && showingBottomPane {
                withAnimation { selectedBottomTab = .details }
            }
        }
        .onChange(of: settings.availableProviders) { _, _ in
            Task {
                await syncManager.prefetch(providers: settings.availableProviders)
            }
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

    /// Refreshes the directory trees and performs a differential scan.
    /// This utilizes `syncManager.refreshTreesAndScan` which includes re-entrancy and cancellation protection.
    private func refreshAction() {
        guard let sourceProvider = settings.availableProviders.first(where: { $0.id == sourceProviderId }),
              let destProvider = settings.availableProviders.first(where: { $0.id == destinationProviderId }) else { 
            return 
        }
        Task {
            await syncManager.refreshTreesAndScan(source: sourceProvider, destination: destProvider)
        }
    }

    @ViewBuilder
    private var mainContentView: some View {
        VStack(spacing: 0) {
            NavigationToolbar(syncManager: syncManager, refreshAction: refreshAction)
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
            delegate: PaneActionDelegate(handler: actionHandler, syncManager: syncManager, isSource: true, sourceProviderId: sourceProviderId, destProviderId: destinationProviderId)
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
            delegate: PaneActionDelegate(handler: actionHandler, syncManager: syncManager, isSource: false, sourceProviderId: sourceProviderId, destProviderId: destinationProviderId)
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
                        DifferencesView(syncManager: syncManager, refreshAction: refreshAction)
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
    let isSource: Bool
    let sourceProviderId: String
    let destProviderId: String
    
    func handleFocus(_ node: FileNode) { handler?.focusFolder(node, isSource: isSource, sourceProviderId: sourceProviderId, destProviderId: destProviderId) }
    func handleCopy(_ nodes: [FileNode]) { handler?.copyItems(nodes, fromSource: isSource, sourceProviderId: sourceProviderId, destProviderId: destProviderId) }
    func handleDelete(_ nodes: [FileNode]) { handler?.confirmDelete(nodes) }
    func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) { 
        syncManager.clipboardNodes = nodes
        syncManager.clipboardIsCut = isCut 
    }
    func handlePaste(_ targetDir: FileNode) { handler?.pasteClipboard(to: targetDir) }
    func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode]) { handler?.pasteItems(nodes, to: targetDir, isCut: false) }
    func handlePasteToPath(_ path: String) { handler?.pasteClipboard(toPath: path) }
    func handleRename(_ node: FileNode) { handler?.beginRename(node) }
    func handleCreateFolder(at path: String) { handler?.beginCreateFolder(in: path) }
    func handleGetInfo(for path: String) { handler?.openGetInfo(for: path) }
    func handleSort(_ option: SortOption) { syncManager.sortOption = option }
}

