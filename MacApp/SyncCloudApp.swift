import SwiftUI
import Sync
import Events
import AppIntents

// Keep an explicit AppIntents symbol reference so metadata extraction sees the framework dependency.
private let _syncCloudAppIntentsDependency: Any.Type = (any AppIntent).self

@main
/// The main entry point for the SyncCloud macOS application.
/// Manages the lifecycle of `FileSyncManager` and configures the root `ContentView`.
/// Integrated with `SyncCloudAppDelegate` for app-level guards and termination handling.
struct SyncCloudApp: App {
    @NSApplicationDelegateAdaptor(SyncCloudAppDelegate.self) var appDelegate
    @StateObject private var syncManager = FileSyncManager()
    
    private var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    
    var body: some Scene {
        WindowGroup {
            if isRunningUnitTests {
                Color.clear
            } else {
                ContentView(syncManager: syncManager)
                    .environmentObject(Logger.shared)
                    .onAppear {
                        appDelegate.syncManager = syncManager
                    }
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
    /// Reference to the shared sync manager for checking active operations.
    var syncManager: FileSyncManager?
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager = syncManager, manager.activeFileOperationsCount > 0 else {
            return .terminateNow
        }
        
        let alert = NSAlert()
        alert.messageText = "File Operations in Progress"
        alert.informativeText = "Quitting now may cause data corruption or partial synchronization. Are you sure you want to quit?"
        alert.addButton(withTitle: "Wait")
        alert.addButton(withTitle: "Quit Anyway")
        alert.alertStyle = .warning
        
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            return .terminateNow
        } else {
            return .terminateCancel
        }
    }
}
