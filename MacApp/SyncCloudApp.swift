import SwiftUI
import Sync
import Events

@main
/// The main entry point for the SyncCloud macOS application.
/// Configures the root `ContentView` and injects the global `Logger` environment object.
struct SyncCloudApp: App {
    @NSApplicationDelegateAdaptor(SyncCloudAppDelegate.self) var appDelegate
    @StateObject private var syncManager = FileSyncManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView(syncManager: syncManager)
                .environmentObject(Logger.shared)
                .onAppear {
                    appDelegate.syncManager = syncManager
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        
        Window("Activity Log", id: "activity-log") {
            LogViewer()
                .environmentObject(Logger.shared)
        }
        .windowResizability(.contentMinSize)
    }
} 