import SwiftUI
import UserNotifications
import Design
import Sync
import Events
import Settings
import Dashboard
import FileExplorer
import AppIntents

// Keep an explicit AppIntents symbol reference so metadata extraction sees the framework dependency.
private let _syncCloudAppIntentsDependency: Any.Type = (any AppIntent).self

/// AppKit's display-cycle assert, named once so the site that registers it off and the launch
/// breadcrumb that reads it back cannot disagree; a mismatch would report the crash armed for a
/// session that suppresses it (`docs/columns-layout-loop.md`). ``isArmed(in:)`` takes its defaults
/// because neither site can be driven to a chosen state under the test host.
enum DisplayCycleAssert {
    static let key = "NSWindowAssertWhenDisplayCycleLimitReached"

    /// Whether AppKit will raise, read in AppKit's own order (`objectForKey:`, then `boolForKey:`)
    /// so the breadcrumb matches what happens. Absent means armed: under tests nothing is
    /// registered, so CI still fails loudly if a fixture reproduces the runaway. See
    /// `docs/columns-layout-loop.md` ▸ "Is the mitigation actually plumbed in".
    static func isArmed(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }
}

/// The log level this launch runs at, decided once in `App.init` before anything logs.
///
/// The persisted level, Info by default, unless a trace switch was armed by hand
/// (`DiagnosticTraces`): then Debug, because a trace's readers also compare the ungated decision
/// lines (`[click]`, `[columns]`, `[crumb]`, `[deselect]`, `PaneScrollTrace`), which are Debug, and
/// read "no line" as a finding (`docs/columns-layout-loop.md`). For this launch only: nothing is
/// stored, and choosing a level in Settings or Reset All ends it.
@MainActor
enum LaunchLogLevel {
    private(set) static var level: LogLevel = Logger.defaultMinimumLevel
    /// The one INFO line naming the armed switches, or nil when none is armed.
    private(set) static var traceLine: String?

    static func decide(persisted: LogLevel, armedTraces: [String]) {
        let decided = Self.decision(persisted: persisted, armedTraces: armedTraces)
        level = decided.level
        traceLine = decided.line
    }

    /// Pure, for `LaunchLogLevelTests`.
    nonisolated static func decision(persisted: LogLevel, armedTraces: [String]) -> (level: LogLevel, line: String?) {
        guard !armedTraces.isEmpty, persisted != .debug else { return (persisted, nil) }
        return (.debug, "[trace] \(armedTraces.joined(separator: ", ")) armed, so this launch logs at "
                + "Debug; Settings ▸ Advanced ▸ Log level says \(persisted.settingName), and choosing a "
                + "level there ends it")
    }
}

/// AppKit's AutoFill heuristics, switched off app-wide.
///
/// When an editable `NSTextField` (the Go to field among them) takes the caret,
/// `NSAutoFillHeuristicController` walks the window's whole key-view loop looking for a password
/// field. In a SwiftUI window each step gathers key views over the entire responder tree, so the
/// walk is quadratic and can hang the app for minutes on ⌘K. SyncCloud has no password, contact or
/// card fields, so there is nothing for AutoFill to offer.
///
/// AppKit reads `NSAutoFillHeuristicsEnabled` through `NSUserDefaults` `objectForKey:`, so the
/// registration domain reaches it, as for ``DisplayCycleAssert``. It caches the answer on first
/// read, so this must be registered before any field takes focus.
enum AutoFillHeuristics {
    static let key = "NSAutoFillHeuristicsEnabled"

    static func registerOff(in defaults: UserDefaults) {
        defaults.register(defaults: [key: false])
    }

    /// AppKit's own order, `objectForKey:` then `boolForKey:` — an absent key means ON.
    static func isOff(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) != nil && !defaults.bool(forKey: key)
    }
}

/// How long the pointer rests on a control before its tooltip shows, app-wide.
///
/// AppKit's own wait is 1.5 s, long enough that a tooltip reads as something you stumble on. 300 ms
/// shows it once the pointer has plainly stopped, without flashing tips at one passing over.
///
/// Milliseconds, and read once: `NSToolTipManager` reads the key when it is created, so this is
/// registered first thing in `App.init`. Registration domain, so
/// `defaults write com.abhishekgirish.SyncCloud NSInitialToolTipDelay -int …` still overrides it.
enum ToolTipDelay {
    static let key = "NSInitialToolTipDelay"
    static let milliseconds = 300

    static func register(in defaults: UserDefaults) {
        defaults.register(defaults: [key: milliseconds])
    }
}

@main
/// The main entry point for the SyncCloud macOS application.
/// Manages the lifecycle of `FileSyncManager` and configures the root `ContentView`.
/// Integrated with `SyncCloudAppDelegate` for app-level guards and termination handling.
struct SyncCloudApp: App {
    /// The main scene's id. SwiftUI stamps it onto the NSWindow's `identifier`, which is how the
    /// delegate's Dock-reopen hook tells the main window from auxiliary scenes.
    static let mainWindowId = "main"
    /// How many times `body` has run. Test instrumentation: `AppSceneObservationTests` holds a
    /// manager publish to zero of these. Nothing in the app reads it.
    @MainActor static var sceneBodyRuns = 0

    @NSApplicationDelegateAdaptor(SyncCloudAppDelegate.self) var appDelegate

    /// Held for its lifetime: it registers `NSWorkspace` observers in `init` and removes them in
    /// `deinit`, so an unretained monitor would stop reporting and the survey would silently never
    /// notice a sleeping display.
    @State private var machineConditionsMonitor: MachineConditionsMonitor
    /// `@State`, not `@StateObject`: a state object would subscribe the whole scene to the
    /// manager's constant publishes, re-running this body and its `.commands` tree each time.
    /// Nothing here renders from the manager; every reader observes it itself (`ContentView`,
    /// `ActivityWindowHost`, `RunWriteLockFromManager`), and menu state arrives as focused values.
    @State private var syncManager: FileSyncManager
    @StateObject private var settings: SettingsManager
    /// Drives the in-window settings overlay. Hoisted to App scope so the ⌘, menu command can
    /// open it; ContentView renders the overlay and owns which tab is shown.
    @State private var showSettings = false
    /// Drives the in-window Help overlay. Hoisted to App scope so the Help ▸ SyncCloud Help (⌘?)
    /// menu command can open it; ContentView renders the overlay and owns dismissal.
    @State private var showHelp = false
    /// Whether ContentView's once-per-session bootstrap has run. App-owned so it outlives the view,
    /// as the session does: nothing in SwiftUI promises the view survives a close + Dock reopen,
    /// and `applicationShouldHandleReopen`'s fall-through would build a new one. @State, not
    /// @AppStorage: it must reset on every launch.
    @State private var hasBootstrappedSession = false
    /// The active duplicate-copy review (the Duplicates lens's "Compare copies" hand-off).
    /// App-owned like `hasBootstrappedSession`: the provider pins and pane focus survive a window
    /// close + Dock reopen, so the review, above all the snapshot that un-pins the panes, must too,
    /// or the panes stay pinned with no way back. Never persisted.
    @State private var duplicateReview: DuplicateCompareContext? = nil
    /// Guided-review session state. App-owned so a window close + Dock reopen mid-review (or
    /// mid-decision: an in-flight copy's outcome lands in this store) doesn't drop the session
    /// while the underlying comparison lives on in the shared FileSyncManager.
    @StateObject private var reviewStore = ReviewSessionStore()

    /// The one open document.
    ///
    /// Owned by the app so the document outlives the window: close it, reopen from the Dock, and
    /// the typing is still there. Nothing promises `ContentView` survives a close (see
    /// `hasBootstrappedSession`), and a view-owned document could lose an unsaved buffer.
    @StateObject private var editorDocument = EditorDocument()
    /// The PDF open in Edit, read-only; never open at once with the text document
    /// (`EditorOpenRoute`). Here for the document's reason: it outlives the window.
    @StateObject private var editorPDF = EditorPDFDocument()

    /// One undo stack per document, so ⌘Z survives switching files; here so it outlives the window
    /// too. See ``PlainTextEditor/undoManager`` for why the editor's history is separate from the
    /// file engine's, and `EditorUndoStore` for why it is per path.
    @StateObject private var editorUndoStore = EditorUndoStore()
    /// Which files autosave may write, for this run of the app.
    ///
    /// Here so it outlives the view: a set that died with a rebuilt `ContentView` would switch
    /// autosave back on for a document still open. Not persisted; see `EditorAutosavePolicy`.
    @StateObject private var editorAutosavePolicy = EditorAutosavePolicy()
    /// Watches the open document's file for changes made elsewhere. Here for the document's
    /// reason, it outlives the window; attached to the document from `ContentView.onAppear`.
    @StateObject private var editorDiskWatch = EditorDiskWatch()

