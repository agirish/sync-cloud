import SwiftUI
import AppKit
import Sync
import Events
import Settings
import FileExplorer
import Dashboard
import QuickLook
import Design

/// Main window content: provider sidebar, two file panes (left/right), toolbar, and bottom tab (Differences / Details).
struct ContentView: View {
    @ObservedObject var syncManager: FileSyncManager
    @EnvironmentObject var settings: SettingsManager

    /// Drives the in-window settings overlay (owned by the App so ⌘, can open it).
    @Binding var showSettings: Bool
    /// Drives the in-window Help overlay (owned by the App so the Help ▸ SyncCloud Help / ⌘?
    /// menu command can open it). ContentView renders it and owns dismissal.
    @Binding var showHelp: Bool
    /// Whether the once-per-session part of the `onAppear` bootstrap has already run. Owned by
    /// the App (session-scoped, never persisted) because closing and Dock-reopening the single
    /// window recreates ContentView and all its `@State` — a view-owned flag would forget.
    @Binding var hasBootstrappedSession: Bool
    /// Which settings tab the overlay shows. Owned here so it persists across open/close and can
    /// be preset (e.g. the invalid-pane fix-it action jumps straight to Providers).
    @State private var settingsTab: SettingsView.SettingsTab = .appearance

    @AppStorage("selectedLeftProviderId") var leftProviderId: String = "iCloud"
    @AppStorage("selectedRightProviderId") var rightProviderId: String = "iCloud"
    @State var isScanning = false

    /// First-run welcome gate (H1). Persisted; set when the welcome tour is dismissed with "Don't
    /// show this again" left checked (the default), so it auto-shows once per install.
    @AppStorage(FirstRunWelcome.hasSeenDefaultsKey) private var hasSeenFirstRunWelcome: Bool = false
    /// Whether the welcome tour has been dismissed for the rest of this session. App-owned (a
    /// binding) for the same reason as `hasBootstrappedSession`: a window close + Dock reopen
    /// recreates ContentView and its @State, and the tour shouldn't reappear after the user already
    /// dismissed it. Separate from the persisted flag so an unchecked "Don't show this again" can
    /// hide the tour now yet let it return next launch. Help ▸ Welcome to SyncCloud flips this back
    /// to false to re-summon the tour mid-session.
    @Binding var welcomeDismissedThisSession: Bool

    /// Number of provider-id `onChange` notifications still expected from an in-flight pane
    /// swap. A swap flips both @AppStorage ids at once, which would fire both id onChanges and
    /// drive two navigation resets that wipe the focus/selection the swap just moved to the
    /// other side. Each suppressed onChange decrements this; the swap action seeds it with the
    /// number of ids that actually change (2, or 0 when both panes already share a provider) so
    /// later real provider switches are never suppressed.
    @State private var pendingSwapProviderChanges: Int = 0

