import SwiftUI
import Design
import Sync
import Events
import Settings
import Dashboard
import FileExplorer
import AppIntents

// Keep an explicit AppIntents symbol reference so metadata extraction sees the framework dependency.
private let _syncCloudAppIntentsDependency: Any.Type = (any AppIntent).self

/// AppKit's display-cycle assert, named once.
///
/// **The key was spelled as a bare literal twice, ~630 lines apart** — once where it is registered
/// off, once where the launch breadcrumb reads it back to say whether the crash is armed. They
/// matched, and a typo in either would have made the diagnostic lie in the worst possible
/// direction: registering one key and reading another reports ARMED for a session that is in fact
/// suppressed, which is the exact question `docs/columns-layout-loop.md` exists to answer. Both
/// sites sit inside `if !isRunningTests`, so no test covers either.
enum DisplayCycleAssert {
    static let key = "NSWindowAssertWhenDisplayCycleLimitReached"

    /// Whether AppKit will raise — **mirroring AppKit's own order** (`objectForKey:`, then
    /// `boolForKey:`), which is what makes the breadcrumb agree with what actually happens.
    ///
    /// Absent means armed: under tests nothing is registered at all, deliberately, so CI keeps
    /// failing loudly if a fixture ever reproduces the runaway. See
    /// `docs/columns-layout-loop.md` ▸ "Is the mitigation actually plumbed in".
    static func isArmed(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }
}

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

        // Not under tests: the migration writes into the real defaults domain and the theme pin
        // sets the shared NSApp's appearance from the developer's stored preference — both are
        // launch behavior, and the test host rendering appearance-sensitive UI must not depend
        // on the machine it runs on.
        if !isRunningTests {
            // Stop AppKit turning a layout that will not settle into a hard crash.
            //
            // `-[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints]` raises
            // `NSGenericException` once a window "has already had more update constraints passes
            // than there are views in the window". A pane in COLUMNS reaches that on a provider
            // switch: `resetNavigation()` drops both trees, and while the replacements paint a
            // column row keeps reporting a new ideal height from inside the pass
            // (`OutlineListCoordinator.listTableCellView(_:didUpdateIdealHeight:)` →
            // `enqueueLayoutInvalidation()` → another pass).
            //
            // **A mitigation, not the fix** — the window still churns passes, it just stops dying
            // of it. `docs/columns-layout-loop.md` carries the mechanism, the repro, everything
            // three investigations have ruled out, and why a survival/death outcome is too
            // low-powered to evaluate the real fix with.
            //
            // Registration domain, so it is overridable and writes nothing into the user's
            // preferences; a diagnostic session gets the crash and its backtrace back with
            // `defaults write com.abhishekgirish.SyncCloud NSWindowAssertWhenDisplayCycleLimitReached -bool YES`.
            // Deliberately NOT registered under tests: CI should still fail loudly if a fixture
            // ever reproduces the runaway, which is the outcome still being hunted.
            //
            // **The registration domain really is visible to the read AppKit does** — measured
            // 2026-08-03, because "it stopped crashing" could not tell a working mitigation from
            // an inert one. AppKit reads this key through `_NSGetBoolAppConfig`, whose body calls
            // `-[NSUserDefaults standardUserDefaults]` `objectForKey:`/`boolForKey:` and
            // `volatileDomainForName:`; there is no `CFPreferences` call on that path, so the
            // registration domain cannot be invisible to it. Driving AppKit's own
            // `_NSGetBoolAppConfig` with AppKit's own default-value function for this key answered
            // YES (raise) unregistered, NO (tolerate) after registering `false`, and YES again
            // after registering `true` — it tracks the registration domain in both directions.
            // `docs/columns-layout-loop.md` ▸ "Is the mitigation actually plumbed in" has the
            // method, so this does not get re-litigated from the crash rate again.
            UserDefaults.standard.register(
                defaults: [DisplayCycleAssert.key: false])

            // The log line that reports which state this session is in is deliberately NOT here —
            // it is in the delegate's `applicationDidFinishLaunching`, for exactly the reason the
            // "launched" breadcrumb is: App.init can be re-run by SwiftUI, and a diagnostic that
            // says the crash guard is off is worth less every time it repeats itself.

            // Move a pre-GlassLevel install onto the two-control Appearance model before any
            // @AppStorage property wrapper reads the keys. Idempotent, so the repeat App.init
            // calls noted above are harmless.
            LiquidGlass.migrateLegacyAppearance()

            // Main-thread hitch reporting, when the diagnostic flag is set. Installed here rather
            // than from a view so it covers the whole session — including launch, which is where a
            // wedged `getxattr` once cost the app every one of its windows. Idempotent, so the
            // repeat App.init calls noted above are harmless, and it installs nothing at all on a
            // normal launch.
            MainThreadHitchMonitor.startIfEnabled()

            // Undo the one thing the preview's old sizing rule made people do to their columns.
            // Idempotent by its own flag, so the repeat App.init calls noted above are harmless.
            PaneViewMode.liftColumnWidthOffTheFloor()

            // Pin the app's light/dark theme before any window exists, so a pinned appearance is
            // what the first frame draws rather than a flash of the system one. Settings
            // re-applies on change; `.system` (the default) assigns nil — AppKit for "follow
            // macOS".
            AppAppearance.applyPersisted()
        }

        let manager = FileSyncManager()
        // The Sync package is UI-free: its seam defaults fail safe (skip collisions, refuse
        // permanent deletes). Wire the real NSAlert-backed prompts here, at the app boundary.
        // Each prompt first consults the user's standing conflict policy (Settings → Sync),
        // re-read per collision so a Settings change applies to the very next conflict;
        // folder collisions always fall through to the prompt (see ConflictPolicy).
        Self.wireCollisionResolvers(into: manager)
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
            // The router also LOGS the one silent case — cloud Filing on, no usable key — which
            // otherwise left the user believing Claude filed documents the on-device model filed.
            // `hasCloudKey` is an @autoclosure, so the Keychain below is only queried once the
            // toggle says yes — as the plain `if` this replaced did. Evaluating it on every scan
            // regardless would warn (and can prompt) on a locked item for a disabled feature.
            let route = FilingBackendRouter.route(
                cloudEnabled: UserDefaults.standard.bool(forKey: FileSyncManager.usesCloudDefaultsKey),
                hasCloudKey: AnthropicKeychain.hasKey)
            if route == .cloud {
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
    ///
    /// `defaults` is a seam: production reads `.standard` (the user's live policy), tests inject
    /// their own suite so pinning the policy never writes into the user's real settings domain.
    @MainActor
    static func policyAutoResolution(for collision: FileCollision,
                                     defaults: UserDefaults = .standard) -> CollisionResolution? {
        let policy = ConflictPolicy.persisted(from: defaults)
        guard let auto = policy.autoResolution(isDirectory: collision.isDirectory) else { return nil }
        Logger.shared.info("Collision on \"\(collision.fileName)\" auto-resolved by Settings policy: \(policy.displayName)")
        return auto
    }

    /// Wires the two collision seams — the single-item resolver and the bulk-sync one — to the
    /// standing conflict policy, falling through to the NSAlert prompt whenever the policy says
    /// ask (which includes every FOLDER collision; see `ConflictPolicy`). Split out of `init` so
    /// the wiring itself is testable: the policy function is covered by Sync's `ConflictPolicyTests`,
    /// but nothing pinned that BOTH seams route through it, that a folder collision still reaches
    /// the prompt, or that the policy is re-read per collision — and an inverted gate or a dropped
    /// wiring silently replaces the user's files with no prompt and no undo trail.
    ///
    /// The two prompts are parameters (defaulting to the real alerts) purely so a test can assert
    /// the routing without driving a modal; production behavior is exactly the pre-extraction code.
    /// A policy answer never offers "apply to all" — the policy already applies to every
    /// collision, so `false` is the only consistent answer.
    @MainActor
    static func wireCollisionResolvers(
        into manager: FileSyncManager,
        defaults: UserDefaults = .standard,
        prompt: @escaping @MainActor (FileCollision) -> CollisionResolution = {
            SyncOperationAlerts.promptForCollision($0)
        },
        bulkPrompt: @escaping @MainActor (FileCollision) -> (resolution: CollisionResolution, applyToAll: Bool) = {
            SyncOperationAlerts.promptForCollisionWithApplyToAll($0)
        }
    ) {
        manager.collisionResolver = { collision in
            Self.policyAutoResolution(for: collision, defaults: defaults)
                ?? prompt(collision)
        }
        manager.bulkCollisionResolver = { collision in
            Self.policyAutoResolution(for: collision, defaults: defaults).map { ($0, false) }
                ?? bulkPrompt(collision)
        }
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
                    .appFontSizeFromSettings()
            }
        }
        .windowStyle(.hiddenTitleBar)
        // Open at ~85% of the screen (the two-pane + Differences layout needs room); without a
        // defaultSize, `.contentSize` resizability collapsed the first launch to the content's
        // own minimum (600×560 — see `ContentView.chromedContent`). `.contentMinSize` keeps that
        // minimum as a floor but lets the window take (and remember) any larger size.
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
                .appFontSizeFromSettings()
        }
        .windowResizability(.contentSize)

        Window("Activity Log", id: "activity-log") {
            if isRunningTests {
                Color.clear
            } else {
                LogViewer()
                    .environmentObject(Logger.shared)
                    .appFontSizeFromSettings()
            }
        }
        // Same chrome as the main window (and therefore as the Settings overlay that floats in
        // it): the title bar is hidden so the window's glass background runs to the top edge,
        // instead of a system-white slab above it. LogViewer already draws "Activity Log" as its
        // own header row and insets it past the traffic lights.
        .windowStyle(.hiddenTitleBar)
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
                .appFontSizeFromSettings()
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

        // Which state the AppKit display-cycle guard is in, recorded once per launch.
        //
        // The suppression `SyncCloudApp.init` registers is app-GLOBAL and lasts the whole session:
        // every window the process opens — Settings, Activity Log, anything added later — runs
        // without AppKit's runaway-layout guard, not just the Columns pane that needs it. That is
        // worth a breadcrumb, because `~/sync-cloud.log` is the only channel that can tell a
        // support session which build state it is looking at.
        //
        // Read back rather than restating what init asked for, so this reports the EFFECTIVE value:
        // an explicit `defaults write` (persistent domain) or a launch argument beats the
        // registration domain, and then the guard is armed and the crash is live again.
        //
        // **`object(forKey:)` first, and that is not a stylistic choice.** `bool(forKey:)` alone
        // cannot tell "registered false" from "absent" — it answers `false` to both — whereas
        // AppKit, absent the key, falls back to its own default-value function, which returns YES
        // for a modern-linked binary. So a `bool`-only check would report "suppressed" in exactly
        // the case where AppKit would raise. That case is real: under tests nothing is registered
        // at all, deliberately, so CI keeps failing loudly if a fixture ever reproduces the
        // runaway — and this line has to say ARMED there, not the opposite.
        //
        // Mirroring AppKit's own order (`objectForKey:` then `boolForKey:`) is what makes the two
        // agree. See `docs/columns-layout-loop.md` ▸ "Is the mitigation actually plumbed in".
        //
        // Here rather than in `App.init` because this fires exactly once; init can be re-run.
        if DisplayCycleAssert.isArmed(in: .standard) {
            Logger.shared.info(
                "[layout-guard] AppKit display-cycle assert is ARMED — a Columns provider switch "
                + "can crash this session (docs/columns-layout-loop.md)")
        } else {
            Logger.shared.info(
                "[layout-guard] AppKit display-cycle assert suppressed app-wide for this session; "
                + "the Columns layout loop still churns update-constraints passes, it just is not fatal")
        }
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
            // Counterpart to the launch breadcrumb: a clean quit gets a closing line, so a log that
            // simply stops with no shutdown line reads as a crash or force-kill, not a normal exit.
            // (The two "Quit Anyway" paths below already emit a distinctive last line of their own.)
            Logger.shared.info("SyncCloud is quitting")
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