    /// Watches for ⌥ held alone, and publishes it to every `.shortcutKeycap(_:)` in the window.
    /// One per app: it installs local `NSEvent` monitors, and a second would double them.
    @StateObject private var shortcutReveal = ShortcutRevealTracker()
    /// Whether setup has been dismissed this session. App-owned (like `hasBootstrappedSession`) so a
    /// close + Dock reopen doesn't resurrect a form answered *Not Now*. Never persisted: the form
    /// offers itself again next launch unless it was completed.
    @State private var setupDismissedThisSession = false
    /// Whether Help ▸ Set Up SyncCloud… asked for the form. Held here because the menu command lives
    /// in this scene and ContentView's overlay chain is what reads it.
    @State private var showSetup = false
    private let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    
    init() {
        LaunchTiming.initBegan()
        // Apply the launch's log-level gate before anything logs; Settings → Advanced updates it
        // from then on. A hand-armed trace switch lowers it to Debug for this launch, so the
        // ungated `[click]`/`[columns]` lines its readers compare against are written too
        // (`docs/columns-layout-loop.md`). The launch breadcrumb, which states the level, and the
        // trace's own line live in `applicationDidFinishLaunching`, which fires once, because
        // SwiftUI can re-run App.init. Deterministic, so a re-run decides the same.
        LaunchLogLevel.decide(persisted: Logger.persistedMinimumLevel(),
                              armedTraces: DiagnosticTraces.armed(in: .standard))
        Logger.shared.minimumLevel = LaunchLogLevel.level
        LogLevelSetting.traceLoweredThisLaunch = LaunchLogLevel.traceLine != nil

        // Before any field can take the caret: AppKit caches the answer on first read. Not gated on
        // tests — a hosted test that focuses a field would hang the same way.
        AutoFillHeuristics.registerOff(in: .standard)

        // Before any view exists: AppKit's tooltip manager reads the delay once, when it is made.
        ToolTipDelay.register(in: .standard)

        // Not under tests: the migrations write into the real defaults domain, and the theme pin
        // would make the test host's appearance depend on the machine it runs on.
        if !isRunningTests {
            // Stop AppKit turning a layout that will not settle into a hard crash. AppKit raises
            // `NSGenericException` once a window has had more update-constraints passes than it has
            // views, and a pane in Columns reaches that on a provider switch, as a column row keeps
            // reporting a new ideal height from inside the pass.
            //
            // A mitigation, not the fix: the window still churns passes, it just stops dying of it.
            // `docs/columns-layout-loop.md` has the mechanism and the repro, and its section "Is
            // the mitigation actually plumbed in" shows AppKit reads this key through
            // `NSUserDefaults`, so the registration domain reaches it.
            //
            // Registration domain, so it writes nothing into the user's preferences; a diagnostic
            // session gets the crash back with
            // `defaults write com.abhishekgirish.SyncCloud NSWindowAssertWhenDisplayCycleLimitReached -bool YES`.
            // Not registered under tests, so CI still fails loudly if a fixture reproduces it.
            UserDefaults.standard.register(
                defaults: [DisplayCycleAssert.key: false])

            // The line reporting the crash guard's state is in `applicationDidFinishLaunching`,
            // like the "launched" breadcrumb, because SwiftUI can re-run App.init.

            // Say so when the diagnostic walk stall is armed: it imitates cold-provider slowness,
            // so one left on by accident would be read as the bug it exists to reproduce.
            if WalkStall.isArmed {
                Logger.shared.info(
                    "[walk] DIAGNOSTIC STALL ARMED — \(WalkStall.millisecondsPerDirectory)ms per directory."
                    + " Clear it with: defaults delete com.abhishekgirish.SyncCloud \(WalkStall.defaultsKey)")
            }

            // An accent no longer offered (Slate) moves to the one that replaced it, before any
            // @AppStorage reads it; read raw, it would fall back to Blue. Logged only when it does.
            if let moved = LiquidGlass.migrateRetiredHue() {
                Logger.shared.info("Accent migrated: \"\(moved.from)\" is no longer offered → \(moved.to.displayName)")
            }
            // The preview lives in the Info inspector: Info opens once for anyone who had the
            // in-pane preview on, and folds the preview away for anyone who had it off. Before any
            // @AppStorage reads either key. Logged when it runs.
            switch InfoPreviewMigration.run(in: .standard) {
            case .openedInfo?:
                Logger.shared.info("[info] The preview is in the Info inspector now — opened Info, as the preview was on")
            case .foldedPreview?:
                Logger.shared.info("[info] The preview is in the Info inspector now — folded it away there, as the preview was off")
            case nil:
                break
            }

            // Put a newly shipped pane-bar control onto a bar arranged on an earlier build, before
            // any @AppStorage reads the arrangement; otherwise a customized bar keeps the new
            // control hidden in ⋯. Stamped, once per added control, so a deliberate removal
            // afterwards is never undone.
            //
            // Logged when it moves a bar, because no test can reach this call (the test host skips
            // it), and the log line is what makes its absence noticeable. The sentence comes from
            // `migrationMessage` over `apply`'s `Outcome`, never a literal here, so it names what
            // each step changed. An `Outcome`, not a list of added controls, because a removing or
            // reordering step rewrites the bar without adding one.
            if let line = PaneBarMigration.migrationMessage(
                for: PaneBarMigration.apply(defaults: .standard)) {
                Logger.shared.info(line)
            }

            // Decision JT retired Let Claude read files: on, it becomes the home folder shared
            // without asking, so nothing reaches Claude differently. Once, by its key.
            if let line = AskClaudePrivacy.retireReadsFiles(home: NSHomeDirectory(), in: .standard) {
                Logger.shared.info(line)
            }

            // Refine's own spend and caps give way to Ask Claude's one limit: this month's spend is
            // carried into its total, the old caps and history become one notice, and the old record
            // goes. Once, by its stamp; a record that can't be read waits for the next launch.
            if let line = RefineSpendMigration.applyAtLaunch() {
                Logger.shared.info(line)
            }

            // Sources begin at their account folder rather than the `Documents` inside it, so every
            // position stored relative to a source root (pane folders, tab strips, pinned and
            // recent folders, Favorites order, filing destinations) moves down a level here.
            //
            // Here, and synchronously: the bootstrap task reads those a moment later, and a strip
            // whose folders do not resolve is re-rooted and saved that way, a permanent and silent
            // loss. Idempotent by its stamp.
            if let line = RootsMigration.applyAtLaunch(defaults: .standard).logLine {
                Logger.shared.info(line)
            }

            // Main-thread hitch reporting, when the diagnostic flag is set. Installed here, not from
            // a view, so it covers the whole session including launch. Idempotent, and installs
            // nothing on a normal launch.
            MainThreadHitchMonitor.startIfEnabled()
            // Unlike the hitch monitor, always on: it is the one thing that takes a stack while the
            // main thread is stalled, and the stalls it is for happen in the installed app.
            MainThreadStallWatch.shared.start()
            MainThreadStallWatch.stallOnceIfAsked()

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
        manager.permanentDeleteConfirmer = { itemPaths in
            SyncOperationAlerts.confirmPermanentDelete(itemPaths: itemPaths)
        }
        // The out-of-process Trash, for when `FileManager.trashItem` is refused permission (see
        // `FileSyncManager.trashViaWorkspace`). Wired here because the engine may not import
        // AppKit (`LayeringPinTests`).
        //
        // `@MainActor` inside: the delete loop that reaches this runs off the main actor. The
        // completion returns on an arbitrary thread; the continuation absorbs that.
        manager.trashViaWorkspace = { urls in
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    NSWorkspace.shared.recycle(urls) { moved, _ in
                        continuation.resume(returning: moved ?? [:])
                    }
                }
            }
        }
        // Cloud (Claude) Filing spend guardrail: before a cloud classify, show the cost estimate and
        // budget, and let the user or the cap decline, falling back on-device. Only consulted when
        // cloud Filing is on.
        manager.filingCloudSpendConfirmer = { preflight in
            SyncOperationAlerts.promptForFilingSpend(preflight)
        }
        // Whole-tree passes (Storage, Find Duplicates) probe the folder's size first and ask when
        // the real pass would take minutes. The Sync default is to refuse, so this wiring is what
        // makes a large folder analysable at all; see `largeWalkConfirmer`.
        manager.largeWalkConfirmer = { preflight in
            SyncOperationAlerts.confirmLargeWalk(preflight)
        }
        // Destination names the provider forbids (a trailing space or dot on Dropbox, reserved
        // names on OneDrive) prompt before any I/O. No standing policy: the wrong answer silently
        // creates an unsyncable local-only duplicate.
        manager.invalidNameResolver = { prompt in
            SyncOperationAlerts.promptForInvalidName(prompt)
        }
        // Filing: on-device content signals for files whose name says nothing. Gated by the
        // read-contents Settings toggle; runs only on the no-confident-home tail.
        manager.filingContentExtractor = { path in
            await ContentSignalExtractor.tokens(forFileAt: path)
        }
        // Storage reports survive launches, so the lens opens on the last reading. The only lens
        // whose results are restored; `StorageLensSnapshot` says why read-only makes that safe.
        manager.storageLensStoreURL = StorageLensStore.defaultURL()
        // Lenses whose rows carry destructive applies never restore results; opening one re-runs
        // its scan when the target matches the last and the run cannot cost money, so nothing
        // stale is offered. This store remembers those targets and Compare's last summary, which
        // is loaded at once because ContentView's empty state renders from it on the first frame.
        //
        // Not under tests: the app-target suite is hosted in this app, so `.standard` here would
        // give every test that completes a scan a writable handle on the user's real defaults.
        if !isRunningTests {
            manager.persistedUIStateDefaults = .standard
            manager.loadLastScanSummary()
            // The folder watcher, not under tests for the same reason, and because the test host's
            // panes sit on real folders: a live stream would mark them changed under any suite that
            // reads the freshness readouts.
            manager.enableFolderWatching(history: .userDefaults(.standard))
        }
        // The content-hash index survives launches, so Verify and Duplicates do not re-read what
        // they already hashed. Enabled here, not in the library, because `ContentHashCache.shared`
        // is the default argument of `findDuplicates` and Verify, and tests would otherwise touch
        // the real index. Loaded detached: decoding takes hundreds of milliseconds, and a scan
        // started first just misses and re-hashes.
        if let indexURL = ContentHashIndexStore.defaultURL() {
            Task.detached(priority: .utility) {
                let adopted = await ContentHashCache.shared.enablePersistence(at: indexURL)
                if adopted > 0 {
                    Logger.shared.info("Content-hash index: \(adopted) digest(s) reloaded — unchanged files won't be re-hashed")
                }
            }
        }
        // The same for the same-text pass's document fingerprints, the costlier half to recompute:
        // a full PDF parse per document.
        if let fingerprintURL = ContentHashIndexStore.defaultFingerprintURL() {
            Task.detached(priority: .utility) {
                let adopted = await ContentHashCache.sharedFingerprints.enablePersistence(at: fingerprintURL)
                if adopted > 0 {
                    Logger.shared.info("Document-fingerprint index: \(adopted) digest(s) reloaded — unchanged documents won't be re-read")
                }
            }
        }
        // And the documents that pass read and found too little text in, so a warm rescan does not
        // re-parse every image-only scan. Its own file — see `ContentHashCache.sharedTextless`.
        if let textlessURL = ContentHashIndexStore.defaultTextlessURL() {
            Task.detached(priority: .utility) {
                let adopted = await ContentHashCache.sharedTextless.enablePersistence(at: textlessURL)
                if adopted > 0 {
                    Logger.shared.info("Textless-document index: \(adopted) document(s) reloaded — they won't be re-read")
                }
            }
        }
        // Verdicts are cached per file identity, backend and prompt version, so unchanged files are
        // not re-classified or, on the cloud backend, re-paid for. Injected rather than defaulted
        // in `Sync`, so only the real app touches the real file (see `filingVerdictCacheURL`).
        manager.filingVerdictCacheURL = FilingVerdictStore.defaultURL()
        // Which backend a cached verdict came from, resolved through the same router as the
        // classifier below, so a cloud-on-but-no-key downgrade is cached as on-device. Otherwise
        // later scans would serve the on-device answer as Claude's.
        //
        // `logDowngrade` is silenced: the classifier reports it when the scan runs. The Keychain
        // is read twice per cloud-enabled scan, but never when cloud is off, since the toggle is
        // checked first.
        manager.filingBackendIdentity = { tier in
            // `.free` short-circuits before the router: the free pass routes on-device below, so
            // its verdicts must key as on-device, or the next refine would serve the free answer
            // back as Claude's.
            guard tier == .refine else { return FileSyncManager.onDeviceBackendIdentity }
            switch FilingBackendRouter.route(
                cloudEnabled: true,   // a saved key is the opt-in (TE335); `hasCloudKey` decides
                hasCloudKey: AnthropicKeychain.hasKey,
                logDowngrade: { _ in }
            ) {
            case .cloud:
                // The chat's model: Refine, Try Another and Refine Names use Ask Claude's.
                return "cloud:" + AskClaudeModels.option(for: UserDefaults.standard.string(forKey: AskClaudeModels.defaultsKey)).id
            case .onDevice, .onDeviceCloudKeyUnavailable:
                return FileSyncManager.onDeviceBackendIdentity
            }
        }
        // The display half of the same question, a second seam because `isConfigured` is an
        // attributes-only Keychain match that never decrypts or prompts, unlike `hasKey`. The
        // Organize toolbar reads it on every render, every keystroke in its search field. An item
        // that exists but cannot be read is named in the refine banner.
        manager.filingCloudRefineConfigured = { AnthropicKeychain.isConfigured }
        // Filing (AI): reason over the folder taxonomy and document text to pick a home. Opt-in
        // cloud (Claude) when enabled with a key, else on-device Foundation Models. Always injected
        // so the toggle and key can change at runtime; the backend is resolved per call.
        //
        // This closure is the whole of "a scan cannot cost money": `.free` goes straight on-device
        // without the toggle or the Keychain; only `.refine` (an explicit click, or a card's "Try
        // another") may reach Claude. `Sync` also skips classifying if the free route comes back
        // cloud (`freePassWouldReachAPaidBackend`).
        manager.filingClassifier = { context, files, tier in
            // Destinations, not the raw taxonomy: the context knows which folders are inboxes, and
            // the unfiltered list would teach a backend to file into `TODO`.
            let taxonomy = context.destinations
            // The router logs the silent case, cloud on with no usable key. `hasCloudKey` is an
            // @autoclosure, so the Keychain is queried only once the toggle says yes; otherwise it
            // could warn or prompt for a disabled feature. Gated on the tier, so a scan never
            // queries the Keychain.
            let route = tier == .refine
                ? FilingBackendRouter.route(
                    cloudEnabled: true,   // a saved key is the opt-in (TE335); `hasCloudKey` decides
                    hasCloudKey: AnthropicKeychain.hasKey)
                : .onDevice
            if route == .cloud {
                // Claude is reached through `filingRefineClassifier`, which says how a request ended,
                // so a failure is shown as one. Nothing here answers in its place.
                return [:]
            }
            if OnDeviceFilingClassifier.isAvailable {
                return await OnDeviceFilingClassifier.classify(taxonomyFolders: taxonomy, files: files)
            }
            return [:]
        }
        // The mapping refine: a paid call over folder names, through the same key, model, caps and
        // spend store as the filing refine. The sheet gates the offer on a stored key
        // (`filingCloudRefineAvailable`); this closure is only the transport.
        manager.filingRefineClassifier = CloudFilingRefiner.live
        manager.mappingRefiner = CloudFilingRefiner.liveNames
        manager.filingSnippetExtractor = { path in
            await ContentSignalExtractor.snippet(forFileAt: path)
        }
        // Offered per file, never spent by a scan — see `FileSyncManager.readScan(for:)`.
        manager.filingOCRExtractor = { path in
            await ContentSignalExtractor.ocrPDFFirstPage(atPath: path)
        }
        // What the document survey stands aside for: display sleep and the thermal band, which come
        // from AppKit and `ProcessInfo`, so a library reading them would answer differently under
        // `swift test`. A host that installs none gets `MachineConditions.unknown`, which never
        // pauses.
        let machineConditions = MachineConditionsMonitor()
        _machineConditionsMonitor = State(wrappedValue: machineConditions)
        manager.machineConditions = { machineConditions.current() }
        // The second half of `filingContentExtractor` on its own, so the scan can read a page once
        // and share it with the router and the classifier.
        manager.filingTokensFromText = { ContentSignalExtractor.tokens(fromText: $0) }
        // Records the trend only where a person launched the app: this line also runs under the
        // test host, whose writes would land in the real profile directory.
        FilingArtifacts.attach(to: manager, recordingTrend: !isRunningTests)

