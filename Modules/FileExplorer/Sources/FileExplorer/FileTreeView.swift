import Events
import SwiftUI
import Sync

/// A recursive tree view that displays an interactive file hierarchy for a single CloudProvider pane.
/// It delegates business logic to the injected `FileActionDelegate`.
public struct FileTreeView: View {
    public let tree: [FileNode]
    public let otherTree: [FileNode]
    public let isLoading: Bool
    public let currentPath: String
    
    @Binding public var selection: Set<String>
    @Binding public var expandedPaths: Set<String>
    public let otherSelection: Set<String>
    public let isSource: Bool
    
    // Delegate for all file operations
    public let delegate: FileActionDelegate
    
    // Set of paths that are currently ignored from comparison
    public let ignoredPaths: Set<String>
    
    public init(tree: [FileNode], otherTree: [FileNode], isLoading: Bool, currentPath: String, selection: Binding<Set<String>>, expandedPaths: Binding<Set<String>>, otherSelection: Set<String>, isSource: Bool, delegate: FileActionDelegate, ignoredPaths: Set<String>) {
        self.tree = tree
        self.otherTree = otherTree
        self.isLoading = isLoading
        self.currentPath = currentPath
        self._selection = selection
        self._expandedPaths = expandedPaths
        self.otherSelection = otherSelection
        self.isSource = isSource
        self.delegate = delegate
        self.ignoredPaths = ignoredPaths
    }
    
    private func isPathIgnored(_ node: FileNode) -> Bool {
        return delegate.isNodeIgnored(node, currentPath: currentPath)
    }
    
