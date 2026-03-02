import SwiftUI

@main
/// The main entry point for the SyncCloud macOS application.
/// Configures the root `ContentView` and injects the global `Logger` environment object.
struct SyncCloudApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(Logger.shared)
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