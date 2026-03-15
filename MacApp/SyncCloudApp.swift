import SwiftUI
import Sync
import Events
import Settings
import AppIntents

// Keep an explicit AppIntents symbol reference so metadata extraction sees the framework dependency.
private let _syncCloudAppIntentsDependency: Any.Type = (any AppIntent).self

@main
/// The main entry point for the SyncCloud macOS application.
/// Manages the lifecycle of `FileSyncManager` and configures the root `ContentView`.
/// Integrated with `SyncCloudAppDelegate` for app-level guards and termination handling.
struct SyncCloudApp: App {
    @NSApplicationDelegateAdaptor(SyncCloudAppDelegate.self) var appDelegate
    @StateObject private var syncManager: FileSyncManager
    @StateObject private var settings: SettingsManager
    private let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    
    init() {
        let manager = FileSyncManager()
        _syncManager = StateObject(wrappedValue: manager)
        _settings = StateObject(wrappedValue: SettingsManager())
        // CRITICAL: Link the manager to the delegate so the termination guard is active.
        // Use both instance and static ref so the delegate always has the manager on every quit attempt.
        appDelegate.syncManager = manager
        SyncCloudAppDelegate.sharedSyncManager = manager
    }
    
    var body: some Scene {
        WindowGroup {
            if isRunningTests {
                Color.clear
                    .frame(width: 1, height: 1)
            } else {
                ContentView(syncManager: syncManager)
                    .environmentObject(Logger.shared)
                    .environmentObject(settings)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        
        Window("Activity Log", id: "activity-log") {
            if isRunningTests {
                Color.clear
            } else {
                LogViewer()
                    .environmentObject(Logger.shared)
            }
        }
        .windowResizability(.contentMinSize)
        
        Window("Settings", id: "settings") {
            if isRunningTests {
                Color.clear
            } else {
                SettingsView()
                    .environmentObject(settings)
            }
        }
        .windowResizability(.contentMinSize)
    }
}

/// A custom app delegate for SyncCloud to handle macOS system events.
/// Implements `applicationShouldTerminate` to prevent accidental quitting during active file operations.
class SyncCloudAppDelegate: NSObject, NSApplicationDelegate {
    /// Reference to the shared sync manager for checking active operations.
    var syncManager: FileSyncManager?
    
    /// Static reference so the delegate always has the current manager even if the App struct is recreated.
    static weak var sharedSyncManager: FileSyncManager?
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let manager = syncManager ?? Self.sharedSyncManager
        guard let manager, manager.activeFileOperationsCount > 0 else {
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
