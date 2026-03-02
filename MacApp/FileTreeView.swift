import SwiftUI

struct FileTreeView: View {
    let tree: [FileNode]
    let otherTree: [FileNode]
    let isLoading: Bool
    let currentPath: String
    @Binding var selection: Set<String>
    let otherSelection: Set<String>
    let onFocus: (FileNode) -> Void
    let onCopy: ([FileNode]) -> Void
    let onDelete: ([FileNode]) -> Void
    let onCopyToClipboard: ([FileNode]) -> Void
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
                                onPasteExplicit: onPasteExplicit,
                                onRename: onRename,
                                onCreateFolder: onCreateFolder
                            )
                        }
                }
                .listStyle(SidebarListStyle())
                .contextMenu { emptyAreaContextMenu }
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
    
    @ViewBuilder
    private var emptyAreaContextMenu: some View {
        Button(action: { onCreateFolder(currentPath) }) {
            Label("New Folder", systemImage: "folder.badge.plus")
        }
        Divider()
        Button(action: { }) {
            Label("View options...", systemImage: "gearshape")
        }
        Menu("Group By") {
            Button("Name") {}
            Button("Date Modified") {}
            Button("Size") {}
            Button("Kind") {}
        }
    }
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
                        Label("Sync only this folder", systemImage: "scope")
                    }
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
