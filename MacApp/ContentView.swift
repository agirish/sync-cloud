import SwiftUI

struct ContentView: View {
    @StateObject private var syncManager = DocumentSyncManager()
    @StateObject private var settings = SettingsManager()
    @State private var sourceProviderId: String = "iCloud"
    @State private var destinationProviderId: String = "iCloud"
    @State private var isScanning = false
    
    @State private var selectedSourcePath: String?
    @State private var selectedDestinationPath: String?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "cloud.fill")
                    .font(.title)
                    .foregroundColor(.blue)
                Text("SyncCloud")
                    .font(.title)
                    .fontWeight(.bold)
                Spacer()
                Button(action: { showingSettings = true }) {
                    Image(systemName: "gear")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .environmentObject(settings)
            }
            
            // Panes
            HSplitView {
                // Left Pane
                VStack(spacing: 0) {
                    providerPicker(selection: $sourceProviderId, label: "Source")
                    if let provider = settings.availableProviders.first(where: { $0.id == sourceProviderId }) {
                        let path = settings.path(for: provider.id)
                        Text(path)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.bottom, 4)
                    }
                    FileTreeView(tree: syncManager.sourceTree, isLoading: syncManager.isLoadingSourceTree, selection: $selectedSourcePath)
                }
                .frame(minWidth: 250)
                
                // Right Pane
                VStack(spacing: 0) {
                    providerPicker(selection: $destinationProviderId, label: "Destination")
                    if let provider = settings.availableProviders.first(where: { $0.id == destinationProviderId }) {
                        let path = settings.path(for: provider.id)
                        Text(path)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.bottom, 4)
                    }
                    FileTreeView(tree: syncManager.destinationTree, isLoading: syncManager.isLoadingDestinationTree, selection: $selectedDestinationPath)
                }
                .frame(minWidth: 250)
            }
            
            Divider()
            
            // Bottom Action Area
            VStack(spacing: 15) {
                Button(action: {
                    guard let sourceProvider = settings.availableProviders.first(where: { $0.id == sourceProviderId }),
                          let destProvider = settings.availableProviders.first(where: { $0.id == destinationProviderId }) else { return }
                          
                    let sourceToScan = selectedSourcePath ?? settings.path(for: sourceProvider.id)
                    let destToScan = selectedDestinationPath ?? settings.path(for: destProvider.id)
                    Task {
                        await syncManager.scanDirectories(
                            source: sourceProvider, sourcePath: sourceToScan,
                            destination: destProvider, destinationPath: destToScan
                        )
                    }
                }) {
                    HStack {
                        if isScanning {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isScanning ? "Scanning..." : "Scan for Differences")
                                .fontWeight(.bold)
                            if selectedSourcePath != nil || selectedDestinationPath != nil {
                                Text("Selected sub-directories")
                                    .font(.caption)
                                    .opacity(0.8)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isScanning)
                
                // Results Area
                if !syncManager.differences.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Differences Found:")
                                .font(.headline)
                            Spacer()
                            Text("\(syncManager.differences.count) files")
                                .foregroundColor(.secondary)
                        }
                        
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(syncManager.differences, id: \.id) { difference in
                                    DifferenceRow(difference: difference) {
                                        Task {
                                            await syncManager.syncFile(difference)
                                            loadTrees()
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 200)
                    }
                } else if syncManager.hasScanned {
                    HStack {
                        Image(systemName: "checkmark.circle")
                            .foregroundColor(.green)
                        Text("Directories are in sync!")
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 5)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 800, minHeight: 600)
        .onReceive(syncManager.$isScanning) { scanning in
            isScanning = scanning
        }
        .onAppear {
            if let first = settings.availableProviders.first?.id {
                sourceProviderId = first
                destinationProviderId = settings.availableProviders.dropFirst().first?.id ?? first
            }
            loadTrees()
        }
        .onChange(of: sourceProviderId) { _ in
            selectedSourcePath = nil
            Task { await syncManager.loadSourceTree(path: settings.path(for: sourceProviderId)) }
        }
        .onChange(of: destinationProviderId) { _ in
            selectedDestinationPath = nil
            Task { await syncManager.loadDestinationTree(path: settings.path(for: destinationProviderId)) }
        }
        .onReceive(settings.objectWillChange) { _ in
            // Reload trees if settings change
            loadTrees()
        }
    }
    
    @State private var showingSettings = false
    
    private func loadTrees() {
        Task {
            await syncManager.loadSourceTree(path: settings.path(for: sourceProviderId))
            await syncManager.loadDestinationTree(path: settings.path(for: destinationProviderId))
        }
    }
    
    private func providerPicker(selection: Binding<String>, label: String) -> some View {
        HStack {
            Text("\(label):")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Picker("", selection: selection) {
                ForEach(settings.availableProviders) { provider in
                    HStack {
                        Image(provider.imageName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                        Text(provider.displayName)
                    }
                    .tag(provider.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            Spacer()
        }
        .padding([.horizontal, .top])
        .background(Color(NSColor.controlBackgroundColor))
    }
}

struct FileTreeView: View {
    let tree: [FileNode]
    let isLoading: Bool
    @Binding var selection: String?
    
    var body: some View {
        VStack {
            if isLoading {
                ProgressView("Loading directory...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tree.isEmpty {
                Text("Directory is empty or invalid")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(tree, children: \.children, selection: $selection) { node in
                    HStack {
                        Image(systemName: node.isDirectory ? "folder.fill" : "doc.text")
                            .foregroundColor(node.isDirectory ? .blue : .primary)
                        Text(node.name)
                    }
                }
                .listStyle(SidebarListStyle())
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }
}

struct DifferenceRow: View {
    let difference: FileDifference
    let onSync: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(difference.relativePath)
                    .fontWeight(.medium)
                Text(difference.description)
                    .font(.caption)
                    .foregroundColor(colorForDescription(difference))
            }
            
            Spacer()
            
            Button {
                onSync()
            } label: {
                HStack {
                    switch difference.action {
                    case .copyToDestination:
                        Text("Copy →")
                    case .copyToSource:
                        Text("← Copy")
                    }
                }
            }
            .buttonStyle(.bordered)
            .tint(difference.action == .copyToDestination ? .blue : .purple)
            .disabled(difference.isSyncing)
            
            if difference.isSyncing {
                ProgressView()
                    .scaleEffect(0.5)
            }
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(8)
    }
    
    private func colorForDescription(_ diff: FileDifference) -> Color {
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