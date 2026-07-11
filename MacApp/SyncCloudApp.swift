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
    /// The main scene's id. SwiftUI stamps it onto the NSWindow's `identifier`, which is how
    /// the delegate's Dock-reopen hook tells the main window apart from auxiliary scenes
    /// (Activity Log).
    static let mainWindowId = "main"

    @NSApplicationDelegateAdaptor(SyncCloudAppDelegate.self) var appDelegate
    @StateObject private var syncManager: FileSyncManager
    @StateObject private var settings: SettingsManager
    /// Drives the in-window settings overlay. Hoisted to App scope so the ⌘, menu command can
    /// open it; ContentView renders the overlay and owns which tab is shown.
    @State private var showSettings = false
    /// Whether ContentView's once-per-session bootstrap has run. App-owned because a window
    /// close + Dock reopen recreates ContentView (and its @State) while the session — the
    /// shared FileSyncManager, its trees, and mid-session toggles — lives on. Deliberately
    /// @State, not @AppStorage: it must reset on every app launch.
    @State private var hasBootstrappedSession = false
    private let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    
    init() {
        // Apply the persisted log-level gate before anything logs; Settings → Advanced
        // updates both the default and the live gate from then on.
        Logger.shared.minimumLevel = Logger.persistedMinimumLevel()

        let manager = FileSyncManager()
        // The Sync package is UI-free: its seam defaults fail safe (skip collisions, refuse
        // permanent deletes). Wire the real NSAlert-backed prompts here, at the app boundary.
        // Each prompt first consults the user's standing conflict policy (Settings → Sync),
        // re-read per collision so a Settings change applies to the very next conflict;
        // folder collisions always fall through to the prompt (see ConflictPolicy).
        manager.collisionResolver = { collision in
            Self.policyAutoResolution(for: collision)
                ?? SyncOperationAlerts.promptForCollision(collision)
        }
        manager.bulkCollisionResolver = { collision in
            Self.policyAutoResolution(for: collision).map { ($0, false) }
                ?? SyncOperationAlerts.promptForCollisionWithApplyToAll(collision)
        }
        // Copy/move confirmation, gated by Settings → Sync ("Confirm before copying or
        // moving"). Re-read per transfer so a Settings change applies to the very next one.
        manager.transferConfirmer = { summary in
            guard GeneralSettings.shouldConfirmBeforeTransfer() else { return true }
            return SyncOperationAlerts.confirmTransfer(summary)
        }
        manager.permanentDeleteConfirmer = { itemNames in
            SyncOperationAlerts.confirmPermanentDelete(itemNames: itemNames)
        }
        // Destination names the target provider forbids (trailing space/dot on Dropbox,
        // reserved names on OneDrive, …) prompt before any I/O, offering the sanitized name.
        // No standing-policy shortcut here: each violation names a specific item and the
        // wrong answer silently creates an unsyncable local-only duplicate.
        manager.invalidNameResolver = { prompt in
            SyncOperationAlerts.promptForInvalidName(prompt)
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

    /// The Settings conflict policy's answer for a collision, or nil when the policy says ask
    /// (folder collisions always ask — see ConflictPolicy). Shared by both resolver wirings
    /// so the policy check and its log line can't drift between the single and bulk prompts;
    /// reads the persisted policy once per collision so a Settings change applies to the
    /// very next conflict.
    @MainActor
    private static func policyAutoResolution(for collision: FileCollision) -> CollisionResolution? {
        let policy = ConflictPolicy.persisted()
        guard let auto = policy.autoResolution(isDirectory: collision.isDirectory) else { return nil }
        Logger.shared.info("Collision on \"\(collision.fileName)\" auto-resolved by Settings policy: \(policy.displayName)")
        return auto
    }
    
    var body: some Scene {
        // A single-window `Window` scene, not a WindowGroup: two ContentViews would share one
        // FileSyncManager and the App-level showSettings, so a second window re-ran the full
        // bootstrap (redundant discovery + rescan, provider re-selection over live panes) and
        // the settings overlay opened in every window at once. `Window` also removes
        // File ▸ New Window / ⌘N; nothing in `.commands` re-adds it.
        Window("SyncCloud", id: SyncCloudApp.mainWindowId) {
            if isRunningTests {
                Color.clear
                    .frame(width: 1, height: 1)
            } else {
                ContentView(
                    syncManager: syncManager,
                    showSettings: $showSettings,
                    hasBootstrappedSession: $hasBootstrappedSession
                )
                    .environmentObject(Logger.shared)
                    .environmentObject(settings)
            }
        }
        .windowStyle(.hiddenTitleBar)
        // Open at ~85% of the screen (the two-pane + Differences layout needs room); without a
        // defaultSize, `.contentSize` resizability collapsed the first launch to the content's
        // 600pt minimum. `.contentMinSize` keeps that minimum as a floor but lets the window
        // take (and remember) any larger size.
        .defaultSize(
            width: (NSScreen.main?.visibleFrame.width ?? 1600) * 0.85,
            height: (NSScreen.main?.visibleFrame.height ?? 1000) * 0.85
        )
        .windowResizability(.contentMinSize)
        .commands {
            // Settings is no longer a separate window (it's an in-window overlay so it floats
            // over the content even in full screen), so re-supply the standard ⌘, menu item
            // that the native Settings scene used to provide.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            // The discoverability half of the shortcuts story: review-mode keys, the drag
            // move modifier, and ⌥-breadcrumb navigation are otherwise invisible.
            CommandGroup(after: .help) {
                ShortcutsWindowCommand()
            }
        }

        Window("Keyboard Shortcuts", id: "keyboard-shortcuts") {
            ShortcutsReferenceView()
        }
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
    }
}

/// A custom app delegate for SyncCloud to handle macOS system events.
/// Implements `applicationShouldTerminate` to prevent accidental quitting during active file operations.
/// @MainActor because the delegate reads MainActor state (`FileSyncManager.activeFileOperationsCount`)
/// — AppKit only ever calls it on the main thread, but without the annotation Swift 6 strict
/// checking would reject those reads.
@MainActor
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
    /// without driving a modal alert. `nonisolated`: pure over its arguments, so the tests
    /// don't have to hop to the main actor just because the class is isolated.
    nonisolated static func quitDecision(activeOperations: Int, warnBeforeQuit: Bool) -> QuitDecision {
        guard activeOperations > 0 else { return .allowNoActiveOperations }
        return warnBeforeQuit
            ? .warn(activeOperations: activeOperations)
            : .allowWithoutWarning(activeOperations: activeOperations)
    }

    /// Dock click (or any app reactivation) with no visible windows must bring the main
    /// window back — with a single `Window` scene there is no File ▸ New Window fallback.
    /// SwiftUI keeps a closed scene window alive rather than releasing it, so ordering the
    /// stored window front restores it with all its state; the identifier match keeps an
    /// auxiliary scene (Activity Log) from being resurrected as "the app". If the window is
    /// ever genuinely gone, fall through to the default reopen handling instead of eating
    /// the event.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        guard let mainWindow = sender.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix(SyncCloudApp.mainWindowId) == true
        }) else { return true }
        mainWindow.makeKeyAndOrderFront(nil)
        return false
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