        // Installed whether or not the model is available: `prewarm()` asks that itself, off the
        // main thread. Asking here would hold the first window, by seconds after a macOS update.
        manager.filingClassifierPrewarm = { OnDeviceFilingClassifier.prewarm() }
        _syncManager = State(wrappedValue: manager)
        // ContentView's bootstrap discovers providers, so skip the init-time discovery. The
        // overrides domain keeps global-domain keys from masquerading as provider overrides.
        _settings = StateObject(wrappedValue: SettingsManager(
            autoDiscover: false,
            overridesDomainName: Bundle.main.bundleIdentifier ?? SettingsManager.appSuiteName
        ))
        // CRITICAL: Link the manager to the delegate so the termination guard is active.
        appDelegate.adoptSyncManager(manager)
        LaunchTiming.initEnded()
    }

    /// The Settings conflict policy's answer for a collision, or nil when it says ask (folder
    /// collisions always do; see ConflictPolicy). Shared by both resolver wirings so they can't
    /// drift, and re-read per collision so a Settings change applies to the very next one.
    ///
    /// `defaults` is a seam: tests inject their own suite so they never write the user's settings.
    @MainActor
    static func policyAutoResolution(for collision: FileCollision,
                                     defaults: UserDefaults = .standard) -> CollisionResolution? {
        let policy = ConflictPolicy.persisted(from: defaults)
        guard let auto = policy.autoResolution(isDirectory: collision.isDirectory) else { return nil }
        // Skip and Keep Both stay Info: the only record of which file a policy left out, or kept a
        // second copy of. A Replace is recorded by its own "Replaced … recoverable at" line, so its
        // per-file line, one per colliding file in a bulk run, is Debug.
        let logLine = "Collision on \"\(collision.fileName)\" auto-resolved by Settings policy: \(policy.displayName)"
        if case .replace = auto { Logger.shared.debug(logLine) } else { Logger.shared.info(logLine) }
        return auto
    }

    /// Wires the single-item and bulk collision seams to the standing conflict policy, falling
    /// through to the NSAlert prompt whenever it says ask (every folder collision included; see
    /// `ConflictPolicy`). Out of `init` so tests can pin that both seams route through the policy:
    /// an inverted gate or a dropped wiring would silently replace the user's files with no prompt.
    ///
    /// The prompts are parameters so a test can assert the routing without a modal. A policy answer
    /// never offers "apply to all", since the policy already applies to every collision.
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
        let _ = Self.sceneBodyRuns += 1
        // A single-window `Window` scene, not a WindowGroup: two ContentViews would share one
        // FileSyncManager and `showSettings`, so a second window would re-run the bootstrap and
        // open the settings overlay in both. `Window` also removes File ▸ New Window / ⌘N; nothing
        // in `.commands` re-adds it.
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
                    editorDocument: editorDocument,
                    editorPDF: editorPDF,
                    editorUndoManager: editorUndoStore.current,
                    editorUndoStore: editorUndoStore,
                    editorAutosavePolicy: editorAutosavePolicy,
                    editorDiskWatch: editorDiskWatch,
                    setupDismissedThisSession: $setupDismissedThisSession,
                    showSetup: $showSetup,
                    duplicateReview: $duplicateReview,
                    reviewStore: reviewStore,
                    externalOpens: appDelegate.externalOpens,
                    launchBootstrap: appDelegate.launchBootstrap
                )
                    .environmentObject(Logger.shared)
                    .environmentObject(settings)
                    .appFontSizeFromSettings()
                    // The window's switches, sliders, checkboxes and progress bars, Settings, Help
                    // and Setup's panels among them, take the app's hue.
                    .nativeControlAccent()
                    .selectionLensAppearanceFromDefaults()
                    // Outermost, so every badged control sees the reveal in the same render pass;
                    // badges arriving one by one would read as a glitch.
                    .shortcutRevealSource(shortcutReveal)
            }
        }
        .windowStyle(.hiddenTitleBar)
        // Open at ~85% of the screen, since the two-pane layout needs room; without a default size
        // the first launch would open at the content's minimum (760×560, see
        // `ContentView.chromedContent`). `.contentMinSize` keeps that as a floor and lets the
        // window take and remember any larger size.
        .defaultSize(
            width: (NSScreen.main?.visibleFrame.width ?? 1600) * 0.85,
            height: (NSScreen.main?.visibleFrame.height ?? 1000) * 0.85
        )
        .windowResizability(.contentMinSize)
        // The test host opens no window: it is this app, so it would cover the user's screen at
        // the saved frame for every app-target run. No test reads the window. Restoration is off
        // too, since the host shares the app's saved state and could reopen the user's windows.
        .defaultLaunchBehavior(isRunningTests ? .suppressed : .automatic)
        .restorationBehavior(isRunningTests ? .disabled : .automatic)
        .commands {
            // Settings is an in-window overlay, so it floats over the content even in full
            // screen, and there is no Settings scene to supply ⌘, — so supply it here.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { showSettings = true }
                    .keyboardShortcut(AppChord.settings.key, modifiers: AppChord.settings.modifiers)
            }
            // Edit ▸ the file clipboard, then Find. Find is here because a focus-scoped
            // `.onKeyPress` never sees ⌘F while focus is in a file table (see `FindInPaneCommand`).
            //
            // Replacing `.pasteboard`, not adding after it: AppKit's own Cut/Copy/Paste/Select All
            // do nothing for a file pane, and keeping them would put two items on each chord and
            // let AppKit pick one. Text editing is not lost: each routes back to the field editor
            // through `TextEditingChord` when the caret owns the keystroke.
            CommandGroup(replacing: .pasteboard) {
                CutCommand()                // ⌘X
                CopyCommand()               // ⌘C
                PasteCommand()              // ⌘V
                Divider()
                SelectAllCommand()          // ⌘A
                Divider()
                FindInPaneCommand()         // ⌘F
            }
            // File ▸ the pane chrome's actions. Replacing `.newItem` costs nothing in a one-window
            // app with no New Window. ⌘N is New Text File, beside New Folder. They route to the
            // focused pane or its selection through ContentView's focused values (see
            // `ShortcutCommands.swift`). Close Tab sits beside New Tab, not in AppKit's `.saveItem`
            // group, which renders after this one, far from the item it undoes.
            CommandGroup(replacing: .newItem) {
                NewTextFileCommand()        // ⌘N
                // The files Edit opened last, below New, where a document app keeps it.
                OpenRecentCommand()         // no chord — see the type
                NewFolderCommand()          // ⇧⌘N
                NewTabCommand()             // ⌘T
                CloseTabCommand()           // ⌘W
                ReopenClosedTabCommand()    // no chord — see the type
                Divider()
                // The row menu's verbs, over the pane selection, without a right-click on the row.
                PaneRowVerbCommands()
                Divider()
                RescanCommand()             // ⌘R
                Divider()
                DeleteSelectionCommand()    // ⌘⌫
            }
            // `.saveItem` is where AppKit puts File ▸ Close, whose key and job Close Tab has taken
            // (on the last tab it closes the window). Replaced, or AppKit's Close and Close All
            // come back and two items claim ⌘W. It holds Save, and Close Document above it: Close's
            // job for the editor's document, without Close's key.
            //
            // Close All (⌥⌘W) goes too: the app is one window plus a few utility windows, and an ⌥
            // chord would fire through the ⌥-hold reveal (see `AppChord.foldAllDifferences`).
            // `theFileMenuIsInTheRoadmapsOrder` pins its absence.
            //
            // Grouped because `CommandsBuilder` takes ten children; an eleventh fails as `extra
            // argument in call` at the closing brace. `Group` changes nothing in the bar.
            Group {
                CommandGroup(replacing: .saveItem) {
                    // Where AppKit's Close lived, above Save, with no key: ⌘W is Close Tab's, and
                    // ⌥⌘W is an ⌥ chord.
                    CloseDocumentCommand()      // no chord — see the type
                    SaveDocumentCommand()       // ⌘S
                }
                // File ▸ the document on paper. In `.printItem`, where AppKit puts printing, so the
                // items sit below Save with the platform's own separator and the Save group means
                // one thing. Replacing, since SwiftUI supplies no Print item here to keep.
                CommandGroup(replacing: .printItem) {
                    ExportPDFCommand()          // no chord — see AppChord.printDocument
                    PrintDocumentCommand()      // ⌘P
                    // The PDF header's Tools menu, after a divider: each tool writes a new copy,
                    // as Export as PDF… does. No chords — see the type.
                    PDFToolsCommand()
                    // The header's Fill & Sign button and its save pill's Save — see the type.
                    PDFFillSignCommand()
                    // The row menu's Save as PDF for the selection — see the type.
                    SaveAsPDFCommand()
                }
            }
            // View ▸ the workspaces (one ⌘-digit each, checkmarked) and the show/hide switches. The
            // workspaces are here because they change which surface the window shows. The
            // builder's ten-child limit is why three children are pairs.
            CommandGroup(after: .sidebar) {
                WorkspaceCommands()
                Divider()
                // Sidebar first: the only switch here that changes the window's structure rather
                // than what a pane shows. Disabled, not removed, while the panes are collapsed,
                // the same rule as the toolbar button. With Edit's Text Files, as one child.
                ColumnCommands()                // ⌃⌘S, and ⌃⌘T in Edit
                // Tab Bar and Status Bar, as one child. See the type.
                PaneChromeCommands()            // ⇧⌘T, and Status Bar with no chord
                ToggleHiddenFilesCommand()      // ⇧⌘.
                // With Ask Claude after it, as one child. See the type.
                InspectorAndAskClaudeCommands() // ⌘I (and Italic in Edit's document), ⌘J
                ToggleDifferencesListCommand()  // ⌘D
                FoldAllDifferencesCommand()     // ⇧⌘F
                // The whole app's type, on the slider's own stops: a divider and a Text Size
                // submenu, as one child.
                TextSizeMenuCommand()           // ⌘+ ⌘− ⌘0
            }
            // Go ▸ per-pane history, Finder's menu for Finder's chords, plus the chord that decides
            // which pane "per-pane" means. `SwitchPaneFocusCommand` sits here because it aims the
            // others (and ⌘F, ⇧⌘N), and its title is the at-rest answer to "which pane is focused".
            CommandMenu("Go") {
                // First, on its own: the only item that reaches a destination not on screen. The
                // items below move around where you already are.
                CommandPaletteCommand()     // ⌘K
                Divider()
                // Back, Forward and the column-stack pair, as one child. See
                // `PaneNavigationCommands`.
                PaneNavigationCommands()    // ⌘[ ⌘] ⌘↑ ⌘↓
                Divider()
                NextTabCommand()            // ⇧⌘]
                PreviousTabCommand()        // ⇧⌘[
                // Hidden behind the item above, its key live (`GoMenuDuplicates`).
                PreviousTabControlCommand() // ⌃⇧⇥
                Divider()
                // ⌃⇥: the other pane in Compare, the next tab in Browse, with a title naming which
                // (`PaneFocusSwitch`). As Next Tab it is hidden behind Next Tab ⇧⌘], its key live
                // (`GoMenuDuplicates`).
                SwitchPaneFocusCommand()    // ⌃⇥
            }
            // Compare ▸ the differences header's two bulk actions. Their availability is the
            // header's own facts, published by `DifferencesView` from the render that drew (or
            // withheld) the matching buttons.
            CommandMenu("Compare") {
                // The directional transfers first, since they act on the selection. Review and
                // Verify act on the whole comparison, so they sit below the divider.
                TransferCommands()          // ⌘← ⌘→ ⇧⌘← ⇧⌘→
                CompareTwoFilesCommand()    // ⇧⌘C — also acts on the selection, so it joins them
                Divider()
                ReviewDifferencesCommand()  // ⇧⌘R
                VerifyDifferencesCommand()  // ⇧⌘V
            }
            // Organize ▸ its sections, then its verbs, in a menu of its own, the shape the Compare
            // menu has. A submenu under View would put a second "Organize" a few rows below the
            // ⌘3 workspace item; here the word appears once per menu, as Compare's does.
            //
            // Grouped with the two menus after it because `CommandsBuilder` takes ten children.
            // `Group` changes nothing in the bar; `textAndMarkupFollowOrganizeInTheBar` reads the
            // order off the built menu.
            Group {
                CommandMenu("Organize") {
                    OrganizeLensCommands()      // the five sections, ticked
                    Divider()
                    OrganizeVerbCommands()      // the four row verbs, over the pane selection
                }
                // Text ▸ and Markup ▸, Edit's two menus. Their contents and reasoning are on
                // `EditorMenus`.
                EditorMenus()
            }
            // Replace the whole Help menu. AppKit's `.help` group is the `showHelp:` item, which
            // with no registered Help Book answers "Help isn't available for SyncCloud." Our own
            // Help overlay takes that slot, with the rest of the Help entries.
            CommandGroup(replacing: .help) {
                // The real front door: open the in-window Help overlay. Close Settings first so
                // the two overlays never stack (ContentView also enforces this).
                Button("SyncCloud Help") {
                    showSettings = false
                    showHelp = true
                }
                .keyboardShortcut("?", modifiers: .command)

                // Open the setup form on demand. It auto-shows once, on a machine never set up;
                // this is the way back, unconditional, since the form's own re-run state handles a
                // configured machine. Nothing persisted is cleared, so opening it from the menu
                // never makes it greet again at the next launch.
                Button("Set Up SyncCloud…") {
                    showSettings = false
                    showHelp = false
                    setupDismissedThisSession = false
                    showSetup = true
                }
                Divider()

                // The jump to the on-disk log: a Finder reveal, not a window, so it belongs in
                // Help, where someone filing a report looks.
                Button("Reveal Log File in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Logger.shared.logFileURL])
                }
            }
            // The auxiliary windows, in the Window menu. SwiftUI already creates a Window-menu
            // opener for every `Window` scene, so a second copy in Help would list each twice.
            //
            // Keyboard Shortcuts is supplied by hand, for its chord: an automatic entry has no key
            // equivalent, so its scene's is suppressed (`.commandsRemoved()`) and an item with ⌘/
            // put here; `ShortcutsWindowCommand` is the only thing registering ⌘/, and
            // `everyDeclaredChordIsOnAMenuItem` checks it. Activity keeps its automatic entry, with
            // ⌘L put on it at launch (`ActivityMenuKey`). Sync History, under the name people know,
            // opens Activity on its History tab.
            CommandGroup(before: .windowArrangement) {
                SyncHistoryWindowCommand()      // Activity, on its History tab
                ShortcutsWindowCommand()        // ⌘/
            }
        }

        Window("Keyboard Shortcuts", id: "keyboard-shortcuts") {
            ShortcutsReferenceView()
                .appFontSizeFromSettings()
                .nativeControlAccent()
                .selectionLensAppearanceFromDefaults()
        }
        .windowResizability(.contentSize)
        .restorationBehavior(isRunningTests ? .disabled : .automatic)   // as the main window's
        // Suppressed because this scene's item is supplied by hand in `.commands` above, for ⌘/.
        // Without this the window appears in the Window menu twice.
        .commandsRemoved()

        // One Activity window: Now · History · Log.
        //
        // Its Window-menu entry is SwiftUI's automatic one, with ⌘L put on it by `ActivityMenuKey`.
        // A scene's own `.keyboardShortcut` does not reach the automatic entry, and suppressing it
        // for a hand-written item, with Keyboard Shortcuts' suppressed too, takes the main
        // window's "SyncCloud" opener with them (`theMainWindowKeepsItsOpener`). The window picks
        // its tab as it becomes key (the last used, or Now while a problem waits), since the
        // automatic entry runs no code of ours first.
        Window("Activity", id: ActivityCenter.windowID) {
            if isRunningTests {
                Color.clear
            } else {
                ActivityWindowHost(syncManager: syncManager, settings: settings)
                    .environmentObject(Logger.shared)
                    .modifier(RunWriteLockFromManager(syncManager: syncManager))
                    .appFontSizeFromSettings()
                    .nativeControlAccent()
                    .selectionLensAppearanceFromDefaults()
            }
        }
        // Same chrome as the main window: the title bar is hidden so the window's glass runs to
        // the top edge, and the tabs sit past the traffic lights (`LogViewer.titleBarInset`).
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .restorationBehavior(isRunningTests ? .disabled : .automatic)   // as the main window's
        // NOT suppressed — see above; the main window's opener depends on it.
    }
}

