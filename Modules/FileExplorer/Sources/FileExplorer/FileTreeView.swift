import Events
import SwiftUI
import Sync

/// A recursive tree view that displays an interactive file hierarchy for a single CloudProvider pane.
/// It delegates business logic (drag-and-drop, context menus) to the injected `FileActionHandler` closures.
public struct FileTreeView: View {
    public let tree: [FileNode]
    public let otherTree: [FileNode]
    public let isLoading: Bool
    public let currentPath: String
    
    @Binding public var selection: Set<String>
    @Binding public var expandedPaths: Set<String>
    public let otherSelection: Set<String>
    
    // Delegate for all file operations
    public let delegate: FileActionDelegate
    
    public init(tree: [FileNode], otherTree: [FileNode], isLoading: Bool, currentPath: String, selection: Binding<Set<String>>, expandedPaths: Binding<Set<String>>, otherSelection: Set<String>, delegate: FileActionDelegate) {
        self.tree = tree
        self.otherTree = otherTree
        self.isLoading = isLoading
        self.currentPath = currentPath
        self._selection = selection
        self._expandedPaths = expandedPaths
        self.otherSelection = otherSelection
        self.delegate = delegate
    }
    
    public var body: some View {
        ZStack {
            List(selection: $selection) {
                ForEach(tree) { node in
                    RecursiveFileNodeView(
                        node: node,
                        selection: $selection,
                        expandedPaths: $expandedPaths,
                        tree: tree,
                        otherTree: otherTree,
                        otherSelection: otherSelection,
                        delegate: delegate
                    )
                }
            }
            .listStyle(SidebarListStyle())
            .contextMenu { emptyAreaContextMenu }
            
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
    let delegate: FileActionDelegate
    
    var body: some View {
        let selectedNodes = tree.findNodes(at: selection.isEmpty ? Set([node.id]) : selection)
        let count = selectedNodes.count
        
        Group {
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
                Divider()
            }
            
            Button(action: { delegate.handleCopy(selectedNodes) }) {
                Label(count > 1 ? "Copy \(count) items to other provider" : "Copy to other provider", systemImage: "square.and.arrow.trailing")
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

/// Recursively evaluates and creates `DisclosureGroup` lists for deep directory views.
/// Delegates operation requests (like Cut, Copy, Paste, Delete, Rename) to the injected `FileActionDelegate`.
struct RecursiveFileNodeView: View {
    let node: FileNode
    @Binding var selection: Set<String>
    @Binding var expandedPaths: Set<String>
    let tree: [FileNode]
    let otherTree: [FileNode]
    let otherSelection: Set<String>
    let delegate: FileActionDelegate
    
    var isExpanded: Binding<Bool> {
        Binding(
            get: { expandedPaths.contains(node.id) },
            set: { isExpanding in
                if isExpanding {
                    expandedPaths.insert(node.id)
                } else {
                    expandedPaths.remove(node.id)
                }
            }
        )
    }
    
    var nodeContextMenu: some View {
        FileContextMenu(
            node: node,
            selection: selection,
            tree: tree,
            otherTree: otherTree,
            otherSelection: otherSelection,
            delegate: delegate
        )
    }
    
    var body: some View {
        if let children = node.children, !children.isEmpty {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(children) { child in
                    RecursiveFileNodeView(
                        node: child,
                        selection: $selection,
                        expandedPaths: $expandedPaths,
                        tree: tree,
                        otherTree: otherTree,
                        otherSelection: otherSelection,
                        delegate: delegate
                    )
                }
            } label: {
                FileRowView(node: node).tag(node.id)
            }
            .contextMenu { nodeContextMenu }
        } else {
            // Leaf node or empty directory
            FileRowView(node: node).tag(node.id)
                .contextMenu { nodeContextMenu }
        }
    }
}
