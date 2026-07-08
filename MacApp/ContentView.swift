import SwiftUI
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
    
    @AppStorage("selectedLeftProviderId") private var leftProviderId: String = "iCloud"
    @AppStorage("selectedRightProviderId") private var rightProviderId: String = "iCloud"
    @State private var isScanning = false
    
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    
    @State private var actionHandler: FileActionHandler?
    @State private var quickLookURL: URL? = nil
    @State private var showingBottomPane: Bool = true
    @State private var isBootstrappingProviders: Bool = true
    
    @AppStorage(LiquidGlass.intensityKey) private var glassIntensity: Double = 0.65
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    
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

    private static let bannerAutoDismissNanoseconds: UInt64 = 5_000_000_000 // 5 seconds
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
                rightProviderId: $rightProviderId
            )
        } detail: {
            mainContentView
                .frame(minWidth: 600)
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        ControlGroup {
                            Button(action: forceRefreshAction) {
                                Label("Scan", systemImage: isScanning ? "hourglass" : "arrow.clockwise")
                            }
                            .disabled(isScanning)
                            
                            Button(action: {
                                withAnimation { showingBottomPane.toggle() }
                            }) {
                                Label("Toggle Bottom Pane", systemImage: "rectangle.bottomthird.inset.filled")
                                    .foregroundColor(showingBottomPane ? .accentColor : .primary)
                            }
                            
                            Button(action: { openWindow(id: "activity-log") }) {
                                Label("Logs", systemImage: "list.bullet.rectangle")
                            }
                            
                            Button(action: { openSettings() }) {
                                Label("Settings", systemImage: "gear")
                            }
                        }
                    }
                }
        }
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
        .alert("Error", isPresented: Binding(
            get: { syncManager.currentError != nil },
            set: { _ in syncManager.currentError = nil }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            if let errorMsg = syncManager.currentError {
                Text(errorMsg)
            }
        }
        .onReceive(syncManager.$isScanning) { scanning in
            withAnimation { isScanning = scanning }
        }
        .onReceive(syncManager.refreshSubject) { _ in
            refreshAction()
        }
        .onAppear {
            // Diagnostic hook (like paneDragDisabled): `defaults write
            // com.abhishekgirish.SyncCloud openSettingsOnLaunch -bool YES` opens the
            // Settings scene at startup, so automated verification can reach it
            // without synthesizing input. No-op unless explicitly armed.
            if UserDefaults.standard.bool(forKey: "openSettingsOnLaunch") {
                openSettings()
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
            Logger.shared.info("User switched left provider to \(newId)")
            // resetNavigation() fires refreshSubject, which onReceive above turns into a refresh.
            syncManager.resetNavigation()
        }
        .onChange(of: rightProviderId) { _, newId in
            guard !isBootstrappingProviders else { return }
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

    /// User-triggered refresh: clears prefetch cache so new files on disk appear immediately.
    private func forceRefreshAction() {
        Logger.shared.info("User requested a force refresh")
        syncManager.prefetchedTrees.removeAll()
        refreshAction()
    }

    @ViewBuilder
    private var mainContentView: some View {
        VStack(spacing: 0) {
            NavigationToolbar(syncManager: syncManager)
            Divider()
            paneActionBar
            Divider()
            VSplitView {
                VStack(spacing: 0) {
                    HSplitView {
                        VStack(spacing: 0) {
                            PaneHeader(
                                title: "Left",
                                provider: settings.availableProviders.first(where: { $0.id == leftProviderId }),
                                rootPath: settings.path(for: leftProviderId),
                                relativePath: syncManager.leftRelativePath,
                                onNavigate: { syncManager.focusOn(relativePath: $0, isLeft: true) },
                                onNavigateBoth: { syncManager.focusBoth(relativePath: $0) }
                            )
                            leftTreeView
                        }
                        .frame(minWidth: 250)
                        
                        VStack(spacing: 0) {
                            PaneHeader(
                                title: "Right",
                                provider: settings.availableProviders.first(where: { $0.id == rightProviderId }),
                                rootPath: settings.path(for: rightProviderId),
                                relativePath: syncManager.rightRelativePath,
                                onNavigate: { syncManager.focusOn(relativePath: $0, isLeft: false) },
                                onNavigateBoth: { syncManager.focusBoth(relativePath: $0) }
                            )
                            rightTreeView
                        }
                        .frame(minWidth: 250)
                    }
                    Divider()
                    DashboardHeader(leftCount: syncManager.leftItemCount, rightCount: syncManager.rightItemCount, differences: syncManager.differences)
                }
                if showingBottomPane {
                    bottomPaneView
                        .frame(minHeight: 150)
                }
            }
        }
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
            if let banner = syncManager.bannerMessage {
                OperationBannerView(message: banner)
                    .padding(.top, 8)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: syncManager.bannerMessage)
        .onChange(of: syncManager.bannerMessage) { _, newValue in
            bannerDismissScheduler.bannerChanged(to: newValue, delayNanoseconds: Self.bannerAutoDismissNanoseconds) {
                syncManager.bannerMessage = nil
            }
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
    private func OperationBannerView(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .glassCardStyle(material: .ultraThickMaterial, intensity: glassIntensity)
    }

    @ViewBuilder
    private var paneActionBar: some View {
        // Each access walks the full pane tree; resolve the selection once per render. The trees
        // and selections are all @Published, so any change re-renders this bar with fresh nodes.
        let selectionNodes = activeSelectionNodes
        let copyTarget = PaneLogic.copyTargetName(activePane: activePane, paneNames: paneNames)
        let actionSymbols = PaneLogic.actionBarSymbols(activePane: activePane)
        HStack(spacing: 10) {
            Button(action: {
                guard let node = selectionNodes.first, node.isDirectory else { return }
                let isLeft = (activePane == .left)
                actionHandler?.focusFolder(node, isLeft: isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId)
            }) {
                Label("Compare", systemImage: "scope")
            }
            .disabled(selectionNodes.count != 1 || !selectionNodes[0].isDirectory)

            Button(action: {
                guard !selectionNodes.isEmpty, let activePane else { return }
                let fromLeft = (activePane == .left)
                actionHandler?.copyItems(selectionNodes, fromLeft: fromLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId)
            }) {
                Label(copyTarget.map { "Copy to \($0)" } ?? "Copy", systemImage: actionSymbols.copy)
            }
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
            .disabled(selectionNodes.isEmpty)
            .help(copyTarget.map { "Move the selected items to \($0)" } ?? "Move the selected items to the other pane")

            Button(action: {
                guard let path = activePanePath else { return }
                actionHandler?.beginCreateFolder(in: path)
            }) {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .disabled(activePane == nil)

            Button(role: .destructive, action: {
                guard !selectionNodes.isEmpty else { return }
                actionHandler?.confirmDelete(selectionNodes)
            }) {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selectionNodes.isEmpty)

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

            Spacer()
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .glassBarStyle(intensity: glassIntensity)
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
            delegate: PaneActionDelegate(handler: actionHandler, syncManager: syncManager, settings: settings, isLeft: true, leftProviderId: leftProviderId, rightProviderId: rightProviderId, forceRefreshAction: forceRefreshAction, quickLook: { quickLookURL = URL(fileURLWithPath: $0) }),
            ignoredPaths: syncManager.ignoredPaths,
            diffIndex: leftDiffIndex,
            otherPaneName: paneNames.right
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
            delegate: PaneActionDelegate(handler: actionHandler, syncManager: syncManager, settings: settings, isLeft: false, leftProviderId: leftProviderId, rightProviderId: rightProviderId, forceRefreshAction: forceRefreshAction, quickLook: { quickLookURL = URL(fileURLWithPath: $0) }),
            ignoredPaths: syncManager.ignoredPaths,
            diffIndex: rightDiffIndex,
            otherPaneName: paneNames.left
        )
    }
    
    /// The tabbed workspace at the bottom of the file explorer.
    /// It dynamically switches between `DifferencesView` and `DetailsSidebar`.
    @ViewBuilder
    private var bottomPaneView: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: manualBottomTabSelection) {
                    ForEach(BottomTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                
                Spacer()
            }
            .frame(height: 44)
            .layoutPriority(1)
            .background(.ultraThinMaterial)
            
            Divider()
                .opacity(0.6)
            
            ZStack {
                if selectedBottomTab == .differences {
                    if !syncManager.differences.isEmpty {
                        DifferencesView(syncManager: syncManager, paneNames: paneNames)
                            .frame(minHeight: 0)
                    } else if syncManager.hasScanned {
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
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.regularMaterial.opacity(0.5))
                    } else {
                        VStack(spacing: 8) {
                            Text("No Scan Performed")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Text("Click Scan to compare directories.")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    DetailsSidebar(syncManager: syncManager, leftPath: currentLeftPath, rightPath: currentRightPath)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(minHeight: 0)
                }
            }
            .frame(minHeight: 0)
            .background(.regularMaterial.opacity(0.4))
        }
        .glassCardStyle(material: .regularMaterial, intensity: glassIntensity)
        .overlay(
            RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
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
    /// Shows Quick Look for the given absolute path (double-click on a file row).
    let quickLook: (String) -> Void

    func handleRefresh() {
        forceRefreshAction()
    }
    func handleQuickLook(_ node: FileNode) { quickLook(node.id) }
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