/// The app delegate: the quit guard (`applicationShouldTerminate`), Dock reopen, and launch.
/// @MainActor because it reads main-actor state such as the manager's operation counts; AppKit
/// only calls it on the main thread, but Swift 6 strict checking needs the annotation.
@MainActor
class SyncCloudAppDelegate: NSObject, NSApplicationDelegate {
    /// The launch line naming both AppKit guards, pure so its words are pinned
    /// (`ShippedLogLevelTests`).
    nonisolated static func launchGuardsLine(displayCycleArmed: Bool, autoFillOff: Bool) -> String {
        let layout = displayCycleArmed
            ? "[layout-guard] AppKit display-cycle assert is ARMED — a Columns provider switch can crash this session (docs/columns-layout-loop.md)"
            : "[layout-guard] AppKit display-cycle assert suppressed app-wide for this session; the Columns layout loop still churns update-constraints passes, it just is not fatal"
        let autofill = autoFillOff
            ? "[autofill] AppKit AutoFill heuristics off — no key-view walk when a field takes the caret"
            : "[autofill] AppKit AutoFill heuristics are ON — focusing a field can walk the whole key-view loop"
        return layout + " · " + autofill
    }

    /// Reference to the shared sync manager for checking active operations.
    var syncManager: FileSyncManager?

