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


// MARK: - Subviews

struct DashboardHeader: View {
    let sourceCount: Int
    let destinationCount: Int
    let differences: [FileDifference]
    
    var body: some View {
        HStack {
            DashboardMetric(title: "Source Items", value: "\(sourceCount)", icon: "doc.on.doc", color: .blue)
            Divider().frame(height: 30)
            DashboardMetric(title: "Destination Items", value: "\(destinationCount)", icon: "arrow.down.doc", color: .purple)
            Divider().frame(height: 30)
            DashboardMetric(title: "Differences", value: "\(differences.count)", icon: "exclamationmark.triangle", color: differences.isEmpty ? .green : .orange)
        }
        .padding()
        .background(.ultraThinMaterial)
    }
}

struct DashboardMetric: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(color)
            
            VStack(alignment: .leading) {
                Text(value)
                    .font(.title2)
                    .fontWeight(.bold)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct PaneHeader: View {
    let title: String
    let provider: CloudProvider?
    let path: String
    
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if let provider = provider {
                    HStack {
                        Image(provider.imageName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                        Text(provider.displayName)
                    }
                    .font(.subheadline)
                }
            }
            HStack {
                Text(path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

struct NavigationToolbar: View {
    @ObservedObject var syncManager: DocumentSyncManager
    let refreshAction: () -> Void
    
    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Button(action: { syncManager.goBack(); refreshAction() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!syncManager.canGoBack)
                
                Button(action: { syncManager.goForward(); refreshAction() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!syncManager.canGoForward)
            }
            .buttonStyle(.bordered)
            
            Divider().frame(height: 20).padding(.horizontal, 8)
            
            if !syncManager.sourceRelativePath.isEmpty || !syncManager.destRelativePath.isEmpty {
                HStack {
                    Image(systemName: "scope")
                        .foregroundColor(.accentColor)
                    Text("Focusing on:")
                        .fontWeight(.medium)
                    Text(syncManager.sourceRelativePath.isEmpty ? syncManager.destRelativePath : syncManager.sourceRelativePath)
                        .italic()
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.subheadline)
                
                Spacer()
                
                Button(action: { syncManager.resetNavigation(); refreshAction() }) {
                    Label("Restore Root", systemImage: "house")
                }
                .buttonStyle(.bordered)
            } else {
                Text("Viewing All Files (Root)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}

struct FileTreeView: View {
    let tree: [FileNode]
    let otherTree: [FileNode]
    let isLoading: Bool
    @Binding var selection: Set<String>
    let otherSelection: Set<String>
    let onFocus: (FileNode) -> Void
    let onCopy: ([FileNode]) -> Void
    let onDelete: ([FileNode]) -> Void
    let onCopyToClipboard: ([FileNode]) -> Void
    let onPaste: (FileNode) -> Void
    let onPasteExplicit: (FileNode, [FileNode]) -> Void
    
    var body: some View {
        ZStack {
            Color(NSColor.textBackgroundColor)
            
            if isLoading {
                ProgressView("Loading...")
                    .padding()
            } else if tree.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("Directory is empty or invalid")
                        .foregroundColor(.secondary)
                }
            } else {
                List(tree, children: \.children, selection: $selection) { node in
                    FileRowView(node: node)
                        .tag(node.id)
                        .contextMenu {
                            FileContextMenu(
                                node: node,
                                selection: selection,
                                tree: tree,
                                otherTree: otherTree,
                                otherSelection: otherSelection,
                                onFocus: onFocus,
                                onCopy: onCopy,
                                onDelete: onDelete,
                                onCopyToClipboard: onCopyToClipboard,
                                onPaste: onPaste,
                                onPasteExplicit: onPasteExplicit
                            )
                        }
                }
                .listStyle(SidebarListStyle())
                .onDrop(of: [.data], isTargeted: nil) { providers in
                    // This is for dropping ONTO THE ENTIRE LIST (root of the pane)
                    // But we want to drop onto individual folders. 
                    // SwiftUI List doesn't make it super easy to drop "onto" a row without complications.
                    // For now, let's stick to the row-level drop.
                    return false
                }
            }
        }
    }
}

struct DifferencesView: View {
    @ObservedObject var syncManager: DocumentSyncManager
    let refreshAction: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Differences Found")
                    .font(.headline)
                Spacer()
                Text("\(syncManager.differences.count) files")
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(syncManager.differences, id: \.id) { difference in
                        DifferenceRow(difference: difference) {
                            Task {
                                await syncManager.syncFile(difference)
                                refreshAction()
                            }
                        }
                        .transition(.slide)
                    }
                }
                .padding()
            }
            .background(.ultraThinMaterial)
        }
    }
}

struct DifferenceRow: View {
    let difference: FileDifference
    let onSync: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            // Icon
            iconForDifference(difference)
                .font(.system(size: 24))
                .foregroundColor(colorForDifference(difference))
                .frame(width: 32)
            
            // File Info
            VStack(alignment: .leading, spacing: 4) {
                let parts = difference.relativePath.split(separator: "/")
                if parts.count > 1 {
                    Text(parts.dropLast().joined(separator: " / "))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Text(parts.last ?? "")
                    .fontWeight(.medium)
                
                Text(difference.description)
                    .font(.caption)
                    .foregroundColor(colorForDifference(difference))
            }
            
            Spacer()
            
            // Sync Action
            Button(action: onSync) {
                HStack {
                    if difference.isSyncing {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    } else {
                        switch difference.action {
                        case .copyToDestination:
                            Label("Copy to Dest", systemImage: "arrow.right.circle.fill")
                        case .copyToSource:
                            Label("Copy to Source", systemImage: "arrow.left.circle.fill")
                        }
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(difference.action == .copyToDestination ? .blue : .purple)
            .disabled(difference.isSyncing)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
    
    @ViewBuilder
    private func iconForDifference(_ diff: FileDifference) -> some View {
        switch diff.type {
        case .missingInDestination:
            Image(systemName: "plus.circle.fill")
        case .missingInSource:
            Image(systemName: "plus.circle.fill")
        case .differentDates:
            Image(systemName: "arrow.triangle.2.circlepath")
        }
    }
    
    private func colorForDifference(_ diff: FileDifference) -> Color {
        switch diff.type {
        case .missingInDestination:
            return .blue
        case .missingInSource:
            return .purple
        case .differentDates:
            return .orange
        }
    }
}

#Preview {
    ContentView()
}


struct FileContextMenu: View {
    let node: FileNode
    let selection: Set<String>
    let tree: [FileNode]
    let otherTree: [FileNode]
    let otherSelection: Set<String>
    let onFocus: (FileNode) -> Void
    let onCopy: ([FileNode]) -> Void
    let onDelete: ([FileNode]) -> Void
    let onCopyToClipboard: ([FileNode]) -> Void
    let onPaste: (FileNode) -> Void
    let onPasteExplicit: (FileNode, [FileNode]) -> Void
    
    var body: some View {
        let selectedNodes = tree.findNodes(at: selection.isEmpty ? Set([node.id]) : selection)
        let count = selectedNodes.count
        
        Group {
            if count == 1, let singleNode = selectedNodes.first, singleNode.isDirectory {
                Button(action: { onFocus(singleNode) }) {
                    Label("Sync only this folder", systemImage: "scope")
                }
                Divider()
            }
            
            Button(action: { onCopy(selectedNodes) }) {
                Label(count > 1 ? "Copy \(count) items to other provider" : "Copy to other provider", systemImage: "square.and.arrow.trailing")
            }
            
            Divider()
            
            Button(action: { onCopyToClipboard(selectedNodes) }) {
                Label(count > 1 ? "Copy \(count) items" : "Copy", systemImage: "doc.on.doc")
            }
            
            if node.isDirectory {
                Button(action: { onPaste(node) }) {
                    Label("Paste here", systemImage: "doc.on.clipboard")
                }
                
                if !otherSelection.isEmpty {
                    let otherSelectedNodes = otherTree.findNodes(at: otherSelection)
                    Button(action: { onPasteExplicit(node, otherSelectedNodes) }) {
                        Label(otherSelectedNodes.count > 1 ? "Copy \(otherSelectedNodes.count) items from other pane" : "Copy '\(otherSelectedNodes.first?.name ?? "")' from other pane", systemImage: "arrow.right.to.line.compact")
                    }
                }
            }
            
            Divider()
            
            Button(role: .destructive, action: { onDelete(selectedNodes) }) {
                Label(count > 1 ? "Delete \(count) items" : "Delete", systemImage: "trash")
            }
        }
    }
}

struct FileRowView: View {
    let node: FileNode
    
    var body: some View {
        HStack {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc.text.fill")
                .foregroundColor(node.isDirectory ? .blue : .secondary)
            Text(node.name)
                .font(.system(.body, design: .rounded))
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}