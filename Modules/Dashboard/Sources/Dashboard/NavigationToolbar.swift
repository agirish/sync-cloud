import Settings
import FileExplorer
import Events
import SwiftUI
import Sync
import Design

/// Toolbar above the two file panes: back/forward navigation and the hidden-files toggle.
/// Folder context lives in each pane's own breadcrumb (`PaneHeader`). Navigation and toggles
/// trigger reloads through the manager itself (`refreshSubject` / `applyFilters()`), so this
/// view takes no refresh callback.
public struct NavigationToolbar: View {
    @ObservedObject public var syncManager: FileSyncManager
    @AppStorage(LiquidGlass.intensityKey) private var glassIntensity: Double = 0.65

    public init(syncManager: FileSyncManager) {
        self.syncManager = syncManager
    }

    public var body: some View {
        HStack {
            HStack(spacing: 8) {
                Button(action: { syncManager.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!syncManager.canGoBack)
                .help("Navigate to the previous directory")

                Button(action: { syncManager.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!syncManager.canGoForward)
                .help("Navigate to the next directory")
            }
            .buttonStyle(.bordered)

            Spacer()


            // No refresh here: raw trees and differences already include hidden entries, and the
            // showHiddenFiles didSet re-filters them in memory via applyFilters().
            Toggle(isOn: $syncManager.showHiddenFiles) {
                Label("Hidden", systemImage: "eye")
            }
            .toggleStyle(.button)
            .help("Toggle visibility of hidden files")
            .onChange(of: syncManager.showHiddenFiles) { _, newValue in
                Logger.shared.info("User toggled hidden files to: \(newValue)")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBarStyle(intensity: glassIntensity)
    }
}