    /// The `[glass]` breadcrumb's keeper — see `GlassLogLine`.
    private let glassLogLine = GlassLogLine()
    
    /// Static reference so the delegate always has the current manager even if the App struct is recreated.
    static weak var sharedSyncManager: FileSyncManager?

    /// The live delegate, so a view can hand it something to guard. Read from `NSApp.delegate`
    /// rather than a second static, which could point at an orphan.
    @MainActor static var shared: SyncCloudAppDelegate? { NSApp.delegate as? SyncCloudAppDelegate }

    /// The window's open editor document, so the quit guard can ask whether it has unsaved work.
    ///
    /// Weak and static like the manager above: SwiftUI may re-run `App.init`, and the guard must
    /// point at the live document, not an orphan that answers "nothing unsaved". Adopted by
    /// `ContentView` once it appears.
    static weak var sharedEditorDocument: EditorDocument?

    /// Wires the quit guard to the app's editor document.
    ///
    /// Unconditional, unlike ``adoptSyncManager(_:)``, which keeps the first manager against an
    /// orphan from a re-run `App.init`. Here the mirror hazard applies: keeping the first would
    /// hold a stale document still alive mid-teardown, and the quit guard would answer "nothing
    /// unsaved" about a document nobody can see. The reference is weak, so the newest is the live
    /// one.
    func adoptEditorDocument(_ document: EditorDocument) {
        Self.sharedEditorDocument = document
    }

    /// Which files autosave may write, for the quit flush to consult.
    ///
    /// Weak and static, adopted beside the document, for the same reasons. Here because
    /// `applicationShouldTerminate` is outside the view layer, and its flush is the one write in
    /// the app that happens with nobody looking.
    static weak var sharedAutosavePolicy: EditorAutosavePolicy?

    func adoptAutosavePolicy(_ policy: EditorAutosavePolicy) {
        Self.sharedAutosavePolicy = policy
    }

    /// The editor's disk watch, so the quit guard can ask whether a deleted file's text may be the
    /// only copy. Weak and static, adopted beside the document, for the same reasons.
    static weak var sharedDiskWatch: EditorDiskWatch?

    func adoptDiskWatch(_ watch: EditorDiskWatch) {
        Self.sharedDiskWatch = watch
    }

    /// Why autosave stopped on the open document, mirrored from the window for the quit alert's
    /// cause line. A value, so nothing is held.
    static var editorAutosaveStop: EditorAutosaveStop?

    /// The open PDF's tools, for the quit guard to ask about a pending page order — the one thing a
    /// PDF in Edit can lose. Weak and static, adopted beside the document, for the same reasons.
    static weak var sharedPDFTools: EditorPDFTools?

    func adoptPDFTools(_ tools: EditorPDFTools) {
        Self.sharedPDFTools = tools
    }

    /// The panes' PDF tools — a run started from a row's right-click menu, which the open PDF's
    /// tools know nothing of — for the quit guard to ask about the same way.
    static weak var sharedPanePDFTools: PanePDFTools?

    func adoptPanePDFTools(_ tools: PanePDFTools) {
        Self.sharedPanePDFTools = tools
    }

    /// Whether the quit flush may write the open document.
    ///
    /// A function apart from the plumbing because it is the decision, like `quitDecision`. With no
    /// policy adopted yet it answers `true`: refusing to save on quit over an unconnected wire
    /// would be the worse failure.
    static func mayFlushOnQuit(path: String?, policy: EditorAutosavePolicy?) -> Bool {
        guard let policy else { return true }
        return policy.isOn(path)
    }

    /// Wires the termination guard to `manager`, keeping the first one wired (instance and static
    /// ref). SwiftUI may re-run `App.init`, but `@State` keeps only the first manager alive, so
    /// re-wiring would point the guard at an orphan whose operation count is always 0.
    func adoptSyncManager(_ manager: FileSyncManager) {
        guard syncManager == nil, Self.sharedSyncManager == nil else { return }
        syncManager = manager
        Self.sharedSyncManager = manager
    }

