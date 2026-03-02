import SwiftUI

/// A SwiftUI ViewModifier that attaches application-wide filesystem alerts (rename, create folder, delete) directly to the layout hierarchy.
struct FileOperationAlerts: ViewModifier {
    @ObservedObject var syncManager: DocumentSyncManager
    let refreshAction: () -> Void
    
    @Binding var renamingNode: FileNode?
    @Binding var newName: String
    @Binding var creatingFolderInPath: String?
    @Binding var newFolderName: String
    @Binding var nodesToDelete: [FileNode]?
    
    func body(content: Content) -> some View {
        content
            .alert("Rename Item", isPresented: Binding(
                get: { renamingNode != nil },
                set: { if !$0 { renamingNode = nil } }
            )) {
                TextField("New name", text: $newName)
                Button("Cancel", role: .cancel) { }
                Button("Rename") {
                    if let node = renamingNode, !newName.isEmpty {
                        Task {
                            await syncManager.renameItem(at: node.id, to: newName)
                            refreshAction()
                        }
                    }
                }
            }
            .alert("New Folder", isPresented: Binding(
                get: { creatingFolderInPath != nil },
                set: { if !$0 { creatingFolderInPath = nil } }
            )) {
                TextField("Folder name", text: $newFolderName)
                Button("Cancel", role: .cancel) { }
                Button("Create") {
                    if let path = creatingFolderInPath, !newFolderName.isEmpty {
                        Task {
                            await syncManager.createFolder(named: newFolderName, in: path)
                            refreshAction()
                        }
                    }
                }
            }
            .alert("Confirm Deletion", isPresented: Binding(
                get: { nodesToDelete != nil },
                set: { if !$0 { nodesToDelete = nil } }
            )) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    if let nodes = nodesToDelete {
                        deleteItems(nodes)
                    }
                }
            } message: {
                if let nodes = nodesToDelete {
                    if nodes.count == 1, let first = nodes.first {
                        Text("Are you sure you want to delete '\(first.name)'?")
                    } else {
                        Text("Are you sure you want to delete \(nodes.count) items?")
                    }
                }
            }
    }
    
    /// Executes the deletion of the selected node targets using the global sync manager.
    /// - Parameter nodes: The items queued for imminent destruction.
    private func deleteItems(_ nodes: [FileNode]) {
        Task {
            await syncManager.deleteItems(at: nodes.map { $0.id })
            refreshAction()
        }
    }
}
