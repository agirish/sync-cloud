import SwiftUI

/// A recursive tree view that displays an interactive file hierarchy for a single CloudProvider pane.
/// Supports intra/inter-pane drag-and-drop, context menus, and hierarchical selection bindings.
struct FileTreeView: View {
    let tree: [FileNode]
    let otherTree: [FileNode]
    let isLoading: Bool
    let currentPath: String
    
    @Binding var selection: Set<String>
    @Binding var expandedPaths: Set<String>
    let otherSelection: Set<String>
    
    // Callbacks for file operations
    let onFocus: (FileNode) -> Void
    let onCopy: ([FileNode]) -> Void
    let onDelete: ([FileNode]) -> Void
    let onCopyToClipboard: ([FileNode], Bool) -> Void
    let onPaste: (FileNode) -> Void
    let onPasteExplicit: (FileNode, [FileNode]) -> Void
    let onRename: (FileNode) -> Void
    let onCreateFolder: (String) -> Void
    
    var body: some View {
        ZStack {
            Color(NSColor.textBackgroundColor)
                .contextMenu { emptyAreaContextMenu }
            
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
                List(selection: $selection) {
                    ForEach(tree) { node in
                        RecursiveFileNodeView(
                            node: node,
                            selection: $selection,
                            expandedPaths: $expandedPaths,
                            tree: tree,
                            otherTree: otherTree,
                            otherSelection: otherSelection,
                            onFocus: onFocus,
                            onCopy: onCopy,
                            onDelete: onDelete,
                            onCopyToClipboard: onCopyToClipboard,
                            onPaste: onPaste,
                            onPasteExplicit: onPasteExplicit,
                            onRename: onRename,
                            onCreateFolder: onCreateFolder
                        )
                    }
                }
                .listStyle(SidebarListStyle())
                .contextMenu { emptyAreaContextMenu }
                .onDrop(of: [.data], isTargeted: nil) { providers in
                    // Dropping onto the root of the pane is unsupported right now
                    return false
                }
            }
        }
    }
    
    @ViewBuilder
    private var emptyAreaContextMenu: some View {
        Button(action: { onCreateFolder(currentPath) }) {
            Label("New Folder", systemImage: "folder.badge.plus")
        }
        Divider()
        Menu("Sort By") {
            Button("Name") {}
            Button("Kind") {}
            Button("Date Modified") {}
            Button("Size") {}
            Button("Tags") {}
        }
        Button(action: { }) {
            Label("Show View Options", systemImage: "gearshape")
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
    let onFocus: (FileNode) -> Void
    let onCopy: ([FileNode]) -> Void
    let onDelete: ([FileNode]) -> Void
    let onCopyToClipboard: ([FileNode], Bool) -> Void
    let onPaste: (FileNode) -> Void
    let onPasteExplicit: (FileNode, [FileNode]) -> Void
    let onRename: (FileNode) -> Void
    let onCreateFolder: (String) -> Void
    
    var body: some View {
        let selectedNodes = tree.findNodes(at: selection.isEmpty ? Set([node.id]) : selection)
        let count = selectedNodes.count
        
        Group {
            if count == 1, let singleNode = selectedNodes.first {
                Button(action: { onRename(singleNode) }) {
                    Label("Rename", systemImage: "pencil")
                }
                
                if singleNode.isDirectory {
                    Button(action: { onCreateFolder(singleNode.id) }) {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    Divider()
                    Button(action: { onFocus(singleNode) }) {
                        // Better clarifies the function which isolates a specific folder mapping
                        Label("Compare only this folder", systemImage: "scope")
                    }
                }
                Divider()
            }
            
            Button(action: { onCopy(selectedNodes) }) {
                Label(count > 1 ? "Copy \(count) items to other provider" : "Copy to other provider", systemImage: "square.and.arrow.trailing")
            }
            
            Divider()
            
            Button(action: { onCopyToClipboard(selectedNodes, true) }) {
                Label(count > 1 ? "Cut \(count) items" : "Cut", systemImage: "scissors")
            }
            
            Button(action: { onCopyToClipboard(selectedNodes, false) }) {
                Label(count > 1 ? "Copy \(count) items" : "Copy", systemImage: "doc.on.doc")
            }
            
            if node.isDirectory {
                Button(action: { onPaste(node) }) {
                    Label("Paste here", systemImage: "doc.on.clipboard")
                }
                
                if !otherSelection.isEmpty {
                    let otherSelectedNodes = otherTree.findNodes(at: otherSelection)
                    if !otherSelectedNodes.isEmpty {
                        Button(action: { onPasteExplicit(node, otherSelectedNodes) }) {
                            if otherSelectedNodes.count > 1 {
                                Label("Copy \(otherSelectedNodes.count) items from other pane", systemImage: "arrow.right.to.line.compact")
                            } else if let first = otherSelectedNodes.first {
                                Label("Copy '\(first.name)' from other pane", systemImage: "arrow.right.to.line.compact")
                            }
                        }
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
/// Delegates operation requests (like Cut, Copy, Paste, Delete, Rename) up the chain to the parent environment via callbacks.
struct RecursiveFileNodeView: View {
    let node: FileNode
    @Binding var selection: Set<String>
    @Binding var expandedPaths: Set<String>
    let tree: [FileNode]
    let otherTree: [FileNode]
    let otherSelection: Set<String>
    let onFocus: (FileNode) -> Void
    let onCopy: ([FileNode]) -> Void
    let onDelete: ([FileNode]) -> Void
    let onCopyToClipboard: ([FileNode], Bool) -> Void
    let onPaste: (FileNode) -> Void
    let onPasteExplicit: (FileNode, [FileNode]) -> Void
    let onRename: (FileNode) -> Void
    let onCreateFolder: (String) -> Void
    
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
            onFocus: onFocus,
            onCopy: onCopy,
            onDelete: onDelete,
            onCopyToClipboard: onCopyToClipboard,
            onPaste: onPaste,
            onPasteExplicit: onPasteExplicit,
            onRename: onRename,
            onCreateFolder: onCreateFolder
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
                        onFocus: onFocus,
                        onCopy: onCopy,
                        onDelete: onDelete,
                        onCopyToClipboard: onCopyToClipboard,
                        onPaste: onPaste,
                        onPasteExplicit: onPasteExplicit,
                        onRename: onRename,
                        onCreateFolder: onCreateFolder
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