    /// One-way sync's saved rows in Activity ▸ Now, read at launch with the reminders that came due
    /// while SyncCloud was closed, then hourly and on wake. Only in the installed app
    /// (`OneWaySyncLaunchGate`): a test host or another build beside it would read and write the
    /// user's saved rows and post the same reminders twice.
    private func startOneWaySyncNotices() {
        guard OneWaySyncLaunchGate.refusalForThisProcess() == nil,
              let directory = OneWaySyncStore.defaultDirectory() else { return }
        let center = ActivityCenter.shared
        center.postOneWaySyncNotice = { OneWaySyncNotifier.post($0) }
        center.attachOneWaySync(OneWaySyncNoticeStore(url: OneWaySyncStore(directory: directory).noticesURL))
        // Sync Now's state, read once; nothing syncs until asked.
        OneWaySyncController.shared.start()
        oneWaySyncReminders = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { ActivityCenter.shared.remindOneWaySync() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated { ActivityCenter.shared.remindOneWaySync() }
        }
    }

    private var oneWaySyncReminders: Timer?

    /// The rows' last save reaches the disk before the process ends, and so does the count of
    /// autosaves since each document's first (`EditorAutosaveTally`). Here, after every quit
    /// branch, so a cancelled quit doesn't close the tally out early; flushed, because nothing
    /// after this point flushes the log.
    func applicationWillTerminate(_ notification: Notification) {
        ActivityCenter.shared.flushOneWaySync()
        for line in EditorAutosaveTally.closeOutAll() { Logger.shared.info(line) }
        MainThreadStallWatch.shared.writeCount(because: "the app is quitting")
        Logger.shared.flushToDisk()
    }

    /// Launch breadcrumb — fires exactly once per process (unlike App.init, which SwiftUI may
    /// re-run), so the log's first line unambiguously names the build that produced the session.
    func applicationDidFinishLaunching(_ notification: Notification) {
        hasFinishedLaunching = true
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        // The level inside the parentheses, not after "launched": the install skill waits for a
        // line ending in "launched" (`.claude/skills/install-sync-cloud/SKILL.md` step 7). Read off
        // the live gate, so it states what this session's log actually keeps.
        Logger.shared.info(
            "SyncCloud \(version) (build \(build), log level \(Logger.shared.minimumLevel.settingName)) launched")
        if let line = LaunchTiming.report() { Logger.shared.info(line) }

        // The Go menu's ⌃⇥ / ⌃⇧⇥ twins: hidden behind their ⇧⌘ items, keys live.
        GoMenuDuplicates.install()
        // Where a right-click menu stood, so a Close Tab chosen from it keeps the strip.
        PaneMenuOrigin.shared.install()
        // Edit ▸ Undo and ⌘Z wait while a long run is going, on the file operations' stack.
        RunUndoGate.shared.install()
        // Window ▸ Activity carries ⌘L.
        ActivityMenuKey.install()
        // A background-completion notification's click opens its message in Activity.
        UNUserNotificationCenter.current().delegate = OperationNotificationClicks.shared
        startOneWaySyncNotices()

        // How this build is signed, on the very next line: ad-hoc means its first launch waits
        // behind the Documents-access dialog. A few milliseconds, so it runs inline and keeps the
        // lines adjacent. See `LaunchSignature`.
        Logger.shared.info(LaunchSignature.current().logLine)
        // After the signature line, which the install skill and CLAUDE.md §6 read as the line after
        // "launched". Says why the level above is not the one Settings shows.
        if let line = LaunchLogLevel.traceLine { Logger.shared.info(line) }

        // Which appearance the session draws selection and bar buttons in (glass or plain markers,
        // gliding or instant), at launch and whenever it changes (`GlassLogLine`).
        glassLogLine.start()

        // Which state the AppKit display-cycle guard is in, once per launch. The suppression is
        // app-wide for the session, every window included, so the log should say which state a
        // support session is looking at.
        //
        // Read back, so it reports the effective value: a `defaults write` or launch argument
        // beats the registration domain. `isArmed` checks `object(forKey:)` first, as AppKit does,
        // because `bool(forKey:)` alone reads "absent" as false while AppKit treats it as armed
        // (see `docs/columns-layout-loop.md` ▸ "Is the mitigation actually plumbed in").
        //
        // Here rather than in `App.init` because this fires exactly once.
        //
        // One line with the AutoFill guard, also read back rather than assumed, so a session that
        // hangs on a focused field can be told apart from one where the guard never took. Both
        // tags stay word for word: `docs/columns-layout-loop.md` greps the `[layout-guard]` words.
        Logger.shared.info(Self.launchGuardsLine(displayCycleArmed: DisplayCycleAssert.isArmed(in: .standard),
                                                 autoFillOff: AutoFillHeuristics.isOff(in: .standard)))

        // And how many passes the suppressed loop churns, when someone asks
        // (`docs/columns-layout-loop.md`). Off unless armed by hand, so an ordinary session installs
        // no hook; see `DisplayCycleTrace`. Here, not in `App.init`, so its "ARMED" line is
        // written once.
        DisplayCycleTrace.arm()

        // And the click side: whether a click reached a row at all, which no handler's stamp can
        // report for a dead click. Same arming switch, off by default; see `MouseDownProbe`.
        MouseDownProbe.arm()

        // What the stored pane bar cannot show, once per launch. A control taken off the bar is
        // gone rather than demoted into ⋯, so this line is the only trace of a missing one, and it
        // is written on every launch, not only those that migrate.
        //
        // Here, not in `App.init`, which SwiftUI may re-run and would repeat the line. After
        // `init`, so it reports the bar the session will draw.
        PaneBarMigration.reportStoredArrangementReach(defaults: .standard)
    }

    /// The quit guard's pure outcome, apart from the NSAlert plumbing so it is unit-testable.
    /// `applicationShouldTerminate` maps each case to a `TerminateReply`, logging the choice and
    /// flushing the log before any branch that quits with operations in flight.
    enum QuitDecision: Equatable {
        /// Nothing is in flight — quit freely, no breadcrumb needed.
        case allowNoActiveOperations
        /// Operations are in flight but the user disabled the warning — quit, but log first.
        case allowWithoutWarning(activeOperations: Int)
        /// Operations are in flight and the warning is enabled — must show the alert.
        ///
        /// `hasUnsavedDocument` travels with it: the file-operation warning leads but does not
        /// replace the document's, or "Quit Anyway" would drop unsaved typing the alert never
        /// mentioned.
        case warn(activeOperations: Int, hasUnsavedDocument: Bool)
        /// The editor holds a document that is not on disk, and nothing outranks saying so.
        ///
        /// Carries the operation count, unused by the wording, so the breadcrumb still records how
        /// many operations were in flight at termination.
        ///
        /// Not covered by `warnBeforeQuit`: that setting is about file operations, which the engine
        /// can finish or roll back, not typing that exists only in memory.
        case warnUnsavedDocument(activeOperations: Int)
    }

    /// The quit alert for a deleted file with nothing typed: Quit Anyway first, with Return taken
    /// off it, and Cancel second; on screen, Cancel · Quit Anyway.
    nonisolated static let quitGoneInformativeText = "Quitting now loses this text — it may be the only copy."
    nonisolated static let quitGoneButtonTitles = ["Quit Anyway", "Cancel"]

    /// What the File Operations in Progress alert adds about the open document: unsaved typing and
    /// why autosave didn't write it, or a deleted file whose text may be the only copy.
    nonisolated static func fileOperationsDocumentSentence(name: String, isDirty: Bool, isOnlyCopy: Bool,
                                                         cause: EditorAlerts.LeaveCause?) -> String {
        if isDirty {
            return " Unsaved changes to “\(name)” are discarded too." + (cause.map { " " + EditorAlerts.causeLine($0) } ?? "")
        }
        return isOnlyCopy ? " “\(name)” is no longer on disk, and its text may be the only copy." : ""
    }

    /// What ⌘Q says of a version kept beside the file by the final save. The flush counts it as
    /// saved and the window's banner is never drawn, so nothing else would say it.
    nonisolated static func keptAsideSentence(name: String, clause: String) -> String {
        "Saved “\(name)”, but \(clause)"
    }
    nonisolated static func keptAsideMessage(name: String) -> String {
        "Another version of “\(name)” was kept"
    }
    /// Quit first, the default: the save is on disk and nothing is lost; Don’t Quit stays to look.
    nonisolated static let keptAsideButtonTitles = ["Quit", "Don’t Quit"]

    /// Whether `decision` quits with no alert of its own — where the kept-aside one is shown.
    nonisolated static func quitsWithoutAsking(_ decision: QuitDecision) -> Bool {
        switch decision {
        case .allowNoActiveOperations, .allowWithoutWarning: return true
        case .warn, .warnUnsavedDocument: return false
        }
    }

    /// Pure decision: which quit path applies, given the in-flight operation count and the
    /// warn-before-quit setting, so `SyncCloudTests` can pin the branches without a modal.
    /// `nonisolated` so the tests need not hop to the main actor.
    nonisolated static func quitDecision(activeOperations: Int, warnBeforeQuit: Bool,
                                         hasUnsavedDocument: Bool = false) -> QuitDecision {
        guard activeOperations > 0 else {
            return hasUnsavedDocument ? .warnUnsavedDocument(activeOperations: 0)
                                      : .allowNoActiveOperations
        }
        // Operations in flight: their warning leads, a half-finished copy being the worse thing to
        // interrupt, and the buffer travels with it so one alert names both.
        if warnBeforeQuit {
            return .warn(activeOperations: activeOperations, hasUnsavedDocument: hasUnsavedDocument)
        }
        // The warning is off, and the buffer still asks: the setting covers file operations, not
        // typing that exists only in memory (see `warnUnsavedDocument`).
        return hasUnsavedDocument
            ? .warnUnsavedDocument(activeOperations: activeOperations)
            : .allowWithoutWarning(activeOperations: activeOperations)
    }

