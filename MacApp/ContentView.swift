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

    /// Number of provider-id `onChange` notifications still expected from an in-flight pane
    /// swap. A swap flips both @AppStorage ids at once, which would fire both id onChanges and
    /// drive two navigation resets that wipe the focus/selection the swap just moved to the
    /// other side. Each suppressed onChange decrements this; the swap action seeds it with the
    /// number of ids that actually change (2, or 0 when both panes already share a provider) so
    /// later real provider switches are never suppressed.
    @State private var pendingSwapProviderChanges: Int = 0

    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) var openWindow

    @State var actionHandler: FileActionHandler?
    @State var quickLookURL: URL? = nil
    @State var showingBottomPane: Bool = true
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

    var surfaceStyle: SurfaceStyle {
        SurfaceStyle(rawValue: surfaceStyleRaw) ?? .unified
    }
    private var glassHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: glassHueRaw) ?? .blue
    }

    /// Represents the available tabs in the integrated bottom workspace.
    enum BottomTab: String, CaseIterable {
        /// Displays differential scanning results and sync actions.
        case differences = "Differences"
        /// Displays rich file metadata (size, dates, permissions).
        case details = "Details"
    }
    /// Persisted so a user who was on Details stays there across launches. Stored by
    /// `BottomTab` raw value — SyncCloudTests pins the raw values as a stable format.
    @AppStorage("selectedBottomTab") private var selectedBottomTab: BottomTab = .differences

    /// True once the user manually picks the Differences tab via the segmented Picker;
    /// suppresses the selection-driven auto-switch to Details until they manually pick
    /// Details again. Per-launch only — deliberately not persisted.
    @State private var differencesTabPickedManually: Bool = false

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

    var body: some View {
        NavigationSplitView {
            ProviderSidebar(
                settings: settings,
                leftProviderId: $leftProviderId,
                rightProviderId: $rightProviderId,
                onSwap: swapPanesAction
            )
        } detail: {
            mainContentView
                .frame(minWidth: 600)
                .toolbar { mainToolbar }
        }
        .overlay {
            if showSettings {
                settingsOverlay
            }
        }
        .animation(.easeOut(duration: 0.15), value: showSettings)
        .quickLookPreview($quickLookURL)
        .liquidGlassAppBackground(intensity: glassIntensity, hue: glassHue)
        .alert(
            syncManager.currentError?.title ?? "Error",
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
                case .discoverProvidersAndApplyInitialSelection:
                    Task { @MainActor in
                        await settings.discoverProviders()
                        applyProviderSelection(preferDistinctPair: true)
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
            syncManager.resetNavigation()
        }
        .onChange(of: syncManager.selectedLeftPaths) { _, paths in
            switchToDetailsTabIfNeeded(whenSelectionChanges: paths)
        }
        .onChange(of: syncManager.selectedRightPaths) { _, paths in
            switchToDetailsTabIfNeeded(whenSelectionChanges: paths)
        }
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
                syncManager.invalidateComparisonState()
                refreshAction()
            }
        }
        .onChange(of: settings.ignoreGoogleDriveNewerDateOnly) { _, new in
            syncManager.ignoreGoogleDriveNewerDateOnly = new
        }
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

    /// When user selects items in a pane and the bottom pane is on Differences, switch to
    /// Details tab — unless the user manually picked Differences (see PaneLogic).
    private func switchToDetailsTabIfNeeded(whenSelectionChanges paths: Set<String>) {
        guard PaneLogic.shouldAutoSwitchToDetails(
            hasSelection: !paths.isEmpty,
            bottomPaneVisible: showingBottomPane,
            currentTabIsDetails: selectedBottomTab == .details,
            differencesPickedManually: differencesTabPickedManually
        ) else { return }
        selectedBottomTab = .details
    }

    /// Binding used exclusively by the bottom-tab Picker, so every write through it is by
    /// construction a manual user pick — the programmatic auto-switch above writes
    /// `selectedBottomTab` directly and never trips this setter.
    private var manualBottomTabSelection: Binding<BottomTab> {
        Binding(
            get: { selectedBottomTab },
            set: { tab in
                differencesTabPickedManually = (tab == .differences)
                selectedBottomTab = tab
            }
        )
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
    private func swapPanesAction() {
        // While discoverProviders() is still awaiting, both id onChanges bail on the bootstrap
        // guard without decrementing pendingSwapProviderChanges — a swap now would strand the
        // counter at 2 and silently swallow the user's next two real provider switches. The
        // window is interactive during bootstrap, so refuse the swap outright.
        guard !isBootstrappingProviders else { return }
        guard syncManager.swapPanes() else { return }
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

            SettingsView(selection: $settingsTab, onClose: { showSettings = false })
                .environmentObject(settings)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.3), radius: 30, y: 8)
                // Absorb clicks on the card so they don't fall through to the dismiss backdrop.
                .contentShape(Rectangle())
        }
        .transition(.opacity)
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
        case .dismiss:
            Button("Dismiss", role: .cancel) {
                syncManager.currentError = nil
            }
        }
    }

    /// The alert body: the human message, then the underlying reason and affected path when known.
    private func errorAlertMessage(_ error: SyncError) -> String {
        var lines = [error.message]
        if let reason = error.reason, !reason.isEmpty { lines.append(reason) }
        if let path = error.path { lines.append(path) }
        return lines.joined(separator: "\n")
    }

    /// User-triggered refresh: clears prefetch cache so new files on disk appear immediately.
    func forceRefreshAction() {
        Logger.shared.info("User requested a force refresh")
        syncManager.prefetchedTrees.removeAll()
        refreshAction()
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
        VStack(spacing: 0) {
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
                showHiddenFiles: $syncManager.showHiddenFiles
            )
            treeView(pane)
        }
        .paneCardIfNeeded(surfaceStyle)
    }

    @ViewBuilder
    private var mainContentView: some View {
        verticalSplit
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
                OperationBannerView(banner: banner)
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
        }
        .onChange(of: syncManager.showHiddenFiles) { _, newValue in
            Logger.shared.info("User toggled hidden files to: \(newValue)")
        }
    }

    /// Lightweight in-app banner used for bulk operation completion notifications.
    @ViewBuilder
    private func OperationBannerView(banner: OperationBanner) -> some View {
        HStack(spacing: 10) {
            Image(systemName: OperationBannerStyle.iconName(for: banner.severity))
                .font(.title3)
                .foregroundStyle(OperationBannerStyle.tint(for: banner.severity))
            Text(banner.message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Button {
                syncManager.banner = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close notification")
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .glassCardStyle(material: .ultraThickMaterial, intensity: glassIntensity)
        .onHover { hovering in
            bannerDismissScheduler.hoverChanged(isHovering: hovering)
        }
    }

    /// Selection binding for one pane that enforces the one-pane-selected invariant
    /// synchronously: setting a non-empty selection also clears the other pane in the
    /// same update, so consumers (`PaneLogic.activePane`, Details, Quick Look) never see
    /// both panes selected — not even for one runloop tick. Binding setters run during
    /// event handling, so writing both `@Published` properties here is safe; a didSet on
    /// FileSyncManager would publish from within a view update and had to defer instead,
    /// which left a stale other-pane selection when a click produced no set change.
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
                if syncManager.selectedLeftPaths != reconciled.left {
                    syncManager.selectedLeftPaths = reconciled.left
                }
                if syncManager.selectedRightPaths != reconciled.right {
                    syncManager.selectedRightPaths = reconciled.right
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
            delegate: PaneActionDelegate(handler: actionHandler, syncManager: syncManager, settings: settings, isLeft: pane.isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId, forceRefreshAction: forceRefreshAction),
            diffIndex: pane.diffIndex,
            otherPaneName: pane.otherPaneName,
            rootPathIsValid: settings.isPathValid(for: pane.providerId),
            providerIsEnabled: settings.isEnabled(pane.providerId),
            hasOnlyHiddenEntries: pane.hasOnlyHiddenEntries,
            rootPath: settings.path(for: pane.providerId),
            onOpenSettings: openProviderSettings
        )
    }

    /// The Differences/Details segmented tabs. Shown standalone above the Details/empty states,
    /// and passed into DifferencesView so the tabs merge into its single toolbar (Option C).
    private var bottomTabPicker: some View {
        Picker("", selection: manualBottomTabSelection) {
            ForEach(BottomTab.allCases, id: \.self) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .tint(glassHue.accentColor)
        .frame(width: 200)
        .labelsHidden()
    }

    /// The tabbed workspace at the bottom of the file explorer.
    /// It dynamically switches between `DifferencesView` and `DetailsSidebar`.
    @ViewBuilder
    var bottomPaneView: some View {
        // Stable outer container: keeps this bottom pane's identity constant across tab
        // switches, so selecting Details doesn't reset the vertical split or collapse the panes.
        VStack(spacing: 0) {
        // An active review keeps the view mounted through an empty live list: an external
        // change resolving the last live difference mid-review must not vanish the session.
        if selectedBottomTab == .differences && (!syncManager.differences.isEmpty || reviewStore.isReviewing) {
            // DifferencesView renders its own two cards (toolbar + table) with the tabs inline.
            DifferencesView(syncManager: syncManager, reviewStore: reviewStore, paneNames: paneNames, onQuickLook: { quickLookURL = $0 }, leadingHeader: AnyView(bottomTabPicker))
        } else {
            // Details / empty / no-scan: a slim tabs card, then the content as its own card.
            VStack(spacing: 8) {
                HStack {
                    bottomTabPicker
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .bottomSectionCard(surfaceStyle, intensity: glassIntensity, hue: glassHue, tint: surfaceTint)

                Group {
                    if selectedBottomTab == .differences {
                        if syncManager.hasScanned {
                            VStack(spacing: 12) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 44))
                                    .foregroundStyle(.green)
                                Text("Everything is in sync")
                                    .font(.title3.weight(.semibold))
                                Text("No differences found between focused directories.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            VStack(spacing: 8) {
                                Text("No Scan Performed")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                Text("Click Scan to compare directories.")
                                    .font(.subheadline)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } else {
                        DetailsSidebar(syncManager: syncManager, leftPath: currentLeftPath, rightPath: currentRightPath)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .bottomSectionCard(surfaceStyle, intensity: glassIntensity, hue: glassHue, tint: surfaceTint)
            }
            // Match the pane cards' gutter so the bottom cards line up with the panes above.
            .padding(LiquidGlass.cardGutter)
        }
        }
    }
}
