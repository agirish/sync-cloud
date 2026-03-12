import Settings
import FileExplorer
import Events
import SwiftUI
import Sync
import Design

/// Toolbar above the two file panes: back/forward navigation, current folder context, hidden-files toggle.
public struct NavigationToolbar: View {
    @ObservedObject public var syncManager: FileSyncManager
    public let refreshAction: () -> Void
    @AppStorage(LiquidGlass.intensityKey) private var glassIntensity: Double = 0.65
    
    public init(syncManager: FileSyncManager, refreshAction: @escaping () -> Void) {
        self.syncManager = syncManager
        self.refreshAction = refreshAction
    }
    
    public var body: some View {
        HStack {
            HStack(spacing: 8) {
                Button(action: { syncManager.goBack(); refreshAction() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!syncManager.canGoBack)
                .help("Navigate to the previous directory")
                
                Button(action: { syncManager.goForward(); refreshAction() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!syncManager.canGoForward)
                .help("Navigate to the next directory")
            }
            .buttonStyle(.bordered)
            
            Rectangle()
                .fill(.quaternary)
                .frame(width: 1, height: 20)
                .padding(.horizontal, 8)
            
            if !syncManager.leftRelativePath.isEmpty || !syncManager.rightRelativePath.isEmpty {
                HStack {
                    Image(systemName: "scope")
                        .foregroundColor(.accentColor)
                    Text("Focusing on:")
                        .fontWeight(.medium)
                    Text(syncManager.leftRelativePath.isEmpty ? syncManager.rightRelativePath : syncManager.leftRelativePath)
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
                .help("Return to the root directory view")
            } else {
                Text("Viewing All Files (Root)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
            
            Toggle(isOn: $syncManager.showHiddenFiles) {
                Label("Hidden", systemImage: "eye")
            }
            .toggleStyle(.button)
            .help("Toggle visibility of hidden files")
            .onChange(of: syncManager.showHiddenFiles) { _, newValue in
                Logger.shared.info("User toggled hidden files to: \(newValue)")
                refreshAction()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBarStyle(intensity: glassIntensity)
    }
}
