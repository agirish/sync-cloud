import SwiftUI
import Sync
import Events
import Settings
import Dashboard
import FileExplorer
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
    /// Drives the in-window Help overlay. Hoisted to App scope so the Help ▸ SyncCloud Help (⌘?)
    /// menu command can open it; ContentView renders the overlay and owns dismissal.
    @State private var showHelp = false
    /// Whether ContentView's once-per-session bootstrap has run. App-owned because a window
    /// close + Dock reopen recreates ContentView (and its @State) while the session — the
    /// shared FileSyncManager, its trees, and mid-session toggles — lives on. Deliberately
    /// @State, not @AppStorage: it must reset on every app launch.
    @State private var hasBootstrappedSession = false
    /// The active duplicate-copy review (Tidy's "Compare copies" hand-off). App-owned for the
    /// same reason as `hasBootstrappedSession`: its provider pins live in @AppStorage and the
    /// FileSyncManager's pane focus survives a window close + Dock reopen, so the review context
    /// — the banner, the trash-right action, and above all the restore snapshot that un-pins the
    /// panes — must survive it too, or the panes stay pinned with no way back. @State (never
    /// persisted): a review never outlives the app session.
    @State private var duplicateReview: DuplicateCompareContext? = nil
    /// Guided-review session state. App-owned so a window close + Dock reopen mid-review (or
    /// mid-decision: an in-flight copy's outcome lands in this store) doesn't drop the session
    /// while the underlying comparison lives on in the shared FileSyncManager.
    @StateObject private var reviewStore = ReviewSessionStore()
    /// The first-run welcome gate, shared with ContentView by key. Held here too so the Help ▸
    /// Welcome to SyncCloud command can flip it back to `false` and re-summon the tour: ContentView's
    /// `@AppStorage` on the same key observes the write and re-renders the overlay.
    @AppStorage(FirstRunWelcome.hasSeenDefaultsKey) private var hasSeenFirstRunWelcome = false
    /// Whether the welcome tour has been dismissed this session. App-owned (like hasBootstrappedSession)
    /// so a window close + Dock reopen doesn't resurrect it; the Help command resets it to re-summon
    /// the tour even after the user dismissed it earlier this session. @State (never persisted): a
    /// dismissal only lasts the session unless "Don't show this again" also set the persisted flag.
    @State private var welcomeDismissedThisSession = false
    private let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    
    init() {
        // Apply the persisted log-level gate before anything logs; Settings → Advanced
        // updates both the default and the live gate from then on. (The launch breadcrumb lives in
        // the delegate's applicationDidFinishLaunching, which fires exactly once — App.init can be
        // re-run by SwiftUI, which would otherwise emit a duplicate "launched" line each time.)
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
        // Cloud (Claude) Filing spend guardrail: before a cloud classify commits, show the pre-flight
        // cost estimate and this month's budget, and let the user (or the monthly cap) decline. A
        // decline falls back to the free on-device suggestions. Only consulted when cloud Filing is
        // actually on, so it's a no-op for the common on-device path.
        manager.filingCloudSpendConfirmer = { preflight in
            SyncOperationAlerts.promptForFilingSpend(preflight)
        }
        // Destination names the target provider forbids (trailing space/dot on Dropbox,
        // reserved names on OneDrive, …) prompt before any I/O, offering the sanitized name.
        // No standing-policy shortcut here: each violation names a specific item and the
        // wrong answer silently creates an unsyncable local-only duplicate.
        manager.invalidNameResolver = { prompt in
            SyncOperationAlerts.promptForInvalidName(prompt)
        }
        // Filing (F2): on-device content signals for files whose name says nothing. Gated by the
        // read-contents Settings toggle; runs only on the no-confident-home tail.
        manager.filingContentExtractor = { path in
            await ContentSignalExtractor.tokens(forFileAt: path)
        }
        // Filing (AI): reason about the folder taxonomy + document text to pick a home, overriding
        // keyword guesses. Hybrid backend — opt-in cloud (Claude) as primary when enabled with a
        // key, else the on-device Apple Foundation Models model. Always injected so the cloud toggle
        // and key can change at runtime; the routing closure resolves the backend per scan.
        manager.filingClassifier = { taxonomy, files in
            if UserDefaults.standard.bool(forKey: FileSyncManager.usesCloudDefaultsKey), AnthropicKeychain.hasKey {
                if let cloud = await CloudFilingClassifier.classify(taxonomyFolders: taxonomy, files: files) {
                    return cloud   // cloud succeeded (even if it placed nothing)
                }
                // hard failure (no key / network / non-200) → fall back to on-device
            }
            if OnDeviceFilingClassifier.isAvailable {
                return await OnDeviceFilingClassifier.classify(taxonomyFolders: taxonomy, files: files)
            }
            return [:]
        }
        manager.filingSnippetExtractor = { path in
            await ContentSignalExtractor.snippet(forFileAt: path)
        }
        if OnDeviceFilingClassifier.isAvailable {
            manager.filingClassifierPrewarm = { OnDeviceFilingClassifier.prewarm() }
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
                    showHelp: $showHelp,
                    hasBootstrappedSession: $hasBootstrappedSession,
                    welcomeDismissedThisSession: $welcomeDismissedThisSession,
                    duplicateReview: $duplicateReview,
                    reviewStore: reviewStore
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
            // Replace the whole Help menu. AppKit's default `.help` group is just the
            // `showHelp:` item (and its search field), which — with no registered Help Book —
            // answers "Help isn't available for SyncCloud." Swapping the group lets our own
            // SyncCloud Help overlay take that slot, and hosts the rest of the Help entries.
            CommandGroup(replacing: .help) {
                // The real front door: open the in-window Help overlay. Close Settings first so
                // the two overlays never stack (ContentView also enforces this).
                Button("SyncCloud Help") {
                    showSettings = false
                    showHelp = true
                }
                .keyboardShortcut("?", modifiers: .command)

                // Re-summon the welcome tour on demand (it only auto-shows once per install). Close
                // the other overlays first, then clear both the persisted seen flag and this
                // session's dismissal so the tour shows again from the start. ContentView observes both.
                Button("Welcome to SyncCloud") {
                    showSettings = false
                    showHelp = false
                    hasSeenFirstRunWelcome = false
                    welcomeDismissedThisSession = false
                }
                // The discoverability half of the shortcuts story: review-mode keys, the drag
                // move modifier, and ⌥-breadcrumb navigation are otherwise invisible.
                ShortcutsWindowCommand()

                Divider()

                // Surface the Activity Log window (it otherwise has no menu entry) and a jump to
                // the on-disk log — the two things a user reaches for when troubleshooting or
                // filing a report.
                ActivityLogWindowCommand()
                SyncHistoryWindowCommand()
                Button("Reveal Log File in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Logger.shared.logFileURL])
                }

                Divider()

                Button("About SyncCloud") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
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

        // Durable Sync History (X2): its own window (not a bottom tab) so it doesn't collide with
        // the main content. Reads the shared `SyncHistoryStore` the manager records into, and
        // reverses the last run through the manager's undo stack behind an NSAlert confirmation.
        Window("Sync History", id: "sync-history") {
            if isRunningTests {
                Color.clear
            } else {
                SyncHistoryView(
                    store: .shared,
                    onUndoLastSyncRun: {
                        // Only prompt when the last recorded run is genuinely still on top of the
                        // undo stack; otherwise let the manager surface the honest reason (a
                        // non-sync action is on top, or the stack reset on relaunch).
                        guard let preview = syncManager.lastSyncRunUndoPreview else {
                            syncManager.undoLastSyncRun()
                            return
                        }
                        guard SyncOperationAlerts.confirmUndoLastSyncRun(preview) else { return }
                        syncManager.undoLastSyncRun()
                    }
                )
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

    /// Launch breadcrumb — fires exactly once per process (unlike App.init, which SwiftUI may
    /// re-run), so the log's first line unambiguously names the build that produced the session.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        Logger.shared.info("SyncCloud \(version) (build \(build)) launched")
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
            // Even a clean quit must flush: the writer runs at background qos with no implicit
            // flush, so the launch breadcrumb and any late lines from this session could be lost
            // between the last append and process exit if we terminated without draining.
            // The sync-history writer buffers the same way, so drain it alongside the log —
            // otherwise the newest run's records silently vanish on quit.
            Logger.shared.flushToDisk()
            SyncHistoryStore.shared.flushToDisk()
            return .terminateNow

        case .allowWithoutWarning(let count):
            // The quit decision + flush is the single event most correlated with crash-time
            // corruption, so record it and force the buffered lines to disk before we quit.
            Logger.shared.warning("User chose Quit Anyway with \(count) active file operation(s)")
            Logger.shared.flushToDisk()
            SyncHistoryStore.shared.flushToDisk()
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
                SyncHistoryStore.shared.flushToDisk()
                return .terminateNow
            } else {
                Logger.shared.info("User chose Wait with \(count) active file operation(s) in progress")
                return .terminateCancel
            }
        }
    }
}
