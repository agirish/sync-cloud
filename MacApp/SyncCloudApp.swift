import SwiftUI
import Sync
import Events

@main
/// The main entry point for the SyncCloud macOS application.
/// Manages the lifecycle of `FileSyncManager` and configures the root `ContentView`.
/// Integrated with `SyncCloudAppDelegate` for app-level guards and termination handling.
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

/// A custom app delegate for SyncCloud to handle macOS system events.
/// Implements `applicationShouldTerminate` to prevent accidental quitting during active file operations.
class SyncCloudAppDelegate: NSObject, NSApplicationDelegate {
}