    /// Active "compare two duplicate copies" handoff from Tidy: the keeper (left pane) and the
    /// redundant copy (right pane) opened in Compare, plus the duplicate scan root to re-scan once
    /// the right copy is trashed. Drives the keep-left / trash-right banner over Compare; nil when
    /// no such review is in progress.
    @State private var duplicateReview: DuplicateCompareContext? = nil

    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) var openWindow

    @State var actionHandler: FileActionHandler?
    @State var quickLookURL: URL? = nil
    @State private var isBootstrappingProviders: Bool = true
    /// Guided-review state, owned here so it outlives DifferencesView — that view unmounts on
    /// a Details-tab peek and whenever the live differences list goes empty, and the session
    /// (plus any in-flight copy's outcome) must survive both.
    @StateObject private var reviewStore = ReviewSessionStore()
    
    @AppStorage(LiquidGlass.intensityKey) private var glassIntensity: Double = 0.65
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0

    /// Left pane's share of the pane row's width (0…1). Persisted so the split survives relaunches.
    /// Drives the custom two-pane split that replaced HSplitView, whose NSSplitView divider bled
    /// up through the `.hiddenTitleBar` toolbar band; a SwiftUI HStack + divider respects the
    /// toolbar's safe area, so the divider now starts at the pane headers.
    @AppStorage("mainPaneSplitFraction") var paneSplitFraction: Double = 0.5
    /// Live split fraction while the divider is being dragged; nil when idle. Kept in @State so a
    /// drag updates smoothly without rewriting @AppStorage every frame — it's persisted once, on
    /// drag end. `mainContentView` reads this in preference to `paneSplitFraction` mid-drag.
    @State var paneDragFraction: Double? = nil

    /// The bottom (Differences/Details) pane's share of the content height. Persisted so it
    /// survives relaunches and never resets when switching the Differences/Details tab.
    @AppStorage("mainBottomPaneFraction") var bottomPaneFraction: Double = 0.4
    /// Live vertical-split fraction while dragging; nil when idle (persisted once on release).
    @State var verticalDragFraction: Double? = nil

    /// The single-source source rail's share of the content width when expanded (Tidy). Persisted
    /// like the other split fractions; the workspace fills the rest.
    @AppStorage("tidyRailFraction") var railFraction: Double = 0.28
    /// Live rail-split fraction while dragging; nil when idle (persisted once on release).
    @State var railDragFraction: Double? = nil

    var surfaceStyle: SurfaceStyle {
        SurfaceStyle(rawValue: surfaceStyleRaw) ?? .unified
    }
    private var glassHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: glassHueRaw) ?? .blue
    }

    /// Represents the available top-level tabs. Compare shows the two provider panes; Tidy is the
    /// single-source hub. (Details is no longer a tab — it's the Info inspector inside Compare.)
    enum BottomTab: String, CaseIterable {
        /// Differential scanning results and sync actions, across the two panes.
        case differences = "Differences"
        /// Single-provider hub: Duplicates, Organize, Automations, and the read-only Storage lens.
        case tidy = "Tidy"

        /// The label shown in the tab picker. Kept separate from `rawValue` so the display name can
        /// change without breaking the persisted `selectedBottomTab` id (Differences shows as
        /// "Compare").
        var title: String {
            switch self {
            case .differences: return "Compare"
            case .tidy: return "Tidy"
            }
        }
    }
    /// Persisted so a user who was on Details stays there across launches. Stored by
    /// `BottomTab` raw value — SyncCloudTests pins the raw values as a stable format.
    @AppStorage("selectedBottomTab") private var selectedBottomTab: BottomTab = .differences

    /// The active Tidy lens, lifted here (from TidyView) so its picker lives in the persistent tab
    /// strip and its selection survives tab switches and relaunches. Storage Lens is one of these now.
    @AppStorage("selectedTidyLens") private var selectedTidyLens: TidyLens = .duplicates

    /// Per-tab override of the top-pane visibility, a JSON map (tab raw value → hidden).
    /// Empty means "no overrides — every tab uses its default". Persisted, so deliberately
    /// showing or hiding the Left/Right panes on Tidy or Storage Lens sticks across launches.
    @AppStorage("topPaneOverridesByTab") private var topPaneOverridesRaw: String = ""

    /// Whether the Compare Info inspector is shown. It replaces the old Details tab: a toggleable
    /// right-side panel that shows metadata (and both-sides status) for the current selection.
    /// Persisted so it stays open/closed across launches.
    @AppStorage("showCompareInspector") private var showInspector: Bool = false
    /// The Info inspector's persisted width, resizable by dragging its leading edge. Defaults to the
    /// former fixed 270pt. Clamped to `PaneLogic.inspector{Min,Max}Width` whenever it's written.
    @AppStorage("compareInspectorWidth") private var inspectorWidth: Double = 270
    /// The live width during a resize drag; `nil` when idle. Mirrors the pane splits' pattern —
    /// the layout reads `inspectorDragWidth ?? inspectorWidth`, and the drag commits to
    /// `inspectorWidth` only on release, so `inspectorWidth` stays the stable drag-start base.
    @State private var inspectorDragWidth: Double? = nil
    /// An explicit "Get Info" target for the inspector, from a pane or differences-row right-click.
    /// Overrides the pane selection; cleared when the pane selection changes so the inspector then
    /// follows the selection again.
    @State private var infoPath: String? = nil

    @State private var bannerDismissScheduler = BannerDismissScheduler()

    // Per-pane diff lookups for the tree rows, rebuilt only when the differences
    // or pane roots change (not per render — the panes re-render per file during
    // bulk sync, and rebuilding walks every difference's ancestor chain).
    @State private var leftDiffIndex: DiffStatusIndex = .empty
    @State private var rightDiffIndex: DiffStatusIndex = .empty

    /// Everything the tree diff indices are derived from, as one Equatable value
    /// so a single task(id:) covers scan results, navigation, and provider switches.
    private struct DiffIndexInputs: Equatable, Sendable {
        let differences: [FileDifference]
        let leftRoot: String
        let rightRoot: String
    }

    private var diffIndexInputs: DiffIndexInputs {
        DiffIndexInputs(differences: syncManager.differences, leftRoot: currentLeftPath, rightRoot: currentRightPath)
    }

    /// Resolves the left and right provider IDs from the current list (e.g. after provider list changes or bootstrap).
    /// - Parameter preferDistinctPair: If `true`, when both sides would be the same, pick a different provider for the right.
    /// - Returns: `(leftId, rightId)` or `nil` if there are no providers.
    static func resolvedProviderSelection(
        providers: [CloudProvider],
        currentLeftId: String,
        currentRightId: String,
        preferDistinctPair: Bool
    ) -> (leftId: String, rightId: String)? {
        guard let first = providers.first?.id else { return nil }

        var leftId = currentLeftId
        if !providers.contains(where: { $0.id == leftId }) {
            leftId = first
        }

        let fallbackRight = providers.first(where: { $0.id != leftId })?.id ?? leftId
        var rightId = currentRightId
        let rightExists = providers.contains(where: { $0.id == rightId })
        if !rightExists || (preferDistinctPair && rightId == leftId) {
            rightId = fallbackRight
        }

        return (leftId, rightId)
    }

    /// Whether either pane's provider differs between two versions of the enabled-provider
    /// list — by value, so a root-path edit counts, but changes to other providers don't.
    static func paneProvidersChanged(
        old: [CloudProvider],
        new: [CloudProvider],
        leftId: String,
        rightId: String
    ) -> Bool {
        func provider(_ id: String, in providers: [CloudProvider]) -> CloudProvider? {
            providers.first(where: { $0.id == id })
        }
        return provider(leftId, in: old) != provider(leftId, in: new)
            || provider(rightId, in: old) != provider(rightId, in: new)
    }

    /// The window content with its overlays, animations, and background. Split out of `body` so the
    /// full modifier chain stays under the Swift type-checker's budget — `mainContentView` is a heavy
    /// `some View` now (it owns the tab strip, panes, and workspace), and chaining everything on it in
    /// one expression times the checker out.
    private var chromedContent: some View {
        // No provider sidebar: provider choice now rides on each pane/source header (ProviderMenu),
        // so the window is a single content column — the panes fill the space the sidebar used to take.
        mainContentView
            .frame(minWidth: 600)
            .toolbar { mainToolbar }
        .overlay {
            if showSettings {
                settingsOverlay
            } else if showHelp {
                helpOverlay
            } else if !welcomeDismissedThisSession && !isBootstrappingProviders && FirstRunWelcome.shouldShow(hasSeenWelcome: hasSeenFirstRunWelcome) {
                // Wait for provider discovery to finish before showing the welcome card.
                // Its primary action is derived from enabledProviders.count, which is empty at
                // first render (discovery runs async in onAppear); showing it early would flash
                // the "Choose providers…" front door and then flip to "Scan now" once ≥2
                // providers are found.
                firstRunOverlay
            }
        }
        .animation(.easeOut(duration: 0.15), value: showSettings)
        .animation(.easeOut(duration: 0.15), value: showHelp)
        .animation(.easeOut(duration: 0.15), value: hasSeenFirstRunWelcome)
        .animation(.easeOut(duration: 0.15), value: welcomeDismissedThisSession)
        .animation(.easeOut(duration: 0.15), value: isBootstrappingProviders)
        // The overlays are mutually exclusive; Settings wins the precedence above. Close Help
        // from every Settings entry point (toolbar, ⌘,, the invalid-pane fix-it) so it can't be
        // left lingering underneath a Settings card the user opened on top of it.
        .onChange(of: showSettings) { _, isOpen in
            if isOpen { showHelp = false }
        }
        .quickLookPreview($quickLookURL)
        .liquidGlassAppBackground(intensity: glassIntensity, hue: glassHue)
    }

    var body: some View {
        chromedContent
        .alert(
            syncManager.currentError?.title ?? "Something Went Wrong",
            isPresented: Binding(
                get: { syncManager.currentError != nil },
                // Clearing currentError also drops its retry handler (via the manager's didSet).
                set: { _ in syncManager.currentError = nil }
            ),
            presenting: syncManager.currentError
        ) { error in
            // Buttons come straight from the tested pure decision, so the UI can't drift from it.
            ForEach(error.alertActions(hasRetryHandler: syncManager.currentErrorRetry != nil), id: \.self) { action in
                errorAlertButton(action, for: error)
            }
        } message: { error in
            Text(errorAlertMessage(error))
        }
        .onReceive(syncManager.$isScanning) { scanning in
            withAnimation { isScanning = scanning }
        }
        .onReceive(syncManager.refreshSubject) { _ in
            refreshAction()
        }
        .onAppear {
            // Closing and Dock-reopening the single window recreates ContentView, so this
            // block runs again mid-session. PaneLogic.bootstrapSteps owns the once-per-session
            // vs per-window split: re-running the session steps would discard a mid-session
            // hidden-files toggle and re-apply the distinct-pair provider selection over panes
            // the user may have deliberately set to the same provider.
            let isFirstAppearance = !hasBootstrappedSession
            hasBootstrappedSession = true
            for step in PaneLogic.bootstrapSteps(isFirstAppearance: isFirstAppearance) {
                switch step {
                case .resetShowHiddenFilesFromDefault:
                    // General setting: start the session with hidden files shown when the user asked for it.
                    syncManager.showHiddenFiles = UserDefaults.standard.bool(forKey: GeneralSettings.showHiddenByDefaultKey)
                case .honorOpenSettingsOnLaunch:
                    // Diagnostic hook: `defaults write com.abhishekgirish.SyncCloud
                    // openSettingsOnLaunch -bool YES` opens the Settings overlay at startup, so
                    // automated verification can reach it without synthesizing input. No-op
                    // unless explicitly armed; honors `settingsSelectedTab` for the initial tab.
                    if UserDefaults.standard.bool(forKey: "openSettingsOnLaunch") {
                        let storedTab = UserDefaults.standard.string(forKey: SettingsView.selectedTabDefaultsKey) ?? ""
                        settingsTab = SettingsView.SettingsTab(rawValue: storedTab) ?? .appearance
                        showSettings = true
                    }
                case .createActionHandler:
                    actionHandler = FileActionHandler(syncManager: syncManager, settings: settings)
                case .rewireUndoManager:
                    syncManager.undoManager = undoManager
                case .syncProviderQuirkSettings:
                    syncManager.ignoreGoogleDriveNewerDateOnly = settings.ignoreGoogleDriveNewerDateOnly
                    syncManager.sortOption = settings.defaultSortOption
                    syncManager.dateToleranceSeconds = settings.dateToleranceSeconds
                    syncManager.autoVerifySameSizeDuringScan = settings.autoVerifySameSizeDuringScan
                    syncManager.rememberIgnoredItems = settings.rememberIgnoredItems
                    syncManager.ignorePatterns = settings.ignorePatterns
                    // The durable ignore store outlives this view on the manager (window
                    // reopen recreates ContentView); create once, re-key on provider changes.
                    if syncManager.ignoredItemsStore == nil {
                        syncManager.ignoredItemsStore = IgnoredItemsStore()
                    }
                    syncManager.ignoredItemsStore?.activate(
                        pairKey: IgnoredItemsStore.pairKey(leftProviderId, rightProviderId))
                case .discoverProvidersAndApplyInitialSelection:
                    Task { @MainActor in
                        await settings.discoverProviders()
                        applyProviderSelection(preferDistinctPair: true)
                        syncManager.ignoredItemsStore?.activate(
                            pairKey: IgnoredItemsStore.pairKey(leftProviderId, rightProviderId))
                        // First appearance only (this step never runs on a window reopen):
                        // put each pane back on the folder it showed last session before the
                        // initial refresh scans.
                        await restoreLastPaneFocusIfEnabled()
                        if !settings.enabledProviders.isEmpty {
                            refreshAction()
                        }
                        isBootstrappingProviders = false
                    }
                case .endProviderBootstrapGuard:
                    isBootstrappingProviders = false
                }
            }
        }
        .onChange(of: leftProviderId) { _, newId in
            guard !isBootstrappingProviders else { return }
            // A pane swap flips this id itself; its navigation was already swapped atomically,
            // so skip the reset (which would wipe it) and let swapPanesAction drive the rescan.
            if pendingSwapProviderChanges > 0 {
                pendingSwapProviderChanges -= 1
                return
            }
            Logger.shared.info("User switched left provider to \(newId)")
            endReviewForComparisonChange()
            duplicateReview = nil   // a manual provider switch takes over Compare; don't restore later
            syncManager.clearDuplicates()   // stale Tidy results must not outlive their provider
            syncManager.clearFiling()
            syncManager.clearAutomationDryRun()   // and the stale dry-run preview
            syncManager.ignoredItemsStore?.activate(
                pairKey: IgnoredItemsStore.pairKey(newId, rightProviderId))
            // resetNavigation() fires refreshSubject, which onReceive above turns into a refresh.
            syncManager.resetNavigation()
        }
        .onChange(of: rightProviderId) { _, newId in
            guard !isBootstrappingProviders else { return }
            if pendingSwapProviderChanges > 0 {
                pendingSwapProviderChanges -= 1
                return
            }
            Logger.shared.info("User switched right provider to \(newId)")
            endReviewForComparisonChange()
            duplicateReview = nil   // a manual provider switch takes over Compare; don't restore later
            syncManager.clearDuplicates()   // stale Tidy results must not outlive their provider
            syncManager.clearFiling()
            syncManager.clearAutomationDryRun()   // and the stale dry-run preview
            syncManager.ignoredItemsStore?.activate(
                pairKey: IgnoredItemsStore.pairKey(leftProviderId, newId))
            syncManager.resetNavigation()
        }
        // The Info inspector reads the selection directly, so a selection change no longer needs to
        // switch tabs — it just clears any explicit "Get Info" target so the inspector follows the
        // new selection.
        .onChange(of: syncManager.selectedLeftPaths) { _, _ in infoPath = nil }
        .onChange(of: syncManager.selectedRightPaths) { _, _ in infoPath = nil }
        // Watches the enabled subset (not the full discovered list) so toggling a provider
        // off in Settings re-resolves any pane that was showing it and rescans.
        .onChange(of: settings.enabledProviders) { oldProviders, newProviders in
            let previousLeftId = leftProviderId
            let previousRightId = rightProviderId
            applyProviderSelection(preferDistinctPair: isBootstrappingProviders)
            guard !isBootstrappingProviders else { return }
            // If re-resolution switched a pane's provider, its id onChange below already
            // refreshes via resetNavigation — don't schedule a second scan here.
            guard leftProviderId == previousLeftId, rightProviderId == previousRightId else { return }
            // Only rescan when a pane's own provider changed (e.g. its root path was
            // edited). Toggling or re-pathing a provider neither pane shows must not
            // reload the trees — that spurious rescan put spinners over both panes
            // on every unrelated Settings edit.
            if Self.paneProvidersChanged(
                old: oldProviders,
                new: newProviders,
                leftId: previousLeftId,
                rightId: previousRightId
            ) {
                // Same pane ids, different root underneath: the current trees and
                // differences were built against the old root, so drop them before the
                // rescan rather than leaving their stale absolute paths clickable.
                endReviewForComparisonChange()
                syncManager.invalidateComparisonState()
                refreshAction()
            }
        }
        .modifier(SettingsEngineMirrors(syncManager: syncManager, settings: settings))
        // Rebuilding the indices walks every difference's ancestor chain — with tens of
        // thousands of differences that froze the main thread after every scan, so the
        // work runs detached and only the results land on main. task(id:) also cancels a
        // stale rebuild when the inputs change again mid-flight.
        .task(id: diffIndexInputs) {
            let inputs = diffIndexInputs
            let (left, right) = await Task.detached(priority: .userInitiated) {
                (DiffStatusIndex(differences: inputs.differences, rootPath: inputs.leftRoot),
                 DiffStatusIndex(differences: inputs.differences, rootPath: inputs.rightRoot))
            }.value
            guard !Task.isCancelled else { return }
            leftDiffIndex = left
            rightDiffIndex = right
        }
    }
    
    /// The settings→engine mirror handlers, extracted as a modifier: chaining them all
    /// inline pushed the body expression past the type-checker's budget (the same failure
    /// mode that split the Differences Table into per-cell structs).
    private struct SettingsEngineMirrors: ViewModifier {
        @ObservedObject var syncManager: FileSyncManager
        @ObservedObject var settings: SettingsManager

        func body(content: Content) -> some View {
            content
                .onChange(of: settings.ignoreGoogleDriveNewerDateOnly) { _, new in
                    syncManager.ignoreGoogleDriveNewerDateOnly = new
                }
                // The remaining Sync-tab settings mirror the same way; the manager's didSets
                // decide whether a change needs a refilter (ignores) or a rescan (tolerance,
                // verification).
                .onChange(of: settings.dateToleranceSeconds) { _, new in
                    syncManager.dateToleranceSeconds = new
                }
                .onChange(of: settings.autoVerifySameSizeDuringScan) { _, new in
                    syncManager.autoVerifySameSizeDuringScan = new
                }
                .onChange(of: settings.rememberIgnoredItems) { _, new in
                    syncManager.rememberIgnoredItems = new
                }
                .onChange(of: settings.ignorePatterns) { _, new in
                    syncManager.ignorePatterns = new
                }
                // Sort mirrors BOTH ways: the Settings picker drives the panes, and a pane
                // sort-menu change persists as the new default (the equality guards stop
                // the ping-pong after one hop).
                .onChange(of: settings.defaultSortOption) { _, new in
                    syncManager.sortOption = new
                }
                .onChange(of: syncManager.sortOption) { _, new in
                    if settings.defaultSortOption != new {
                        settings.defaultSortOption = new
                    }
                }
                // Continuously persist each pane's focus for the reopen-where-I-left-off
                // launch path. A provider switch resets the focus to "" via resetNavigation,
                // which correctly clears the saved path too.
                .onChange(of: syncManager.leftRelativePath) { _, new in
                    UserDefaults.standard.set(new, forKey: GeneralSettings.lastLeftFocusKey)
                }
                .onChange(of: syncManager.rightRelativePath) { _, new in
                    UserDefaults.standard.set(new, forKey: GeneralSettings.lastRightFocusKey)
                }
        }
    }

    /// Provider display names for the two panes, disambiguated when both panes show the same provider.
    var paneNames: PaneProviderNames {
        PaneProviderNames(
            leftName: settings.availableProviders.first(where: { $0.id == leftProviderId })?.displayName,
            rightName: settings.availableProviders.first(where: { $0.id == rightProviderId })?.displayName
        )
    }

    /// Builds the full path for the left pane. Uses only the left provider's root + left relative path to avoid mixing roots.
    var currentLeftPath: String {
        PaneLogic.fullPath(root: settings.path(for: leftProviderId), relativePath: syncManager.leftRelativePath)
    }

    /// Builds the full path for the right pane. Uses only the right provider's root + right relative path to avoid mixing roots.
    var currentRightPath: String {
        PaneLogic.fullPath(root: settings.path(for: rightProviderId), relativePath: syncManager.rightRelativePath)
    }

    // MARK: - Pane visibility & content layout

    /// The resolved arrangement of the panes and workspace beneath the persistent tab strip.
    /// Comparison tabs stack two panes over the workspace; the single-source Tidy tab docks one
    /// collapsible rail beside a workspace that's always shown.
    enum ContentLayout {
        /// Compare: panes over workspace.
        case compareSplit
        /// Compare: only the workspace (the panes hidden). No UI triggers this today — the compare
        /// pane/workspace toggles were removed (you resize with the divider) — but it's kept as the
        /// honest counterpart to the single-source collapse, should compare-pane hiding return.
        case compareWorkspaceOnly
        /// Single source: the source rail expanded beside the workspace.
        case singleExpanded
        /// Single source: the source rail collapsed to a spine beside the workspace.
        case singleCollapsed
    }

    /// The current tab's layout mode (compare vs single-source).
    var layoutMode: TopPaneVisibility.Mode { TopPaneVisibility.mode(for: selectedBottomTab) }

    /// Whether the current tab's panes are hidden, honoring any stored per-tab override on top of
    /// the tab's default. Computed (not stored) so switching tabs auto-applies each tab's
    /// remembered state with no onChange plumbing.
    var panesHiddenForCurrentTab: Bool {
        TopPaneVisibility.panesHidden(
            for: selectedBottomTab,
            override: TopPaneVisibility.decodeOverrides(topPaneOverridesRaw)[selectedBottomTab.rawValue]
        )
    }

    /// Resolves the content layout from the tab's mode and its pane/workspace visibility.
    var contentLayout: ContentLayout {
        switch layoutMode {
        case .compare:
            // The comparison panes and the workspace are both always shown now (their toggles were
            // removed — you resize with the divider instead), so compare is `.compareSplit` unless a
            // stored override hides the panes, which no current control writes.
            return panesHiddenForCurrentTab ? .compareWorkspaceOnly : .compareSplit
        case .singleSource:
            // The single-source workspace is always shown; only the rail collapses.
            return panesHiddenForCurrentTab ? .singleCollapsed : .singleExpanded
        }
    }

    /// Toggles the panes (both comparison panes, or the single-source rail) for the current tab and
    /// remembers the choice for it. The persistent tab strip keeps the window non-empty, so — unlike
    /// before — no region is forced back on to compensate.
    func togglePanesForCurrentTab() {
        let overrides = TopPaneVisibility.settingOverride(
            TopPaneVisibility.decodeOverrides(topPaneOverridesRaw),
            tab: selectedBottomTab,
            hidden: !panesHiddenForCurrentTab
        )
        topPaneOverridesRaw = TopPaneVisibility.encodeOverrides(overrides)
    }

    /// Entering a Tidy lens from the tab strip opens the source rail and positions it for the lens:
    /// Organize works on the loose-files inbox, so it opens there; every other lens works over the
    /// whole provider, so it opens at the root. Fired only from the explicit tab/lens controls — the
    /// programmatic scan actions (Find Duplicates / loose files from a Compare menu) set the lens
    /// directly and bypass this, so they keep scanning the folder the user picked.
    func presentTidyRail(for lens: TidyLens) {
        // Show the rail for the Tidy tab (remembered per tab, like the manual toggle). The layout
        // animates via `.animation(value: panesHiddenForCurrentTab)`, so no explicit withAnimation.
        let overrides = TopPaneVisibility.settingOverride(
            TopPaneVisibility.decodeOverrides(topPaneOverridesRaw),
            tab: .tidy,
            hidden: false
        )
        topPaneOverridesRaw = TopPaneVisibility.encodeOverrides(overrides)

        // Position the single source (the left pane) for the lens.
        syncManager.focusOn(relativePath: tidyRailRelativePath(for: lens), isLeft: true)
    }

    /// The provider-root-relative folder a Tidy lens's rail opens on: the loose-files inbox for
    /// Organize (Settings ▸ Tidy, default "TODO"), the provider root for every other lens. Falls back
    /// to the root when the inbox is unset or missing, so the rail never strands on an absent folder.
    private func tidyRailRelativePath(for lens: TidyLens) -> String {
        guard lens == .filing else { return "" }
        let inbox = (UserDefaults.standard.string(forKey: GeneralSettings.filingInboxRelativePathKey) ?? "TODO")
            .trimmingCharacters(in: .whitespaces)
        guard !inbox.isEmpty else { return "" }
        let inboxPath = (tidyProviderRootExpanded as NSString).appendingPathComponent(inbox)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: inboxPath, isDirectory: &isDir) && isDir.boolValue
        return exists ? inbox : ""
    }

    private func applyProviderSelection(preferDistinctPair: Bool) {
        guard let resolved = Self.resolvedProviderSelection(
            providers: settings.enabledProviders,
            currentLeftId: leftProviderId,
            currentRightId: rightProviderId,
            preferDistinctPair: preferDistinctPair
        ) else {
            return
        }

        if leftProviderId != resolved.leftId {
            leftProviderId = resolved.leftId
        }
        if rightProviderId != resolved.rightId {
            rightProviderId = resolved.rightId
        }
    }

    /// Reloads both pane trees and runs a diff scan (with re-entrancy and cancellation handled by the manager).
    private func refreshAction() {
        guard let leftProvider = settings.enabledProviders.first(where: { $0.id == leftProviderId }),
              let rightProvider = settings.enabledProviders.first(where: { $0.id == rightProviderId }) else {
            return
        }
        Task {
            await syncManager.refreshTreesAndScan(left: leftProvider, right: rightProvider)
        }
    }

    /// Swaps the left and right panes entirely — providers, focused folders, selections,
    /// per-pane back/forward history, trees, and the differences list (remapped, so every
    /// row's arrows flip with the pane labels) all flip sides in one click. The manager's
    /// paired state is swapped first (so the single post-swap rescan reads already-swapped
    /// focus and selection), then the @AppStorage provider ids. Both id onChanges fire but are
    /// suppressed via `pendingSwapProviderChanges` so they don't reset the just-swapped
    /// navigation; this method drives the one rescan itself. The manager refuses the swap
    /// while file operations are in flight — the provider ids must then stay put too, or the
    /// pane labels would flip over unswapped state.
    /// Ends an active guided review when the comparison itself changes (pane swap, provider
    /// switch, root edit). The frozen queue captured the OLD comparison: its copies would
    /// still run against the captured absolute paths, but the review card relabels each item
    /// against the CURRENT pane names — after a swap, exactly backwards. Ending the session
    /// beats showing directions a user could approve in reverse.
    private func endReviewForComparisonChange() {
        guard reviewStore.isReviewing else { return }
        reviewStore.endSession()
        syncManager.banner = .warning("Review ended — the comparison changed")
    }

    func swapPanesAction() {
        // While discoverProviders() is still awaiting, both id onChanges bail on the bootstrap
        // guard without decrementing pendingSwapProviderChanges — a swap now would strand the
        // counter at 2 and silently swallow the user's next two real provider switches. The
        // window is interactive during bootstrap, so refuse the swap outright.
        guard !isBootstrappingProviders else { return }
        guard syncManager.swapPanes() else { return }
        endReviewForComparisonChange()
        duplicateReview = nil   // the swap redefines the comparison; drop any duplicate review
        let swapped = PaneLogic.swappedProviderIds(
            leftProviderId: leftProviderId,
            rightProviderId: rightProviderId
        )
        // Both ids change together (unless the panes already share a provider, in which case
        // neither onChange fires) — seed the suppression counter accordingly.
        if leftProviderId != rightProviderId {
            pendingSwapProviderChanges = 2
        }
        leftProviderId = swapped.leftProviderId
        rightProviderId = swapped.rightProviderId
        refreshAction()
    }

    /// Opens the settings overlay preselected on the Providers tab — the fix-it action for the
    /// invalid-root / disabled-provider pane placeholders.
    private func openProviderSettings() {
        settingsTab = .providers
        showSettings = true
    }

    /// "Get Info" from a pane or differences-row right-click: show the in-app Info inspector for the
    /// path (not Finder's Get Info). Opens the inspector in place on the current tab — the inspector
    /// is available on both Compare and Tidy, so this no longer yanks the Tidy rail over to Compare.
    func showInfo(for path: String) {
        infoPath = path
        withAnimation(.easeInOut(duration: 0.15)) { showInspector = true }
    }

    /// Reopens each pane at the folder it showed when the app last quit (General setting,
    /// default on). Runs once, inside the first-appearance bootstrap, after the provider
    /// selection resolves and before the initial refresh. Each saved path is validated on
    /// disk first (off the main actor — cloud roots stat slowly), so a folder deleted or
    /// unmounted since last session silently falls back to the provider root.
    private func restoreLastPaneFocusIfEnabled() async {
        guard GeneralSettings.shouldRestoreLastFocus() else { return }
        let panes: [(rel: String, root: String, isLeft: Bool)] = [
            (UserDefaults.standard.string(forKey: GeneralSettings.lastLeftFocusKey) ?? "",
             settings.path(for: leftProviderId), true),
            (UserDefaults.standard.string(forKey: GeneralSettings.lastRightFocusKey) ?? "",
             settings.path(for: rightProviderId), false),
        ]
        for pane in panes where !pane.rel.isEmpty && !pane.root.isEmpty {
            let fullPath = ((pane.root as NSString).expandingTildeInPath as NSString)
                .appendingPathComponent(pane.rel)
            let isRestorable = await Task.detached(priority: .userInitiated) { () -> Bool in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }.value
            guard isRestorable else { continue }
            Logger.shared.info("Restoring \(pane.isLeft ? "left" : "right") pane to last session's folder: \(pane.rel)")
            syncManager.focusOn(relativePath: pane.rel, isLeft: pane.isLeft)
        }
    }

    /// The full reset behind Settings → Advanced. `resetAllSettings()` wipes the defaults
    /// domain and republishes the manager's own settings (each `.onChange` mirror above then
    /// re-seeds the engine); the pieces built from the old values that DON'T flow through
    /// those mirrors — the log gate and the in-memory ignore sets — are reset here.
    private func resetAllSettingsAction() {
        settings.resetAllSettings()
        Logger.shared.minimumLevel = .debug
        syncManager.clearAllIgnoredItems()
    }

    /// The first-run welcome tour (H1). FirstRunOverlay owns the paged layout and primary-action
    /// choice; this wires it to the toolbar's scan, the Providers-tab settings path, and the
    /// dismissal bookkeeping (`dismissWelcome`).
    @ViewBuilder
    private var firstRunOverlay: some View {
        FirstRunOverlay(
            leftProviderName: paneNames.left,
            rightProviderName: paneNames.right,
            providerCount: settings.enabledProviders.count,
            surfaceStyle: surfaceStyle,
            glassHue: glassHue,
            glassIntensity: glassIntensity,
            surfaceTint: surfaceTint,
            onScan: { dontShowAgain in
                dismissWelcome(persist: dontShowAgain)
                forceRefreshAction()
            },
            onChooseProviders: { dontShowAgain in
                dismissWelcome(persist: dontShowAgain)
                openProviderSettings()
            },
            onDismiss: { dontShowAgain in dismissWelcome(persist: dontShowAgain) }
        )
    }

    /// The in-window Help overlay (Help ▸ SyncCloud Help / ⌘?). HelpOverlay owns the backdrop,
    /// card decoration, and the searchable topic/article layout; this just feeds it the current
    /// surface style so the Help card matches Settings and Welcome, and wires dismissal.
    @ViewBuilder
    private var helpOverlay: some View {
        HelpOverlay(
            surfaceStyle: surfaceStyle,
            glassHue: glassHue,
            glassIntensity: glassIntensity,
            surfaceTint: surfaceTint,
            onClose: { showHelp = false }
        )
    }

    /// Hide the welcome tour for the rest of this session, and — when the user left "Don't show
    /// this again" checked — persist the seen flag so it won't auto-open on future launches.
    /// Leaving it unchecked keeps the flag false, so the tour returns next launch; Help ▸ Welcome
    /// to SyncCloud re-opens it any time regardless.
    private func dismissWelcome(persist: Bool) {
        welcomeDismissedThisSession = true
        if persist { hasSeenFirstRunWelcome = true }
    }

    /// The in-window settings overlay: a dimmed backdrop (click to dismiss) behind a centered
    /// card. Because it lives inside the main window it floats over the content even in full
    /// screen, and never kicks the user out to another Space the way a separate window would.
    @ViewBuilder
    private var settingsOverlay: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .ignoresSafeArea()
                .onTapGesture { showSettings = false }

            settingsCard
                // Absorb clicks on the card so they don't fall through to the dismiss backdrop.
                .contentShape(Rectangle())
        }
        .transition(.opacity)
    }

    /// The Settings card, decorated to reflect the app's own content-surface style — the panel that
    /// *configures* translucency should itself *obey* it (item 5.4). `.solid` is an opaque panel;
    /// `.unified`/`.cards` are a frosted glass card whose translucency tracks the glass-intensity
    /// slider and whose fill picks up the accent tint. Radius, clip, and shadow come from the shared
    /// LiquidGlass system (`glassCardStyle`, `cardCornerRadius`) rather than hardcoded values, so the
    /// card matches the rest of the glass surfaces it sits over.
    @ViewBuilder
    private var settingsCard: some View {
        // Same fill + clip both branches share: the surface-style fill (opaque base for `.solid`,
        // tint-only wash otherwise) clipped to the shared card radius.
        let shaped = SettingsView(
            selection: $settingsTab,
            onClose: { showSettings = false },
            syncManager: syncManager,
            onResetAllSettings: { resetAllSettingsAction() }
        )
            .environmentObject(settings)
            .contentSurface(surfaceStyle, hue: glassHue, tint: surfaceTint)
            .clipShape(RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous))
        let border = RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous)
            .strokeBorder(.quaternary, lineWidth: 0.5)

        switch surfaceStyle {
        case .solid:
            // Opaque panel — no see-through material — plus the floating-modal drop shadow.
            shaped
                .overlay(border)
                .shadow(color: .black.opacity(0.3), radius: 30, y: 8)
        case .unified, .cards:
            // Frosted glass card: `glassCardStyle` handles the macOS-26/15 gating and clip+shadow,
            // and its translucency scales with the glass-intensity slider.
            shaped
                .glassCardStyle(intensity: glassIntensity)
                .overlay(border)
        }
    }

    /// Renders one abstract `SyncErrorAction` as its concrete alert button. Dismissing is implicit
    /// on any button, but each clears `currentError` explicitly so the alert can't linger.
    @ViewBuilder
    private func errorAlertButton(_ action: SyncErrorAction, for error: SyncError) -> some View {
        switch action {
        case .revealInFinder:
            Button("Reveal in Finder") {
                if let path = error.path {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                syncManager.currentError = nil
            }
        case .retry:
            // Capture the handler when the button is BUILT, not when it's clicked: SwiftUI may
            // run the alert's isPresented setter (which clears currentError and, via its didSet,
            // nils currentErrorRetry) before the button action — the same unspecified ordering
            // documented at FileSyncManager.verifiedCopyDialogDismissed. Read at click time,
            // Retry would silently no-op.
            let retry = syncManager.currentErrorRetry
            Button("Retry") {
                syncManager.currentError = nil
                retry?()
            }
            // Deliberately the Return-key default (it's also listed first): retrying is safe to
            // mash because every destructive operation in this app confirms separately. Escape
            // stays on Dismiss via its .cancel role.
            .keyboardShortcut(.defaultAction)
        case .dismiss:
            Button("Dismiss", role: .cancel) {
                syncManager.currentError = nil
            }
        }
    }

    /// The alert body: the human message, then the underlying reason and affected path when known.
    /// The path is labeled and tilde-abbreviated, matching the "From:/To:" convention in
    /// `SyncOperationAlerts`.
    private func errorAlertMessage(_ error: SyncError) -> String {
        var lines = [error.message]
        if let reason = error.reason, !reason.isEmpty { lines.append(reason) }
        if let path = error.path {
            // "Location:" deliberately — no File/Folder distinction. Deciding one would need a
            // stat, and this closure runs on the main thread on every alert re-render, against
            // exactly the path most likely to sit on a dead volume (it's the one that just
            // failed). A neutral label is also the only honest one: createFolderFailed carries
            // the parent directory and bulkFailed only the first item's path.
            lines.append("Location: \((path as NSString).abbreviatingWithTildeInPath)")
        }
        return lines.joined(separator: "\n")
    }

    /// User-triggered refresh: clears prefetch cache so new files on disk appear immediately.
    func forceRefreshAction() {
        Logger.shared.info("User requested a force refresh")
        syncManager.prefetchedTrees.removeAll()
        refreshAction()
    }

    // MARK: Tidy — Find Duplicates

    /// Whether a Tidy scan/inspect should target the right pane. Always false in single-source Tidy
    /// (the rail is the left pane), so a stale right-pane selection can't silently aim Tidy at the
    /// hidden provider. In compare mode the focused pane wins. See `PaneLogic.tidyTargetsRightPane`.
    var tidyTargetIsRight: Bool {
        PaneLogic.tidyTargetsRightPane(isCompare: layoutMode == .compare, activePane: activePane)
    }

    /// The provider name for the pane a Tidy scan targets: the single-source rail is always the left
    /// pane; in compare mode it follows the focused pane.
    var tidyProviderName: String {
        tidyTargetIsRight ? paneNames.right : paneNames.left
    }

    /// The absolute (tilde-expanded) folder a Tidy scan walks: the targeted pane's current directory
    /// (always the left rail in single-source; the focused pane in compare).
    var tidyScanRootExpanded: String {
        ((tidyTargetIsRight ? currentRightPath : currentLeftPath) as NSString).expandingTildeInPath
    }

    /// Switches to the Tidy tab and kicks off a duplicate scan of the focused provider.
    func findDuplicatesAction() {
        let root = tidyScanRootExpanded
        guard !root.isEmpty else { return }
        Logger.shared.info("User requested Find Duplicates in \(root)")
        selectedBottomTab = .tidy
        selectedTidyLens = .duplicates
        let options = DuplicateFinderOptions.fromDefaults()
        syncManager.startFindDuplicates(root: URL(fileURLWithPath: root), options: options)
    }

    /// Switches to the Tidy tab's Storage lens and builds a read-only storage picture of the focused
    /// folder (same target-root helper as Find Duplicates). Walk + analyze only — nothing moves.
    func buildStorageLensAction() {
        let root = tidyScanRootExpanded
        guard !root.isEmpty else { return }
        Logger.shared.info("User requested Storage Lens for \(root)")
        selectedBottomTab = .tidy
        selectedTidyLens = .storage
        syncManager.startBuildStorageLens(root: URL(fileURLWithPath: root))
    }

    /// Opens two copies of a duplicate *folder* group side by side in Compare: the keeper on the
    /// left (kept), the redundant copy on the right (the delete candidate). Duplicate groups never
    /// span providers (the finder walks a single provider tree), so both copies share the Tidy
    /// provider root — this pins both panes to that provider, focuses each on its copy, and runs the
    /// diff. Switching to Compare doesn't disturb the Tidy tab's scan results, so the user can tab
    /// back to the duplicate list and compare the next pair.
    ///
    /// Changing a provider id normally clears the Tidy results and resets navigation (see the id
    /// `onChange` handlers) — both would sabotage this, wiping the duplicate list the user must be
    /// able to return to and the focus set just below. So each id change is suppressed via
    /// `pendingSwapProviderChanges`, exactly as a pane swap does.
    func compareCopies(keep: DuplicateCopy, delete: DuplicateCopy) {
        let providerId = tidyTargetIsRight ? rightProviderId : leftProviderId
        let providerRoot = tidyProviderRootExpanded
        let keepPath = (keep.path as NSString).expandingTildeInPath
        let deletePath = (delete.path as NSString).expandingTildeInPath
        guard !providerRoot.isEmpty,
              let keepRel = Self.relativePath(of: keepPath, under: providerRoot),
              let deleteRel = Self.relativePath(of: deletePath, under: providerRoot) else {
            Logger.shared.warning("Compare copies: a copy path sits outside the Tidy provider root — skipping")
            return
        }
        // Snapshot the Compare setup so exiting the review restores it — but when a review is already
        // in progress (comparing a second pair without ending the first), its panes are already
        // pinned to this provider, so keep the ORIGINAL snapshot rather than capturing the pinned one.
        let restore = duplicateReview?.restore ?? SavedCompareState(
            leftProviderId: leftProviderId, rightProviderId: rightProviderId,
            leftRelativePath: syncManager.leftRelativePath, rightRelativePath: syncManager.rightRelativePath)

        // The comparison itself is changing; end any guided review that was framed on the old panes
        // (the id onChange would normally do this, but we're about to suppress it).
        endReviewForComparisonChange()

        // Suppress the id onChange for each id that actually changes, so neither clears the Tidy
        // duplicate results nor resets the focus applied just below.
        if leftProviderId != providerId {
            pendingSwapProviderChanges += 1
            leftProviderId = providerId
        }
        if rightProviderId != providerId {
            pendingSwapProviderChanges += 1
            rightProviderId = providerId
        }
        syncManager.focusOn(relativePath: keepRel, isLeft: true)
        syncManager.focusOn(relativePath: deleteRel, isLeft: false)
        duplicateReview = DuplicateCompareContext(
            groupName: keep.name, keepPath: keepPath, deletePath: deletePath, restore: restore)

        Logger.shared.info("Comparing duplicate copies — keep \(keepPath) · delete candidate \(deletePath)")
        selectedBottomTab = .differences
        refreshAction()
    }

    /// `full` expressed relative to `root` (`""` when they're equal), or nil when `full` is neither
    /// `root` nor inside it. Boundary-safe on "/" so "/a/Docs" never claims "/a/DocsBackup".
    static func relativePath(of full: String, under root: String) -> String? {
        if full == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard full.hasPrefix(prefix) else { return nil }
        return String(full.dropFirst(prefix.count))
    }

    /// The provider root of the pane a Tidy/Filing action targets (the left rail in single-source;
    /// the focused pane in compare).
    var tidyProviderRootExpanded: String {
        let id = tidyTargetIsRight ? rightProviderId : leftProviderId
        return (settings.path(for: id) as NSString).expandingTildeInPath
    }

    /// The provider ruleset a Name Normalizer scan targets — the targeted pane's provider (the left
    /// rail in single-source; the focused pane in compare). Falls back to OneDrive, the strictest
    /// ruleset, when the type can't be resolved, so nothing risky slips past.
    var tidyProviderType: CloudProvider.ProviderType {
        let id = tidyTargetIsRight ? rightProviderId : leftProviderId
        return settings.availableProviders.first(where: { $0.id == id })?.type ?? .oneDrive
    }

    /// Runs the local name scan for the Rename lens's focused folder (triggered by its Scan button).
    func startNameScanAction() {
        let root = tidyScanRootExpanded
        guard !root.isEmpty else { return }
        Logger.shared.info("User requested name scan for \(root)")
        syncManager.startNameScan(root: URL(fileURLWithPath: root), provider: tidyProviderType)
    }

    /// Toggles the shared Quick Look panel for `url`: opens a preview of that file, or — when the
    /// panel is already previewing that same file — closes it, so one button both opens and dismisses
    /// (Space and Esc close it too). Clicking a *different* file re-targets the open panel rather than
    /// closing it. `.quickLookPreview($quickLookURL)` resets the binding to nil on manual dismissal,
    /// keeping this toggle in step with the panel's real state.
    func toggleQuickLook(_ url: URL) {
        quickLookURL = (quickLookURL == url) ? nil : url
    }

    /// N2 — dry-runs the enabled automation rules over the focused folder. Preview only: the manager
    /// walks + evaluates on-device and publishes what *would* happen; no file is moved. Triggered from
    /// the Automations lens's own button, so the pane is already on that lens when this runs.
    func startAutomationPreviewAction(only: UUID? = nil) {
        let root = tidyScanRootExpanded
        // Destinations anchor at the provider root, not the focused subfolder — so a rule's
        // "Home/Utilities/…" template files into the provider root even when previewing inside a
        // subfolder, instead of nesting the tree under whatever folder happened to be focused.
        let providerRoot = tidyProviderRootExpanded
        guard !root.isEmpty, !providerRoot.isEmpty else { return }
        Logger.shared.info("User requested Automations preview for \(root)\(only == nil ? "" : " (single rule)")")
        selectedBottomTab = .tidy
        selectedTidyLens = .automations
        syncManager.startAutomationDryRun(root: URL(fileURLWithPath: root),
                                          destinationRoot: URL(fileURLWithPath: providerRoot),
                                          providerName: tidyProviderName, only: only)
    }

    /// Kicks off a Filing scan for loose files, with the whole provider as the taxonomy. Defaults to
    /// the loose-files inbox (Settings ▸ Tidy, default "TODO"); if the rail has been navigated into a
    /// subfolder, that focused folder is scanned instead.
    func findFilingSuggestionsAction() {
        let focused = tidyScanRootExpanded
        let root = tidyProviderRootExpanded
        guard !focused.isEmpty, !root.isEmpty else { return }
        let inbox = (UserDefaults.standard.string(forKey: GeneralSettings.filingInboxRelativePathKey) ?? "TODO")
            .trimmingCharacters(in: .whitespaces)
        let atRoot = (focused as NSString).standardizingPath == (root as NSString).standardizingPath
        // Default to the inbox only when we're at the provider root AND the inbox folder actually
        // exists; otherwise scan the focused folder. This mirrors `tidyRailRelativePath`'s existence
        // check, so the rail and the scan never disagree about a missing inbox (before, the rail fell
        // back to the root but the scan blindly targeted a non-existent root/TODO).
        let inboxPath = (root as NSString).appendingPathComponent(inbox)
        var isDir: ObjCBool = false
        let inboxExists = !inbox.isEmpty
            && FileManager.default.fileExists(atPath: inboxPath, isDirectory: &isDir) && isDir.boolValue
        let folder = (atRoot && inboxExists) ? inboxPath : focused
        Logger.shared.info("User requested Filing suggestions for \(folder)")
        selectedBottomTab = .tidy
        selectedTidyLens = .filing
        syncManager.startFindFilingSuggestions(folder: URL(fileURLWithPath: folder),
                                               providerRoot: URL(fileURLWithPath: root))
    }

    /// The per-side values a pane is built from, resolved once per render by `paneContext` so
    /// the header and tree builders don't each repeat the same `isLeft ?` pairs (a copy-paste
    /// drift hazard when a side-specific argument changes on one side only).
    struct PaneContext {
        let isLeft: Bool
        let title: String
        let providerId: String
        let relativePath: String
        let canGoBack: Bool
        let canGoForward: Bool
        let tree: [FileNode]
        let otherTree: [FileNode]
        let isLoading: Bool
        let currentPath: String
        let otherSelection: Set<String>
        let diffIndex: DiffStatusIndex
        let otherPaneName: String?
        let hasOnlyHiddenEntries: Bool
    }

    private func paneContext(isLeft: Bool) -> PaneContext {
        PaneContext(
            isLeft: isLeft,
            title: isLeft ? "Left" : "Right",
            providerId: isLeft ? leftProviderId : rightProviderId,
            relativePath: isLeft ? syncManager.leftRelativePath : syncManager.rightRelativePath,
            canGoBack: isLeft ? syncManager.leftHistory.canGoBack : syncManager.rightHistory.canGoBack,
            canGoForward: isLeft ? syncManager.leftHistory.canGoForward : syncManager.rightHistory.canGoForward,
            tree: isLeft ? syncManager.leftTree : syncManager.rightTree,
            otherTree: isLeft ? syncManager.rightTree : syncManager.leftTree,
            isLoading: isLeft ? syncManager.isLoadingLeftTree : syncManager.isLoadingRightTree,
            currentPath: isLeft ? currentLeftPath : currentRightPath,
            otherSelection: isLeft ? syncManager.selectedRightPaths : syncManager.selectedLeftPaths,
            diffIndex: isLeft ? leftDiffIndex : rightDiffIndex,
            otherPaneName: isLeft ? paneNames.right : paneNames.left,
            hasOnlyHiddenEntries: isLeft ? syncManager.leftTreeHasOnlyHiddenEntries : syncManager.rightTreeHasOnlyHiddenEntries
        )
    }

    /// One resizable file pane: provider header stacked over its file tree.
    @ViewBuilder
    func paneColumn(isLeft: Bool) -> some View {
        let pane = paneContext(isLeft: isLeft)
        // Resolve the action-bar selection ONCE per render (a tree walk over ~40k nodes) and reuse
        // it for both the overlay gate and the layout animation below — reading `activeSelectionNodes`
        // separately in each spot re-walked the tree several times per render (~100ms each), which
        // was the comparison panes' selection lag.
        let barNodes = barSelectionNodes(isLeft: isLeft)
        return VStack(spacing: 0) {
            PaneHeader(
                title: pane.title,
                provider: settings.availableProviders.first(where: { $0.id == pane.providerId }),
                rootPath: settings.path(for: pane.providerId),
                relativePath: pane.relativePath,
                canGoBack: pane.canGoBack,
                canGoForward: pane.canGoForward,
                onBack: { syncManager.goBack(isLeft: isLeft) },
                onForward: { syncManager.goForward(isLeft: isLeft) },
                onNavigate: { syncManager.focusOn(relativePath: $0, isLeft: isLeft) },
                onNavigateBoth: { syncManager.focusBoth(relativePath: $0) },
                providers: settings.enabledProviders,
                onSelectProvider: { id in
                    if isLeft { leftProviderId = id } else { rightProviderId = id }
                },
                onManageProviders: openProviderSettings,
                sortOption: $syncManager.sortOption,
                // Only the single-source Tidy rail collapses itself (back to the spine); the two
                // comparison panes never collapse individually.
                onCollapse: layoutMode == .singleSource
                    ? { withAnimation(.easeInOut(duration: 0.2)) { togglePanesForCurrentTab() } }
                    : nil,
                onRefresh: { forceRefreshAction() },
                isRefreshing: isScanning,
                showHiddenFiles: $syncManager.showHiddenFiles
            )
            treeView(pane)
        }
        .paneCardIfNeeded(surfaceStyle)
        // The file actions (Copy/Move/Compare/New Folder/Delete) live here now, not in the titlebar:
        // a contextual bar on whichever pane holds the selection, so the buttons name their target.
        .overlay(alignment: .bottom) {
            if !barNodes.isEmpty {
                paneActionBar(isLeft: isLeft, selectionNodes: barNodes)
                    .padding(10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: barNodes.count)
    }

    /// The Info inspector — the former Details tab, now a toggleable right-side panel showing metadata
    /// for the current selection. Available on both Compare (both-sides status) and the single-source
    /// Tidy rail. `DetailsSidebar` handles the no-selection empty state itself.
    private var infoInspector: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Info").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showInspector = false }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide the inspector")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            DetailsSidebar(syncManager: syncManager, leftPath: currentLeftPath, rightPath: currentRightPath, compact: true, overridePath: infoPath, singleSource: layoutMode == .singleSource)
        }
        .frame(width: inspectorDragWidth ?? inspectorWidth)
        .background(.bar)
    }

    /// The draggable seam between the panes and the Info inspector. Replaces the static `Divider()`
    /// with the same "invisible hit target overlaid on a visible 1pt divider" idiom the pane splits
    /// use: the divider keeps its slim layout footprint while a 10pt-wide clear strip straddles it
    /// for the drag. `inspectorWidth` is held constant through the gesture (written only on release),
    /// so it's the stable base for `PaneLogic.inspectorDragWidth`.
    ///
    /// The drag reads `.global`, NOT the default `.local`, coordinate space: this handle slides left
    /// as the inspector widens, so in its own moving frame `translation` feeds back on itself and
    /// collapses to ~0 once layout catches up — the panes' splits dodge the same trap by reading a
    /// fixed coordinate space. Global translation is the cursor's real delta, independent of the
    /// handle's position, so the resize stays smooth instead of stuttering.
    private var inspectorResizeHandle: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 10)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                inspectorDragWidth = PaneLogic.inspectorDragWidth(
                                    base: inspectorWidth, translation: value.translation.width)
                            }
                            .onEnded { _ in
                                if let w = inspectorDragWidth { inspectorWidth = w }
                                inspectorDragWidth = nil
                            }
                    )
            }
    }

    @ViewBuilder
    private var mainContentView: some View {
        VStack(spacing: 0) {
            topContentBar
            HStack(spacing: 0) {
                verticalSplit
                if showInspector {
                    inspectorResizeHandle
                    infoInspector
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        // Animate the panes collapsing/expanding when the tab's pane state flips — both on
        // the manual toggle and on the auto-collapse that fires when a tab switch changes it.
        .animation(.easeInOut(duration: 0.2), value: panesHiddenForCurrentTab)
        .animation(.easeInOut(duration: 0.2), value: selectedBottomTab)
        .animation(.easeInOut(duration: 0.15), value: showInspector)
        .overlay {
            if let progress = syncManager.activeProgress {
                ZStack {
                    Color.black.opacity(0.1)
                        .ignoresSafeArea()

                    ProgressDialog(progress: progress)
                        .padding()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        // The animation must live on the container (like the banner's below): inside the
        // `if let` it can't animate the overlay's own insertion/removal, so the transition
        // above never ran. Keyed on presence — Progress is a reference type whose counters
        // mutate in place, so the value itself is the wrong animation trigger anyway.
        .animation(.spring(), value: syncManager.activeProgress == nil)
        .overlay(alignment: .top) {
            if let banner = syncManager.banner {
                OperationBannerView(
                    banner: banner,
                    glassIntensity: glassIntensity,
                    canUndo: undoManager?.canUndo ?? false,
                    onUndo: {
                        // The same reversal ⌘Z performs: this operation registered exactly one
                        // (grouped) undo step and its banner is the newest, so it sits on top of
                        // the stack. Clear the banner so the affordance doesn't linger post-undo.
                        undoManager?.undo()
                        syncManager.banner = nil
                    },
                    onClose: { syncManager.banner = nil },
                    onHover: { hovering in bannerDismissScheduler.hoverChanged(isHovering: hovering) }
                )
                .id(banner.id)
                .padding(.top, 8)
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: syncManager.banner)
        .onChange(of: syncManager.banner) { _, newValue in
            bannerDismissScheduler.bannerChanged(to: newValue) {
                syncManager.banner = nil
            }
            // Banners vanish with the window; when the app is in the background, mirror the
            // outcome as a system notification (General setting, default off).
            if let banner = newValue {
                OperationNotifier.postIfEnabled(for: banner)
            }
        }
        .onChange(of: syncManager.showHiddenFiles) { _, newValue in
            Logger.shared.info("User toggled hidden files to: \(newValue)")
        }
        // Feed the pane header's quick-jump "Recent" list: every folder either pane focuses — by
        // drilling in, a crumb, back/forward, or a scan — is recorded against its provider root.
        .onChange(of: syncManager.leftRelativePath) { _, rel in
            FolderJumpStore.shared.recordVisit(root: settings.path(for: leftProviderId),
                                               relativePath: rel, name: (rel as NSString).lastPathComponent)
        }
        .onChange(of: syncManager.rightRelativePath) { _, rel in
            FolderJumpStore.shared.recordVisit(root: settings.path(for: rightProviderId),
                                               relativePath: rel, name: (rel as NSString).lastPathComponent)
        }
    }


    /// Selection binding for one pane that enforces the one-pane-selected invariant: setting a
    /// non-empty selection in one pane clears the other. The clicked pane commits synchronously
    /// so the click lands on the first try; the OTHER pane's clear is deferred one runloop tick.
    ///
    /// Clearing the other pane synchronously here (which the previous version did) writes a
    /// `@Published` the sibling `List` is bound to *while this List is still committing its own
    /// selection* — SwiftUI re-enters the enclosing view update, the sibling table reloads, and
    /// AppKit drops the just-clicked row. The symptom was a dead first click on the comparison
    /// panes: every selection took two clicks to stick. Deferring the sibling's clear to the next
    /// tick lets this pane's selection settle first, so one click is enough.
    ///
    /// The one-tick window where both panes hold a selection is invisible (a single frame) and
    /// harmless — `PaneLogic.activePane` is left-wins, so at worst the action bar / Info follow
    /// the correct pane one frame late. Setting an EMPTY selection (a deselect, or SwiftUI
    /// re-writing an unchanged empty set) still leaves the other pane alone, which is what keeps
    /// the right-click "Copy from other pane" menu working.
    private func paneSelectionBinding(isLeft: Bool) -> Binding<Set<String>> {
        Binding(
            get: { isLeft ? syncManager.selectedLeftPaths : syncManager.selectedRightPaths },
            set: { newSelection in
                let reconciled = PaneLogic.reconciledSelections(
                    settingSelection: newSelection,
                    isLeft: isLeft,
                    currentLeft: syncManager.selectedLeftPaths,
                    currentRight: syncManager.selectedRightPaths
                )
                // Commit the clicked pane now — this is the write the List is waiting on.
                if isLeft {
                    if syncManager.selectedLeftPaths != reconciled.left {
                        syncManager.selectedLeftPaths = reconciled.left
                    }
                } else {
                    if syncManager.selectedRightPaths != reconciled.right {
                        syncManager.selectedRightPaths = reconciled.right
                    }
                }
                // A deselect (empty write) enforces nothing — leave the other pane untouched
                // (this is what keeps the right-click "Copy from other pane" menu working).
                guard !newSelection.isEmpty else { return }
                // Enforce the one-pane-selected invariant by clearing the other pane — but a tick
                // later, so this pane's selection commits first (a synchronous sibling write here
                // reloaded that List mid-commit and dropped the click). The clear is idempotent —
                // it only ever writes the empty set (`reconciled` clears the other side for any
                // non-empty pick) — so it needs no "is this still the active pane" guard: whatever
                // the user's latest pick is, the non-clicked pane should end up empty regardless.
                // Distinct click events land in separate runloop turns with this block draining
                // between them, so it can't clobber a newer pick from a later click.
                DispatchQueue.main.async {
                    if isLeft {
                        if syncManager.selectedRightPaths != reconciled.right {
                            syncManager.selectedRightPaths = reconciled.right
                        }
                    } else {
                        if syncManager.selectedLeftPaths != reconciled.left {
                            syncManager.selectedLeftPaths = reconciled.left
                        }
                    }
                }
            }
        )
    }

    @ViewBuilder
    private func treeView(_ pane: PaneContext) -> some View {
        FileTreeView(
            tree: pane.tree,
            otherTree: pane.otherTree,
            isLoading: pane.isLoading,
            currentPath: pane.currentPath,
            selection: paneSelectionBinding(isLeft: pane.isLeft),
            otherSelection: pane.otherSelection,
            isLeft: pane.isLeft,
            delegate: PaneActionDelegate(handler: actionHandler, syncManager: syncManager, settings: settings, isLeft: pane.isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId, forceRefreshAction: forceRefreshAction, onGetInfo: { showInfo(for: $0) }),
            diffIndex: pane.diffIndex,
            otherPaneName: pane.otherPaneName,
            rootPathIsValid: settings.isPathValid(for: pane.providerId),
            providerIsEnabled: settings.isEnabled(pane.providerId),
            hasOnlyHiddenEntries: pane.hasOnlyHiddenEntries,
            rootPath: settings.path(for: pane.providerId),
            onOpenSettings: openProviderSettings,
            // The Tidy rail is a single source with no opposite pane, so its row menu drops the
            // comparison-only items and renames "Compare only this folder" to "Open".
            isSingleSource: layoutMode == .singleSource
        )
    }

    /// The persistent tab strip above the panes: the primary Differences/Details/Tidy picker plus —
    /// when Tidy is active — the underline lens sub-tabs. Hoisted out of the workspace cards so the
    /// tabs stay visible at a fixed spot and never collapse with the panes or workspace, and so the
    /// two levels read as a clear hierarchy rather than one flat run of peers.
    private var topContentBar: some View {
        HStack(spacing: 12) {
            primaryTabPicker
            if selectedBottomTab == .tidy {
                // A down-right elbow signals the lens tabs are a level *under* Tidy.
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                lensTabs
            }
            Spacer(minLength: 0)
            // Info inspector toggle — available on every tab now (Compare shows both-sides status;
            // Tidy shows the single source), so opening Info never yanks the Tidy rail over to Compare.
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showInspector.toggle() }
            } label: {
                Label("Info", systemImage: "sidebar.right")
                    .font(.system(size: 12, weight: .medium))
                    // Accent-blue when the inspector is open; a normal enabled label (`.primary`)
                    // when closed. It used to render `.secondary`, which read as disabled/greyed.
                    .foregroundStyle(showInspector ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            }
            .buttonStyle(.borderless)
            .help(showInspector ? "Hide the Info inspector" : "Show details for the selected item")
            .accessibilityLabel(showInspector ? "Hide inspector" : "Show inspector")
        }
        .padding(.horizontal, 16)
        // Pin the bar to a fixed height so switching tabs never nudges the chrome. Without this the
        // height tracks the tallest child: Compare's segmented picker (~22pt) vs. Tidy's taller
        // padded lens tabs (~27pt), which made the bar grow a few points on Tidy. 44pt clears the
        // tallest content with room to spare (content stays vertically centered, nothing clips), so
        // the bar reads at one constant height across every tab.
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Binding for the primary tab picker that, when the user switches *to* Tidy, opens the source
    /// rail and positions it for the active lens. Wrapping the binding (rather than observing
    /// `selectedBottomTab` globally) confines this to the tab strip's own control: the programmatic
    /// scan actions assign `selectedBottomTab` directly and so never trip it, keeping their chosen
    /// scan folder intact.
    private var primaryTabSelection: Binding<BottomTab> {
        Binding(
            get: { selectedBottomTab },
            set: { newTab in
                selectedBottomTab = newTab
                if newTab == .tidy { presentTidyRail(for: selectedTidyLens) }
            }
        )
    }

    /// The primary tabs — a boxed segmented control, the parent level of the underline lens tabs.
    private var primaryTabPicker: some View {
        Picker("", selection: primaryTabSelection) {
            ForEach(BottomTab.allCases, id: \.self) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .tint(glassHue.accentColor)
        .fixedSize()
        .labelsHidden()
    }

    /// The Tidy lens sub-tabs, styled as borderless underline tabs so they read as a clearly
    /// subordinate second level beneath the boxed primary tabs — not another row of segmented peers
    /// (the confusion the shipped app had, where the two pickers looked identical).
    private var lensTabs: some View {
        HStack(spacing: 2) {
            ForEach(TidyLens.allCases) { lens in
                let isActive = (selectedTidyLens == lens)
                Button {
                    selectedTidyLens = lens
                    // Open the source rail and point it at this lens's folder (root, or the TODO
                    // inbox for Organize).
                    presentTidyRail(for: lens)
                } label: {
                    Text(lens.title)
                        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? Color.primary : Color.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(isActive ? glassHue.accentColor : Color.clear)
                                .frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    /// The tabbed workspace at the bottom of the file explorer.
    /// It dynamically switches between `DifferencesView` and `DetailsSidebar`.
    @ViewBuilder
    var bottomPaneView: some View {
        // Stable outer container: keeps this bottom pane's identity constant across tab
        // switches, so selecting Details doesn't reset the vertical split or collapse the panes.
        VStack(spacing: 0) {
        // Keep-left / trash-right banner for a duplicate-copy review handed off from Tidy. Sits
        // above the diff so it shows even when the two copies are identical (empty diff → the
        // "Everything is in sync" placeholder). Hidden the moment either pane is navigated away
        // from the reviewed copies, so the scoped trash can't fire against the wrong folder.
        if selectedBottomTab == .differences, let review = duplicateReview, duplicateReviewActive(review) {
            duplicateReviewBanner(review)
        }
        // An active review keeps the view mounted through an empty live list: an external
        // change resolving the last live difference mid-review must not vanish the session.
        if selectedBottomTab == .tidy {
            // The single-source hub. Tidy owns its own cards; the Storage lens (folded in) renders
            // its own read-only surface. The lens picker lives in the top strip, not here.
            TidyView(
                syncManager: syncManager,
                lens: $selectedTidyLens,
                providerName: tidyProviderName,
                scanTargetFolder: tidyScanRootExpanded,
                onFindDuplicates: findDuplicatesAction,
                onFindFilingSuggestions: findFilingSuggestionsAction,
                onScanNames: { startNameScanAction() },
                onNormalizeNames: { names in Task { await syncManager.normalizeNames(names) } },
                onPreviewAutomations: { only in startAutomationPreviewAction(only: only) },
                automationDestinationRoot: tidyProviderRootExpanded,
                onQuickLook: { toggleQuickLook($0) },
                onBuildStorage: buildStorageLensAction,
                // The single Tidy source is the left provider; its picker shows in the workspace only
                // while the rail is collapsed (expanded, the rail header owns the provider dropdown).
                showSourcePicker: panesHiddenForCurrentTab,
                providers: settings.enabledProviders,
                currentProviderId: leftProviderId,
                onSelectProvider: { leftProviderId = $0 },
                onManageProviders: openProviderSettings,
                onCompareCopies: compareCopies
            )
        } else if selectedBottomTab == .differences && (!syncManager.differences.isEmpty || reviewStore.isReviewing) {
            // DifferencesView renders its own two cards (toolbar + table); tabs live in the top strip.
            DifferencesView(syncManager: syncManager, reviewStore: reviewStore, paneNames: paneNames, onQuickLook: { toggleQuickLook($0) }, onGetInfo: { showInfo(for: $0) })
        } else {
            // Compare with nothing to list yet: scanning / all-in-sync / not-scanned placeholder.
                Group {
                    if isScanning {
                        // While the first scan runs the whole placeholder becomes a busy
                        // state (the Tidy pattern) — livelier than a spinning button glyph.
                        VStack(spacing: 14) {
                            ProgressView()
                                .controlSize(.large)
                            Text("Scanning \(paneNames.left) and \(paneNames.right)…")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    } else if syncManager.hasScanned {
                        EmptyStateView(
                            icon: "checkmark.seal.fill",
                            tint: .green,
                            title: "Everything is in sync",
                            message: "No differences found between focused directories.",
                            secondary: .init("Scan again", systemImage: "arrow.clockwise") { forceRefreshAction() }
                        )
                    } else {
                        // Same symbol as the toolbar's Compare button — one glyph for
                        // "compare these two panes"; ⇄ stays reserved for swap (UX 1.2).
                        EmptyStateView(
                            icon: PaneGlyph.compare,
                            tint: glassHue.accentColor,
                            title: "Compare \(paneNames.left) ↔ \(paneNames.right)",
                            message: "Nothing scanned yet. Scan the two focused folders to see what differs.",
                            primary: .init("Scan", systemImage: "arrow.clockwise") { forceRefreshAction() }
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .bottomSectionCard(surfaceStyle, intensity: glassIntensity, hue: glassHue, tint: surfaceTint)
                // Match the pane cards' gutter so the bottom card lines up with the panes above.
                .padding(LiquidGlass.cardGutter)
        }
        }
    }

    /// Whether the duplicate-review banner should show: a handoff is active AND both panes are still
    /// focused on exactly the two copies it opened. If the user drills either pane elsewhere, the
    /// comparison is no longer that review, so the scoped trash action disappears with the banner.
    func duplicateReviewActive(_ review: DuplicateCompareContext) -> Bool {
        (currentLeftPath as NSString).expandingTildeInPath == review.keepPath
            && (currentRightPath as NSString).expandingTildeInPath == review.deletePath
    }

    /// The keep-left / trash-right banner shown over Compare during a duplicate-copy review.
    @ViewBuilder
    func duplicateReviewBanner(_ review: DuplicateCompareContext) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(glassHue.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Reviewing duplicate “\(review.groupName)”")
                    .font(.system(size: 12, weight: .semibold))
                Text("Keeping the left copy — the right is the one you're deciding on")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Done") { endDuplicateReview() }
                .controlSize(.small)
            Button(role: .destructive) { trashRightCopy(review) } label: {
                Label("Trash right copy", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Ends the duplicate review without deleting: dismisses the banner and restores the Compare
    /// setup the review overrode, so the right pane returns to the user's own provider and folder.
    func endDuplicateReview() {
        guard let review = duplicateReview else { return }
        duplicateReview = nil
        restoreCompareState(review.restore)
    }

    /// Puts both Compare panes back to a saved setup — used when a duplicate review ends, so pinning
    /// both panes to the duplicate's provider never permanently repoints the user's right pane. The
    /// id onChanges are suppressed (as `compareCopies` does) so the restore can't clear the surviving
    /// Tidy results or reset navigation; then each pane re-focuses its saved folder and rescans.
    private func restoreCompareState(_ saved: SavedCompareState) {
        if leftProviderId != saved.leftProviderId {
            pendingSwapProviderChanges += 1
            leftProviderId = saved.leftProviderId
        }
        if rightProviderId != saved.rightProviderId {
            pendingSwapProviderChanges += 1
            rightProviderId = saved.rightProviderId
        }
        syncManager.focusOn(relativePath: saved.leftRelativePath, isLeft: true)
        syncManager.focusOn(relativePath: saved.rightRelativePath, isLeft: false)
        refreshAction()
    }

    /// Trashes the right copy of the reviewed duplicate (undoable), then returns to the Duplicates
    /// list, drops just that copy from its group in place — the group's figures update, or the group
    /// disappears when only the keeper is left, without re-walking the whole tree — and restores the
    /// Compare setup. A declined or failed trash keeps the review (and its banner) up for a retry.
    func trashRightCopy(_ review: DuplicateCompareContext) {
        let ok = NativeAlerts.confirmDestructive(
            messageText: "Move the right copy of “\(review.groupName)” to the Trash?",
            informativeText: "Trashes \((review.deletePath as NSString).abbreviatingWithTildeInPath). The left copy is kept. Reversible with ⌘Z.",
            confirmTitle: "Move to Trash")
        guard ok else { return }
        Task {
            let removed = await syncManager.deleteItems(at: [review.deletePath])
            guard removed > 0 else { return }
            Logger.shared.info("Trashed the right duplicate copy \(review.deletePath)")
            duplicateReview = nil
            selectedBottomTab = .tidy
            selectedTidyLens = .duplicates
            syncManager.removeResolvedDuplicateCopy(atPath: review.deletePath)
            restoreCompareState(review.restore)
        }
    }
}

/// A live "compare two duplicate copies" review handed off from Tidy to the Compare tab. Holds the
/// two absolute (tilde-expanded) copy paths — keeper on the left, delete candidate on the right —
/// plus the Compare setup to put back when the review ends.
struct DuplicateCompareContext: Equatable {
    let groupName: String
    let keepPath: String
    let deletePath: String
    /// Where Compare was before this review pinned both panes to the duplicate's provider — restored
    /// on exit so opening two copies never permanently repoints the user's right pane.
    let restore: SavedCompareState
}

/// A Compare pane setup — both providers and both focused folders. Captured before a duplicate
/// review overrides them and replayed when it ends.
struct SavedCompareState: Equatable {
    let leftProviderId: String
    let rightProviderId: String
    let leftRelativePath: String
    let rightRelativePath: String
}