    /// A Dock click or reactivation with no visible windows brings the main window back; a single
    /// `Window` scene has no New Window fallback. SwiftUI keeps a closed scene window alive, so
    /// ordering it front restores its state; the identifier match keeps an auxiliary window from
    /// standing in for the app. If the window is truly gone, fall through to the default handling.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        guard let mainWindow = sender.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix(SyncCloudApp.mainWindowId) == true
        }) else { return true }
        mainWindow.makeKeyAndOrderFront(nil)
        return false
    }

    /// Files macOS hands the app to open, for the window to take. See ``ExternalOpen``.
    let externalOpens = ExternalOpenQueue()

    /// Whether this run's launch bootstrap has finished. See ``LaunchBootstrap``.
    let launchBootstrap = LaunchBootstrap()

    /// Set as `applicationDidFinishLaunching` begins. AppKit hands a launch's files to
    /// `application(_:open:)` before that, so a batch arriving while this is false is the one the
    /// app was launched to open.
    private var hasFinishedLaunching = false

    /// Finder's double-click and Open With, a drop on the Dock icon, `open -a SyncCloud <file>`.
    ///
    /// Queued, never acted on here: on a cold launch this arrives before the bootstrap has put the
    /// panes anywhere. It does not bring the window forward either; SwiftUI has already re-presented
    /// a closed or hidden window for the open event (which is also why `onAppear` runs again; see
    /// ``LaunchBootstrap``).
    func application(_ application: NSApplication, open urls: [URL]) {
        // The test host is SyncCloud.app too: Launch Services can hand it a double-click made
        // during a test run, and nothing there would ever take the queue. Logged, not swallowed.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            Logger.shared.info(ExternalOpen.receiptLine(urls) + " — this is a test host, which opens nothing")
            return
        }
        Logger.shared.info(ExternalOpen.receiptLine(urls, atLaunch: !hasFinishedLaunching))
        externalOpens.receive(urls, atLaunch: !hasFinishedLaunching)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A PDF's pending page order or running tool is asked about first, as on every route out
        // of the document (`settleEditorDocument`). It only asks, so a later "Don’t Quit" keeps the
        // order. A filled copy saved from the question quits once it lands. The question says
        // Quit, not Leave.
        if let tools = Self.sharedPDFTools, !tools.mayLeave(quitting: true, thenRetry: { NSApp.terminate(nil) }) {
            Logger.shared.info("Quit cancelled — the open PDF has work that would be lost")
            return .terminateCancel
        }
        if let tools = Self.sharedPanePDFTools, !tools.mayQuit() {
            Logger.shared.info("Quit cancelled — a pane's PDF tool is still running")
            return .terminateCancel
        }
        let manager = syncManager ?? Self.sharedSyncManager
        // A Restructure landing counts too: its re-derive queues nothing, and a quit there leaves
        // the survey on a folder with nothing learned in it yet.
        let activeOperations = manager?.operationsAQuitWouldInterrupt ?? 0
        // Respect the General setting; default to warning when the key was never written.
        let warnBeforeQuit = UserDefaults.standard.object(forKey: GeneralSettings.warnBeforeQuitKey) as? Bool ?? true

        // Flushed before it is asked about: the buffer is normally on disk already, and what ⌘Q can
        // still catch is the two-second debounce, which is better written than asked about.
        // `EditorAutosave.attempt` makes the timer's decision without the view layer.
        //
        // The question remains for what the flush could not write: a document autosave stopped on
        // (the file changed underneath it, or the volume refused) is still dirty, and quitting
        // would lose it.
        //
        // Never for a document whose autosave switch is off: the user said not to write it. The
        // buffer stays dirty, `hasUnsavedDocument` sees it, and the guard asks.
        // A word being composed is committed first, so the flush and the question see it.
        Self.sharedEditorDocument?.buffer.source.endComposition()
        let mayFlush = Self.mayFlushOnQuit(path: Self.sharedEditorDocument?.path,
                                           policy: Self.sharedAutosavePolicy)
        // Why the document is asked about, for the alert's cause line: what the flush just found,
        // else the stop the window last had.
        var stop = Self.editorAutosaveStop
        // A version that arrived during the final save, kept beside the file; said before the app
        // goes, since the window's banner for it never gets drawn.
        var keptAside: String?
        // A save that couldn't be checked is checked now: a file holding what it wrote counts as
        // saved, and is neither flushed again nor asked about.
        if let document = Self.sharedEditorDocument, document.uncheckedWrite != nil,
           EditorFileStore.settleUncheckedWrite(of: document) {
            Logger.shared.info("Checked the editor's last save before quitting — the file holds what it wrote")
            if case .unchecked = stop { stop = nil }
        }
        if let document = Self.sharedEditorDocument, mayFlush {
            switch EditorAutosave.attempt(document) {
            case .wrote:
                Logger.shared.info("Flushed the editor's document before quitting")
            case .blocked(let divergence):
                stop = .diverged(divergence)
                Logger.shared.warning(
                    "Could not flush the editor's document before quitting: it \(divergence == .missing ? "is no longer where it was opened" : "changed on disk")")
            case .failed(let message):
                stop = .failed(message)
                Logger.shared.warning("Could not flush the editor's document before quitting — \(message)")
            case .savedUnchecked(let clause):
                stop = .unchecked(clause)
                Logger.shared.warning("Flushed the editor's document before quitting, but \(clause)")
            case .wroteKeepingAside(let clause):
                // Saved and checked; the version it displaced is beside it, said in the log and to
                // the reader below before quitting.
                keptAside = clause
                Logger.shared.warning("Flushed the editor's document before quitting, but \(clause)")
            case .nothingToDo:
                break
            }
        } else if let document = Self.sharedEditorDocument, document.isDirty {
            Logger.shared.info(
                "Did not flush “\(document.name)” before quitting — autosave is off for it")
        }
        let isDirty = Self.sharedEditorDocument?.isDirty ?? false
        // A deleted file with nothing typed is asked about too: its text may be the only copy. The
        // watch looks first, so a move is followed; a file still in the Trash isn't asked about.
        let watch = Self.sharedDiskWatch
        if !isDirty, watch?.isGone == true { watch?.reconcile() }
        let isOnlyCopy = !isDirty && watch?.mayBeTheOnlyCopy == true
        let hasUnsavedDocument = isDirty || isOnlyCopy
        let cause = EditorAlerts.leaveCause(isGone: watch?.isGone ?? false, stop: stop, autosaveOff: !mayFlush)

        let decision = Self.quitDecision(activeOperations: activeOperations, warnBeforeQuit: warnBeforeQuit,
                                         hasUnsavedDocument: hasUnsavedDocument)
        let documentName = Self.sharedEditorDocument?.name ?? "the open document"
        // A quit that would ask nothing says where the other version went; the file operations
        // alert carries it as a sentence instead, so ⌘Q never asks twice.
        if let keptAside, Self.quitsWithoutAsking(decision) {
            let alert = NSAlert()
            alert.messageText = Self.keptAsideMessage(name: documentName)
            alert.informativeText = Self.keptAsideSentence(name: documentName, clause: keptAside)
            for title in Self.keptAsideButtonTitles { alert.addButton(withTitle: title) }
            alert.alertStyle = .informational
            if alert.runModal() != .alertFirstButtonReturn {
                Logger.shared.info("User chose Don’t Quit to look at the version kept beside “\(documentName)”")
                return .terminateCancel
            }
        }

        switch decision {
        case .allowNoActiveOperations:
            // A clean quit gets a closing line, so a log that stops without one reads as a crash or
            // force-kill. The "Quit Anyway" paths below write their own last line.
            Logger.shared.info("SyncCloud is quitting")
            // Even a clean quit must flush: the log writer runs at background QoS with no implicit
            // flush, so late lines could be lost at exit. The sync-history writer buffers the same
            // way, or the newest run's records would vanish on quit.
            Logger.shared.flushToDisk()
            SyncHistoryStore.shared.flushToDisk()
            return .terminateNow

        case .allowWithoutWarning(let count):
            // Quitting mid-operation is the event most tied to crash-time corruption, so record it
            // and flush before quitting. Not "chose Quit Anyway": no dialog was shown, so the line
            // names the setting that decided.
            Logger.shared.info("Quitting with \(count) active file operation(s) — warn-before-quit is switched off")
            Logger.shared.flushToDisk()
            SyncHistoryStore.shared.flushToDisk()
            return .terminateNow

        case .warn(let count, let unsaved):
            let alert = NSAlert()
            alert.messageText = "File Operations in Progress"
            // The document's sentence is appended, not given its own alert: two modal questions in
            // a row teach people to dismiss both unread.
            let name = Self.sharedEditorDocument?.name ?? "the open document"
            alert.informativeText = "Quitting now may cause data corruption or partial synchronization."
                + Self.fileOperationsDocumentSentence(name: name, isDirty: isDirty, isOnlyCopy: isOnlyCopy,
                                                      cause: unsaved ? cause : nil)
                + (keptAside.map { " " + Self.keptAsideSentence(name: name, clause: $0) } ?? "")
                + " Are you sure you want to quit?"
            // "Don’t Quit", not "Wait": nothing quits once the copies finish, so the button
            // cancels the quit and should say so.
            alert.addButton(withTitle: "Don’t Quit")
            alert.addButton(withTitle: "Quit Anyway")
            alert.alertStyle = .warning
            // The destructive answer gives up Return, as everywhere else in the app; here it can
            // also drop a buffer.
            alert.buttons.last?.keyEquivalent = ""
            alert.buttons.last?.hasDestructiveAction = true

            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                Logger.shared.info("User chose Quit Anyway with \(count) active file operation(s)"
                    + (unsaved ? " and unsaved changes to “\(name)”" : ""))
                Logger.shared.flushToDisk()
                SyncHistoryStore.shared.flushToDisk()
                return .terminateNow
            } else {
                Logger.shared.info("User chose Don’t Quit with \(count) active file operation(s) in progress")
                return .terminateCancel
            }

        case .warnUnsavedDocument(let count) where isOnlyCopy:
            // Nothing typed, and the file gone: the text on screen may be the only copy. Quitting
            // can't write it back, so the question is Quit Anyway or Cancel, and Return does
            // nothing.
            let name = Self.sharedEditorDocument?.name ?? "the open document"
            let alert = NSAlert()
            alert.messageText = EditorAlerts.goneMessage(name: name)
            alert.informativeText = Self.quitGoneInformativeText
            for title in Self.quitGoneButtonTitles { alert.addButton(withTitle: title) }
            alert.alertStyle = .warning
            alert.buttons[0].keyEquivalent = ""
            alert.buttons[0].hasDestructiveAction = true
            if alert.runModal() == .alertFirstButtonReturn {
                Logger.shared.warning("User chose Quit Anyway with “\(name)” no longer on disk — its text may have been the only copy"
                    + (count > 0 ? ", and \(count) active file operation(s)" : ""))
                Logger.shared.flushToDisk()
                SyncHistoryStore.shared.flushToDisk()
                return .terminateNow
            }
            Logger.shared.info("User cancelled quitting — “\(name)” is no longer on disk, and its text may be the only copy")
            return .terminateCancel

        case .warnUnsavedDocument(let count):
            let name = Self.sharedEditorDocument?.name ?? "the open document"
            let alert = NSAlert()
            alert.messageText = "“\(name)” has unsaved changes"
            // Cancel, not Save: saving here would run the divergence check and its prompt inside a
            // termination handler, on state being torn down. Back in the editor, ⌘S is one
            // keystroke away. The cause line comes first: why autosave didn't write them.
            alert.informativeText = (cause.map { EditorAlerts.causeLine($0) + " " } ?? "")
                + "Quitting now discards them. Cancel to go back and save with "
                + "\(AppChord.saveDocument.display)."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Discard Changes")
            alert.alertStyle = .warning
            // The destructive answer gives up Return, as it does everywhere else in the app.
            alert.buttons.last?.keyEquivalent = ""
            alert.buttons.last?.hasDestructiveAction = true

            if alert.runModal() == .alertSecondButtonReturn {
                Logger.shared.warning("User chose Discard Changes and quit with “\(name)” unsaved"
                    + (count > 0 ? " and \(count) active file operation(s)" : ""))
                Logger.shared.flushToDisk()
                SyncHistoryStore.shared.flushToDisk()
                return .terminateNow
            }
            Logger.shared.info("User cancelled quitting to save “\(name)”")
            return .terminateCancel
        }
    }
}

