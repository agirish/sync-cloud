import SwiftUI
import AppKit
import Sync
import Events
import Settings
import FileExplorer
import Dashboard
import QuickLook
import Design

/// Main window content: two file panes (left/right, each choosing its own provider from its header),
/// toolbar, and bottom tab (Differences / Details).
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
    /// no such review is in progress. App-owned (a binding, like `hasBootstrappedSession`): a
    /// window close + Dock reopen recreates ContentView and its `@State`, and losing the review
    /// context here while its provider pins persist in @AppStorage would strand the panes pinned
    /// to the duplicate's provider with no banner, no Done button, and no restore snapshot.
    @Binding var duplicateReview: DuplicateCompareContext?

    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) var openWindow

    @State var actionHandler: FileActionHandler?
    @State var quickLookURL: URL? = nil
    @State private var isBootstrappingProviders: Bool = true
    /// Guided-review state, owned by the App (like `duplicateReview`) so it outlives BOTH
    /// DifferencesView — that view unmounts on a Details-tab peek and whenever the live
    /// differences list goes empty, and the session (plus any in-flight copy's outcome) must
    /// survive both — and this ContentView itself, which a window close + Dock reopen recreates.
    @ObservedObject var reviewStore: ReviewSessionStore
    
    /// Read here purely to drive the theme applier below — unlike the other Appearance keys,
    /// nothing in this view renders from it; the appearance lives on NSApp, not in the view tree.
    @AppStorage(LiquidGlass.appearanceModeKey) private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    // Not `private`: the split-layout extension lives in another file and reads it for the rail
    // spine's card, and `private` is invisible to a same-type extension across files.
    @AppStorage(LiquidGlass.tintKey) var surfaceTint: Double = 0

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
    /// Whether the Compare differences pane is collapsed to just its header strip, freeing its
    /// height for the panes above. Persisted so the choice sticks across launches. Only takes
    /// effect while the differences list is actually showing (see `compareBottomListActive`).
    @AppStorage("compareBottomCollapsed") var bottomPaneCollapsed: Bool = false
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

    /// The resolved glass material. Falls back to `.frosted` — the standard Liquid Glass — when
    /// the stored raw value is unrecognized. Not `private`: the split-layout extension frames the
    /// panes region with it.
    var glassLevel: GlassLevel {
        GlassLevel(rawValue: glassLevelRaw) ?? .frosted
    }
    // Not `private`: the split-layout extension (ContentView+SplitLayout.swift) paints its
    // seam chrome (swap button, rail spine) with the same user-selected hue (C7).
    var glassHue: LiquidGlassHue {
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
    /// Internal, not private: the tab picker it drives lives in the window toolbar now
    /// (ContentView+Toolbar.swift), which `private` would put out of reach.
    @AppStorage("selectedBottomTab") var selectedBottomTab: BottomTab = .differences

    /// The active Tidy lens. Held here rather than in TidyView so the selection survives tab
    /// switches and relaunches; TidyView renders the lens tabs from the binding this hands it.
    @AppStorage("selectedTidyLens") private var selectedTidyLens: TidyLens = .duplicates

    /// Per-tab override of the top-pane visibility, a JSON map (tab raw value → hidden).
    /// Empty means "no overrides — every tab uses its default". Persisted, so deliberately
    /// showing or hiding the Left/Right panes on Tidy or Storage Lens sticks across launches.
    @AppStorage("topPaneOverridesByTab") private var topPaneOverridesRaw: String = ""

    /// Whether the Compare Info inspector is shown. It replaces the old Details tab: a toggleable
    /// right-side panel that shows metadata (and both-sides status) for the current selection.
    /// Persisted so it stays open/closed across launches. Internal, not private: its toggle sits in
    /// the window toolbar now (ContentView+Toolbar.swift).
    @AppStorage("showCompareInspector") var showInspector: Bool = false
    /// The Info inspector's persisted width, resizable by dragging its leading edge. Defaults to the
    /// former fixed 270pt. Clamped to `PaneLogic.inspector{Min,Max}Width` whenever it's written.
    @AppStorage("compareInspectorWidth") private var inspectorWidth: Double = 270
    /// The live width during a resize drag; `nil` when idle. Mirrors the pane splits' pattern —
    /// the layout reads `inspectorDragWidth ?? inspectorWidth`, and the drag commits to
    /// `inspectorWidth` only on release, so `inspectorWidth` stays the stable drag-start base.
    @State private var inspectorDragWidth: Double? = nil
    /// Per-pane action-bar placement scratch space. `FileTreeView` fills each with live row/viewport
    /// geometry; `paneColumn` reads the resolved edge straight from `body`, so the bar's edge is
    /// known synchronously the instant the selection changes — no gate, no show-then-flip.
    @State private var leftPlacement = PaneBarPlacement()
    @State private var rightPlacement = PaneBarPlacement()
    /// Orders the deferred cross-pane selection clears, so a clear queued by one pane's click can
    /// never wipe a selection a later click made in the other pane. See
    /// `PaneLogic.applySelectionWrite`.
    @State private var selectionSequencer = PaneSelectionSequencer()
    /// A pure re-render trigger for SCROLL-driven edge flips: `FileTreeView` mutates the placement
    /// (a class, so no invalidation) and calls back to toggle this, which re-renders `paneColumn` so
    /// it re-reads the flipped edge — animated. Selection changes re-render on their own.
    @State private var leftBarAtTop = false
    @State private var rightBarAtTop = false
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

    /// Each pane's presentation, stored per side so one can be a deep tree while the other is
    /// flat. Defaults to Columns — which rests as a single full-pane column, so the pane opens
    /// exactly as it did before the setting existed.
    @AppStorage(PaneViewMode.defaultsKey(isLeft: true)) private var leftViewModeRaw = PaneViewMode.default.rawValue
    @AppStorage(PaneViewMode.defaultsKey(isLeft: false)) private var rightViewModeRaw = PaneViewMode.default.rawValue

    func paneViewMode(isLeft: Bool) -> PaneViewMode {
        PaneViewMode(rawValue: isLeft ? leftViewModeRaw : rightViewModeRaw) ?? .default
    }

    /// Applies a column drill, mirroring it onto the sibling pane when the panes are linked (or ⌥
    /// is held) — the same rule the breadcrumb and the tree's drill-in already follow, so all three
    /// ways of walking into a folder move the panes together or not together as one setting says.
    ///
    /// The mirror is *pruned* against the other pane's tree rather than copied outright. The two
    /// sides are being compared precisely because they differ, so the folder you just opened may
    /// not exist over there; pruning walks that pane as deep as it genuinely can and stops, which
    /// is both honest and useful — it lands you on the deepest folder the two still share instead
    /// of on an empty column claiming a folder that isn't there.
    func applyColumnNavigation(_ path: PaneBrowsePath, isLeft: Bool) {
        // Only the comparison layout has a sibling to mirror into; the Tidy rail has none. The
        // link-or-⌥ test is the same one the breadcrumb and the tree's drill-in already apply, so
        // all three ways of walking into a folder obey one setting.
        let mirror = layoutMode == .compare
            && (PaneLinkPreference.isLinked || NSEvent.modifierFlags.contains(.option))
        let otherRoot = isLeft ? currentRightPath : currentLeftPath
        syncManager.applyColumnNavigation(
            path,
            isLeft: isLeft,
            mirror: mirror,
            otherIndex: isLeft
                ? syncManager.rightChildrenIndex(treeRoot: otherRoot)
                : syncManager.leftChildrenIndex(treeRoot: otherRoot),
            otherTreeRoot: otherRoot
        )
    }

    /// A crumb click that must move both panes: the ⌥-click, and every plain click while the seam
    /// link is on. Hands the sibling's tree to the manager so the mirrored stack is pruned against
    /// the folders that pane genuinely has — the same treatment a mirrored column drill gets above.
    ///
    /// The root captured here is the sibling's root *before* the navigation, which is the one its
    /// current tree was loaded for; `navigateBothPanes` ignores it when that pane re-roots.
    func navigateBothPanes(toCombinedPath combined: String, from isLeft: Bool) {
        let otherRoot = isLeft ? currentRightPath : currentLeftPath
        syncManager.navigateBothPanes(
            toCombinedPath: combined,
            from: isLeft,
            otherIndex: isLeft
                ? syncManager.rightChildrenIndex(treeRoot: otherRoot)
                : syncManager.leftChildrenIndex(treeRoot: otherRoot),
            otherTreeRoot: otherRoot
        )
    }

    /// Binding for the view switch in a pane's nav cluster.
    func paneViewModeBinding(isLeft: Bool) -> Binding<PaneViewMode> {
        Binding(
            get: { paneViewMode(isLeft: isLeft) },
            set: { if isLeft { leftViewModeRaw = $0.rawValue } else { rightViewModeRaw = $0.rawValue } }
        )
    }

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
    /// list — comparing only identity-relevant fields (id, root path, type), so a root-path
    /// edit counts, but changes to other providers don't. Cosmetic fields are deliberately
    /// excluded: comparing whole structs made a Settings rename (setCustomName → new
    /// displayName) read as a root edit, which tore down an in-flight duplicate review
    /// (`.comparisonRootEdited` has no restore) and forced a full rescan for a label change.
    static func paneProvidersChanged(
        old: [CloudProvider],
        new: [CloudProvider],
        leftId: String,
        rightId: String
    ) -> Bool {
        func provider(_ id: String, in providers: [CloudProvider]) -> CloudProvider? {
            providers.first(where: { $0.id == id })
        }
        func sameIdentity(_ a: CloudProvider?, _ b: CloudProvider?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (a?, b?): return a.id == b.id && a.path == b.path && a.type == b.type
            default: return false
            }
        }
        return !sameIdentity(provider(leftId, in: old), provider(leftId, in: new))
            || !sameIdentity(provider(rightId, in: old), provider(rightId, in: new))
    }

    /// The window content with its overlays, animations, and background. Split out of `body` so the
    /// full modifier chain stays under the Swift type-checker's budget — `mainContentView` is a heavy
    /// `some View` now (it owns the panes and workspace), and chaining everything on it in
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
        // The theme is the one Appearance control no view can render on its own: it lives on
        // NSApp, so that the AppKit surfaces (the NSAlert prompts, NSOpenPanel, the About panel,
        // and the separate Activity Log / Sync History windows) follow it too. Applied from the
        // root view rather than from the Settings picker so it re-applies whoever writes the key
        // and whether or not the Settings overlay happens to be on screen; App.init covers launch.
        .onChange(of: appearanceModeRaw) { AppAppearance.applyPersisted() }
        .liquidGlassAppBackground(level: glassLevel, hue: glassHue)
        // Render the glass as if the window were always key. SwiftUI materials/`glassEffect` thin out
        // and desaturate to gray when the window loses focus (the whole surface visibly shifts as you
        // click away); pinning the active state keeps the panes and chrome looking identical whether
        // or not the app is frontmost.
        .environment(\.controlActiveState, .active)
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
                        // One-time: convert the legacy remembered filing rules (F3) into
                        // automations. Destinations stay absolute — the same provider scoping
                        // the legacy rules had — so nothing needs the provider list; the flag
                        // makes re-runs no-ops.
                        syncManager.migrateFilingRulesToAutomations()
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
            // Ends the guided review and drops the duplicate review without restoring the
            // comparison (the user chose this switch) — but releases the review's pin from the
            // RIGHT pane if the review was no longer active, since that pin is not their choice.
            reviewCoordinator.dispatchReview(.providerSwitched(isLeft: true))
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
            // Mirror of the left handler above, releasing the pin from the LEFT pane instead.
            reviewCoordinator.dispatchReview(.providerSwitched(isLeft: false))
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
        // The Get-Info override also goes stale when the comparison context changes underneath it:
        // a provider switch (its file is on the old provider) or a tab switch (Tidy is single-source
        // and shows its own selection). Without these, `DetailsSidebar` — which prefers `overridePath`
        // over everything — keeps showing the old-provider/old-tab file, defeating the single-source
        // guard. `resetNavigation` only clears selections when non-empty, so the selection onChanges
        // above don't cover the no-selection case.
        .onChange(of: leftProviderId) { _, _ in infoPath = nil }
        .onChange(of: rightProviderId) { _, _ in infoPath = nil }
        .onChange(of: selectedBottomTab) { _, _ in infoPath = nil }
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
                // rescan rather than leaving their stale absolute paths clickable. The
                // review teardown goes through the reducer — this handler used to call
                // endReviewForComparisonChange inline and (like the two shipped bugs the
                // reducer exists for) forgot to clear the duplicate review, whose keeper/
                // copy paths live under the edited root.
                reviewCoordinator.dispatchReview(.comparisonRootEdited)
                syncManager.invalidateComparisonState()
                refreshAction()
            }
        }
        .modifier(SettingsEngineMirrors(syncManager: syncManager, settings: settings))
        // A republish can delete a folder a column stack is standing in — externally, or by the
        // user's own Delete. Re-resolve each stack against the new tree so it falls back to the
        // deepest surviving ancestor; without this the columns render nothing while
        // `currentDirectory` still names the dead folder, which is where New Folder and paste
        // would then act. `PaneTree` compares by publish stamp, so this fires once per publish.
        .onChange(of: syncManager.leftPaneTree) { _, _ in
            // Skipped entirely when the pane has no column stack to prune — building the index to
            // prune an empty path would be the whole-tree walk for nothing.
            guard !syncManager.leftBrowsePath.isEmpty else { return }
            syncManager.pruneBrowsePath(isLeft: true,
                                        against: syncManager.leftChildrenIndex(treeRoot: currentLeftPath),
                                        treeRoot: currentLeftPath)
        }
        .onChange(of: syncManager.rightPaneTree) { _, _ in
            guard !syncManager.rightBrowsePath.isEmpty else { return }
            syncManager.pruneBrowsePath(isLeft: false,
                                        against: syncManager.rightChildrenIndex(treeRoot: currentRightPath),
                                        treeRoot: currentRightPath)
        }
        // Rebuilding the indices walks every difference's ancestor chain — with tens of
        // thousands of differences that froze the main thread after every scan, so the
        // work runs detached and only the results land on main. task(id:) also cancels a
        // stale rebuild when the inputs change again mid-flight.
        .task(id: diffIndexInputs) {
            let inputs = diffIndexInputs
            let (left, right) = await Task.detached(priority: .userInitiated) {
                // Per-pane case-fold gating for the folded badge fallback: a missing row's
                // expected path carries the SOURCE side's ancestor casing, so a destination
                // folder differing only in case showed no contained-diff badge. One stat per
                // rebuild, on the detached walk with the rest of the work.
                func foldsCase(_ root: String) -> Bool {
                    // Only a DEFINITE insensitive answer enables folding: the ??-false helper
                    // reads a vanished/unmounted root as "insensitive", enabling merges on a
                    // volume of unknown semantics during a transient state.
                    guard !root.isEmpty,
                          let sensitive = try? URL(fileURLWithPath: root).resourceValues(
                              forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
                    else { return false }
                    return !sensitive
                }
                return (DiffStatusIndex(differences: inputs.differences, rootPath: inputs.leftRoot,
                                        foldsCase: foldsCase(inputs.leftRoot)),
                        DiffStatusIndex(differences: inputs.differences, rootPath: inputs.rightRoot,
                                        foldsCase: foldsCase(inputs.rightRoot)))
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

    /// The resolved arrangement of the panes and workspace, which now start directly under the
    /// window toolbar. Comparison tabs stack two panes over the workspace; the single-source Tidy
    /// tab docks one collapsible rail beside a workspace that's always shown.
    enum ContentLayout {
        /// Compare: panes over workspace.
        case compareSplit
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
            // The comparison panes and the workspace are both always shown (their toggles were
            // removed — you resize with the divider instead; no current control writes a hidden
            // override for a compare tab), so compare is always the split.
            return .compareSplit
        case .singleSource:
            // The single-source workspace is always shown; only the rail collapses.
            return panesHiddenForCurrentTab ? .singleCollapsed : .singleExpanded
        }
    }

    /// Toggles the panes (both comparison panes, or the single-source rail) for the current tab and
    /// remembers the choice for it. The toolbar's tab picker is always on screen, so — unlike
    /// before — no region is forced back on to compensate.
    func togglePanesForCurrentTab() {
        let overrides = TopPaneVisibility.settingOverride(
            TopPaneVisibility.decodeOverrides(topPaneOverridesRaw),
            tab: selectedBottomTab,
            hidden: !panesHiddenForCurrentTab
        )
        topPaneOverridesRaw = TopPaneVisibility.encodeOverrides(overrides)
    }

    /// Entering a Tidy lens from the lens tabs opens the source rail and positions it for the lens:
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
    func swapPanesAction() {
        // While discoverProviders() is still awaiting, both id onChanges bail on the bootstrap
        // guard without decrementing pendingSwapProviderChanges — a swap now would strand the
        // counter at 2 and silently swallow the user's next two real provider switches. The
        // window is interactive during bootstrap, so refuse the swap outright.
        guard !isBootstrappingProviders else { return }
        guard syncManager.swapPanes() else { return }
        reviewCoordinator.dispatchReview(.panesSwapped)   // the swap redefines the comparison; end the guided review + drop any duplicate review (no restore)
        let swapped = PaneLogic.swappedProviderIds(
            leftProviderId: leftProviderId,
            rightProviderId: rightProviderId
        )
        // Both ids change together (unless the panes already share a provider, in which case
        // the plan is empty and neither onChange fires) — seed the suppression counter with the
        // plan's exact change count. `=` rather than `+=`, preserving the swap's historical
        // reset semantics.
        let plan = ProviderPinPlan.make(
            currentLeft: leftProviderId, currentRight: rightProviderId,
            targetLeft: swapped.leftProviderId, targetRight: swapped.rightProviderId)
        if !plan.assignments.isEmpty {
            pendingSwapProviderChanges = plan.suppressCount
        }
        applyProviderPinAssignments(plan)
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
        // The gate, the root+relative composition, the on-disk validation and the
        // drop-to-root fallback all live in `PaneLogic.paneFocusRestores` (pinned by tests);
        // this only applies the answer.
        let restores = await PaneLogic.paneFocusRestores(
            isEnabled: GeneralSettings.shouldRestoreLastFocus(),
            left: (UserDefaults.standard.string(forKey: GeneralSettings.lastLeftFocusKey) ?? "",
                   settings.path(for: leftProviderId)),
            right: (UserDefaults.standard.string(forKey: GeneralSettings.lastRightFocusKey) ?? "",
                    settings.path(for: rightProviderId)))
        for restore in restores {
            Logger.shared.info("Restoring \(restore.isLeft ? "left" : "right") pane to last session's folder: \(restore.relativePath)")
            syncManager.focusOn(relativePath: restore.relativePath, isLeft: restore.isLeft)
        }
    }

    /// The full reset behind Settings → Advanced. `resetAllSettings()` wipes the defaults
    /// domain and republishes the manager's own settings (each `.onChange` mirror above then
    /// re-seeds the engine); the pieces built from the old values that DON'T flow through
    /// those mirrors — the log gate and the in-memory ignore sets — are reset here.
    ///
    /// A static over the two collaborators so a test can pin all three steps together (the view
    /// method below is the only caller). The order matters and is part of what's pinned:
    /// `resetAllSettings()` re-seeds the live log gate from the just-cleared defaults, so the
    /// `.debug` write must follow it — ahead of it, the re-seed would overwrite it and a user who
    /// had raised the threshold would stay half-reset, seeing no INFO entries after a "reset all".
    ///
    /// `setLogLevel` is a seam only so the test can observe that write without mutating the
    /// process-wide `Logger.shared` gate (which would swallow other suites' entries); production
    /// passes the real one.
    @MainActor
    static func applyFullSettingsReset(
        settings: SettingsManager,
        syncManager: FileSyncManager,
        setLogLevel: (LogLevel) -> Void = { Logger.shared.minimumLevel = $0 }
    ) {
        settings.resetAllSettings()
        setLogLevel(.debug)
        syncManager.clearAllIgnoredItems()
    }

    private func resetAllSettingsAction() {
        Self.applyFullSettingsReset(settings: settings, syncManager: syncManager)
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
            glassHue: glassHue,
            glassLevel: glassLevel,
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
            glassHue: glassHue,
            glassLevel: glassLevel,
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
        // The card is sized in points and grows with the Text size setting, but the window's own
        // minimum is 600pt wide — narrower than the card wants. Hand it the space it actually
        // has so it can clamp itself rather than hang off the edge.
        GeometryReader { proxy in
            ZStack {
                Rectangle()
                    // Deepens for `.clear` (`overlayScrimOpacity`): the card below is floored to
                    // frosted, and pushing the app further back is what lets it read cleanly.
                    .fill(Color.black.opacity(glassLevel.overlayScrimOpacity))
                    .ignoresSafeArea()
                    .onTapGesture { showSettings = false }

                settingsCard(available: proxy.size)
                    // Absorb clicks on the card so they don't fall through to the dismiss backdrop.
                    .contentShape(Rectangle())
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .transition(.opacity)
    }

    /// The Settings card. It picks up the accent tint and the glass material like every other
    /// surface, but `glassCardStyle` applies `flooredForChrome` — this is the one panel with the
    /// whole app behind it rather than the window's gradient, and clear glass over content is two
    /// layers of text competing (it rendered at ~9% opacity before the floor existed). Radius,
    /// clip and shadow come from the shared LiquidGlass system rather than hardcoded values.
    @ViewBuilder
    private func settingsCard(available: CGSize) -> some View {
        SettingsView(
            selection: $settingsTab,
            onClose: { showSettings = false },
            syncManager: syncManager,
            onResetAllSettings: { resetAllSettingsAction() },
            availableSize: available
        )
        .environmentObject(settings)
        .contentSurface(hue: glassHue, tint: surfaceTint)
        .glassCardStyle(level: glassLevel)
        .overlay(
            RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
        // The floating-modal drop shadow, deeper than a content card's: this panel is meant to
        // read as lifted off the window, whatever material it resolved to.
        .shadow(color: .black.opacity(0.3), radius: 30, y: 8)
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
        // Drop the cache AND bump the scan-config epoch so this supersedes any same-target refresh
        // already in flight — a bare cache clear leaves the RefreshKey identical and the forced
        // rescan gets deduped away, silently doing nothing.
        syncManager.prepareForcedRescan()
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

    /// The duplicate-review flow's coordinator — `compareCopies`, the keep-left / trash-right
    /// banner, and the `CompareReviewReducer` effect execution live there now. Stateless by
    /// design: it closes over this view's App-owned bindings and live computed context, so a
    /// fresh value per access is equivalent to the methods it replaced (and the review state's
    /// window-cycle survival — see `duplicateReview` — is untouched).
    var reviewCoordinator: DuplicateReviewCoordinator {
        DuplicateReviewCoordinator(
            syncManager: syncManager,
            reviewStore: reviewStore,
            duplicateReview: $duplicateReview,
            leftProviderId: $leftProviderId,
            rightProviderId: $rightProviderId,
            pendingSwapProviderChanges: $pendingSwapProviderChanges,
            selectedBottomTab: $selectedBottomTab,
            selectedTidyLens: $selectedTidyLens,
            accentColor: glassHue.accentColor,
            glassLevel: glassLevel,
            currentLeftPath: { currentLeftPath },
            currentRightPath: { currentRightPath },
            tidyTargetIsRight: { tidyTargetIsRight },
            tidyProviderRootExpanded: { tidyProviderRootExpanded },
            refreshAction: { refreshAction() },
            applyProviderPinAssignments: { applyProviderPinAssignments($0) }
        )
    }

    /// Applies a `ProviderPinPlan`'s id writes, left before right. The caller must seed
    /// `pendingSwapProviderChanges` with `plan.suppressCount` FIRST — the plan contains only
    /// writes that really change an id, so each one fires exactly one onChange to suppress.
    private func applyProviderPinAssignments(_ plan: ProviderPinPlan) {
        for assignment in plan.assignments {
            switch assignment.side {
            case .left: leftProviderId = assignment.providerId
            case .right: rightProviderId = assignment.providerId
            }
        }
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
                                               providerRoot: URL(fileURLWithPath: root),
                                               providerName: tidyProviderName)
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
        let tree: PaneTree
        let otherTree: PaneTree
        let isLoading: Bool
        let currentPath: String
        let otherSelection: Set<String>
        let diffIndex: DiffStatusIndex
        let otherPaneName: String?
        let hasOnlyHiddenEntries: Bool
        /// How this pane presents its tree. Only the comparison panes reach Columns; the Tidy rail
        /// renders through the same view and deliberately stays on `.tree`.
        let viewMode: PaneViewMode
        /// Path → children for the columns presentation, cached per publish by the manager. `nil`
        /// in Tree mode: building it walks the whole tree, and a pane that will never draw a column
        /// should not pay that on every publish.
        let childrenIndex: PaneChildrenIndex?
    }

    private func paneContext(isLeft: Bool) -> PaneContext {
        // The Tidy rail shares this builder but never Columns: it has no sibling pane, no seam
        // link, and re-roots per lens, so none of the Columns navigation rules apply to it.
        let mode: PaneViewMode = layoutMode == .singleSource ? .tree : paneViewMode(isLeft: isLeft)
        return PaneContext(
            isLeft: isLeft,
            title: isLeft ? "Left" : "Right",
            providerId: isLeft ? leftProviderId : rightProviderId,
            relativePath: syncManager.combinedRelativePath(isLeft: isLeft),
            canGoBack: syncManager.canGoBack(isLeft: isLeft),
            canGoForward: syncManager.canGoForward(isLeft: isLeft),
            tree: isLeft ? syncManager.leftPaneTree : syncManager.rightPaneTree,
            otherTree: isLeft ? syncManager.rightPaneTree : syncManager.leftPaneTree,
            isLoading: isLeft ? syncManager.isLoadingLeftTree : syncManager.isLoadingRightTree,
            currentPath: isLeft ? currentLeftPath : currentRightPath,
            otherSelection: isLeft ? syncManager.selectedRightPaths : syncManager.selectedLeftPaths,
            diffIndex: isLeft ? leftDiffIndex : rightDiffIndex,
            otherPaneName: isLeft ? paneNames.right : paneNames.left,
            hasOnlyHiddenEntries: isLeft ? syncManager.leftTreeHasOnlyHiddenEntries : syncManager.rightTreeHasOnlyHiddenEntries,
            viewMode: mode,
            childrenIndex: mode == .columns
                ? (isLeft ? syncManager.leftChildrenIndex(treeRoot: currentLeftPath)
                          : syncManager.rightChildrenIndex(treeRoot: currentRightPath))
                : nil
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
        // Read the scroll-flip trigger so this column re-renders when a scroll crossing flips the
        // edge; the value itself is unused — the edge is resolved fresh below.
        _ = isLeft ? leftBarAtTop : rightBarAtTop
        // Resolve the bar's edge synchronously from the pane's live geometry and current selection.
        // Because this runs in `body`, a selection change (which re-renders here) lands the bar at
        // the correct edge in the same pass — no gate, no deferred flip.
        let placement = isLeft ? leftPlacement : rightPlacement
        let barAtTop = placement.resolveAtTop(selection: Set(barNodes.map(\.id)))
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
                onNavigate: { syncManager.navigatePane(isLeft: isLeft, toCombinedPath: $0) },
                // The Tidy rail has no visible sibling: ⌥-click (and the 🔗-linked crumb click)
                // must behave as plain navigation there, never drive the hidden right pane.
                onNavigateBoth: layoutMode == .singleSource
                    ? { syncManager.navigatePane(isLeft: isLeft, toCombinedPath: $0) }
                    : { navigateBothPanes(toCombinedPath: $0, from: isLeft) },
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
                showHiddenFiles: $syncManager.showHiddenFiles,
                // The Tidy rail gets no switch: it has no Columns mode to switch to.
                viewMode: layoutMode == .singleSource ? nil : paneViewModeBinding(isLeft: isLeft),
                // Targets the pane's current folder, which in Columns is the deepest open column.
                onNewFolder: {
                    let target = pane.viewMode == .columns
                        ? (isLeft ? syncManager.leftBrowsePath : syncManager.rightBrowsePath)
                            .currentDirectory(treeRoot: pane.currentPath)
                        : pane.currentPath
                    actionHandler?.beginCreateFolder(in: target)
                }
            )
            // Cards gives the provider header its own card, so the chrome reads as a separate
            // object from the data — the same [toolbar][gap][content] rhythm the bottom workspace
            // already has. The gap arithmetic needs no new number: each card insets itself by half
            // a gutter, so header↔list comes to one `cardGutter`, and pane↔pane and pane↔window
            // edge stay exactly where they were. In Unified `paneCardIfNeeded` is a no-op, so the
            // pane stays one continuous surface and the two styles read differently — which is the
            // point of having both.
            .paneCardIfNeeded(surfaceStyle, level: glassLevel)
            treeView(pane)
                .paneCardIfNeeded(surfaceStyle, level: glassLevel)
                // The file actions (Compare/Copy/Move/Delete) live here now, not in the titlebar: a
                // contextual bar on whichever pane holds the selection, so the buttons name their
                // target. (New Folder stays on the right-click menu to keep the bar compact.) The
                // overlay is scoped to the list — NOT the whole column — so its top position lands
                // just under the pane header, never over it. It flips to the top when a selected
                // row is near the list's bottom, keeping the selection visible.
                .overlay(alignment: barAtTop ? .top : .bottom) {
                    if !barNodes.isEmpty {
                        paneActionBar(isLeft: isLeft, selectionNodes: barNodes)
                            .padding(10)
                            // Feed the padded bar's real footprint to the placement math, so the
                            // flip-to-top triggers exactly when a bottom bar would cover the
                            // selected row — not at a guessed fixed band. Writes to the shared
                            // class, so no view invalidation.
                            .background(
                                GeometryReader { proxy in
                                    Color.clear
                                        .onAppear { placement.coverage = proxy.size.height }
                                        .onChange(of: proxy.size.height) { _, h in placement.coverage = h }
                                }
                            )
                            // Re-key on the edge so a scroll-crossing flip is a clean cross-fade (old
                            // copy fades out at one edge, new fades in at the other) rather than an
                            // alignment snap. A selection-driven edge change carries no animation
                            // context, so it lands instantly; a scroll flip runs inside the callback's
                            // `withAnimation`, so it cross-fades.
                            .id(barAtTop)
                            .transition(.move(edge: barAtTop ? .top : .bottom).combined(with: .opacity))
                    }
                }
                // Quick fade on appear/disappear only (keyed on presence, not the edge), so clicking
                // a file shows the bar at once and clearing the selection fades it out.
                .animation(.easeOut(duration: 0.11), value: barNodes.isEmpty)
        }
        // Escape clears this pane's selection — the file lists give no deselect gesture, so
        // without this a folder picked here could never be un-picked. Only swallow the key when
        // there's actually a selection here; otherwise let it bubble (dialogs, etc.).
        //
        // The Tidy rail reads its RAW selection rather than `barNodes`: the action bar (and with it
        // `barSelectionNodes`) is compare-only, so gating on it alone made Escape dead on the one
        // surface that has neither a bar nor its ✕ to fall back on. Compare's gate is unchanged —
        // see `PaneLogic.escapeClearsSelection`.
        .onKeyPress(.escape) {
            let paneSelection = isLeft ? syncManager.selectedLeftPaths : syncManager.selectedRightPaths
            guard PaneLogic.escapeClearsSelection(
                isSingleSource: layoutMode == .singleSource,
                hasActionBarSelection: !barNodes.isEmpty,
                paneHasSelection: !paneSelection.isEmpty
            ) else { return .ignored }
            clearSelection(isLeft: isLeft)
            return .handled
        }
    }

    /// The Info inspector — the former Details tab, now a toggleable right-side panel showing metadata
    /// for the current selection. Available on both Compare (both-sides status) and the single-source
    /// Tidy rail. `DetailsSidebar` handles the no-selection empty state itself.
    private var infoInspector: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .scaledFont(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Info").scaledFont(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                CloseButton {
                    withAnimation(.easeInOut(duration: 0.15)) { showInspector = false }
                }
                .help("Hide the inspector")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            DetailsSidebar(syncManager: syncManager, leftPath: currentLeftPath, rightPath: currentRightPath, compact: true, overridePath: infoPath, singleSource: layoutMode == .singleSource)
        }
        .frame(width: inspectorDragWidth ?? inspectorWidth)
        // A card like every other surface, not a docked `.bar` panel: the opaque bar fill was a
        // solid band down a window Clear asks to see through, and its zero inset broke the gap
        // model (2.5pt to the pane card, flush to the window edge the root padding then floated).
        .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
    }

    /// The draggable seam between the panes and the Info inspector: a 1pt clear strip in the
    /// HStack flow with a 10pt-wide hit target straddling it — the pane splits' idiom, minus
    /// their visible divider, since the card gap already draws the separation here.
    /// `inspectorWidth` is held constant through the gesture (written only on release), so it's
    /// the stable base for `PaneLogic.inspectorDragWidth`.
    ///
    /// The drag reads `.global`, NOT the default `.local`, coordinate space: this handle slides left
    /// as the inspector widens, so in its own moving frame `translation` feeds back on itself and
    /// collapses to ~0 once layout catches up — the panes' splits dodge the same trap by reading a
    /// fixed coordinate space (the rule is documented on the shared `ResizeHandle`). Global
    /// translation is the cursor's real delta, independent of the handle's position, so the resize
    /// stays smooth instead of stuttering.
    private var inspectorResizeHandle: some View {
        // A clear 1pt strip, not a visible Divider: the inspector is a floating card now, so the
        // seam is the gap between cards — same construction as the panes↔workspace boundary
        // (2.5 + 1 + 2.5). Only the hit target remains.
        Color.clear.frame(width: 1)
            .overlay {
                ResizeHandle(
                    axis: .horizontal,
                    thickness: 10,
                    minimumDistance: 1,
                    coordinateSpace: .global,
                    onDrag: { value in
                        inspectorDragWidth = PaneLogic.inspectorDragWidth(
                            base: inspectorWidth, translation: value.translation.width)
                    },
                    onCommit: {
                        if let w = inspectorDragWidth { inspectorWidth = w }
                        inspectorDragWidth = nil
                    }
                )
            }
    }

    @ViewBuilder
    private var mainContentView: some View {
        HStack(spacing: 0) {
            verticalSplit
            if showInspector {
                inspectorResizeHandle
                infoInspector
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // The window-edge half of every gap. Each card insets itself by the other half, so a
        // card-to-edge gap and a card-to-card gap both come to `cardGutter`. Applied once,
        // here, and nowhere else — per-container padding is what made the gaps uneven before.
        .padding(LiquidGlass.cardInset)
        // Animate the panes collapsing/expanding when the tab's pane state flips — both on
        // the manual toggle and on the auto-collapse that fires when a tab switch changes it.
        .animation(.easeInOut(duration: 0.2), value: panesHiddenForCurrentTab)
        // No animation on the collapse: the differences pane snaps open/closed instantly with the
        // chevron, which is what reads as responsive here; the others keep the softer easeInOut.
        .animation(nil, value: bottomPaneIsCollapsed)
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
                    glassLevel: glassLevel,
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
        // A banner that outlived the previous window (the manager owns it; the scheduler below is
        // view `@State`) gets its auto-dismiss armed here, since the `onChange` never fires for a
        // value that didn't change. `adoptExistingBanner` no-ops when there's no banner or this
        // scheduler is already tracking one, so a re-appearance can't restart the countdown.
        .onAppear {
            bannerDismissScheduler.adoptExistingBanner(syncManager.banner) {
                syncManager.banner = nil
            }
        }
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
    /// so the click lands on the first try; the OTHER pane's clear is deferred one runloop tick,
    /// and stands down if a newer click has landed by the time it runs.
    ///
    /// Both halves of that, and why each is necessary, live in `PaneLogic.applySelectionWrite` —
    /// where the ORDERING can be tested rather than only the arithmetic.
    private func paneSelectionBinding(isLeft: Bool) -> Binding<Set<String>> {
        Binding(
            get: { isLeft ? syncManager.selectedLeftPaths : syncManager.selectedRightPaths },
            set: { newSelection in
                PaneLogic.applySelectionWrite(
                    newSelection,
                    isLeft: isLeft,
                    state: syncManager,
                    sequencer: selectionSequencer,
                    schedule: { DispatchQueue.main.async(execute: $0) }
                )
            }
        )
    }

    /// Clears the selection in one pane. The single-pane-selected invariant means at most one
    /// side is ever populated, so this is what both the Escape key and the action bar's ✕ call to
    /// dismiss the current selection — the file lists themselves offer no deselect gesture.
    func clearSelection(isLeft: Bool) {
        if isLeft {
            if !syncManager.selectedLeftPaths.isEmpty { syncManager.selectedLeftPaths = [] }
        } else {
            if !syncManager.selectedRightPaths.isEmpty { syncManager.selectedRightPaths = [] }
        }
    }

    @ViewBuilder
    private func treeView(_ pane: PaneContext) -> some View {
        // The Tidy rail is the only pane on screen: it shows no action bar, so it takes no placement
        // scratch space and no flip callback (`placement`'s own contract), and it has no sibling to
        // be subordinate to, so its selection wears the full-strength wash.
        let isRail = layoutMode == .singleSource
        FileTreeView(
            tree: pane.tree,
            otherTree: pane.otherTree,
            isLoading: pane.isLoading,
            currentPath: pane.currentPath,
            selection: paneSelectionBinding(isLeft: pane.isLeft),
            otherSelection: pane.otherSelection,
            isLeft: pane.isLeft,
            delegate: PaneActionDelegate(handler: actionHandler, syncManager: syncManager, settings: settings, isLeft: pane.isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId, isSingleSource: layoutMode == .singleSource, forceRefreshAction: forceRefreshAction, onGetInfo: { showInfo(for: $0) }),
            diffIndex: pane.diffIndex,
            otherPaneName: pane.otherPaneName,
            rootPathIsValid: settings.isPathValid(for: pane.providerId),
            providerIsEnabled: settings.isEnabled(pane.providerId),
            hasOnlyHiddenEntries: pane.hasOnlyHiddenEntries,
            rootPath: settings.path(for: pane.providerId),
            onOpenSettings: openProviderSettings,
            // The Tidy rail is a single source with no opposite pane, so its row menu drops the
            // comparison-only items and renames "Compare only this folder" to "Open".
            isSingleSource: layoutMode == .singleSource,
            // Shared placement scratch space this pane fills from live geometry; `paneColumn` reads
            // the edge from it synchronously. The flip callback fires only when a SCROLL crossing
            // changes the edge — it re-renders the column inside `withAnimation` so the bar
            // cross-fades. Clicking a file needs no callback: it re-renders the column on its own,
            // which lands the bar at the correct edge instantly.
            placement: isRail ? nil : (pane.isLeft ? leftPlacement : rightPlacement),
            onBarEdgeFlip: isRail ? nil : {
                withAnimation(.easeInOut(duration: 0.22)) {
                    if pane.isLeft { leftBarAtTop.toggle() } else { rightBarAtTop.toggle() }
                }
            },
            // Which pane the action bar is acting on — the same predicate that decides where the bar
            // renders, so the strong selection wash and the bar can never point at different panes.
            // The rail has no bar and no sibling, so it is always its own active pane.
            isActivePane: isRail || paneActionBarSideActive(isLeft: pane.isLeft),
            viewMode: pane.viewMode,
            childrenIndex: pane.childrenIndex,
            browsePath: pane.isLeft ? $syncManager.leftBrowsePath : $syncManager.rightBrowsePath,
            onColumnNavigate: { applyColumnNavigation($0, isLeft: pane.isLeft) },
            onBackgroundDeselect: { handleBackgroundDeselect(depth: $0, isLeft: pane.isLeft) }
        )
    }

    /// A plain click on a pane's empty space: let the selection go, and — in Columns — close the
    /// columns to the right of the one clicked in, which is what Finder does.
    ///
    /// **Both panes are cleared, deliberately.** The one-pane-selected invariant means the selection
    /// usually lives in the pane the user did *not* just click, so clearing only this side would
    /// leave the click looking dead on the more common path. That is also why this does not go
    /// through `paneSelectionBinding`: `PaneLogic.applySelectionWrite` treats an empty write as
    /// enforcing nothing and leaves the other pane alone on purpose, since that is what keeps the
    /// right-click "Copy N items from other pane" menu working. Right-click cannot reach here —
    /// `NSClickGestureRecognizer` watches the primary button only — so that menu is untouched.
    ///
    /// Both writes are synchronous, and safely so: the recognizer fires on mouse-UP, outside the
    /// mouse-down tracking loop an `NSTableView` commits its selection from. This is therefore not
    /// the mid-commit sibling write that dropped clicks in `aa9d407`, and it queues no deferral that
    /// could go stale the way `94554e9`'s did.
    ///
    /// The truncation is routed through `applyColumnNavigation` rather than written straight to the
    /// browse path so that closing columns obeys the seam link exactly as opening them does — a
    /// linked pane truncates (pruned) alongside, and the move is logged like any other.
    func handleBackgroundDeselect(depth: Int?, isLeft: Bool) {
        PaneLogic.clearBothSelections(state: syncManager)
        let browsePath = isLeft ? syncManager.leftBrowsePath : syncManager.rightBrowsePath
        guard let path = PaneLogic.backgroundDeselectPath(from: browsePath, depth: depth) else { return }
        applyColumnNavigation(path, isLeft: isLeft)
    }

    /// Binding for the primary tab picker that, when the user switches *to* Tidy, opens the source
    /// rail and positions it for the active lens. Wrapping the binding (rather than observing
    /// `selectedBottomTab` globally) confines this to the picker's own control: the programmatic
    /// scan actions assign `selectedBottomTab` directly and so never trip it, keeping their chosen
    /// scan folder intact. Internal so the toolbar (ContentView+Toolbar.swift) can drive it.
    var primaryTabSelection: Binding<BottomTab> {
        Binding(
            get: { selectedBottomTab },
            set: { newTab in
                let previousTab = selectedBottomTab
                selectedBottomTab = newTab
                // All duplicate-review / guided-review teardown & restore decisions go through the
                // reducer (CompareReviewReducer): an abandoned review — left Compare while inactive,
                // banner and Done button gone — is torn down like Done (ending the guided review AND
                // restoring the auto-pinned provider); returning to Compare re-focuses the two copies
                // (the shared left pane was reset to the rail root while away).
                reviewCoordinator.dispatchReview(.tabSwitched(toCompare: newTab == .differences, fromCompare: previousTab == .differences))
                if newTab == .tidy {
                    presentTidyRail(for: selectedTidyLens)
                }
            }
        )
    }

    /// Binding for the Tidy lens tabs, which TidyView renders. Wraps the stored lens with the same
    /// side effect the tabs carried when they lived up here: choosing a lens opens the source rail
    /// and points it at that lens's folder (root, or the TODO inbox for Organize). Wrapping the
    /// binding rather than observing `selectedTidyLens` keeps the programmatic scan actions — which
    /// assign the lens directly — from re-homing the rail out from under their chosen scan folder.
    private var tidyLensSelection: Binding<TidyLens> {
        Binding(
            get: { selectedTidyLens },
            set: { newLens in
                selectedTidyLens = newLens
                presentTidyRail(for: newLens)
            }
        )
    }

    /// True when the Compare bottom pane is showing the actual differences list (not a
    /// placeholder like scanning / all-in-sync). Collapse only applies here — the header strip it
    /// leaves behind belongs to `DifferencesView`, which the placeholders don't render. Internal so
    /// the split-layout extension can gate the collapsed frame on it.
    var compareBottomListActive: Bool {
        selectedBottomTab == .differences && (!syncManager.differences.isEmpty || reviewStore.isReviewing)
    }

    /// The Compare bottom pane is collapsed to its header strip right now: the user asked for it,
    /// the differences list (which owns that strip) is the thing on screen, and no guided review is
    /// running. The review override is NOT restated here — it comes from
    /// `DifferencesView.isCollapsedToHeaderStrip`, the same function the view itself renders
    /// against, so the height and the content cannot disagree about whether this pane is a strip
    /// or a full list.
    var bottomPaneIsCollapsed: Bool {
        compareBottomListActive && DifferencesView.isCollapsedToHeaderStrip(
            storedCollapse: bottomPaneCollapsed, isReviewing: reviewStore.isReviewing)
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
        if selectedBottomTab == .differences, let review = duplicateReview, reviewCoordinator.duplicateReviewActive(review) {
            reviewCoordinator.duplicateReviewBanner(review)
                .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
        }
        // An active review keeps the view mounted through an empty live list: an external
        // change resolving the last live difference mid-review must not vanish the session.
        if selectedBottomTab == .tidy {
            // The single-source hub. Tidy owns its own cards — including the lens tabs, which head
            // the workspace they switch; the Storage lens (folded in) renders its own read-only
            // surface beneath them. Compare | Tidy itself lives in the window toolbar.
            TidyView(
                syncManager: syncManager,
                lens: tidyLensSelection,
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
                onCompareCopies: reviewCoordinator.compareCopies
            )
        } else if compareBottomListActive {
            // DifferencesView renders its own two cards (toolbar + table); Compare | Tidy lives in
            // the window toolbar.
            DifferencesView(syncManager: syncManager, reviewStore: reviewStore, paneNames: paneNames, onQuickLook: { toggleQuickLook($0) }, onGetInfo: { showInfo(for: $0) }, isCollapsed: $bottomPaneCollapsed)
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
                                .scaledFont(.system(size: 13, weight: .medium))
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
                .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
        }
        }
    }

}
