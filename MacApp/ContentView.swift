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
    /// Which settings tab the overlay shows. Owned here so it persists across open/close and can
    /// be preset (e.g. the invalid-pane fix-it action jumps straight to Providers).
    @State private var settingsTab: SettingsView.SettingsTab = .appearance

    @AppStorage("selectedLeftProviderId") private var leftProviderId: String = "iCloud"
    @AppStorage("selectedRightProviderId") private var rightProviderId: String = "iCloud"
    @State private var isScanning = false

    /// Number of provider-id `onChange` notifications still expected from an in-flight pane
    /// swap. A swap flips both @AppStorage ids at once, which would fire both id onChanges and
    /// drive two navigation resets that wipe the focus/selection the swap just moved to the
    /// other side. Each suppressed onChange decrements this; the swap action seeds it with the
    /// number of ids that actually change (2, or 0 when both panes already share a provider) so
    /// later real provider switches are never suppressed.
    @State private var pendingSwapProviderChanges: Int = 0

    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow

    @State private var actionHandler: FileActionHandler?
    @State private var quickLookURL: URL? = nil
    @State private var showingBottomPane: Bool = true
    @State private var isBootstrappingProviders: Bool = true
    
    @AppStorage(LiquidGlass.intensityKey) private var glassIntensity: Double = 0.65
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0

    /// Left pane's share of the pane row's width (0…1). Persisted so the split survives relaunches.
    /// Drives the custom two-pane split that replaced HSplitView, whose NSSplitView divider bled
    /// up through the `.hiddenTitleBar` toolbar band; a SwiftUI HStack + divider respects the
    /// toolbar's safe area, so the divider now starts at the pane headers.
    @AppStorage("mainPaneSplitFraction") private var paneSplitFraction: Double = 0.5
    /// Live split fraction while the divider is being dragged; nil when idle. Kept in @State so a
    /// drag updates smoothly without rewriting @AppStorage every frame — it's persisted once, on
    /// drag end. `mainContentView` reads this in preference to `paneSplitFraction` mid-drag.
    @State private var paneDragFraction: Double? = nil

    private var surfaceStyle: SurfaceStyle {
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
        .background(
            Button(action: {
                if let targetPath = PaneLogic.primarySelectionPath(
                    leftSelection: syncManager.selectedLeftPaths,
                    rightSelection: syncManager.selectedRightPaths
                ) {
                    quickLookURL = URL(fileURLWithPath: targetPath)
                }
            }) { EmptyView() }
            .keyboardShortcut(.space, modifiers: [])
            .opacity(0)
        )
        .liquidGlassAppBackground(intensity: glassIntensity, hue: LiquidGlassHue(rawValue: glassHueRaw) ?? .blue)
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
            // General setting: start the session with hidden files shown when the user asked for it.
            syncManager.showHiddenFiles = UserDefaults.standard.bool(forKey: GeneralSettings.showHiddenByDefaultKey)
            // Diagnostic hook: `defaults write com.abhishekgirish.SyncCloud
            // openSettingsOnLaunch -bool YES` opens the Settings overlay at startup, so
            // automated verification can reach it without synthesizing input. No-op
            // unless explicitly armed; honors `settingsSelectedTab` for the initial tab.
            if UserDefaults.standard.bool(forKey: "openSettingsOnLaunch") {
                let storedTab = UserDefaults.standard.string(forKey: SettingsView.selectedTabDefaultsKey) ?? ""
                settingsTab = SettingsView.SettingsTab(rawValue: storedTab) ?? .appearance
                showSettings = true
            }
            actionHandler = FileActionHandler(syncManager: syncManager, settings: settings)
            syncManager.undoManager = undoManager
            syncManager.ignoreGoogleDriveNewerDateOnly = settings.ignoreGoogleDriveNewerDateOnly
            Task { @MainActor in
                await settings.discoverProviders()
                applyProviderSelection(preferDistinctPair: true)
                if !settings.enabledProviders.isEmpty {
                    refreshAction()
                }
                isBootstrappingProviders = false
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
    private var paneNames: PaneProviderNames {
        PaneProviderNames(
            leftName: settings.availableProviders.first(where: { $0.id == leftProviderId })?.displayName,
            rightName: settings.availableProviders.first(where: { $0.id == rightProviderId })?.displayName
        )
    }

    /// Builds the full path for the left pane. Uses only the left provider's root + left relative path to avoid mixing roots.
    private var currentLeftPath: String {
        PaneLogic.fullPath(root: settings.path(for: leftProviderId), relativePath: syncManager.leftRelativePath)
    }

    /// Builds the full path for the right pane. Uses only the right provider's root + right relative path to avoid mixing roots.
    private var currentRightPath: String {
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

    /// Swaps the left and right panes entirely — providers, focused folders, selections, and
    /// per-pane back/forward history all flip sides in one click. The manager's paired state is
    /// swapped first (so the single post-swap rescan reads already-swapped focus and selection),
    /// then the @AppStorage provider ids. Both id onChanges fire but are suppressed via
    /// `pendingSwapProviderChanges` so they don't reset the just-swapped navigation; this method
    /// drives the one rescan itself.
    private func swapPanesAction() {
        syncManager.swapPanes()
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
            Button("Retry") {
                // Grab the handler before clearing the error — clearing it nils the handler.
                let retry = syncManager.currentErrorRetry
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
    private func forceRefreshAction() {
        Logger.shared.info("User requested a force refresh")
        syncManager.prefetchedTrees.removeAll()
        refreshAction()
    }

    /// One resizable file pane: provider header stacked over its file tree.
    @ViewBuilder
    private func paneColumn(isLeft: Bool) -> some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: isLeft ? "Left" : "Right",
                provider: settings.availableProviders.first(where: { $0.id == (isLeft ? leftProviderId : rightProviderId) }),
                rootPath: settings.path(for: isLeft ? leftProviderId : rightProviderId),
                relativePath: isLeft ? syncManager.leftRelativePath : syncManager.rightRelativePath,
                canGoBack: isLeft ? syncManager.leftHistory.canGoBack : syncManager.rightHistory.canGoBack,
                canGoForward: isLeft ? syncManager.leftHistory.canGoForward : syncManager.rightHistory.canGoForward,
                onBack: { syncManager.goBack(isLeft: isLeft) },
                onForward: { syncManager.goForward(isLeft: isLeft) },
                onNavigate: { syncManager.focusOn(relativePath: $0, isLeft: isLeft) },
                onNavigateBoth: { syncManager.focusBoth(relativePath: $0) },
                showHiddenFiles: $syncManager.showHiddenFiles
            )
            if isLeft { leftTreeView } else { rightTreeView }
        }
        .paneCardIfNeeded(surfaceStyle)
    }

    /// Two file panes side by side with a draggable divider between them. This replaces
    /// `HSplitView`: its NSSplitView-backed divider ignored the top safe area and drew up
    /// through the `.hiddenTitleBar` toolbar band, whereas this SwiftUI HStack lays out
    /// entirely within the safe area, so the divider starts at the pane headers. Drag-to-resize
    /// is preserved via a hit-testable divider handle that updates `paneSplitFraction`.
    @ViewBuilder
    private var panesSplit: some View {
        GeometryReader { geo in
            let minPane: CGFloat = 250
            let totalWidth = geo.size.width
            // Clamp so neither pane goes below minPane (degrades gracefully in a too-narrow window).
            let minFraction = totalWidth > 0 ? min(0.5, Double(minPane / totalWidth)) : 0
            // While dragging, the live @State value drives the layout; otherwise the persisted one.
            let fraction = min(max(paneDragFraction ?? paneSplitFraction, minFraction), 1 - minFraction)
            let leftWidth = totalWidth * fraction
            HStack(spacing: 0) {
                paneColumn(isLeft: true)
                    .frame(width: leftWidth)
                paneColumn(isLeft: false)
                    .frame(width: totalWidth - leftWidth)
            }
            .frame(width: totalWidth, height: geo.size.height)
            // Panes sit flush (no divider element) so they read as one continuous surface with no
            // seam. An invisible, hit-testable handle straddles the boundary to preserve resize.
            .overlay(alignment: .leading) {
                paneResizeHandle(totalWidth: totalWidth, minFraction: minFraction)
                    .offset(x: leftWidth - 6)
            }
            .coordinateSpace(.named(Self.paneRowSpace))
        }
    }

    /// Invisible 12pt-wide drag handle centered on the pane boundary. The drag reads the cursor's
    /// absolute x within the pane row (a fixed coordinate space) rather than accumulating
    /// translation on the moving handle — so it stays smooth — and persists `paneSplitFraction`
    /// only on release.
    @ViewBuilder
    private func paneResizeHandle(totalWidth: CGFloat, minFraction: Double) -> some View {
        Color.clear
            .frame(width: 12)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.paneRowSpace))
                    .onChanged { value in
                        guard totalWidth > 0 else { return }
                        let f = Double(value.location.x / totalWidth)
                        paneDragFraction = min(max(f, minFraction), 1 - minFraction)
                    }
                    .onEnded { _ in
                        if let f = paneDragFraction { paneSplitFraction = f }
                        paneDragFraction = nil
                    }
            )
    }

    /// Name of the coordinate space spanning the pane row, so the divider drag can read the
    /// cursor's absolute x position independent of the divider's own (moving) frame.
    private static let paneRowSpace = "panesRow"
    private static let verticalStackSpace = "verticalStack"

    /// The bottom (Differences/Details) pane's share of the content height. Persisted so it
    /// survives relaunches and never resets when switching the Differences/Details tab.
    @AppStorage("mainBottomPaneFraction") private var bottomPaneFraction: Double = 0.4
    /// Live vertical-split fraction while dragging; nil when idle (persisted once on release).
    @State private var verticalDragFraction: Double? = nil

    /// The panes stacked over the bottom workspace, with a draggable — but invisible — horizontal
    /// divider between them. Replaces `VSplitView` so the divider line can be hidden (VSplitView's
    /// divider isn't customizable) while keeping resize. Because the split ratio is driven by
    /// `bottomPaneFraction`, it never resets when the Differences/Details tab changes.
    @ViewBuilder
    private var verticalSplit: some View {
        GeometryReader { geo in
            let totalHeight = geo.size.height
            if showingBottomPane {
                let minTop: CGFloat = 220
                let minBottom: CGFloat = 150
                let dividerHeight: CGFloat = 1
                let panesHeight = max(0, totalHeight - dividerHeight)
                // fraction = the bottom pane's share; clamp so neither section drops below its min.
                let minFraction = panesHeight > 0 ? min(0.85, Double(minBottom / panesHeight)) : 0
                let maxFraction = panesHeight > 0 ? max(minFraction, 1 - Double(minTop / panesHeight)) : 1
                let fraction = min(max(verticalDragFraction ?? bottomPaneFraction, minFraction), maxFraction)
                let bottomHeight = panesHeight * fraction
                VStack(spacing: 0) {
                    panesSplit
                        .frame(height: panesHeight - bottomHeight)
                    verticalResizeDivider(panesHeight: panesHeight, minFraction: minFraction, maxFraction: maxFraction)
                        .frame(height: dividerHeight)
                    bottomPaneView
                        .frame(height: bottomHeight)
                }
                .frame(width: geo.size.width, height: totalHeight)
                .coordinateSpace(.named(Self.verticalStackSpace))
            } else {
                panesSplit
            }
        }
    }

    /// The invisible, draggable horizontal divider between the panes and the bottom workspace.
    /// Like the vertical one, it tracks the cursor's absolute y in a fixed coordinate space and
    /// persists only on release.
    @ViewBuilder
    private func verticalResizeDivider(panesHeight: CGFloat, minFraction: Double, maxFraction: Double) -> some View {
        Rectangle()
            .fill(Color.clear)
            .overlay {
                Color.clear
                    .frame(height: 12)
                    .contentShape(Rectangle())
                    .pointerStyle(.rowResize)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.verticalStackSpace))
                            .onChanged { value in
                                guard panesHeight > 0 else { return }
                                let bottomH = panesHeight - value.location.y
                                let f = Double(bottomH / panesHeight)
                                verticalDragFraction = min(max(f, minFraction), maxFraction)
                            }
                            .onEnded { _ in
                                if let f = verticalDragFraction { bottomPaneFraction = f }
                                verticalDragFraction = nil
                            }
                    )
            }
    }

    @ViewBuilder
    private var mainContentView: some View {
        verticalSplit
        .overlay {
            if let progress = syncManager.activeProgress {
                ZStack {
                    Color.black.opacity(0.1)
                        .edgesIgnoringSafeArea(.all)
                    
                    ProgressDialog(progress: progress)
                        .padding()
                        .transition(AnyTransition.move(edge: Edge.top).combined(with: AnyTransition.opacity))
                }
                .animation(.spring(), value: progress)
            }
        }
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

    private var activePane: PaneLogic.ActivePane? {
        PaneLogic.activePane(
            leftSelection: syncManager.selectedLeftPaths,
            rightSelection: syncManager.selectedRightPaths
        )
    }

    private var activeSelectionNodes: [FileNode] {
        switch activePane {
        case .left?:
            return syncManager.leftTree.findNodes(at: syncManager.selectedLeftPaths)
        case .right?:
            return syncManager.rightTree.findNodes(at: syncManager.selectedRightPaths)
        case nil:
            return []
        }
    }

    private var activePanePath: String? {
        switch activePane {
        case .left?: return currentLeftPath
        case .right?: return currentRightPath
        case nil: return nil
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

    /// The window toolbar: file actions in a leading group (right after the sidebar toggle),
    /// utility actions trailing. Lives in the native toolbar so it fills the titlebar band.
    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            // Resolve the active selection once; @Published changes refresh these.
            let selectionNodes = activeSelectionNodes
            let copyTarget = PaneLogic.copyTargetName(activePane: activePane, paneNames: paneNames)
            let actionSymbols = PaneLogic.actionBarSymbols(activePane: activePane)

            Button(action: {
                guard let node = selectionNodes.first, node.isDirectory else { return }
                let isLeft = (activePane == .left)
                actionHandler?.focusFolder(node, isLeft: isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId)
            }) {
                Label("Compare", systemImage: "rectangle.split.2x1")
            }
            .labelStyle(.titleAndIcon)
            .disabled(selectionNodes.count != 1 || !selectionNodes[0].isDirectory)
            .help("Open the selected folder in both panes to compare them")

            Button(action: {
                guard !selectionNodes.isEmpty, let activePane else { return }
                let fromLeft = (activePane == .left)
                actionHandler?.copyItems(selectionNodes, fromLeft: fromLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId)
            }) {
                Label(copyTarget.map { "Copy to \($0)" } ?? "Copy", systemImage: actionSymbols.copy)
            }
            .labelStyle(.titleAndIcon)
            .disabled(selectionNodes.isEmpty)
            .help(copyTarget.map { "Copy the selected items to \($0)" } ?? "Copy the selected items to the other pane")

            Button(action: {
                guard !selectionNodes.isEmpty, let activePane else { return }
                let fromLeft = (activePane == .left)
                Task {
                    _ = await actionHandler?.moveItems(selectionNodes, fromLeft: fromLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId)
                }
            }) {
                Label(copyTarget.map { "Move to \($0)" } ?? "Move", systemImage: actionSymbols.move)
            }
            .labelStyle(.titleAndIcon)
            .disabled(selectionNodes.isEmpty)
            .help(copyTarget.map { "Move the selected items to \($0)" } ?? "Move the selected items to the other pane")

            Button(action: {
                guard let path = activePanePath else { return }
                actionHandler?.beginCreateFolder(in: path)
            }) {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .labelStyle(.titleAndIcon)
            .disabled(activePane == nil)
            .help("Create a new folder in the active pane")

            Button(role: .destructive, action: {
                guard !selectionNodes.isEmpty else { return }
                actionHandler?.confirmDelete(selectionNodes)
            }) {
                Label("Delete", systemImage: "trash")
            }
            .labelStyle(.titleAndIcon)
            .disabled(selectionNodes.isEmpty)
            .help("Delete the selected items")

            Menu {
                ForEach(SortOption.allCases, id: \.self) { option in
                    Button {
                        syncManager.sortOption = option
                    } label: {
                        Label(option.rawValue, systemImage: syncManager.sortOption == option ? "checkmark" : "")
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .labelStyle(.titleAndIcon)
            .help("Choose how items are sorted")
            // The hidden-files toggle now lives in each pane header, next to its nav buttons.
        }

        // Push the utility actions to the trailing edge of the titlebar. macOS 26's grouped
        // toolbar no longer trails `.primaryAction` on its own, so a flexible spacer separates
        // the file actions from the utility pill; earlier systems trail primaryAction natively.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: forceRefreshAction) {
                Label("Scan", systemImage: isScanning ? "hourglass" : "arrow.clockwise")
            }
            .disabled(isScanning)
            .help("Scan for changes")

            Button(action: { withAnimation { showingBottomPane.toggle() } }) {
                Label("Toggle Bottom Pane", systemImage: "rectangle.bottomthird.inset.filled")
            }
            .help("Toggle the bottom pane")

            Button(action: { openWindow(id: "activity-log") }) {
                Label("Logs", systemImage: "list.bullet.rectangle")
            }
            .help("Activity log")

            Button(action: { showSettings = true }) {
                Label("Settings", systemImage: "gear")
            }
            .help("Settings")
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
    private var leftTreeView: some View {
        FileTreeView(
            tree: syncManager.leftTree,
            otherTree: syncManager.rightTree,
            isLoading: syncManager.isLoadingLeftTree,
            currentPath: currentLeftPath,
            selection: paneSelectionBinding(isLeft: true),
            otherSelection: syncManager.selectedRightPaths,
            isLeft: true,
            delegate: PaneActionDelegate(handler: actionHandler, syncManager: syncManager, settings: settings, isLeft: true, leftProviderId: leftProviderId, rightProviderId: rightProviderId, forceRefreshAction: forceRefreshAction),
            ignoredPaths: syncManager.ignoredPaths,
            diffIndex: leftDiffIndex,
            otherPaneName: paneNames.right,
            rootPathIsValid: settings.isPathValid(for: leftProviderId),
            providerIsEnabled: settings.isEnabled(leftProviderId),
            hasOnlyHiddenEntries: syncManager.leftTreeHasOnlyHiddenEntries,
            rootPath: settings.path(for: leftProviderId),
            onOpenSettings: openProviderSettings
        )
    }
    
    @ViewBuilder
    private var rightTreeView: some View {
        FileTreeView(
            tree: syncManager.rightTree, 
            otherTree: syncManager.leftTree,
            isLoading: syncManager.isLoadingRightTree, 
            currentPath: currentRightPath,
            selection: paneSelectionBinding(isLeft: false),
            otherSelection: syncManager.selectedLeftPaths,
            isLeft: false,
            delegate: PaneActionDelegate(handler: actionHandler, syncManager: syncManager, settings: settings, isLeft: false, leftProviderId: leftProviderId, rightProviderId: rightProviderId, forceRefreshAction: forceRefreshAction),
            ignoredPaths: syncManager.ignoredPaths,
            diffIndex: rightDiffIndex,
            otherPaneName: paneNames.left,
            rootPathIsValid: settings.isPathValid(for: rightProviderId),
            providerIsEnabled: settings.isEnabled(rightProviderId),
            hasOnlyHiddenEntries: syncManager.rightTreeHasOnlyHiddenEntries,
            rootPath: settings.path(for: rightProviderId),
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
    private var bottomPaneView: some View {
        // Stable outer container: keeps the VSplitView child identity constant across tab
        // switches, so selecting Details no longer resets the divider and collapses the panes.
        VStack(spacing: 0) {
        if selectedBottomTab == .differences && !syncManager.differences.isEmpty {
            // DifferencesView renders its own two cards (toolbar + table) with the tabs inline.
            DifferencesView(syncManager: syncManager, paneNames: paneNames, onQuickLook: { quickLookURL = $0 }, leadingHeader: AnyView(bottomTabPicker))
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
    
/// Connects a single pane’s `FileTreeView` to `FileActionHandler` (focus, copy, move, delete, rename, etc.).
@MainActor
struct PaneActionDelegate: FileActionDelegate {
    let handler: FileActionHandler?
    let syncManager: FileSyncManager
    let settings: SettingsManager
    let isLeft: Bool
    let leftProviderId: String
    let rightProviderId: String
    let forceRefreshAction: () -> Void

    func handleRefresh() {
        forceRefreshAction()
    }
    func handleFocus(_ node: FileNode) { handler?.focusFolder(node, isLeft: isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId) }
    func handleCopy(_ nodes: [FileNode]) { handler?.copyItems(nodes, fromLeft: isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId) }
    func handleMove(_ nodes: [FileNode]) { 
        Task {
            _ = await handler?.moveItems(nodes, fromLeft: isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId) 
        }
    }
    func handleDelete(_ nodes: [FileNode]) { handler?.confirmDelete(nodes) }
    func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) { 
        handler?.handleCopyToClipboard(nodes, isCut: isCut)
    }
    func handlePaste(_ targetDir: FileNode) { handler?.pasteClipboard(to: targetDir) }
    func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode]) { handler?.pasteItems(nodes, to: targetDir, isCut: false) }
    func handlePasteToPath(_ path: String) { handler?.pasteClipboard(toPath: path) }
    func handleDrop(_ nodes: [FileNode], toPath path: String, isMove: Bool) {
        if isMove {
            handler?.moveItems(nodes, toPath: path)
        } else {
            handler?.pasteItems(nodes, toPath: path, isCut: false)
        }
    }
    func handleRename(_ node: FileNode) { handler?.beginRename(node) }
    func handleCreateFolder(at path: String) { handler?.beginCreateFolder(in: path) }
    func handleGetInfo(for path: String) { handler?.openGetInfo(for: path) }
    func handleSort(_ option: SortOption) { 
        Logger.shared.info("User changed sort option to \(option)")
        syncManager.sortOption = option 
    }
    func handleIgnore(_ nodes: [FileNode]) {
        let rootPath = isLeft ? settings.path(for: leftProviderId) : settings.path(for: rightProviderId)
        let expandedRoot = (rootPath as NSString).expandingTildeInPath
        let relPrefix = isLeft ? syncManager.leftRelativePath : syncManager.rightRelativePath
        
        let basePath = relPrefix.isEmpty ? expandedRoot : (expandedRoot as NSString).appendingPathComponent(relPrefix)

        // Convert to relative paths from current focal point so they sync across panes seamlessly
        let relativeTargets = PaneLogic.relativeIgnoreTargets(nodeIds: nodes.map(\.id), basePath: basePath)
        syncManager.ignoredPaths = PaneLogic.toggledIgnoredPaths(
            targets: relativeTargets,
            ignoredPaths: syncManager.ignoredPaths
        )
    }
    func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool {
        syncManager.isNodeIgnored(node, currentPath: currentPath)
    }
}
