import SwiftUI

/// A horizontal focus and history control bar spanning the top of the main file viewer.
/// Provides back/forward directory traversal and context on which relative folder is currently targeted.
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
