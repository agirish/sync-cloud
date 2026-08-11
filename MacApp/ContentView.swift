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

    // MARK: The ⌘K palette (ROADMAP 14)

    /// Raises and dismisses the palette. A `@StateObject` because it owns an `NSPanel` and a set of
    /// observers that must outlive a body pass — see `CommandPalettePanel.swift` for why the
    /// palette is a window rather than an overlay on this view.
    @StateObject var palettePanel = CommandPalettePanelController()
    /// Whether the palette is up. **Not the source of truth** — the panel is — but the menu chords
    /// are suspended off it (`ShortcutValuePublisher.suspended`), so it is kept in step by the
    /// controller's single `onDismiss`. The query and the selection live with the panel; a copy
    /// here would be a second answer to what has been typed.
    @State var showCommandPalette = false

    /// Organize's rail selection and scope, **as `@AppStorage` rather than raw `UserDefaults`**.
    ///
    /// `aimOrganize` writes both when ⌘K routes to a lens or a folder, and it wrote them through
    /// `UserDefaults.standard.set` — which this app has already been bitten by and documented:
    /// `@AppStorage`'s process-wide storage location per (store, key) can **lose** a standard-domain
    /// write outright rather than deliver it late, which is why the defaults-backed test suites
    /// mount with their own `ScratchDefaults`. `TidyView` holds both keys in `@AppStorage`, so a
    /// route could land on Organize and leave the rail on whatever lens it was already showing,
    /// intermittently and with nothing to see. Writing through the same property wrapper puts both
    /// sides on one storage location, which is the path every other writer in the app already takes.
    @AppStorage(OrganizeLens.defaultsKey) var paletteRailLens: OrganizeLens?
    @AppStorage(OrganizeScopeDefaults.pathKey) var paletteScopePath: String = ""

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

    /// The app's text scale. Read here rather than off `UserDefaults` inside the toolbar because
    /// the workspace bar's shedding rule depends on it: a direct defaults read produces the right
    /// answer once and never invalidates, so raising Settings ▸ Text size would leave the bar
    /// claiming its labels still fit until something unrelated re-rendered it.
    @Environment(\.appFontScale) var appFontScale
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) var openWindow

    @State var actionHandler: FileActionHandler?
    @State var quickLookURL: URL? = nil
    @State private var isBootstrappingProviders: Bool = true
    /// The `openCommandPaletteOnLaunch` diagnostic, waiting for provider discovery — see the
    /// bootstrap case that sets it.
    @State private var paletteOnLaunchArmed = false
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

    /// The selected workspace, persisted so a session resumes where it left off. Stored by
    /// ``Workspace`` raw value — `WorkspaceTests` pins those as a stable format, and
    /// `Workspace.migrateSelection` carries the old two-key selection forward at launch.
    /// Internal, not private: the workspace bar it drives lives in the window toolbar
    /// (ContentView+Toolbar.swift), which `private` would put out of reach.
    @AppStorage(Workspace.defaultsKey) var selectedWorkspace: Workspace = .compare
    /// Which lens is showing inside Organize, or `nil` for its overview.
    ///
    /// Lives beside the workspace rather than inside `TidyView` because programmatic navigation
    /// needs to write it: "Find duplicates of this" names a lens, and since the fold that lens is
    /// one rail item inside Organize rather than a workspace of its own. `TidyView` reads the same
    /// key through its own `@AppStorage`, so the two cannot disagree.
    @AppStorage(OrganizeLens.defaultsKey) var selectedOrganizeLens: OrganizeLens?
    /// Set while a ⌘F query has been turned into a person gather. Clearing it returns the pane to
    /// whatever it was showing — the gather is a lens over the source, not a place you navigate to.
    @State var personScope: PersonScope?

    /// The subtree Organize is answering about — **empty is the global view, and it is the
    /// default.**
    ///
    /// Beside the lens selection and for the same reason: programmatic callers set it. "Organize
    /// This Folder…" from a folder's context menu and the ⌘K command both name a folder, and both
    /// have to be able to re-aim Organize before any scan has run. `TidyView` reads the same key
    /// through its own `@AppStorage`, so the two cannot disagree.
    ///
    /// Never written directly — see ``setOrganizeScope(_:)``, which is where the provider root is
    /// normalized to the empty string so the global view has exactly one representation.
    @AppStorage(OrganizeScopeDefaults.pathKey) var organizeScopePath: String = ""

    /// The lens the selected workspace shows, or `nil` on Compare. Derived, not stored: there is
    /// one selection now, and a second copy of it would be a second thing to keep in step.
    var selectedLens: TidyLens? { selectedWorkspace.lens }

    /// The file a pane row's "Find duplicates of this" asked the Duplicates lens to reveal.
    ///
    /// Held HERE and not inside `TidyView`, because the workspace switch that carries the user
    /// there mounts that view: state set on the way in has to outlive the mount. Not persisted —
    /// it names a scan that only exists in this session.
    @State var duplicateRevealRequest: DuplicateRevealRequest?

    /// Whether the workspace bar can spell its segments out at the window's current width.
    ///
    /// The *style*, not the width. `.onGeometryChange` only calls its action when the transformed
    /// value changes, so resolving the answer inside the transform means a live window resize
    /// writes this once — when the labels actually shed — instead of once per frame. Storing the
    /// raw width invalidated `ContentView.body` on every frame of every drag to answer a question
    /// whose answer flips maybe twice in a session.
    ///
    /// `.onGeometryChange` rather than a `GeometryReader` writing a preference: it fires outside
    /// the layout pass, which is what keeps a width-driven toolbar from re-entering layout and
    /// tripping the AppKit constraint-loop crash that pattern caused before.
    /// Both controls' rungs, resolved together — see `WorkspaceBarMetrics.styles`. One value
    /// because they share one row: two states resolved from two thresholds is how each concludes
    /// it fits a width the other is also spending.
    @State var toolbarStyles = ToolbarBarStyles(workspace: .iconOnly, search: .compact)

    /// Per-workspace override of the top-pane visibility, a JSON map (workspace raw value →
    /// hidden). Empty means "no overrides — every workspace uses its default". Persisted, so
    /// deliberately showing or hiding the panes on a workspace sticks across launches.
    @AppStorage(TopPaneVisibility.overridesKey) private var topPaneOverridesRaw: String = ""

    /// Whether the Compare Info inspector is shown. It replaces the old Details tab: a toggleable
    /// right-side panel that shows metadata (and both-sides status) for the current selection.
    /// Persisted so it stays open/closed across launches. Internal, not private: its toggle sits in
    /// the window toolbar now (ContentView+Toolbar.swift).
    @AppStorage("showCompareInspector") var showInspector: Bool = false
    /// The Columns preview column — the pane header's pill owns this preference; it is declared
    /// here as well only so ⇧⌘P (`shortcutPreviewColumn`) has a stored property to flip. Same key,
    /// same default, one value.
    @AppStorage(PaneViewMode.previewColumnDefaultsKey) var previewColumnEnabled: Bool = PaneViewMode.previewColumnDefault
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

    // MARK: Search inside the pane trees
    //
    // Per side, and there are only two sides to hold: the single-source rail IS the left pane on a
    // different surface (see `paneContext`), so Organize, Duplicates and Storage all search through
    // `leftPaneSearch` without a third copy of any of this. See `ContentView+PaneSearch.swift`.

    /// What the user typed and where the walk has got to, per pane. The field's own state.
    @State var leftPaneSearch = PaneSearchFieldState()
    @State var rightPaneSearch = PaneSearchFieldState()
    /// The results those queries produced, recomputed off the debounce rather than per render — a
    /// query runs over the whole loaded tree, and `body` here is re-evaluated by any of the
    /// manager's ~56 published properties.
    @State var leftSearchResults: PaneSearchResults = .empty(side: .left)
    @State var rightSearchResults: PaneSearchResults = .empty(side: .right)
    /// The recomputation counter behind `PaneSearchResults.generation`. One per side, exactly like
    /// the manager's own publish counters, so a stamp is only ever compared against its own pane's.
    @State var leftSearchGeneration = 0
    @State var rightSearchGeneration = 0

    /// Each pane's presentation, stored per side so one can be a deep tree while the other is
    /// flat. Defaults to Columns — which rests as a single full-pane column, so the pane opens
    /// exactly as it did before the setting existed.
    @AppStorage(PaneViewMode.defaultsKey(isLeft: true)) private var leftViewModeRaw = PaneViewMode.default.rawValue
    @AppStorage(PaneViewMode.defaultsKey(isLeft: false)) private var rightViewModeRaw = PaneViewMode.default.rawValue
    /// The Tidy rail's own presentation, on its own key so switching a comparison pane never
    /// restacks the rail. Columns by default for the same reason the panes are: a resting Columns
    /// pane is one full-width column listing exactly what the tree listed, so this changes what a
    /// click *does* — one click opens a folder instead of needing the row menu's Open.
    @AppStorage(PaneViewMode.railDefaultsKey) private var railViewModeRaw = PaneViewMode.default.rawValue

    func paneViewMode(isLeft: Bool) -> PaneViewMode {
        PaneViewMode(rawValue: isLeft ? leftViewModeRaw : rightViewModeRaw) ?? .default
    }

    /// The rail is a single source, so it takes no side — reading it through `paneViewMode(isLeft:)`
    /// would hand it the left comparison pane's setting.
    var railViewMode: PaneViewMode {
        PaneViewMode(rawValue: railViewModeRaw) ?? .default
    }

    /// The destination question on screen, if any. Held here because both surfaces that raise it —
    /// the Tidy rail's row menu and an Organize card's "Choose folder…" — are children of this view.
    @State var pendingDestination: PendingDestination?
    /// The recents the on-screen picker was opened with.
    ///
    /// Snapshotted when the card is raised, not read in the card's body: `DestinationRecents.load`
    /// stats every stored path to prune the ones that no longer resolve, and a body reads on every
    /// render. The list also must not shift under the user mid-decision — recording a destination
    /// happens on commit, by which point the card is gone.
    @State var pendingRecents: [String] = []

    /// Raises the picker, whoever asked for it. The one place `pendingDestination` is set, so the
    /// recents snapshot can never drift out of step with the request it belongs to.
    func presentDestination(_ pending: PendingDestination) {
        // The palette is a real window that holds key (observed: `[palette] panel key=true
        // active=true` in `~/sync-cloud.log`); the picker is an overlay *inside* the host, so
        // raising one under the other would leave the picker unable to take a keystroke or a click —
        // its buttons, ↩ and esc would all go to the palette's field instead.
        //
        // **No caller can reach that today**, and an earlier version of this comment invented one
        // ("a file operation finishing while the palette is up"). Both callers are direct mouse
        // gestures inside the content, which by this file's own model land on the panel and dismiss
        // it. The line is here so a fourth caller — or a keyboard route to the picker — cannot
        // invert the ownership silently. `toggleCommandPalette` blocks the other order.
        palettePanel.dismiss()
        pendingRecents = DestinationRecents.load(providerRoot: pending.request.providerRoot)
        pendingDestination = pending
    }

    /// Raises the picker for a rail selection, and runs the transfer into whatever it returns.
    ///
    /// Routes through `moveItems(_:toPath:)` / `pasteItems(_:toPath:isCut:)` — the same explicit
    /// destination entry points drag-and-drop already uses — rather than the cross-pane transfer,
    /// which derives its own destination and would ignore the folder just chosen. That distinction
    /// is the entire point of this verb.
    func requestDestination(for nodes: [FileNode], isMove: Bool) {
        guard let first = nodes.first else { return }
        let root = tidyProviderRootExpanded
        let commit: (String) -> Void = { destination in
            if isMove {
                actionHandler?.moveItems(nodes, toPath: destination)
            } else {
                actionHandler?.pasteItems(nodes, toPath: destination, isCut: false)
            }
        }
        let panel = {
            ContentView.runDestinationPanel(for: first.name, itemCount: nodes.count,
                                            startingAt: root.isEmpty ? nil : root)
        }
        // No provider root — an unconfigured provider path — means there is nothing to browse.
        // `subfolders` refuses an empty root, and the column stack resolves an empty root against
        // "/", so the card would offer the whole filesystem drawn as a stack whose first column is
        // permanently empty. The system panel is the honest surface for that, and it is the one
        // this verb was built to replace, so falling back to it costs the user nothing.
        guard !root.isEmpty else {
            if let chosen = panel() { commit(chosen) }
            return
        }
        presentDestination(PendingDestination(
            request: DestinationRequest(
                sourcePaths: nodes.map(\.id),
                firstItemName: first.name,
                isMove: isMove,
                providerRoot: root,
                providerName: tidyProviderName.isEmpty ? "this provider" : tidyProviderName,
                // The selection's own parent, NOT the rail's current directory. In Columns,
                // clicking a folder drills into it, so the rail's current directory IS the folder
                // being moved — opening there would land the picker inside the selection and greet
                // it with the nesting refusal. The parent is where the item lives, is never inside
                // the selection, and is one click from anywhere else.
                openAt: (first.id as NSString).deletingLastPathComponent
            ),
            onCommit: commit,
            onOther: panel
        ))
    }

    /// The system folder panel behind the picker's `Other…`, for a destination outside the
    /// provider. Returns nil when cancelled.
    static func runDestinationPanel(for firstItemName: String, itemCount: Int, startingAt folder: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = itemCount == 1
            ? "Choose a folder for “\(firstItemName)”"
            : "Choose a folder for \(itemCount) items"
        if let folder, !folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: folder) }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
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

    /// Binding for the same switch on the Tidy rail, writing the rail's own key.
    var railViewModeBinding: Binding<PaneViewMode> {
        Binding(get: { railViewMode }, set: { railViewModeRaw = $0.rawValue })
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
            // Resolved in the transform, so the action — and the state write behind it — fires
            // only when the answer changes. See `workspaceBarStyle`. The label widths are measured
            // rather than tabulated because the app scales its own type (Settings ▸ Text size), and
            // reading `appFontScale` here means a scale change rebuilds this closure and
            // re-resolves; a constant would be correct at exactly one setting.
            .onGeometryChange(for: ToolbarBarStyles.self) { proxy in
                WorkspaceBarMetrics.styles(
                    contentWidth: proxy.size.width,
                    labelWidths: Self.workspaceLabelWidths(scale: appFontScale),
                    searchLabelWidth: CommandPaletteBarMetrics.labelWidth(CommandPaletteBar.label,
                                                                          scale: appFontScale),
                    searchKeycapWidth: CommandPaletteBarMetrics.keycapWidth(
                        symbol: AppChord.commandPalette.display, scale: appFontScale))
            } action: { styles in
                toolbarStyles = styles
            }
            .toolbar { mainToolbar }
        .overlay {
            // The picker wins the precedence: it is a direct answer to an action the user just
            // took on a file, where Settings and Help are ambient panels they can reopen.
            if pendingDestination != nil {
                destinationOverlay
            } else if showSettings {
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
        // The armed launch diagnostic, fired once discovery has given the palette a root to index.
        .onChange(of: isBootstrappingProviders) { _, bootstrapping in
            // The arm is consumed only when it is actually spent. Discovery can land anywhere from
            // a fraction of a second to hours after launch, so a destination picker may well be up
            // when it does — and clearing the flag before `toggleCommandPalette` could refuse it
            // burned the one shot for that session with nothing but a debug line to say so.
            guard !bootstrapping, paletteOnLaunchArmed, pendingDestination == nil else { return }
            paletteOnLaunchArmed = false
            toggleCommandPalette()
        }
        // The overlays are mutually exclusive; Settings wins the precedence above. Close Help
        // from every Settings entry point (toolbar, ⌘,, the invalid-pane fix-it) so it can't be
        // left lingering underneath a Settings card the user opened on top of it.
        .onChange(of: showSettings) { _, isOpen in
            if isOpen { showHelp = false }
        }
        .quickLookPreview($quickLookURL)
        .animation(.easeOut(duration: 0.15), value: pendingDestination?.id)
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
                case .honorLaunchOverlayDiagnostics:
                    // Diagnostic hook: `defaults write com.abhishekgirish.SyncCloud
                    // openSettingsOnLaunch -bool YES` opens the Settings overlay at startup, so
                    // automated verification can reach it without synthesizing input. No-op
                    // unless explicitly armed; honors `settingsSelectedTab` for the initial tab.
                    if UserDefaults.standard.bool(forKey: "openSettingsOnLaunch") {
                        // Through `resolvingStored` rather than spelling the fallback here: this
                        // file is in no SPM package, so a `??` written inline is reachable by no
                        // test. See `StoredTabResolutionTests`.
                        settingsTab = SettingsView.SettingsTab.resolvingStored(
                            UserDefaults.standard.string(forKey: SettingsView.selectedTabDefaultsKey))
                        showSettings = true
                    }
                    // `defaults write com.abhishekgirish.SyncCloud openCommandPaletteOnLaunch
                    // -bool YES` brings up ⌘K at startup. The palette is keyboard-only and its
                    // chord is a menu key equivalent, so nothing short of assistive access — which
                    // this machine refuses — can open it from a script; without this hook the one
                    // surface that most needs looking at is the one nothing but a human can reach.
                    //
                    // **Armed here, opened when provider discovery finishes** — the same wait the
                    // first-run card takes, and for a sharper reason. Discovery is async and fills
                    // `availableProviders`, so at this point `tidyProviderRootExpanded` is still
                    // empty and the palette's folder index resolves to NOTHING. Opened here it
                    // logged "19 rows from 0 folders" on a tree of 3,013 — a diagnostic showing a
                    // state no user can ever be in, which is worse than no diagnostic.
                    paletteOnLaunchArmed = UserDefaults.standard.bool(forKey: "openCommandPaletteOnLaunch")
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
                    // The names the user has said they meant. Created once, alongside the ignore
                    // store, and for the same reason — it outlives this view. It takes no pair key:
                    // a keep is a decision about a name, not about a comparison (see
                    // `KeptNamesStore`), so there is nothing to re-key on a provider change.
                    if syncManager.keptNamesStore == nil {
                        syncManager.keptNamesStore = KeptNamesStore()
                    }
                    // What the cross-person rule has refused. Created here for the same reason:
                    // it outlives this view, and it is keyed on nothing — a refusal is a fact
                    // about a document and a person, not about the pair being compared.
                    if syncManager.filingPersonVetoLog == nil {
                        syncManager.filingPersonVetoLog = PersonVetoLog()
                    }
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
            // Stale Tidy results must not outlive their provider — every lens, from the one list
            // that owns that rule. Spelling them out here is what let the risky-name finding be
            // forgotten when Rename folded into Organize.
            syncManager.clearLensResultsForProviderSwitch()
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
            syncManager.clearLensResultsForProviderSwitch()
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
        .onChange(of: selectedWorkspace) { _, _ in
            infoPath = nil
            restoreStorageLensIfShowing()
            autoRescanTidyLensIfShowing()
        }
        // The workspace is @AppStorage, so quitting on Storage means the next launch STARTS there
        // and `onChange` never fires — the restore has to be attempted on appearance too, or the
        // feature silently fails in exactly the case it exists for. The root is also empty until
        // provider discovery finishes, which is why its own change is a trigger as well.
        // `restoreStorageLens` declines when a build is running or results already exist, so the
        // three triggers cannot fight: whichever arrives first wins and the rest are no-ops.
        // `autoRescanTidyLensIfShowing` rides the same trio under the same contract, for the two
        // lenses whose results are recomputed rather than restored.
        .onAppear {
            restoreStorageLensIfShowing()
            autoRescanTidyLensIfShowing()
        }
        .onChange(of: tidyScanRootExpanded) { _, _ in
            restoreStorageLensIfShowing()
            autoRescanTidyLensIfShowing()
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
            // Skipped entirely when the pane has nothing to prune — building the index to prune an
            // empty path would be the whole-tree walk for nothing. `canAdvance` counts: a pane
            // resting at its root can still hold a `›` stack pointing at a folder that has just
            // been deleted, and advancing into it is the same dead-path hazard.
            guard !syncManager.leftBrowsePath.isEmpty || syncManager.leftBrowsePath.canAdvance else { return }
            syncManager.pruneBrowsePath(isLeft: true,
                                        against: syncManager.leftChildrenIndex(treeRoot: currentLeftPath),
                                        treeRoot: currentLeftPath)
        }
        .onChange(of: syncManager.rightPaneTree) { _, _ in
            guard !syncManager.rightBrowsePath.isEmpty || syncManager.rightBrowsePath.canAdvance else { return }
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

    /// Both panes' name rulesets, for the Differences table's risky-name badge.
    ///
    /// `SettingsManager.nameRuleType(for:)` owns both substitutions: OneDrive — the strictest — for
    /// a provider id that won't resolve, so an unresolved source over-reports rather than letting a
    /// name that will break a sync pass unflagged; and the user's `folderNameRule` for a folder
    /// source, which has no rules of its own to check against.
    var paneRules: PaneProviderRules {
        PaneProviderRules(left: settings.nameRuleType(for: leftProviderId),
                          right: settings.nameRuleType(for: rightProviderId))
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
    var layoutMode: TopPaneVisibility.Mode { TopPaneVisibility.mode(for: selectedWorkspace) }

    /// Whether the current workspace's panes are hidden, honoring any stored override on top of
    /// its default. Computed (not stored) so switching workspace auto-applies its remembered state
    /// with no onChange plumbing.
    var panesHiddenForCurrentTab: Bool {
        TopPaneVisibility.panesHidden(
            for: selectedWorkspace,
            override: TopPaneVisibility.decodeOverrides(topPaneOverridesRaw)[selectedWorkspace.rawValue]
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

    /// Toggles the panes (both comparison panes, or the single-source rail) for the current
    /// workspace and remembers the choice for it. The workspace bar is always on screen, so no
    /// region is forced back on to compensate.
    func togglePanesForCurrentTab() {
        let overrides = TopPaneVisibility.settingOverride(
            TopPaneVisibility.decodeOverrides(topPaneOverridesRaw),
            workspace: selectedWorkspace,
            hidden: !panesHiddenForCurrentTab
        )
        topPaneOverridesRaw = TopPaneVisibility.encodeOverrides(overrides)
    }

    /// Entering a lens workspace from the workspace bar opens the source rail and positions it:
    /// Organize works on the loose-files inbox, so it opens there; every other lens works over the
    /// whole provider, so it opens at the root. Fired only from the bar itself — the programmatic
    /// scan actions (Find Duplicates / loose files from a Compare menu) set the workspace directly
    /// and bypass this, so they keep scanning the folder the user picked.
    func presentTidyRail(for workspace: Workspace) {
        // The lens itself no longer changes where the rail opens — it is the guard that this is a
        // lensed workspace at all, which is what makes the early return correct for Compare.
        guard workspace.lens != nil else { return }
        // Show the rail for this workspace (remembered per workspace, like the manual toggle). The
        // layout animates via `.animation(value: panesHiddenForCurrentTab)`, so no withAnimation.
        let overrides = TopPaneVisibility.settingOverride(
            TopPaneVisibility.decodeOverrides(topPaneOverridesRaw),
            workspace: workspace,
            hidden: false
        )
        topPaneOverridesRaw = TopPaneVisibility.encodeOverrides(overrides)

        // Position the single source (the left pane) at the provider root — **the same place for
        // every lens, Organize included.**
        //
        // Organize used to be the exception: `tidyRailRelativePath(for:)` opened it on the
        // loose-files inbox, so on a fresh install (where the setting defaults to `TODO`) switching
        // to Organize moved the source rail into a folder nobody had asked for. That is the last of
        // the hidden inbox behaviour. `filingScanTargetFolder`'s root-swap went first — a browsing
        // accident deciding the subject — and this is the same rule wearing the other hat: the pane
        // was not choosing the subject any more, it was being moved *to* the inbox instead, which
        // is the same surprise arriving from the opposite direction.
        //
        // **The inbox is not gone, it is only no longer automatic.** Organize's overview offers it
        // as a visible one-click scope ("Inbox (TODO) — N loose files"), and because the scope is
        // sticky across launches it is clicked once rather than re-implied every time the workspace
        // is opened. `filingInboxFolder` still resolves the path for exactly that.
        syncManager.focusOn(relativePath: "", isLeft: true)
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

    /// "Choose Folder…" from a source menu: pick a folder, make it a source, and hand the id back
    /// so the caller can point its own pane at it — the create-and-select gesture, as against
    /// Settings ▸ Sources ▸ Add Folder…, which is the deliberate door and selects nothing.
    ///
    /// Choosing a folder that is ALREADY a source (or is a discovered provider's own root) selects
    /// that source instead of adding a second — `addFolderSource` returns the existing id, so this
    /// closure does the right thing either way without knowing which happened.
    /// Internal, not private: the ⌘K palette's "Choose Folder…" action runs the same panel, from
    /// `CommandPaletteHost.swift`. Two open-panel call sites would be two prompts to keep in step.
    func chooseFolderSource(_ select: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to use as a source"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        select(settings.addFolderSource(path: url.path))
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
        // Optional rather than a defaulted closure. A default argument is evaluated in a
        // *nonisolated* context, so `{ Logger.shared.minimumLevel = $0 }` sitting there mutated
        // main-actor state from outside the actor — a warning today and an error under Swift 6.
        // Resolving the fallback inside this `@MainActor` body puts the same write where it is
        // already isolated, with no change to what production does.
        setLogLevel: ((LogLevel) -> Void)? = nil
    ) {
        settings.resetAllSettings()
        (setLogLevel ?? { Logger.shared.minimumLevel = $0 })(.debug)
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
    /// The destination picker, floated over the window on a scrim — the Settings overlay's shape,
    /// for the same reason: a card that wants the app's glass needs the app behind it. As a sheet
    /// it had its own opaque window backing, so every material composited onto white and rendered
    /// flat no matter what was applied to it.
    @ViewBuilder
    private var destinationOverlay: some View {
        if let pending = pendingDestination {
            GeometryReader { proxy in
                ZStack {
                    Rectangle()
                        // Much lighter than `overlayScrimOpacity`, which DEEPENS for Clear on the
                        // assumption the card above it is floored to frosted. This card is not:
                        // it takes the app's level verbatim, so at Clear a heavy scrim would leave
                        // the clear material with nothing left to reveal. Enough to focus the card
                        // and settle what shows through it, not enough to switch the window off.
                        .fill(Color.black.opacity(0.20))
                        .ignoresSafeArea()
                        // Clicking away cancels, like every other overlay. Nothing has been moved
                        // at this point, so there is nothing to lose by dismissing.
                        .onTapGesture { pendingDestination = nil }

                    destinationCard(pending, available: proxy.size)
                        .contentShape(Rectangle())
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .transition(.opacity)
        }
    }

    /// The picker card, wearing the same surface treatment as `settingsCard` so the two in-window
    /// panels read as one system.
    @ViewBuilder
    private func destinationCard(_ pending: PendingDestination, available: CGSize) -> some View {
        DestinationPicker(
            request: pending.request,
            availableSize: available,
            recents: pendingRecents,
            showHidden: syncManager.showHiddenFiles,
            onCommit: { destination in
                DestinationRecents.record(destination, providerRoot: pending.request.providerRoot)
                pending.onCommit(destination)
                pendingDestination = nil
            },
            onChooseOther: {
                pendingDestination = nil
                // Deferred a runloop turn: `onOther` runs a modal NSOpenPanel, and raising a modal
                // while the overlay that launched it is still animating out is the kind of overlap
                // AppKit handles unpredictably. Let the card go first.
                DispatchQueue.main.async {
                    guard let chosen = pending.onOther() else { return }
                    DestinationRecents.record(chosen, providerRoot: pending.request.providerRoot)
                    pending.onCommit(chosen)
                }
            },
            onCancel: { pendingDestination = nil }
        )
        .contentSurface(hue: glassHue, tint: surfaceTint)
        // The level at face value, with a ground under the content — see `groundedGlassCard`.
        // Flooring this to Frosted is what made Clear and Frosted indistinguishable.
        // The hairline comes from `groundedGlassCard`, which now owns it in both schemes.
        .groundedGlassCard(level: glassLevel)
        .shadow(color: .black.opacity(0.3), radius: 30, y: 8)
    }

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
    /// surface, at the level's FACE VALUE — `groundedGlassCard` rather than `glassCardStyle`.
    ///
    /// It used to floor Clear to Frosted, on the grounds that clear glass over live content is two
    /// layers of text competing (it rendered at ~9% opacity before the floor existed). True, but
    /// the cure removed the setting: Clear and Frosted drew the identical card, which reads as the
    /// control being broken. The ground under the content solves the same legibility problem
    /// without spending the level to do it.
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
        .groundedGlassCard(level: glassLevel)
        // The hairline comes from `groundedGlassCard` — it draws `.quaternary` in light and the
        // specular edge in dark, so a card no longer adds one of its own (that is what doubled the
        // dark border on all four panels).
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
            //
            // No `.shortcutKeycap` here, and not as an omission: `.alert` renders its buttons
            // through the native alert machinery, which takes title/role/action/key equivalent
            // and drops custom modifiers — a keycap attached here never reaches the screen or the
            // accessibility tree. The Return affordance is the alert's own default-button
            // highlight, which is the system's version of the same badge.
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
    /// (always the left rail in single-source; the focused pane in compare) — **including where the
    /// pane is browsing**, so clicking through columns moves the target and the "Scan '<folder>'"
    /// offer follows in real time. See `PaneLogic.tidyScanRoot`.
    var tidyScanRootExpanded: String {
        PaneLogic.tidyScanRoot(
            focusRootExpanded: ((tidyTargetIsRight ? currentRightPath : currentLeftPath) as NSString)
                .expandingTildeInPath,
            browsePath: tidyTargetIsRight ? syncManager.rightBrowsePath : syncManager.leftBrowsePath)
    }

    /// The coverage the ⌂ badge is resolved against for one pane — nil where the badge never
    /// applies. See `PaneActionDelegate.homeBadgeCoverage`: inside a cloud source's own pane every
    /// row is covered by definition, so the question is only live for a folder source.
    ///
    /// Resolved against `availableProviders` and not `enabledProviders`, through
    /// `SettingsManager.cloudCoverage` — a disabled provider's folder is still on disk.
    func homeBadgeCoverage(forProviderId providerId: String) -> FileLocation.Coverage? {
        FileLocation.badgeCoverage(forProviderId: providerId,
                                   among: settings.availableProviders,
                                   disabledProviderIds: settings.disabledProviderIds)
    }

    /// The "Find duplicates of this" handoff — see `DuplicateRevealCoordinator` for the decision
    /// it makes and why it lives outside this view.
    var revealCoordinator: DuplicateRevealCoordinator {
        DuplicateRevealCoordinator(
            syncManager: syncManager,
            selectedWorkspace: $selectedWorkspace,
            organizeLens: $selectedOrganizeLens,
            revealRequest: $duplicateRevealRequest,
            paneRoot: { isLeft in
                ((isLeft ? currentLeftPath : currentRightPath) as NSString).expandingTildeInPath
            },
            startScan: { root in
                syncManager.startFindDuplicates(root: root,
                                                options: DuplicateFinderOptions.fromDefaults())
            }
        )
    }

    /// Opens Duplicates on one row's file. Aimed at the row's OWN side rather than at
    /// `tidyTargetIsRight`'s focused pane: a right-click does not necessarily move focus, and a
    /// scan aimed at the other pane would answer about a different provider entirely.
    func findDuplicatesOfAction(_ node: FileNode, isLeft: Bool) {
        revealCoordinator.findDuplicates(of: node, isLeft: isLeft)
    }

    /// Switches to the Tidy tab and kicks off a duplicate scan of **the subject** — the scope when
    /// one is set, the focused pane's folder otherwise.
    ///
    /// **The scope, not the pane, for the same reason `autoRescanTidyLensIfShowing` targets it.**
    /// The scan target is browse-aware and moves on every column click, so a pane-targeted scan
    /// answers about wherever the user last clicked while every control that starts it is captioned
    /// for the scope — the overview's Rescan help says "every file in scope is hashed". Scoped to
    /// `Legal` with the pane in `Photos/2024`, that click hashed `Photos/2024`, REPLACED the
    /// duplicate list (results are never merged), and the Legal filter then showed zero: the
    /// overview flipped to "clean" for a subtree nothing had hashed, and a 722-group working list
    /// was gone.
    ///
    /// The header's own Rescan is unaffected in the case it appears — `targetMoved` keeps it off
    /// screen once the pane leaves the subject — and this is what its docstring already claimed it
    /// did ("re-runs the current subject's scan"). The re-aim branch sets the scope first and then
    /// calls this, so it targets the folder it just aimed at.
    func findDuplicatesAction() {
        let root = organizeScope?.path ?? tidyScanRootExpanded
        guard !root.isEmpty else { return }
        Logger.shared.info("User requested Find Duplicates in \(root)")
        show(.duplicates)
        let options = DuplicateFinderOptions.fromDefaults()
        syncManager.startFindDuplicates(root: URL(fileURLWithPath: root), options: options)
    }

    /// Switches to the Tidy tab's Storage lens and builds a read-only storage picture of the focused
    /// folder (same target-root helper as Find Duplicates). Walk + analyze only — nothing moves.
    /// Shows the saved Storage report for the current root, if Storage is what's on screen and
    /// nothing has been analyzed yet. Safe to call from any trigger — see the call sites.
    func restoreStorageLensIfShowing() {
        guard selectedWorkspace == .storage else { return }
        let root = tidyScanRootExpanded
        guard !root.isEmpty else { return }
        syncManager.restoreStorageLens(root: URL(fileURLWithPath: root))
    }

    /// Re-runs the showing lens's scan on open — Duplicates and Organize, the two lenses whose
    /// results are never restored (their rows carry destructive applies; see
    /// `StorageLensSnapshot`). Same trigger trio and safe-to-call-anytime contract as
    /// `restoreStorageLensIfShowing` above: the manager declines unless the target is one the
    /// user has scanned to completion before and still exists, and nothing has run this session.
    /// The rows an auto-rescan shows are recomputed from the live filesystem, so nothing stale is
    /// offered.
    ///
    /// Organize's "can this cost money?" question is deliberately NOT asked here. It lives inside
    /// the scan, which stops before it walks anything expensive — so this stays a plain
    /// synchronous call that cannot race a scan the user starts a moment later.
    func autoRescanTidyLensIfShowing() {
        // Keyed on the LENS now, not the workspace: duplicates and filing are two rail items
        // inside one workspace, so `selectedWorkspace` can no longer tell them apart. The overview
        // deliberately rescans nothing — it reports what each lens already knows, and starting two
        // scans because a folder changed under a summary page is not "if showing".
        guard selectedWorkspace == .filing, let lens = selectedOrganizeLens else { return }
        // **A scope makes the auto-rescan refresh THE SUBJECT, not the pane.**
        //
        // This fires on every pane-folder change — and, now that the scan target is browse-aware,
        // on every column click too, which the eligibility gates absorb: the manager declines once
        // anything has run this session, so browsing can only ever refresh the remembered subject
        // on a fresh lens, never replace a queue. It targeted `tidyScanRootExpanded`. With a
        // scope set that is the queue-destroying failure the design rejects live-binding to
        // prevent, arriving through a different door: browse from a scoped `Legal` into some other
        // previously-scanned folder and the rescan silently replaces `filingSuggestions` with that
        // folder's files, which the Legal scope then filters to nothing. To File empties, and
        // nothing on screen says why.
        //
        // The subject is the scope, so that is what gets refreshed. The manager still declines
        // unless the target is one scanned to completion before and nothing has run this session,
        // so pointing it at a never-scanned scope is a no-op rather than a surprise scan.
        let target = organizeScope?.path ?? tidyScanRootExpanded
        switch lens {
        case .duplicates:
            guard !target.isEmpty else { return }
            syncManager.autoRescanDuplicatesIfEligible(root: URL(fileURLWithPath: target),
                                                       options: DuplicateFinderOptions.fromDefaults())
        // The one filing scan publishes all three of these lists, so any of them showing is a
        // reason to refresh it.
        case .toFile, .names, .renames:
            let root = tidyProviderRootExpanded
            guard !target.isEmpty, !root.isEmpty else { return }
            syncManager.autoRescanFilingIfEligible(
                folder: URL(fileURLWithPath: target), providerRoot: URL(fileURLWithPath: root),
                providerName: tidyProviderName, nameProvider: tidyProviderType)
        // Restructure reads the profile rather than the disk, and rules are configuration —
        // neither goes stale because a folder changed.
        case .restructure, .rules:
            break
        }
    }

    /// The person the find was turned into a gather for, and where the gather is.
    ///
    /// Held here rather than in the pane because the answer is not about one pane: it collects
    /// across the whole source, which is the difference between a find and a gather.
    ///
    /// Carries the **phase**, not just the finished answer, so the slot is taken the moment the
    /// offer is accepted: the sweep behind it takes long enough to notice, and a slot that stays
    /// on its previous content for that interval reads as "nothing happened".
    struct PersonScope: Equatable {
        let person: Person
        /// `let`, like `person`: every write replaces the whole scope. Nothing mutates a phase in
        /// place, and a `var` here invited something to.
        let phase: PersonGatherPhase

        /// Whether a finished sweep for `person` may still write its answer into the slot.
        ///
        /// The slot has to be **the same person and still waiting**. This is the last-write-wins
        /// half of the double-accept race: cancellation stops the loser's sweep, but a sweep that
        /// had already left the loop before the cancel lands would otherwise write its answer over
        /// the winner's.
        static func awaits(_ person: Person, in current: PersonScope?) -> Bool {
            current?.person == person && current?.phase == .gathering
        }

        /// Whether accepting an offer for `person` should start a sweep, given what is in the slot.
        ///
        /// **A second ⌘↩ on the same offer is a repeat of the same question**, not a new one, and
        /// restarting would throw away a sweep that is already partway through 10,171 documents.
        /// Anything else — nobody in the slot, a different person, or the same person whose gather
        /// has already finished or failed — does start one.
        ///
        /// **Exactly `!awaits`, and written that way rather than restated.** Both ends of the race
        /// ask the same question — "is a gather for this person already in flight?" — one before
        /// starting and one before writing, so a second copy of that expression is a place for the
        /// two to drift apart while every test on each of them still passes. If the two ever need
        /// to differ (say, declining to re-gather an answer that is already fresh), expand this
        /// body; that is a deliberate edit rather than a silent divergence.
        static func shouldStart(_ person: Person, given current: PersonScope?) -> Bool {
            !awaits(person, in: current)
        }
    }

    /// The in-flight sweep behind `personScope`, held so a successor or a clear can cancel it.
    /// Without this, accepting twice raced two gathers with last-write-wins.
    ///
    /// **Deliberately not cleared when a gather finishes**, which looks like a leak and is not.
    /// A completed `Task` retains nothing that matters, and the tidy-looking `personGatherTask =
    /// nil` at the end of the task body is a race: task 1 finishing *after* task 2 has been
    /// assigned here would null out task 2's handle, and the next accept or clear would then have
    /// nothing to cancel — re-opening, by hand, the exact bug this property exists to close.
    /// Every writer of this property is on the main actor and outside the task body; keep it that
    /// way. Cancelling an already-finished task is a no-op, so the stale handle costs nothing.
    @State private var personGatherTask: Task<Void, Never>?

    /// Accepts the ⌘F offer: compute what is theirs and show it.
    ///
    /// **Computed on accept, never per keystroke.** The gather walks every surveyed document —
    /// 10,171 of them on the real tree — so doing it as the query changes would put that sweep
    /// between a key and its character. The offer row itself is cheap (one tokenize) and is what
    /// runs per keystroke.
    ///
    /// The corpus read (a 4.9 MB file nothing else in the app holds) **and the sweep itself** run
    /// off the main actor, in ``gatherOffMainActor(personId:profileId:directory:profile:registry:)``;
    /// the main-actor task only waits and writes the result.
    func acceptPersonScope(_ person: Person) {
        guard PersonScope.shouldStart(person, given: personScope) else { return }
        guard let profile = syncManager.filingFolderProfile,
              let registry = syncManager.filingPersonRegistry,
              let directory = syncManager.filingProfilesDirectory else {
            // Cancel first, like every other path that takes the slot from someone: a sweep for
            // the *previous* person can no longer be shown once this write lands, and leaving it
            // running would sweep 10,171 documents for an answer `awaits` will then discard.
            personGatherTask?.cancel()
            personGatherTask = nil
            // **Said, not swallowed.** The offer that leads here needs only the roster
            // (`personOffer` guards on `filingPersonRegistry` alone) while the gather needs the
            // survey too, and `FilingProfileStore.personRegistry` deliberately reads a roster on a
            // machine with no profile at all. So a roster outliving its survey puts an offer on
            // screen whose accept did *nothing*, with no message — the exact "nothing happened"
            // this whole feature exists to remove, surviving in the one path it had not covered.
            personScope = PersonScope(person: person, phase: .failed(Self.noSurveyToGather))
            return
        }
        Logger.shared.info("User asked for everything that is \(person.displayName)'s")
        personGatherTask?.cancel()
        personScope = PersonScope(person: person, phase: .gathering)
        let id = profile.profileId
        // Snapshotted here, on the main actor, rather than read inside the sweep: the store is
        // `@MainActor` and the sweep deliberately is not. A verdict recorded while a gather runs
        // therefore lands in the *next* gather, which is right — the one in flight is answering the
        // question as it stood when it was asked.
        let tags = syncManager.filingPersonTagStore?.index ?? PersonTagIndex(tags: [])
        personGatherTask = Task {
            do {
                let files = try await Self.gatherOffMainActor(
                    personId: person.id, profileId: id, directory: directory,
                    profile: profile, registry: registry, tags: tags)
                // **Both checks, and they close different holes.**
                //
                // `Task.isCancelled` — this gather was superseded or cleared. A cancel that lands
                // *after* the sweep has already returned raises no error at all, so the `catch`
                // below never sees it. The case that needs this: accept Aditi, clear, accept Aditi
                // again. The first sweep finishes in the window before its cancel is observed, and
                // the slot is now the *second* gather's — same person, still `.gathering`, so
                // `awaits` says yes and the dead task writes into the live one's slot.
                //
                // `awaits` — the slot must still be waiting for this person at all. It is the
                // invariant that actually protects the pixels, and it is what stops Aditi's answer
                // landing under Girish's name.
                guard !Task.isCancelled, PersonScope.awaits(person, in: personScope) else { return }
                personScope = PersonScope(
                    person: person,
                    phase: files.map { .ready($0) } ?? .failed(Self.noSurveyToGather))
            } catch is CancellationError {
                // The canceller owns the slot. Nothing to write, and nothing to say.
            } catch {
                // Nothing below throws anything but cancellation today. Swallowing this anyway
                // would leave the spinner turning **forever** — strictly worse than the silent
                // slot this feature replaced — so an unexpected failure ends the wait out loud.
                // Same pair of checks as the success path, for the same two reasons: a dead
                // gather must not write its failure into a live one's slot either.
                guard !Task.isCancelled, PersonScope.awaits(person, in: personScope) else { return }
                Logger.shared.warning("The person gather failed: \(error.localizedDescription)")
                personScope = PersonScope(person: person, phase: .failed(
                    "Something went wrong gathering these files: \(error.localizedDescription)"))
            }
        }
    }

    /// What the slot says when there is no survey to gather from. One string for all of it because
    /// the causes differ only in which artifact is missing, and the thing to do about them is the
    /// same: survey the tree.
    ///
    /// **"No readable survey", not "has not been read yet"** — which is what the banner this
    /// replaced said, and it is false for one of the three causes. `FilingSurveyStore.corpus`
    /// returns nil when the file is *absent* (never surveyed), when the profile never loaded, and
    /// when the file is present but **fails to decode** — and in that last case the tree has been
    /// surveyed. A banner flashes past; this sits in the slot until it is dismissed, so a sentence
    /// that is wrong a third of the time is worth more than it costs to say accurately.
    static let noSurveyToGather =
        "No readable survey of this tree was found, so there is nothing to gather."

    /// Reads the corpus and sweeps it, **off the main actor** — `nonisolated`, so awaiting it from
    /// the main-actor task above hops to the cooperative pool rather than running the sweep
    /// between the user and their next frame. (Measured: a `nonisolated` async function called
    /// from a `@MainActor` context does not run on the main thread, and it inherits cancellation
    /// without a handler — which is why there is no `Task.detached` here.)
    ///
    /// Returns nil when the corpus is absent, which is a state rather than an error: the tree has
    /// not been surveyed. Throws only `CancellationError`.
    ///
    /// Internal rather than private so the supersede suite can drive the real thing.
    nonisolated static func gatherOffMainActor(
        personId: String, profileId: String, directory: URL,
        profile: FolderProfile, registry: PersonRegistry,
        tags: PersonTagIndex = PersonTagIndex(tags: [])
    ) async throws -> PersonFileSet? {
        // Bracketing the read: the decode is a synchronous ~90 ms that cannot be interrupted, so
        // these are the two points at which a gather cancelled during it can actually stop.
        try Task.checkCancellation()
        guard let corpus = FilingSurveyStore.corpus(id: profileId, in: directory) else { return nil }
        try Task.checkCancellation()
        return try PersonFiles.gather(personId: personId, corpus: corpus,
                                      profile: profile, registry: registry, tags: tags)
    }

    /// Records a verdict on a review row, and takes the row off the screen.
    ///
    /// **Two halves, and the order matters.** The display is updated *first* and synchronously, so
    /// the button press has an effect in the same frame; the durable half — deciding the key and
    /// writing the file — follows on a task, because deciding the key means reading the document.
    ///
    /// **The key is the fingerprint where the document has one.** A digest over what a PDF *says*
    /// survives the file being renamed and moved, which is exactly what Organize is for and exactly
    /// what a path-keyed verdict would not survive. It costs one PDF read of one file, here, at the
    /// moment of the decision — never for the 10,171 documents a gather walks. Anything that is not
    /// a fingerprintable PDF (a photo, a `.docx`, a locked or image-only scan) falls back to the
    /// path, which is the weaker promise honestly made rather than no verdict at all.
    ///
    /// Nothing here moves a file. Filing stays Organize's verb.
    func recordPersonVerdict(_ person: Person, path: String, isTheirs: Bool) {
        guard let store = syncManager.filingPersonTagStore else { return }
        if let scope = personScope, scope.person == person, case .ready(let files) = scope.phase {
            personScope = PersonScope(person: person,
                                      phase: .ready(files.applying(verdict: isTheirs, to: path)))
        }
        guard let root = syncManager.filingFolderProfile?.root else { return }
        let full = ((root as NSString).expandingTildeInPath as NSString)
            .appendingPathComponent(path)
        Task {
            var key = PersonTagKey.path(path)
            if ContentFingerprint.canFingerprint(path: full),
               let digest = await PDFTextExtractor.fingerprint(full) {
                key = .fingerprint(digest)
            }
            store.record(personId: person.id, key: key,
                         verdict: isTheirs ? .confirmed : .rejected, path: path)
        }
    }

    /// The one way out of a person gather, from every exit — the ✕, Esc, and leaving the
    /// workspace. Cancels a sweep still running so it stops walking documents nobody will see.
    ///
    /// **The only place `personScope` is set back to nil.** Anything that clears it by hand would
    /// leave the sweep running, and `PersonScope.awaits` would then throw its answer away silently
    /// after paying for all of it.
    func clearPersonScope() {
        personGatherTask?.cancel()
        personGatherTask = nil
        personScope = nil
    }

    /// Point Organize at one folder: select the filing queue and scan **that** folder.
    ///
    /// The whole reason Organize's lenses became permanent rail items rather than chips. A chip
    /// materialises only after a scan has found something, so there was nowhere for this to land;
    /// a rail item exists at zero, which is exactly the state a folder you have just pointed at is
    /// in.
    ///
    /// **Sets the scope**, then scans. The scope is the lasting half — the scan is just what makes
    /// the queue current.
    ///
    /// Every other lens narrows to this folder for free, because filing, names and renames all come
    /// off this one walk and restructure reads the profile. That is the point of scope-filters-does
    /// -not-rescan: one click here re-aims all six lenses and pays for one scan.
    ///
    /// Pointing at the provider root **clears** the scope rather than setting it — see
    /// ``setOrganizeScope(_:)``.
    func organizeFolderAction(_ node: FileNode) {
        let folder = (node.id as NSString).expandingTildeInPath
        let providerRoot = tidyProviderRootExpanded
        guard !folder.isEmpty, !providerRoot.isEmpty else { return }
        Logger.shared.info("User requested Organize for \(folder)")
        setOrganizeScope(folder)
        show(.toFile)
        syncManager.startFindFilingSuggestions(
            folder: URL(fileURLWithPath: folder), providerRoot: URL(fileURLWithPath: providerRoot),
            providerName: tidyProviderName, nameProvider: tidyProviderType)
    }

    /// The one write of Organize's scope, and the one place the root is normalized away.
    ///
    /// **`nil`, an empty path, and the provider root all mean the same thing: the global view.**
    /// Keeping that collapse here rather than at each caller is what stops `scope = provider root`
    /// and `scope = cleared` becoming two encodings of one state — identical in every result and
    /// different only in whether a chip is drawn.
    func setOrganizeScope(_ path: String?) {
        organizeScopePath = resolvedOrganizeScope(path)?.path ?? ""
    }

    /// The subtree Organize is answering about, or nil for the global view.
    ///
    /// Re-resolved on read rather than stored, exactly as `TidyView` does: the provider can change
    /// under a persisted path, and a scope belonging to a tree that is no longer showing degrades
    /// to the global view instead of filtering every lens to nothing.
    var organizeScope: OrganizeScope? { resolvedOrganizeScope(organizeScopePath) }

    /// One resolver behind both the read and the write, so the normalization cannot drift between
    /// them — the read has to agree that a stored provider root means "no scope", or the chip and
    /// the filter would disagree about the same string.
    private func resolvedOrganizeScope(_ path: String?) -> OrganizeScope? {
        guard let path, !path.isEmpty else { return nil }
        return OrganizeScope(path: path, providerRoot: tidyProviderRootExpanded)
    }

    /// Navigate to a lens inside Organize — both halves, always.
    ///
    /// The single place programmatic navigation names a rail item, so a caller cannot set the
    /// workspace and forget the lens and land on the overview having silently dropped the request.
    func show(_ lens: OrganizeLens) {
        selectedWorkspace = .filing
        // A caller asking for the folded lens lands where its findings live now.
        selectedOrganizeLens = lens.resolvedForPresentation
    }

    func buildStorageLensAction() {
        let root = tidyScanRootExpanded
        guard !root.isEmpty else { return }
        Logger.shared.info("User requested Storage Lens for \(root)")
        selectedWorkspace = .storage
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
            selectedWorkspace: $selectedWorkspace,
            organizeLens: $selectedOrganizeLens,
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

    /// The provider ruleset the name check runs against — the targeted pane's source (the left
    /// rail in single-source; the focused pane in compare). See `SettingsManager.nameRuleType(for:)`
    /// for the two substitutions it makes: OneDrive for an unresolvable id, and the user's
    /// `folderNameRule` for a folder source.
    var tidyProviderType: CloudProvider.ProviderType {
        settings.nameRuleType(for: tidyTargetIsRight ? rightProviderId : leftProviderId)
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
        show(.rules)
        syncManager.startAutomationDryRun(root: URL(fileURLWithPath: root),
                                          destinationRoot: URL(fileURLWithPath: providerRoot),
                                          providerName: tidyProviderName, only: only)
    }

    /// The folder a Filing scan targets right now — **the focused folder, always.**
    ///
    /// ## The inbox root-swap is gone
    ///
    /// This used to silently retarget the scan to the loose-files inbox (Settings ▸ Organize,
    /// default `TODO`) whenever the pane happened to be sitting at the provider root. That is a
    /// *browsing accident deciding a subject*: the user navigated to the top of the tree, and the
    /// scan quietly answered about one folder three levels down without ever saying so. It is the
    /// same class of defect as scope-follows-the-last-scan, and the fix is the same — the subject
    /// is something the user sets, not something the pane's position implies.
    ///
    /// The inbox has not been dropped, it has been **promoted**: ``filingInboxFolder`` still
    /// resolves the path, and Organize's overview offers it as a visible one-click scope shortcut
    /// ("Inbox (TODO) — N loose files"). Because the scope is sticky across launches, the inbox is
    /// clicked once and stays, which is what the hidden special case was clumsily approximating.
    ///
    /// **Deleted rather than narrowed.** Narrowing it — say, only when no scope is set — would
    /// leave a rule that fires on a condition the user cannot see, which is the whole complaint.
    ///
    /// It is emphatically not the right default either: scoped to `TODO`, Renames falls from 126
    /// folders to 0 and five of the six lenses go dark on launch. The inbox is the right subject
    /// for To File and the wrong one for everything else.
    var filingScanTargetFolder: String? {
        let focused = tidyScanRootExpanded
        guard !focused.isEmpty, !tidyProviderRootExpanded.isEmpty else { return nil }
        return focused
    }

    /// The loose-files inbox, when it exists — the path only, with no opinion about when to use it.
    ///
    /// **The one reader of the inbox setting now.** The rail resolver that used to share it — and
    /// to open Organize on this folder unasked — is gone, so the existence check this kept in step
    /// with no longer has a twin to disagree with; it stays because a shortcut offering a folder
    /// that is not there is worse than no shortcut. nil when the setting is blank or the folder is
    /// missing, and blank is a state the Settings field can now express.
    var filingInboxFolder: String? {
        let root = tidyProviderRootExpanded
        guard !root.isEmpty else { return nil }
        let inbox = (UserDefaults.standard.string(forKey: GeneralSettings.filingInboxRelativePathKey) ?? "TODO")
            .trimmingCharacters(in: .whitespaces)
        guard !inbox.isEmpty else { return nil }
        let inboxPath = (root as NSString).appendingPathComponent(inbox)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inboxPath, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return inboxPath
    }

    /// Kicks off a Filing scan for loose files, with the whole provider as the taxonomy.
    ///
    /// Aimed at the subject — the scope when set — for the reasons written out on
    /// ``findDuplicatesAction()``. The shape of the miss here is sharper than Duplicates', because
    /// the filing pass enumerates the direct children of ONE folder: scoped to `TODO` from a pane
    /// at the root, the card said "The file pass hasn't run here", the click scanned the root's
    /// loose files, and To File then reported "Nothing to do in TODO" without TODO ever having been
    /// enumerated.
    func findFilingSuggestionsAction(ignoringCache: Bool = false) {
        let root = tidyProviderRootExpanded
        // The provider root is the taxonomy the scan files AGAINST, so it is required whichever
        // folder is being enumerated. `filingScanTargetFolder` folded that check in; the scope
        // branch needs it stated.
        guard !root.isEmpty, let folder = organizeScope?.path ?? filingScanTargetFolder else { return }
        Logger.shared.info("User requested Filing suggestions for \(folder)"
            + (ignoringCache ? " (ignoring saved suggestions)" : ""))
        selectedWorkspace = .filing
        syncManager.startFindFilingSuggestions(folder: URL(fileURLWithPath: folder),
                                               providerRoot: URL(fileURLWithPath: root),
                                               providerName: tidyProviderName,
                                               // Names come back on this pass — see
                                               // `detectRiskyNames`. The ruleset is the scanned
                                               // provider's, not whichever pane is focused later.
                                               nameProvider: tidyProviderType,
                                               ignoringCache: ignoringCache)
    }

    /// Re-derives the folder memory from the provider tree as it stands now.
    ///
    /// Deliberately its own action rather than a step inside the scan. The scan is what the user
    /// clicks to get suggestions and it has to stay fast; a re-survey reads documents the scan has
    /// no interest in — every already-filed one that changed — and its payoff is the *next* scan,
    /// not this one. Tying it to Rescan would make the common act pay for the occasional one.
    func updateFolderMemoryAction() {
        let root = tidyProviderRootExpanded
        guard !root.isEmpty else { return }
        Logger.shared.info("User requested a folder-memory re-survey of \(root)")
        Task { await syncManager.resurveyFilingMemory(root: URL(fileURLWithPath: root)) }
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
        /// How this pane presents its tree. Comparison panes and the Tidy rail all reach Columns,
        /// each from its own stored key.
        let viewMode: PaneViewMode
        /// Path → children for the columns presentation, cached per publish by the manager. `nil`
        /// in Tree mode: building it walks the whole tree, and a pane that will never draw a column
        /// should not pay that on every publish.
        let childrenIndex: PaneChildrenIndex?
    }

    /// Internal rather than private so `ContentView+PaneSearch.swift` can resolve the pane it is
    /// searching from the same one place `paneColumn` does — a second copy of "which tree is this
    /// pane showing" is how a search would end up running against the other side's nodes.
    func paneContext(isLeft: Bool) -> PaneContext {
        // The rail reads its OWN key, not the left pane's — it is the same underlying pane state
        // but a different surface, and a comparison choice must not restack it.
        let mode: PaneViewMode = layoutMode == .singleSource ? railViewMode : paneViewMode(isLeft: isLeft)
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
    ///
    /// No `@ViewBuilder`: the body computes its locals and then has a single `return`, which
    /// *disables* the builder outright (the compiler says so). Carrying the attribute anyway
    /// claimed a multi-statement build that was never happening.
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
                onChooseFolder: { chooseFolderSource { id in
                    if isLeft { leftProviderId = id } else { rightProviderId = id }
                } },
                sortOption: $syncManager.sortOption,
                // Only the single-source Tidy rail collapses itself (back to the spine); the two
                // comparison panes never collapse individually.
                onCollapse: layoutMode == .singleSource
                    ? { withAnimation(.easeInOut(duration: 0.2)) { togglePanesForCurrentTab() } }
                    : nil,
                onRefresh: { forceRefreshAction() },
                isRefreshing: isScanning,
                // Turns the rung into Stop for as long as the scan runs. Both panes get it —
                // there is one scan behind the two of them, so stopping from either is the same
                // act, and the pane the user happens to be looking at is the one they will reach
                // for.
                onCancelScan: { syncManager.cancelScan() },
                // The ring goes on whichever pane the chords act on — the same resolved answer
                // ⌃⇥ flips and ⌘F opens on, so the indicator cannot claim one pane while the
                // shortcuts use the other. Compare only: on a single-source workspace the rail is
                // the one pane on screen and a ring would distinguish it from nothing.
                isFocused: layoutMode == .compare && paneSearchTargetIsLeft == isLeft,
                showHiddenFiles: $syncManager.showHiddenFiles,
                // The rail gets the switch too, bound to its own key.
                viewMode: layoutMode == .singleSource ? railViewModeBinding : paneViewModeBinding(isLeft: isLeft),
                // Targets the pane's current folder, which in Columns is the deepest open column.
                // One resolution shared with ⇧⌘N — see `beginNewFolder(isLeft:)`.
                onNewFolder: { beginNewFolder(isLeft: isLeft) },
                // Search inside THIS pane's tree. Every workspace with a pane browser gets it from
                // here — Compare's two panes and the single-source rail — because they are all this
                // one header over this one pane component.
                searchText: paneSearchState(isLeft: isLeft).query,
                searchIsExpanded: paneSearchState(isLeft: isLeft).isExpanded,
                searchSummary: paneSearchResults(isLeft: isLeft)
                    .summary(at: paneSearchState(isLeft: isLeft).wrappedValue.hitIndex),
                onSearchAdvance: { reverse in advancePaneSearch(isLeft: isLeft, reverse: reverse) },
                personOffer: { query in
                    guard let registry = syncManager.filingPersonRegistry else { return nil }
                    return PersonSearchOffer.person(matching: query, registry: registry)
                },
                onAcceptPerson: { person in acceptPersonScope(person) }
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
        // The debounce. `.task(id:)` cancels and restarts whenever the key moves, so the sleep below
        // IS the debounce — no timer to own, and a keystroke landing mid-sleep simply replaces the
        // pending recomputation rather than queueing a second one.
        //
        // The TREE VERSION is part of the key on purpose: a result set names paths in a tree that
        // has since been rebuilt, and a scan, a delete or a hidden-files toggle leaves hits pointing
        // at rows that no longer exist — the walk would then reveal nothing and select a ghost. It
        // costs a republish one re-search of a query that is usually empty (which returns without
        // walking anything).
        .task(id: PaneSearchRecomputeKey(isLeft: isLeft,
                                         query: paneSearchState(isLeft: isLeft).wrappedValue.query,
                                         treeVersion: pane.tree.version,
                                         otherTreeVersion: pane.otherTree.version)) {
            try? await Task.sleep(for: ContentView.searchDebounce)
            guard !Task.isCancelled else { return }
            // Where the walk lands afterwards is decided INSIDE, past the staleness guard — see
            // `recomputeSearch`. It used to be set here, unconditionally, which moved the user's
            // position even when the results that prompted it were dropped for being stale.
            await recomputeSearch(isLeft: isLeft)
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
            DetailsSidebar(syncManager: syncManager, leftPath: currentLeftPath, rightPath: currentRightPath, compact: true, overridePath: infoPath, singleSource: layoutMode == .singleSource, cloudCoverage: settings.cloudCoverage)
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
        .animation(.easeInOut(duration: 0.2), value: selectedWorkspace)
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
        // ⌘F. Published from here because the menu item lives in the App scope and can see none of
        // this window's state; it cannot be `.onKeyPress` at all, since that is focus-scoped and a
        // pane search is invoked precisely when focus is in a file table. See `FindInPaneCommand`.
        .focusedSceneValue(\.beginPaneSearch, beginPaneSearch)
        // The rest of the menu-bar chords, on the same contract, bundled into one modifier
        // (`ShortcutValuePublisher` — inlining the ten chained publications here broke the
        // type-checker's time budget): each value recomputes with this body, so a menu item's
        // enabled-ness tracks the same facts the control it mirrors renders from.
        .modifier(shortcutValuePublisher)
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


    /// What the not-scanned card says. The rule is `PaneLogic.notScannedMessage`, where it can be
    /// tested; this supplies the live facts. `hasScanned` is false whenever this renders, so there
    /// is no live result for it to contradict — this is the cold-open card and nothing else.
    private var notScannedMessage: String {
        PaneLogic.notScannedMessage(
            summary: syncManager.lastScanSummary,
            leftProviderID: leftProviderId, leftPath: currentLeftPath,
            rightProviderID: rightProviderId, rightPath: currentRightPath,
            now: Date()
        )
    }

    /// The Compare busy state: the whole placeholder becomes the scan while the first one runs
    /// (the Tidy pattern) — livelier than a spinning button glyph.
    ///
    /// It reports **elapsed time and nothing else**, because elapsed time is the only honest number
    /// available. A percentage would need a total, and the walk that produces one
    /// (`FileDiffEngine.getFilesInDirectory`) counts nothing on the way through; instrumenting it
    /// means a callback in the hottest loop in the app plus a main-actor hop to publish from, in a
    /// function whose comments already record two rounds of performance work. A running clock costs
    /// a `TimelineView` and cannot be wrong.
    ///
    /// Cancel is the point of the whole card. `stop.circle` and the same wording as the pane rung's
    /// Stop, which is the other door to `cancelScan()`.
    @ViewBuilder
    private var scanningPlaceholder: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 4) {
                Text("Scanning \(paneNames.left) and \(paneNames.right)…")
                    .scaledFont(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                if let started = syncManager.scanStartedAt {
                    // Ticks once a second from the scan's own start, so the run has no drift to
                    // accumulate and the label is not a view-owned clock that a remount resets.
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(ScanElapsed.text(since: started, now: context.date))
                            .scaledFont(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Button {
                syncManager.cancelScan()
            } label: {
                Label("Stop", systemImage: "stop.circle")
            }
            .buttonStyle(.actionBar(.outline, tint: glassHue.accentColor,
                                    onTint: glassHue.onAccentLabelColor))
            .help("Stop scanning")
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
                // Picking something in a pane is the mouse saying which pane it is working in, so
                // it moves the keyboard's focus there too — otherwise ⌃⇥ and the click would be
                // two independent notions of "the focused pane" that drift apart the moment you
                // use both. The empty-write case is the one that must NOT move it; that rule lives
                // in `PaneLogic` where a test can hold it.
                //
                // **After `applySelectionWrite`, never before.** That call's first act is the
                // commit the clicked List is waiting on, and it is written the way it is because
                // publishing anything else into that window reloaded the List mid-commit and
                // dropped the click outright (`aa9d407`, the two-clicks-to-select bug). This is
                // another `@Published` write on the same manager, so it goes after the commit
                // lands — it changes nothing about what this click selects, only where the
                // keyboard points next.
                let side = PaneLogic.focusedSideAfterSelectionWrite(
                    newSelection, isLeft: isLeft, current: syncManager.focusedPaneSide)
                if syncManager.focusedPaneSide != side { syncManager.focusedPaneSide = side }
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
            delegate: PaneActionDelegate(handler: actionHandler, syncManager: syncManager, settings: settings, isLeft: pane.isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId, isSingleSource: layoutMode == .singleSource, forceRefreshAction: forceRefreshAction, onGetInfo: { showInfo(for: $0) }, onChooseDestination: { nodes, isMove in requestDestination(for: nodes, isMove: isMove) }, ignoreStateToken: syncManager.effectiveIgnoredPaths, keptNamesToken: syncManager.keptNamesStore?.names ?? [], homeBadgeCoverage: homeBadgeCoverage(forProviderId: pane.providerId), onFindDuplicatesOf: { node in findDuplicatesOfAction(node, isLeft: pane.isLeft) }, onOrganizeFolder: { node in organizeFolderAction(node) }, onOrganizeScope: { node in setOrganizeScope(node.id) }),
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
            // What matched, and where the walk has got to. The pane draws its emphasis, dimming and
            // annotations from the first and reveals the hit named by the second — see
            // `FileTreeView.revealInTree` / `revealInColumns`.
            search: paneSearchResults(isLeft: pane.isLeft),
            searchHitIndex: paneSearchState(isLeft: pane.isLeft).wrappedValue.hitIndex,
            searchRevealNonce: paneSearchState(isLeft: pane.isLeft).wrappedValue.revealNonce,
            isActivePane: isRail || paneActionBarSideActive(isLeft: pane.isLeft),
            viewMode: pane.viewMode,
            childrenIndex: pane.childrenIndex,
            browsePath: pane.isLeft ? $syncManager.leftBrowsePath : $syncManager.rightBrowsePath,
            onColumnNavigate: { applyColumnNavigation($0, isLeft: pane.isLeft) },
            onBackgroundDeselect: { handleBackgroundDeselect(depth: $0, isLeft: pane.isLeft) }
        )
        // The whole point of `FileTreeView: Equatable`. Without this the conformance is inert —
        // SwiftUI only consults a view's `==` through `EquatableView` — and this view is built
        // fresh on every one of `ContentView`'s renders, which any of the manager's ~56 published
        // properties can trigger. See the note on `FileTreeView`.
        .equatable()
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

    /// Binding for the workspace bar that, on entering a lens workspace, opens the source rail and
    /// positions it for that lens. Wrapping the binding (rather than observing `selectedWorkspace`
    /// globally) confines this to the bar's own control: the programmatic scan actions assign
    /// `selectedWorkspace` directly and so never trip it, keeping their chosen scan folder intact.
    /// Internal so the toolbar (ContentView+Toolbar.swift) can drive it.
    var workspaceSelection: Binding<Workspace> {
        Binding(
            get: { selectedWorkspace },
            set: { newWorkspace in
                let previous = selectedWorkspace
                selectedWorkspace = newWorkspace
                // All duplicate-review / guided-review teardown & restore decisions go through the
                // reducer (CompareReviewReducer): an abandoned review — left Compare while inactive,
                // banner and Done button gone — is torn down like Done (ending the guided review AND
                // restoring the auto-pinned provider); returning to Compare re-focuses the two copies
                // (the shared left pane was reset to the rail root while away).
                reviewCoordinator.dispatchReview(
                    .tabSwitched(toCompare: newWorkspace == .compare, fromCompare: previous == .compare)
                )
                // Re-home the rail on every entry into a lens, including lens→lens: Organize wants
                // the loose-files inbox and the rest want the provider root, so carrying one lens's
                // folder into the next would scan the wrong place.
                if newWorkspace != previous {
                    // **A person gather does not survive leaving the workspace it was opened
                    // from.** It takes the lens slot in every workspace, so without this,
                    // switching to Compare showed a list of someone's files where the differences
                    // table belongs — nothing on screen explaining why, and the only way out a ✕
                    // on a view you would not connect to Compare at all.
                    //
                    // Inside the `newWorkspace != previous` guard deliberately: re-selecting the
                    // workspace you are already on is not leaving it, and should not throw the
                    // gather away.
                    clearPersonScope()
                    presentTidyRail(for: newWorkspace)
                }
            }
        )
    }

    /// True when the Compare bottom pane is showing the actual differences list (not a
    /// placeholder like scanning / all-in-sync). Collapse only applies here — the header strip it
    /// leaves behind belongs to `DifferencesView`, which the placeholders don't render. Internal so
    /// the split-layout extension can gate the collapsed frame on it.
    ///
    /// **A person gather takes this slot, so it makes this false.** `bottomPaneView`'s chain tries
    /// `personScope` first, so while a gather owns the pane the differences list is not on screen —
    /// and this predicate claiming otherwise was believed by two things that then acted on a view
    /// that was not there. `bottomPaneIsCollapsed` gave `bottomPaneView` a nil (hug-the-strip)
    /// height while `PersonView` was in it, and `shortcutDifferencesList` stayed armed, so the
    /// show/hide-the-list command resized the person gather instead. Predates the gather's loading
    /// state — the slot has always been shared — and is fixed here because it is the same
    /// mechanism: whatever offers an action has to require everything that action needs.
    var compareBottomListActive: Bool {
        selectedWorkspace == .compare && personScope == nil
            && (!syncManager.differences.isEmpty || reviewStore.isReviewing)
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
        if selectedWorkspace == .compare, let review = duplicateReview, reviewCoordinator.duplicateReviewActive(review) {
            reviewCoordinator.duplicateReviewBanner(review)
                .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
        }
        // **A person gather takes the slot from whatever was in it**, in every workspace. It is
        // an answer about the whole source rather than about one lens, so showing it beside a lens
        // would invite reading it as that lens's output; and it is temporary, so it takes the slot
        // rather than replacing anything. Clearing gives the slot straight back.
        if let scope = personScope {
            PersonView(displayName: scope.person.displayName,
                       phase: scope.phase,
                       accent: glassHue.accentColor,
                       onOpenFolder: { relative in
                           guard let root = syncManager.filingFolderProfile?.root else { return }
                           let full = (root as NSString).appendingPathComponent(relative)
                           NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: full)])
                       },
                       onReveal: { relative in
                           guard let root = syncManager.filingFolderProfile?.root else { return }
                           let full = (root as NSString).appendingPathComponent(relative)
                           NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: full)])
                       },
                       onClear: { clearPersonScope() },
                       onVerdict: { relative, isTheirs in
                           recordPersonVerdict(scope.person, path: relative, isTheirs: isTheirs)
                       })
                // **Esc clears it, which the ✕'s own tooltip has been promising.** Nothing was
                // wired to the key: the help text said "(Esc)" and the only way out was the ✕ —
                // a control describing a shortcut that does not exist.
                .onExitCommand { clearPersonScope() }
                .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
        } else if let lens = selectedLens {
            // The lens workspaces' right-hand slot. ONE construction site for all of them, and
            // deliberately so: a `switch` with a branch per lens would give each its own view
            // identity, and TidyView's @State — the per-lens parked queries, the expanded search,
            // the reclaim tally, the filed/dismissed session flags — would reset on every switch.
            // Storage renders its own read-only surface beneath the shared header card.
            TidyView(
                syncManager: syncManager,
                lens: lens,
                providerName: tidyProviderName,
                scanTargetFolder: tidyScanRootExpanded,
                onFindDuplicates: findDuplicatesAction,
                onFindFilingSuggestions: { findFilingSuggestionsAction() },
                onFindFilingSuggestionsFresh: { findFilingSuggestionsAction(ignoringCache: true) },
                // Withheld outright when this machine has no filing profile: the re-survey rebuilds
                // an artifact that does not exist, so offering it would be offering nothing.
                onUpdateFolderMemory: syncManager.filingMemory == nil && syncManager.filingFolderProfile == nil
                    ? nil : { updateFolderMemoryAction() },
                // The way in to the paid pass for someone who has never set it up: Organize's
                // results offer it, and the offer has to land somewhere. Deep-links the tab the
                // same way the Sources shortcut does, so the user arrives at the cloud toggle
                // rather than at whichever tab Settings last showed.
                //
                // `.intelligence`, not `.filing`: the cloud toggle, the key and the model left the
                // Organize tab when the engine got one of its own. Pointing this at `.filing`
                // still compiles and still opens Settings — it just opens the wrong tab, and the
                // user offered "set up cloud refine" arrives at a page with no cloud anything on
                // it. `theCloudRefineOfferLandsOnTheTabThatHoldsTheKey` is what fails on that now.
                onConfigureCloudRefine: {
                    settingsTab = .cloudRefineSetup
                    showSettings = true
                },
                onNormalizeNames: { names in Task { await syncManager.normalizeNames(names) } },
                onApplyRenames: { plans in Task { await syncManager.applyRenamePlans(plans) } },
                onPreviewAutomations: { only in startAutomationPreviewAction(only: only) },
                providerRoot: tidyProviderRootExpanded,
                filingInboxFolder: filingInboxFolder,
                onQuickLook: { toggleQuickLook($0) },
                onBuildStorage: buildStorageLensAction,
                // The single Tidy source is the left provider; its picker shows in the workspace only
                // while the rail is collapsed (expanded, the rail header owns the provider dropdown).
                showSourcePicker: panesHiddenForCurrentTab,
                providers: settings.enabledProviders,
                currentProviderId: leftProviderId,
                onSelectProvider: { leftProviderId = $0 },
                onManageProviders: openProviderSettings,
                onChooseFolder: { chooseFolderSource { leftProviderId = $0 } },
                onCompareCopies: reviewCoordinator.compareCopies,
                onRequestDestination: { presentDestination($0) },
                revealRequest: duplicateRevealRequest,
                // Retire an ANSWERED request. The lens's own applied-id is @State and dies with
                // it, so a request left standing here replayed its whole plan — filter reset,
                // parked query overwritten, the old group re-marked — on every return to a lens
                // workspace after any trip through Compare. The id check keeps a retirement racing
                // a newer ask from clearing the newer request.
                onRevealHandled: { id in
                    if duplicateRevealRequest?.id == id { duplicateRevealRequest = nil }
                },
                // The notScanned recovery button: the same door as the context menu, so it scans a
                // folder that actually CONTAINS the file. `onFindDuplicates` scans the lens's
                // focused root, which for a handoff from the other pane may still not contain it —
                // pressing it re-ran the same unanswerable scan forever.
                onFindDuplicatesOf: { path in revealCoordinator.findDuplicates(ofPath: path) }
            )
        } else if compareBottomListActive {
            // DifferencesView renders its own two cards (toolbar + table); Compare | Tidy lives in
            // the window toolbar.
            DifferencesView(syncManager: syncManager, reviewStore: reviewStore, paneNames: paneNames, paneRules: paneRules, onQuickLook: { toggleQuickLook($0) }, onGetInfo: { showInfo(for: $0) }, isCollapsed: $bottomPaneCollapsed, shortcutsSuspended: pendingDestination != nil)
        } else {
            // Compare with nothing to list yet: scanning / all-in-sync / not-scanned placeholder.
                Group {
                    if isScanning {
                        scanningPlaceholder
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
                            message: notScannedMessage,
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