    public var body: some View {
        ZStack {
            List(selection: $selection) {
                OutlineGroup(tree, children: \.children) { node in
                    FileRowView(node: node, isIgnored: isPathIgnored(node))
                        .tag(node.id)
                        .contextMenu {
                            FileContextMenu(
                                node: node,
                                selection: selection,
                                tree: tree,
                                otherTree: otherTree,
                                otherSelection: otherSelection,
                                isSource: isSource,
                                currentPath: currentPath,
                                delegate: delegate,
                                ignoredPaths: ignoredPaths
                            )
                        }
                }
            }
            .listStyle(SidebarListStyle())
            .contextMenu { emptyAreaContextMenu }
            .onDeleteCommand {
                let selectedNodes = tree.findNodes(at: selection)
                if !selectedNodes.isEmpty {
                    delegate.handleDelete(selectedNodes)
                }
            }
            
            if tree.isEmpty {
                if isLoading {
                    ProgressView("Scanning Directory...")
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("Directory is empty or invalid")
                            .foregroundColor(.secondary)
                    }
                }
            } else if isLoading {
                // Subtle corner overlay when refreshing non-empty tree
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                            .padding(8)
                            .background(.ultraThinMaterial)
                            .cornerRadius(8)
                            .padding(16)
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var emptyAreaContextMenu: some View {
        Button(action: { delegate.handleRefresh() }) {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        Divider()
        Button(action: { delegate.handleCreateFolder(at: currentPath) }) {
            Label("New Folder", systemImage: "folder.badge.plus")
        }
        Button(action: { delegate.handlePasteToPath(currentPath) }) {
            Label("Paste here", systemImage: "doc.on.clipboard")
        }
        Divider()
        Button(action: { delegate.handleGetInfo(for: currentPath) }) {
            Label("Get Info", systemImage: "info.circle")
        }
        Divider()
        Menu("Sort By") {
            Button("Name") { delegate.handleSort(.name) }
            Button("Kind") { delegate.handleSort(.kind) }
            Button("Date Modified") { delegate.handleSort(.dateModified) }
            Button("Size") { delegate.handleSort(.size) }
            Button("Tags") { delegate.handleSort(.tags) }
        }
    }
}

/// Dynamically generated context menu for file operations bounding the selected node and the overarching selection
/// Adapts its available buttons depending on whether a single file, a batch of files, or a folder was right-clicked.
struct FileContextMenu: View {
    let node: FileNode
    let selection: Set<String>
    let tree: [FileNode]
    let otherTree: [FileNode]
    let otherSelection: Set<String>
    let isSource: Bool
    let currentPath: String
    let delegate: FileActionDelegate
    let ignoredPaths: Set<String>
    
    static func resolvedSelection(node: FileNode, selection: Set<String>, tree: [FileNode]) -> [FileNode] {
        let effectiveSelection: Set<String>
        if selection.isEmpty {
            effectiveSelection = [node.id]
        } else if selection.contains(node.id) {
            effectiveSelection = selection
        } else {
            effectiveSelection = [node.id]
        }
        return tree.findNodes(at: effectiveSelection)
    }
    
    var body: some View {
        let selectedNodes = Self.resolvedSelection(node: node, selection: selection, tree: tree)
        let count = selectedNodes.count
        
        Group {
            Button(action: { delegate.handleRefresh() }) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Divider()
            if count == 1, let singleNode = selectedNodes.first {
                Button(action: { delegate.handleGetInfo(for: singleNode.id) }) {
                    Label("Get Info", systemImage: "info.circle")
                }
                Divider()
                Button(action: { delegate.handleRename(singleNode) }) {
                    Label("Rename", systemImage: "pencil")
                }
                
                if singleNode.isDirectory {
                    Button(action: { delegate.handleCreateFolder(at: singleNode.id) }) {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    Divider()
                    Button(action: { delegate.handleFocus(singleNode) }) {
                        // Better clarifies the function which isolates a specific folder mapping
                        Label("Compare only this folder", systemImage: "scope")
                    }
                }
            }
            
            let allIgnored = selectedNodes.allSatisfy { n in 
                delegate.isNodeIgnored(n, currentPath: currentPath)
            }
            Button(action: { delegate.handleIgnore(selectedNodes) }) {
                Label(allIgnored ? "Include in comparison" : "Ignore in comparison", systemImage: allIgnored ? "eye" : "eye.slash")
            }
            Divider()
            
            Button(action: { delegate.handleCopy(selectedNodes) }) {
                let targetPane = isSource ? "Destination" : "Source"
                Label(count > 1 ? "Copy \(count) items to \(targetPane)" : "Copy to \(targetPane)", systemImage: "arrow.right.doc.on.clipboard")
            }
            
            Button(action: { delegate.handleMove(selectedNodes) }) {
                let targetPane = isSource ? "Destination" : "Source"
                Label(count > 1 ? "Move \(count) items to \(targetPane)" : "Move to \(targetPane)", systemImage: "arrow.right.square")
            }
            
            Divider()
            
            Button(action: { delegate.handleCopyToClipboard(selectedNodes, isCut: true) }) {
                Label(count > 1 ? "Cut \(count) items" : "Cut", systemImage: "scissors")
            }
            
            Button(action: { delegate.handleCopyToClipboard(selectedNodes, isCut: false) }) {
                Label(count > 1 ? "Copy \(count) items" : "Copy", systemImage: "doc.on.doc")
            }
            
            Button(action: { delegate.handlePaste(node) }) {
                Label("Paste here", systemImage: "doc.on.clipboard")
            }
            
            if !otherSelection.isEmpty {
                let otherSelectedNodes = otherTree.findNodes(at: otherSelection)
                if !otherSelectedNodes.isEmpty {
                    Button(action: { delegate.handlePasteExplicit(node, nodes: otherSelectedNodes) }) {
                        if otherSelectedNodes.count > 1 {
                            Label("Copy \(otherSelectedNodes.count) items from other pane", systemImage: "arrow.right.to.line.compact")
                        } else if let first = otherSelectedNodes.first {
                            Label("Copy '\(first.name)' from other pane", systemImage: "arrow.right.to.line.compact")
                        }
                    }
                }
            }
            
            Divider()
            
            Button(role: .destructive, action: { delegate.handleDelete(selectedNodes) }) {
                Label(count > 1 ? "Delete \(count) items" : "Delete", systemImage: "trash")
            }
        }
    }
}

/// Renders a single row representing a file or directory node with its associated system icon.
struct FileRowView: View {
    let node: FileNode
    let isIgnored: Bool
    
    var body: some View {
        HStack {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc.text.fill")
                .foregroundColor(node.isDirectory ? .blue : .secondary)
            Text(node.name)
                .font(.system(.body, design: .rounded))
                .strikethrough(isIgnored, color: .secondary)
                .foregroundColor(isIgnored ? .secondary : .primary)
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
