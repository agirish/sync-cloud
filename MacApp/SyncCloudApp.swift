import SwiftUI
import Sync
import Events
import Settings
import Dashboard
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
    /// Drives the in-window settings overlay. Hoisted to App scope so the ⌘, menu command can
    /// open it; ContentView renders the overlay and owns which tab is shown.
    @State private var showSettings = false
    private let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    
    init() {
        let manager = FileSyncManager()
        // The Sync package is UI-free: its seam defaults fail safe (skip collisions, refuse
        // permanent deletes). Wire the real NSAlert-backed prompts here, at the app boundary.
        manager.collisionResolver = { fileName, isMove, isDirectory in
            SyncOperationAlerts.promptForCollision(fileName: fileName, isMove: isMove, isDirectory: isDirectory)
        }
        manager.bulkCollisionResolver = { fileName, isMove, isDirectory in
            SyncOperationAlerts.promptForCollisionWithApplyToAll(fileName: fileName, isMove: isMove, isDirectory: isDirectory)
        }
        manager.permanentDeleteConfirmer = { itemNames in
            SyncOperationAlerts.confirmPermanentDelete(itemNames: itemNames)
        }
        _syncManager = StateObject(wrappedValue: manager)
        // ContentView.onAppear awaits discoverProviders() as part of its bootstrap sequence, so
        // skip the init-triggered scan here to avoid discovering providers twice on launch.
        // overridesDomainName scopes path/name override reads to the app's own defaults
        // domain, so global-domain keys can never masquerade as provider overrides.
        _settings = StateObject(wrappedValue: SettingsManager(
            autoDiscover: false,
            overridesDomainName: Bundle.main.bundleIdentifier ?? SettingsManager.appSuiteName
        ))
        // CRITICAL: Link the manager to the delegate so the termination guard is active.
        appDelegate.adoptSyncManager(manager)
    }
    
    var body: some Scene {
        WindowGroup {
            if isRunningTests {
                Color.clear
                    .frame(width: 1, height: 1)
            } else {
                ContentView(syncManager: syncManager, showSettings: $showSettings)
                    .environmentObject(Logger.shared)
                    .environmentObject(settings)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            // Settings is no longer a separate window (it's an in-window overlay so it floats
            // over the content even in full screen), so re-supply the standard ⌘, menu item
            // that the native Settings scene used to provide.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

        Window("Activity Log", id: "activity-log") {
            if isRunningTests {
                Color.clear
            } else {
                LogViewer()
                    .environmentObject(Logger.shared)
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

    /// Wires the termination guard to `manager`, keeping the first manager when one is already
    /// wired (both instance and static ref, so the guard works on every quit attempt). SwiftUI
    /// may re-run `App.init`, but `@StateObject` keeps only the first manager alive — re-wiring
    /// on a later init would point the quit guard at an orphan whose operation count is always 0.
    func adoptSyncManager(_ manager: FileSyncManager) {
        guard syncManager == nil, Self.sharedSyncManager == nil else { return }
        syncManager = manager
        Self.sharedSyncManager = manager
    }

    /// The pure branch outcome of the quit guard, split out from the NSAlert plumbing so the
    /// decision logic is unit-testable (the alert itself is not). `applicationShouldTerminate`
    /// maps each case to a `TerminateReply`, logging the choice and flushing the log to disk
    /// before any branch that actually quits with operations in flight.
    enum QuitDecision: Equatable {
        /// Nothing is in flight — quit freely, no breadcrumb needed.
        case allowNoActiveOperations
        /// Operations are in flight but the user disabled the warning — quit, but log first.
        case allowWithoutWarning(activeOperations: Int)
        /// Operations are in flight and the warning is enabled — must show the alert.
        case warn(activeOperations: Int)
    }

    /// Pure decision: given the in-flight operation count and the warn-before-quit setting,
    /// which quit path applies. Kept side-effect-free so `SyncCloudTests` can pin the branches
    /// without driving a modal alert.
    static func quitDecision(activeOperations: Int, warnBeforeQuit: Bool) -> QuitDecision {
        guard activeOperations > 0 else { return .allowNoActiveOperations }
        return warnBeforeQuit
            ? .warn(activeOperations: activeOperations)
            : .allowWithoutWarning(activeOperations: activeOperations)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let manager = syncManager ?? Self.sharedSyncManager
        let activeOperations = manager?.activeFileOperationsCount ?? 0
        // Respect the General setting; default to warning when the key was never written.
        let warnBeforeQuit = UserDefaults.standard.object(forKey: GeneralSettings.warnBeforeQuitKey) as? Bool ?? true

        switch Self.quitDecision(activeOperations: activeOperations, warnBeforeQuit: warnBeforeQuit) {
        case .allowNoActiveOperations:
            return .terminateNow

        case .allowWithoutWarning(let count):
            // The quit decision + flush is the single event most correlated with crash-time
            // corruption, so record it and force the buffered lines to disk before we quit.
            Logger.shared.warning("User chose Quit Anyway with \(count) active file operation(s)")
            Logger.shared.flushToDisk()
            return .terminateNow

        case .warn(let count):
            let alert = NSAlert()
            alert.messageText = "File Operations in Progress"
            alert.informativeText = "Quitting now may cause data corruption or partial synchronization. Are you sure you want to quit?"
            alert.addButton(withTitle: "Wait")
            alert.addButton(withTitle: "Quit Anyway")
            alert.alertStyle = .warning

            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                Logger.shared.warning("User chose Quit Anyway with \(count) active file operation(s)")
                Logger.shared.flushToDisk()
                return .terminateNow
            } else {
                Logger.shared.info("User chose Wait with \(count) active file operation(s) in progress")
                return .terminateCancel
            }
        }
    }
}