/// The `[glass]` line in `~/sync-cloud.log`: which path the session draws selection and bar buttons
/// on (`SelectionLensAppearance.logLine`). Written at launch and again whenever it would read
/// differently (a Glass effect, accent or Tint, or an accessibility display option), so a report
/// can be read against the path in force when it happened.
///
/// **Never** observe on `queue: .main`: a queue-based observer makes the poster wait, and
/// `UserDefaults.didChangeNotification` is posted by whatever thread wrote the default, possibly a
/// background writer holding a lock the main thread is waiting on, a deadlock. So the observer
/// only schedules a main-actor turn, and a burst of writes schedules one.
@MainActor
final class GlassLogLine {
    private var last: String?
    private var observers: [NSObjectProtocol] = []
    /// Whether a main-actor turn to re-read the line is already on its way.
    private let scheduled = GlassLogLinePending()

    /// Nonisolated so the app delegate can hold one as a plain stored property.
    nonisolated init() {}

    func start() {
        log()
        // Runs on the posting thread, whatever it is; must not block it.
        let changed: @Sendable (Notification) -> Void = { [weak self, scheduled] _ in
            guard scheduled.claim() else { return }
            Task { @MainActor in
                scheduled.release()
                self?.log()
            }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil, using: changed))
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil,
            queue: nil, using: changed))
    }

    /// Stops following changes — for a test; the app's lasts the session.
    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
    }

    private func log() {
        let workspace = NSWorkspace.shared
        let line = SelectionLensAppearance.stored(in: .standard).logLine(
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            increasedContrast: workspace.accessibilityDisplayShouldIncreaseContrast)
        guard line != last else { return }
        last = line
        Logger.shared.info(line)
    }
}

/// `GlassLogLine`'s "a re-read is already scheduled" flag, claimed from any thread.
final class GlassLogLinePending: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false

    /// True for the caller that should schedule the re-read; false while one is already on its way.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !pending else { return false }
        pending = true
        return true
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        pending = false
    }
}

/// The main window's run lock, for the Activity window: Sync History's Undo Last Run waits during a
/// long run as Edit ▸ Undo does. Observes the manager here, so the scene body does not.
private struct RunWriteLockFromManager: ViewModifier {
    @ObservedObject var syncManager: FileSyncManager

    func body(content: Content) -> some View {
        content.environment(\.runWriteLock,
                            syncManager.activeProgress.map { $0.runLockReason ?? Progress.genericRunLockReason })
    }
}

/// The Activity window's content, observing the manager so its Running rows follow the file
/// operation the main window publishes.
private struct ActivityWindowHost: View {
    @ObservedObject var syncManager: FileSyncManager
    let settings: SettingsManager

    var body: some View {
        ActivityWindow(center: .shared, activeProgress: syncManager.activeProgress,
                       activeProgressStartedAt: syncManager.activeProgressStartedAt,
                       runWriteLock: syncManager.activeProgress.map { $0.runLockReason ?? Progress.genericRunLockReason },
                       scans: ActivityScanRows.rows(syncManager) { ActivityCenter.shared.doors.showScan($0) }) {
            // One-way sync's History entries, with Reverse in iCloud…, above Sync History.
            OneWaySyncHistoryHost()
            SyncHistoryView(
                store: .shared,
                // Settings changed from Ask Claude's chat, with Revert, among the records.
                settings: HistorySettingsChanges(
                    lookup: {
                        SettingsLookup(defaults: .standard, settings: settings, keyIsSaved: { AnthropicKeychain.isConfigured },
                                       hiddenCount: { 0 }, isHidden: { AskClaudePrivacy.Matcher(AskClaudePrivacy.hiddenFolders(in: .standard)).isHidden($0) },
                                       loginItemIsOn: { LoginItemController.shared.isOn })
                    },
                    writer: { SettingsWriter(defaults: .standard, settings: settings) },
                    hiddenNames: { AskClaudePrivacy.hiddenFolders(in: .standard).map { ($0 as NSString).lastPathComponent } },
                    lists: { SettingsLists(settings: settings, sync: syncManager, defaults: .standard) },
                    people: { SettingsPeople(store: syncManager.filingPeopleStore) }),
                runFilter: Binding(get: { ActivityCenter.shared.historyRun },
                                   set: { ActivityCenter.shared.historyRun = $0 }),
                showsTitle: false,
                onUndoLastSyncRun: {
                    // Prompts only when the last recorded run is still on top of the undo stack;
                    // otherwise the reason comes back and the tab shows it itself.
                    syncManager.undoLastSyncRunAskingFirst(confirm: SyncOperationAlerts.confirmUndoLastSyncRun)
                })
            // Launch at login is macOS's: read before a settings change's Revert compares with it.
            .task { await LoginItemController.shared.refresh().value }
        }
        // One-way sync's sheets opened from Now's rows and History, over this window.
        .oneWaySyncSheets(host: .activity)
    }
}

/// One-way sync's History entries over Sync History's, in a height of their own, only when it
/// has any.
private struct OneWaySyncHistoryHost: View {
    @ObservedObject var controller = OneWaySyncController.shared

    var body: some View {
        if controller.isSetUp {
            ScrollView { OneWaySyncHistoryRows() }
                .frame(maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
        }
    }
}

/// How long launch held the main thread before the first window: App.init's own time, and from
/// its start to `applicationDidFinishLaunching`. First init only, since SwiftUI may re-run
/// `App.init` and a later run says nothing about launch.
@MainActor
enum LaunchTiming {
    private static var began: ContinuousClock.Instant?
    private static var ended: ContinuousClock.Instant?

    static func initBegan() { if began == nil { began = .now } }
    static func initEnded() { if ended == nil, began != nil { ended = .now } }

    /// The `[launch]` line, or nil when App.init was never timed.
    static func report(now: ContinuousClock.Instant = .now) -> String? {
        guard let began, let ended else { return nil }
        func ms(_ d: Duration) -> Int {
            Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
        }
        return "[launch] App.init took \(ms(ended - began)) ms; launched \(ms(now - began)) ms after it began"
    }
}
