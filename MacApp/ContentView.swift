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
    /// Read here rather than in `ContentView+Toolbar`, which is an extension and cannot declare
    /// stored properties. Gates the sidebar toggle's reveal — see `withDesignAnimation`.
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    /// Drives the in-window settings overlay (owned by the App so ⌘, can open it).
    @Binding var showSettings: Bool
    /// Drives the in-window Help overlay (owned by the App so the Help ▸ SyncCloud Help / ⌘?
    /// menu command can open it). ContentView renders it and owns dismissal.
    @Binding var showHelp: Bool
    /// The topic Help should open on when a surface pointed here rather than the reader opening
    /// it cold. Cleared on close, so the next ⌘? opens the book at its front as before.
    @State private var helpTopic: String?
    /// §11's folder verbs, written by the menu and carried out by the workspace — see
    /// ``RestructureVerbRequest`` for why it is a value rather than a call. Not `private`: the
    /// verbs are built in `ShortcutCommands`' extension of this view.
    @State var restructureVerbRequest: RestructureVerbRequest?
    /// Whether the once-per-session part of the `onAppear` bootstrap has already run. Owned by
    /// the App (session-scoped, never persisted) because closing and Dock-reopening the single
    /// window recreates ContentView and all its `@State` — a view-owned flag would forget.
    @Binding var hasBootstrappedSession: Bool
    /// Which settings tab the overlay shows. Owned here so it persists across open/close and can
    /// be preset (e.g. the invalid-pane fix-it action jumps straight to Providers).
    @State private var settingsTab: SettingsView.SettingsTab = .appearance

    /// The tab a deep link displaced, held only until the open it asked for is honoured or refused.
    ///
    /// **A deep link writes the tab BEFORE the latch, and the latch can say no.** `openSettings(on:)`
    /// has to preset the tab — the overlay reads `settingsTab` as it appears, so setting it
    /// afterwards would show the previous page first — but `onChange(of: showSettings)` refuses the
    /// open outright while a destination pick is up. Without this the refusal left the tab changed:
    /// the panel the user never saw had still moved Settings to Providers (or to Cloud Refine), and
    /// the next ⌘, — a plain open, which presets nothing — landed on a page nobody asked for.
    /// Non-nil means "a deep link is mid-flight"; a plain open leaves it nil and so restores nothing.
    @State private var settingsTabBeforeDeepLink: SettingsView.SettingsTab?

    // MARK: The Editor workspace

    /// The one open document, owned by the app — see ``SyncCloudApp/editorDocument``. Held here as
    /// an `@ObservedObject` so the workspace is a rendering of it and nothing else.
    @ObservedObject var editorDocument: EditorDocument
    /// The rail's rows for the current folder, re-listed off the main actor by `refreshEditorRail`.
    @State var editorRailEntries: [EditorRailEntry] = []
    /// Whether the rail's inline naming row is open. Held here because ⌘N opens it from any
    /// workspace, including ones where the editor is not on screen yet.
    @State var editorIsNaming = false
    /// The name being typed in that row. **Here rather than inside the rail**, beside the flag that
    /// says the row is open: as `@State` on the view it was thrown away by every workspace switch
    /// while the flag survived, so the row came back open with the typed name silently replaced by
    /// the `Untitled` prefill.
    @State var editorTypedName = ""
    /// Bumped by ⌘N so the naming row takes focus even when it is already open — a pure signal,
    /// never read for its value.
    @State var editorNamingFocus = 0
    /// What is typed into the rail's filter, and whether its field is showing. **Here for the
    /// reason `editorTypedName` is here**: both are things the user typed, and the editor's view is
    /// rebuilt from nothing by every workspace switch.
    @State var editorRailFilter = ""
    @State var editorRailFilterIsExpanded = false
    /// Which half of the rail is showing. **Here for the reason the filter is here**, and for one
    /// more: ⌘N puts it back on the files, and ⌘N is pressed from workspaces where the editor's
    /// view does not exist yet. Not persisted across launches — it describes a reading session,
    /// the same call ``EditorMode`` makes.
    @State var editorRailTab: EditorRailTab = .files
    /// Where each document's outline was last scrolled to, keyed by path. **Here for the reason the
    /// tab is**, and it has to outlive more than the tab does: the rail's outline is destroyed by a
    /// tab switch as well as by a workspace one, and the memory is the whole point of it.
    @State var editorOutlineAnchors: [String: Int] = [:]

    /// Why autosave has stopped writing, or `nil` while it is working.
    ///
    /// **A latch, and the reason it exists is the alert.** Autosave interrupts the moment it finds
    /// the file changed underneath the buffer — but the attempt behind it restarts on every
    /// keystroke, so without somewhere to record "this was already asked and declined" the alert
    /// would return two seconds after each dismissal for as long as the file stayed diverged. It is
    /// cleared by a successful write, by discarding the buffer, and by nothing else.
    @State var editorAutosaveStop: EditorAutosaveStop?
    /// Whether the launch refresh was asked for and could not start, because a pane named a source
    /// `enabledProviders` had not published yet. Cleared by the arrival that completes it.
    @State private var launchRefreshPending = false

    /// The undo stack for the document that is open, read from the store — which swaps it as
    /// documents change. See ``PlainTextEditor/undoManager`` for why it is not the text view's own,
    /// and `EditorUndoStore` for why there is one per document.
    ///
    /// Passed separately from the store so the views below take a plain `UndoManager` and do not
    /// have to know a store exists.
    let editorUndoManager: UndoManager
    @ObservedObject var editorUndoStore: EditorUndoStore
    /// Which files autosave may write. Owned by the app — see `SyncCloudApp`.
    @ObservedObject var editorAutosavePolicy: EditorAutosavePolicy
    /// Source / Preview / Split for the open document.
    ///
    /// **Window state, not a persisted preference.** Which of the three you want is a fact about
    /// the file you are looking at right now; remembering it across launches would open the next
    /// document in whatever mode the last one was left in. It lives here rather than in the
    /// workspace view for the same reason the document does — the view is torn down on every tab
    /// switch, and the mode would go back to Edit each time you came back.
    @State var editorMode: EditorMode = .edit
    /// How the editor's split divides its column. Beside `editorMode` because the two describe the
    /// same reading session, and the workspace view that draws them is rebuilt on every tab switch.
    @State var editorSplitFraction: CGFloat = 0.5

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

    /// Organize's rail selection, **as `@AppStorage` rather than raw `UserDefaults`**.
    ///
    /// `aimOrganize` writes it when ⌘K routes to a lens, and it wrote it through
    /// `UserDefaults.standard.set` — which this app has already been bitten by and documented:
    /// `@AppStorage`'s process-wide storage location per (store, key) can **lose** a standard-domain
    /// write outright rather than deliver it late, which is why the defaults-backed test suites
    /// mount with their own `ScratchDefaults`. `LensWorkspaceView` holds this key in `@AppStorage`, so a
    /// route could land on Organize and leave the rail on whatever lens it was already showing,
    /// intermittently and with nothing to see. Writing through the same property wrapper puts both
    /// sides on one storage location, which is the path every other writer in the app already takes.
    ///
    /// **The scope has no second spelling here.** This pair used to be a pair: a `paletteScopePath`
    /// sat beside it on the same defaults key as ``organizeScopePath``, so the same key had one
    /// property documented "never written directly" and another the palette wrote raw — which is
    /// how the palette came to carry its own copy of the root-means-no-scope normalization. The
    /// palette's write now goes through ``setOrganizeScope(_:)`` like every other, and the second
    /// writable spelling is gone rather than merely unused; `theRouteCannotMintASecondEncodingOfTheGlobalView`
    /// pins its absence by name.
    @AppStorage(OrganizeLens.defaultsKey) var paletteRailLens: OrganizeLens?

    @AppStorage("selectedLeftProviderId") var leftProviderId: String = "iCloud"
    @AppStorage("selectedRightProviderId") var rightProviderId: String = "iCloud"
    @State var isScanning = false

    /// The retired welcome tour's seen flag, still read and never written.
    ///
    /// **It is now evidence about the user rather than about the tour.** Every machine that ran a
    /// build before the setup form carries it, and it means "this person has already been greeted",
    /// so `SetupFlow.shouldAutoShow` uses it to refuse to open the form over somebody's working app.
    /// A fresh install has it false and gets the form; Help ▸ Set Up SyncCloud… ignores it entirely.
    @AppStorage(SetupFlow.legacyWelcomeSeenDefaultsKey) private var hasSeenFirstRunWelcome: Bool = false
    /// Set when the user reaches the end of the setup form. Persisted, so it never auto-opens twice.
    @AppStorage(SetupFlow.hasCompletedDefaultsKey) private var hasCompletedSetup: Bool = false
    /// Whether setup has been dismissed for the rest of this session. App-owned (a binding) for the
    /// same reason as `hasBootstrappedSession`: a window close + Dock reopen recreates ContentView
    /// and its @State, and a form the user answered *Not now* to must not come back when they
    /// reopen the window.
    ///
    /// Separate from `hasCompletedSetup`, and the difference is the whole point: *Not now* hides it
    /// for this session and leaves the persisted flag alone, so the form offers itself again on the
    /// next launch of a machine that still has not been set up.
    @Binding var setupDismissedThisSession: Bool
    /// Whether Help ▸ Set Up SyncCloud… asked for the form explicitly. App-owned so the menu
    /// command — which lives in the App scene and cannot see this view's state — can set it.
    ///
    /// **The explicit latch is what makes the form reachable after it has been completed.** The
    /// auto-show gate refuses a machine that is already set up, which is correct for a launch and
    /// wrong for a menu item; the two are separate inputs to the same overlay rather than one flag
    /// the menu has to lie to.
    @Binding var showSetup: Bool

    /// Number of provider-id `onChange` notifications still expected from an in-flight pane
    /// swap. A swap flips both @AppStorage ids at once, which would fire both id onChanges and
    /// drive two navigation resets that wipe the focus/selection the swap just moved to the
    /// other side. Each suppressed onChange decrements this; the swap action seeds it with the
    /// number of ids that actually change (2, or 0 when both panes already share a provider) so
    /// later real provider switches are never suppressed.
    @State private var pendingSwapProviderChanges: Int = 0

    /// The same counter for a **tab switch**, which also writes a provider id behind the user's
    /// back and must not have `retargetPane()` run over the navigation it has just restored.
    ///
    /// Its own counter rather than the swap's, and not private because `ContentView+PaneTabs`
    /// writes it: sharing one would let a swap consume a tab switch's suppression (or the reverse)
    /// and reset exactly the state the other had moved.
    @State var pendingTabProviderChanges: Int = 0

    /// View ▸ Tab Bar. **Off by default** — the strip appears when a second tab does, which is
    /// Finder's behaviour and what keeps an install that never opens one unchanged. Ticking it
    /// keeps a one-tab strip (and therefore a permanent ＋) on screen at the cost of a row that
    /// restates the folder name the header already shows.
    ///
    /// App-wide rather than per pane, matching the other reading preferences (`paneColumnShowsPreview`):
    /// "do I want a tab bar" is a question about the app, not about one of three surfaces that all
    /// draw the same pane.
    @AppStorage("browseTabBarVisible") var tabBarVisible: Bool = false
    /// The folder sidebar's column. **On by default**: the store has always held the pinned and
    /// recent lists and nothing but a menu ever showed them, so shipping this off would have left
    /// the item exactly as discoverable as the menu it replaced.
    ///
    /// **One preference across every workspace that draws the column**, not Browse's — Browse,
    /// Compare, Organize and Storage all carry it (`Workspace.supportsFolderSidebar`), and
    /// `folderSidebarIsShowing` is the one rule that reads this value. The KEY keeps its `browse`
    /// spelling from when Browse was the only one: renaming it would re-default the column to `true`
    /// for everyone who had switched it off, which is the same reason the key survived the v4.2/v4.3
    /// hold rather than being deleted with the column.
    @AppStorage("browseSidebarVisible") var browseSidebarVisible: Bool = true
    /// The sidebar's width, dragged by the user and clamped to
    /// `FolderSidebarView.minWidth ... .maxWidth`. Stored as a `Double` because `@AppStorage`
    /// has no `CGFloat` overload.
    @AppStorage("browseSidebarWidth") var browseSidebarWidthRaw: Double = 180
    /// Which sections are folded, comma-joined — see `folderSidebarCollapsedSections`.
    @AppStorage("browseSidebarCollapsed") var browseSidebarCollapsed: String = ""
    /// Which places sit in Favorites, JSON-encoded — see `SidebarFavoritePlaces`. Empty means the
    /// key has never been written, which is not the same as "no favorites"; that distinction is
    /// what lets a first run get Desktop, Documents and Downloads while someone who removed all
    /// three keeps them removed.
    @AppStorage("browseSidebarFavoritePlaces") var browseSidebarFavoritePlacesRaw: String = ""
    /// The sidebar's rows, resolved rather than recomputed in `body`.
    ///
    /// `FolderJumpStore.reachable` touches the disk — one `stat` for the root, then one per
    /// remembered folder — and the root's is the one that can block for seconds under a network
    /// mount that has gone away. That is survivable on the ⌘K path, which runs once per open; in a
    /// view body it would run on every render of the workspace. Refreshed at the four moments the
    /// answer can change instead: appearing, the provider changing, the pane moving, and the store
    /// publishing a pin or a visit.
    @State var folderSidebarRows: [FolderSidebarRow] = []
    @State var folderSidebarLocationRows: [SidebarSourceRow] = []
    /// **The mount points a row may be ejected from**, resolved with the rows rather than in the
    /// view body.
    ///
    /// It was computed inline in the sidebar's arguments for one build, which put a
    /// `mountedVolumeURLs` call plus a `resourceValues` read per volume into **every** evaluation of
    /// that body — and the body re-evaluates on hover, on a drag, on every selection change. That
    /// is the exact cost `refreshFolderSidebarRows`'s own gate exists to keep off the render path,
    /// and under an unresponsive network mount a resource read can block. Resolved on the same
    /// pass as the rows, it happens when the volumes can actually have changed.
    @State var folderSidebarEjectablePaths: Set<String> = []
    /// **The narrower half: where an unmount actually forgets the sources.**
    ///
    /// Eject is offered on anything Finder would eject, a network share included; a share is not
    /// local, so unmounting it leaves its sources in place. The confirmation has to know which of
    /// the two it is looking at, or it promises a removal that will not happen — which it did until
    /// this was split out. Resolved on the same walk as the rows, from
    /// `SidebarSourceModel.Volume.losesItsSourcesOnUnmount`, so the sentence the user reads and the
    /// rule `MountedVolumeMemory` applies are one rule.
    @State var folderSidebarDetachablePaths: Set<String> = []
    @State var folderSidebarShortcutRows: [SidebarSourceRow] = []
    /// A promotion that can still be taken back, until the next one or a workspace change.
    @State var folderSidebarNotice: FolderSidebarNotice?
    /// The sidebar width when the current resize drag began — see `folderSidebarResizeHandle`.
    @State var folderSidebarDragOrigin: CGFloat?

    /// Active "compare two duplicate copies" handoff from the Duplicates lens: the keeper (left pane) and the
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

    /// Shared geometry for the workspace bar's selected-segment fill, so the accent capsule
    /// TRAVELS between segments instead of being cut out of one and into the next. Declared here
    /// rather than beside the bar because `@Namespace` is a stored property and the bar lives in
    /// an extension (`ContentView+Toolbar`), which cannot hold one.
    @Namespace var workspaceMarker

    @State var actionHandler: FileActionHandler?
    @State var quickLookURL: URL? = nil
    /// Whether the open Quick Look panel belongs to the PANES, and so should follow their
    /// selection. Set by every pane entry point (Space, the row menu), cleared by every other one
    /// (a Differences row, the Info inspector) and by the panel closing. See
    /// `CurrentSelection.previewFollow`, which is the rule this flag is an input to.
    @State var quickLookFollowsPane = false
    /// Not private: `ContentView+PaneTabs` refuses a tab switch while this is true, for the reason
    /// `swapPanesAction` refuses a swap — a provider `onChange` bails on its own bootstrap guard
    /// without decrementing the suppression counter, which would strand it.
    @State var isBootstrappingProviders: Bool = true
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

    /// Defaults keys for the single-source rail's split layout.
    enum RailLayout {
        /// The rail's persisted width fraction. The literal keeps the pre-Organize "tidy"
        /// spelling — it is frozen, persisted in every existing install.
        static let railFractionKey = "tidyRailFraction"
    }

    /// The single-source source rail's share of the content width when expanded (the lens workspaces). Persisted
    /// like the other split fractions; the workspace fills the rest.
    @AppStorage(RailLayout.railFractionKey) var railFraction: Double = 0.28
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
    ///
    /// **`.browse`, and it must stay equal to ``WorkspaceSelection/default``.** This value is
    /// where a *first run* lands, because `migrateSelection` deliberately writes nothing when
    /// nothing is stored; that other constant is where an *unreadable or retired* stored value
    /// lands. They are reached by different paths and were allowed to disagree, so a fresh install
    /// opened on Compare while a corrupted one opened on Browse — the property both of them claim
    /// to have, quietly false. `theFirstRunDefaultAgreesWithTheFallback` now fails if they part.
    ///
    /// Browse for the reason that constant gives: a file browser is a better place to land than a
    /// comparison of two clouds nothing has scanned yet. Existing installs are untouched — they
    /// carry a stored value that still resolves, and this default is never consulted for them.
    @AppStorage(Workspace.defaultsKey) var selectedWorkspace: Workspace = .browse
    /// Which lens is showing inside Organize, or `nil` for its overview.
    ///
    /// Lives beside the workspace rather than inside `LensWorkspaceView` because programmatic navigation
    /// needs to write it: "Find duplicates of this" names a lens, and since the fold that lens is
    /// one rail item inside Organize rather than a workspace of its own. `LensWorkspaceView` reads the same
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
    /// have to be able to re-aim Organize before any scan has run. `LensWorkspaceView` reads the same key
    /// through its own `@AppStorage`, so the two cannot disagree.
    ///
    /// Never written directly — see ``setOrganizeScope(_:)``, which asks
    /// ``OrganizeScope/normalizedPath(_:providerRoot:)`` for the stored form, so the provider root
    /// collapses to the empty string and the global view has exactly one representation.
    @AppStorage(OrganizeScopeDefaults.pathKey) var organizeScopePath: String = ""

    /// The lens the selected workspace shows, or `nil` on Compare. Derived, not stored: there is
    /// one selection now, and a second copy of it would be a second thing to keep in step.
    var selectedLens: WorkspaceLensKind? { selectedWorkspace.lens }

    /// The file a pane row's "Find duplicates of this" asked the Duplicates lens to reveal.
    ///
    /// Held HERE and not inside `LensWorkspaceView`, because the workspace switch that carries the user
    /// there mounts that view: state set on the way in has to outlive the mount. Not persisted —
    /// it names a scan that only exists in this session.
    @State var duplicateRevealRequest: DuplicateRevealRequest?

    /// The file pair the Compare Copies surface is open on, if any.
    ///
    /// **Held at the window, not inside `LensWorkspaceView`, because the surface needs the
    /// window.** macOS clamps a sheet to its host window's content width and the lens workspace is
    /// a fraction of that window (the panes take the rest), so an overlay anchored inside the lens
    /// would get a few hundred points to draw two previews in. Anchored here it clamps against the
    /// live window: 1080×760 with room, 712×512 at the 760×560 floor. The rest of the wiring is
    /// still the lens's — it decides which pairs come here at all.
    @State private var compareFilePair: DuplicateComparePair?

    /// The same surface, opened on a changed row from the Differences list — ROADMAP §11. Two
    /// states rather than one sum type: the two hosts carry different payloads and mean different
    /// verdict bars, and a shared case would have to be unwrapped at every use anyway.
    @State private var compareDifferencePair: DifferencePair?

    /// The file armed for comparison, waiting for the click that names its counterpart — see
    /// ``ComparePick``.
    ///
    /// **`@State` here rather than a selection anywhere**, which is the whole design: an armed path
    /// that lived in a pane's selection would be cleared by the very click meant to complete it,
    /// because `PaneLogic.applySelectionWrite` holds the one-pane-selected invariant. Outside both
    /// sets, it survives the selection moving, a scroll, and a navigation — the last of which
    /// finding the counterpart usually requires.
    @State private var comparePick: ComparePick?

    /// Both rungs of the toolbar row, resolved together from the window's width — see
    /// `WorkspaceBarMetrics.styleSet`.
    ///
    /// **One value, not two decisions.** The workspace bar and the Go-to control share one row, and
    /// two states resolved from two thresholds is how each concludes it fits a width the other is
    /// also spending. Stored as the closed/open PAIR for a second reason: the field opens on a
    /// keystroke rather than on a resize, so the open answer has to already be in hand.
    ///
    /// The *styles*, not the width. `.onGeometryChange` only calls its action when the transformed
    /// value changes, so resolving the answer inside the transform means a live window resize
    /// writes this once — when the labels actually shed — instead of once per frame. Storing the
    /// raw width invalidated `ContentView.body` on every frame of every drag to answer a question
    /// whose answer flips maybe twice in a session.
    ///
    /// `.onGeometryChange` rather than a `GeometryReader` writing a preference: it fires outside
    /// the layout pass, which is what keeps a width-driven toolbar from re-entering layout and
    /// tripping the AppKit constraint-loop crash that pattern caused before.
    @State var toolbarStyleSet = ToolbarBarStyleSet(
        closed: ToolbarBarStyles(workspace: .iconOnly, search: .compact),
        open: ToolbarBarStyles(workspace: .iconOnly, search: .compact,
                               field: GoToFieldLayout(width: GoToFieldMetrics.floorWidth,
                                                      placeholder: .short)))
    /// Whichever of the two the row is actually wearing right now.
    var toolbarStyles: ToolbarBarStyles { showCommandPalette ? toolbarStyleSet.open : toolbarStyleSet.closed }
    /// What is typed in the toolbar's Go-to field. Held here rather than in the panel's state so
    /// the field can redraw (its trailing key becomes a clear button) without observing it.
    @State var goToQuery = ""
    /// Bumped to claim the caret: on open, and again on ⌘K while already open — where it also
    /// selects what is there, so the next keystroke replaces it.
    @State var goToFocusToken = 0

    /// Per-workspace override of the top-pane visibility, a JSON map (workspace raw value →
    /// hidden). Empty means "no overrides — every workspace uses its default". Persisted, so
    /// deliberately showing or hiding the panes on a workspace sticks across launches.
    @AppStorage(TopPaneVisibility.overridesKey) private var topPaneOverridesRaw: String = ""

    /// Whether the Compare Info inspector is shown. It replaces the old Details tab: a toggleable
    /// right-side panel that shows metadata (and both-sides status) for the current selection.
    /// Persisted so it stays open/closed across launches. Internal, not private: its toggle sits in
    /// the window toolbar now (ContentView+Toolbar.swift).
    @AppStorage("showCompareInspector") var showInspector: Bool = false
    /// The Columns preview column, as Compare and the single-source rail (Organize, Storage) share it.
    /// Declared here rather than in the views that draw it because there are two of these keys now and
    /// only this view knows which surface is on screen — every writer (the header's pill, a column's
    /// empty-area context menu, ⇧⌘P) goes through `resolvedPreviewBinding`.
    @AppStorage(PaneViewMode.previewColumnKey(isBrowse: false)) var previewColumnEnabled: Bool =
        PaneViewMode.previewColumnDefault
    /// Browse's own preview preference, on its own key so turning the preview off to compare two
    /// providers does not take it away from browsing. Nothing seeds it from the shared key: Browse
    /// starts at the default, on. See `PaneViewMode.browsePreviewColumnDefaultsKey`.
    @AppStorage(PaneViewMode.previewColumnKey(isBrowse: true)) var browsePreviewColumnEnabled: Bool =
        PaneViewMode.previewColumnDefault
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
    /// The single-source rail's own presentation, on its own key so switching a comparison pane never
    /// restacks the rail. Columns by default for the same reason the panes are: a resting Columns
    /// pane is one full-width column listing exactly what the tree listed, so this changes what a
    /// click *does* — one click opens a folder instead of needing the row menu's Open.
    @AppStorage(PaneViewMode.railDefaultsKey) private var railViewModeRaw = PaneViewMode.default.rawValue
    /// Browse's own presentation, on its own key for the same reason the rail has one: Browse draws
    /// the same pane the rail does, at full window width instead of in a 220pt column, and a stack
    /// chosen for one is not a choice about the other. Sharing the rail's key would mean flipping
    /// Browse to Tree silently restacks Organize.
    @AppStorage(PaneViewMode.browseDefaultsKey) private var browseViewModeRaw = PaneViewMode.default.rawValue

    func paneViewMode(isLeft: Bool) -> PaneViewMode {
        PaneViewMode(rawValue: isLeft ? leftViewModeRaw : rightViewModeRaw) ?? .default
    }

    /// The rail is a single source, so it takes no side — reading it through `paneViewMode(isLeft:)`
    /// would hand it the left comparison pane's setting.
    var railViewMode: PaneViewMode {
        PaneViewMode(rawValue: railViewModeRaw) ?? .default
    }

    /// Browse's presentation. Same argument as `railViewMode`, one surface further out.
    var browseViewMode: PaneViewMode {
        PaneViewMode(rawValue: browseViewModeRaw) ?? .default
    }

    /// Which of the three stored presentations the pane on screen right now is reading.
    ///
    /// **One member, deliberately.** Three surfaces draw `FileTreeView` — the two comparison panes,
    /// the single-source rail, and Browse — and before Browse existed the choice was a bare
    /// `layoutMode == .singleSource ? rail : pane` ternary restated at each of its three call
    /// sites. Adding a third surface to two of them and missing the third is not a hypothetical:
    /// the missed one would show Browse in the rail's stack and write the user's choice into the
    /// rail's key, which is the exact bug the separate key exists to prevent, arriving silently.
    func resolvedViewMode(isLeft: Bool) -> PaneViewMode {
        if selectedWorkspace == .browse { return browseViewMode }
        return layoutMode == .singleSource ? railViewMode : paneViewMode(isLeft: isLeft)
    }

    /// Whether that presentation draws the pane's column stack.
    ///
    /// The header's path line, the tab chip that mirrors it, the crumb and quick-jump routing,
    /// `‹`/`›`, the lens scan target and New Folder all turn on this one question — see
    /// `FileSyncManager.paneLocation(isLeft:drawsColumns:)`. In Tree the stack is parked, not on
    /// screen, and every one of those surfaces that reads it anyway describes a folder the pane is
    /// not showing.
    ///
    /// Through `resolvedViewMode`, so it inherits that member's whole point: Browse, the rail and
    /// the comparison panes each answer from their own key.
    func paneDrawsColumns(isLeft: Bool) -> Bool {
        resolvedViewMode(isLeft: isLeft) == .columns
    }

    /// The destination question on screen, if any. Held here because both surfaces that raise it —
    /// the single-source rail's row menu and an Organize card's "Choose folder…" — are children of this view.
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
        let root = lensProviderRootExpanded
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
                providerName: lensProviderName.isEmpty ? "this provider" : lensProviderName,
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
        // Only the comparison layout has a sibling to mirror into; the single-source rail has none. The
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
            // Translated, because the two sources need not open at the same depth: iCloud lands at
            // its root and OneDrive two components in, so one root-relative string names folders
            // that far apart. Driving both panes with the clicked pane's spelling sent the sibling
            // to `~/Documents/Documents/Family` one way, and to a real-but-unrelated
            // `<account>/Family` the other — where the comparison then diffed the wrong pair.
            otherCombinedPath: relativePathForPane(combined, isLeft: !isLeft),
            from: isLeft,
            // Each side answers for itself — the presentation is a per-pane setting, so a linked
            // click can be a browse move on one side and a re-root on the other.
            drawsColumns: paneDrawsColumns(isLeft: isLeft),
            otherDrawsColumns: paneDrawsColumns(isLeft: !isLeft),
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

    /// Binding for the same switch on the single-source rail, writing the rail's own key.
    var railViewModeBinding: Binding<PaneViewMode> {
        Binding(get: { railViewMode }, set: { railViewModeRaw = $0.rawValue })
    }

    /// Binding for the same switch in Browse, writing Browse's own key.
    var browseViewModeBinding: Binding<PaneViewMode> {
        Binding(get: { browseViewMode }, set: { browseViewModeRaw = $0.rawValue })
    }

    /// The write side of ``resolvedViewMode(isLeft:)``, and the same one-member argument applies:
    /// a reader that resolved Browse correctly paired with a writer that did not would show the
    /// right stack and store it in the wrong key.
    func resolvedViewModeBinding(isLeft: Bool) -> Binding<PaneViewMode> {
        if selectedWorkspace == .browse { return browseViewModeBinding }
        return layoutMode == .singleSource ? railViewModeBinding : paneViewModeBinding(isLeft: isLeft)
    }

    /// Which stored preview preference the surface on screen is reading and writing.
    ///
    /// Shaped like `resolvedViewModeBinding(isLeft:)` and for the same one-member reason, with one
    /// difference: it takes no side. The two comparison panes are read against each other, so they share
    /// this answer exactly as they share `columnWidthDefaultsKey` — only Browse stands apart, and the
    /// rail falls through to the shared key with Compare because Organize and Storage are lens surfaces
    /// where a preview costs the columns doing the work half the room.
    ///
    /// Every writer resolves through here. Three views can flip this — the header's pill, a column's
    /// empty-area context menu, and ⇧⌘P — and `shortcutPreviewColumn` is the standing record of what a
    /// second, independent answer to "which surface am I on" costs.
    var resolvedPreviewBinding: Binding<Bool> {
        selectedWorkspace == .browse ? $browsePreviewColumnEnabled : $previewColumnEnabled
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

    /// **Which panes** a provider-list edit re-roots, or `nil` when it re-roots neither —
    /// comparing only identity-relevant fields (id, root path, type), so a root-path edit counts,
    /// but changes to other providers don't. Cosmetic fields are deliberately excluded: comparing
    /// whole structs made a Settings rename (setCustomName → new displayName) read as a root edit,
    /// which tore down an in-flight duplicate review (`.comparisonRootEdited` has no restore) and
    /// forced a full rescan for a label change.
    ///
    /// **A side, not a Bool**, because the two panes are edited independently and the answer drives
    /// what gets thrown away. Editing the right pane's source Location in Settings used to return
    /// `true` and take the LEFT pane down with it — tree dropped, columns flattened, spinner — for
    /// a root that had not moved. That is the same over-reach `retargetPane` exists to end, arriving
    /// through Settings instead of through the pane's own source menu.
    static func paneRootEdits(
        old: [CloudProvider],
        new: [CloudProvider],
        leftId: String,
        rightId: String
    ) -> FileSyncManager.PaneReloadScope? {
        func provider(_ id: String, in providers: [CloudProvider]) -> CloudProvider? {
            providers.first(where: { $0.id == id })
        }
        func sameIdentity(_ a: CloudProvider?, _ b: CloudProvider?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            // The ROOT, and deliberately not the landing folder. A pane's tree is rooted at
            // `rootPath`, so moving that is a root edit and must tear the comparison down. Changing
            // where a source *opens* moves no pane that is already open — it decides where the
            // next one starts — so treating it as a root edit would throw away an in-flight
            // duplicate review to honour a preference the current panes never read.
            case let (a?, b?): return a.id == b.id && a.rootPath == b.rootPath && a.type == b.type
            default: return false
            }
        }
        let leftEdited = !sameIdentity(provider(leftId, in: old), provider(leftId, in: new))
        let rightEdited = !sameIdentity(provider(rightId, in: old), provider(rightId, in: new))
        switch (leftEdited, rightEdited) {
        // Both panes on one source is an ordinary configuration, so one edit can move both roots.
        case (true, true): return .both
        case (true, false): return .leftOnly
        case (false, true): return .rightOnly
        case (false, false): return nil
        }
    }

    /// The window content with its overlays, animations, and background. Split out of `body` so the
    /// full modifier chain stays under the Swift type-checker's budget — `mainContentView` is a heavy
    /// `some View` now (it owns the panes and workspace), and chaining everything on it in
    /// one expression times the checker out.
    private var chromedContent: some View {
        // No provider sidebar: provider choice now rides on each pane/source header (ProviderMenu),
        // so the window is a single content column — the panes fill the space the sidebar used to take.
        mainContentView
            // The window's floor, and `.windowResizability(.contentMinSize)` is what makes this
            // frame that floor rather than a suggestion.
            //
            // **600 → 760 → 810 → 760, and every move was made by the same measurement.** The
            // workspace bar has to keep its labels at the narrowest window the app allows, because
            // a toolbar that does not fit is not truncated — macOS folds it behind an overflow
            // chevron, and the only control for switching workspace disappears with no error.
            //
            // At 600 the bar was icon-only at every text size the moment the window sat at its
            // minimum. 760 fixed that for four labels. **Edit made a fifth and the threshold went
            // to 781** at the default text size (833 at Large, 853 at Largest), so the floor went
            // to 810 — which still left the two largest sizes shedding at the floor.
            //
            // **Folding Storage into Organize took the bar back to four labels, and the floor came
            // back down with it.** Measured through `WorkspaceBarMetrics.styles` with the ⌘K pill
            // compact: **666.8 / 683.8 / 725.1 / 741.6** at Small / Default / Large / Largest, all
            // of them under 760. So this is not a return to a previous compromise — it is the first
            // floor at which the bar keeps its labels at EVERY text size, which neither 760 nor 810
            // managed before.
            //
            // The margin to watch is Largest: 741.6 against 760 is **18.4pt**, and that is what a
            // fifth segment spends first. `ROADMAP.md` §1b prices Backup against exactly this, and
            // the answer there is that 810 comes back with it.
            //
            // **One consequence, recorded rather than fixed:** with four labels fitting at every
            // size, the bar's icon-only rung is unreachable at any legal window width.
            // `testTheIconOnlyRungIsOutOfTheShippingBarsReachButStillLive` states that in both
            // directions and says why it is kept.
            //
            // **A height floor at all**, which is the hole rather than the tightening. With no
            // `minHeight`, the window could be dragged down to the toolbar and nothing else: a
            // sliver with the pane header, the file list and the action bar all squeezed out —
            // not a size a user picks so much as one the window cannot refuse. 560 is what keeping
            // it a window costs, in the panes' own constants: the pane header card takes 86
            // (`LiquidGlass.headerHeight` 81 inside 2×`cardInset`) and the action bar 44
            // (`ActionBarMetrics.height` 28 inside 2×8pt of padding), so a 560pt window leaves the
            // file list on the order of 430 — enough to be a list rather than a peephole. (That is
            // the two fixed rungs subtracted, not a rendered measurement of the list itself.) It
            // also clears the 428pt below which `SettingsLayout` stops shrinking its sheet
            // (`floorSize` 380 + `hostMargin` 48) and
            // starts overflowing the window it is centered in.
            .frame(minWidth: 760, minHeight: 560)
            // Resolved in the transform, so the action — and the state write behind it — fires
            // only when the answer changes. See `workspaceBarStyle`. The label widths are measured
            // rather than tabulated because the app scales its own type (Settings ▸ Text size), and
            // reading `appFontScale` here means a scale change rebuilds this closure and
            // re-resolves; a constant would be correct at exactly one setting.
            .onGeometryChange(for: ToolbarBarStyleSet.self) { proxy in
                WorkspaceBarMetrics.styleSet(
                    contentWidth: proxy.size.width,
                    labelWidths: Self.workspaceLabelWidths(scale: appFontScale),
                    searchLabelWidth: CommandPaletteBarMetrics.labelWidth(CommandPaletteBar.label,
                                                                          scale: appFontScale),
                    searchKeycapWidth: CommandPaletteBarMetrics.keycapWidth(
                        symbol: AppChord.commandPalette.display, scale: appFontScale),
                    // The OPEN field's key is `esc`, not ⌘K — measured from the same string the
                    // field draws, so the reserve cannot be right for one and wrong for the other.
                    fieldKeycapWidth: CommandPaletteBarMetrics.keycapWidth(
                        symbol: GoToFieldMetrics.closeKeycap, scale: appFontScale),
                    scale: appFontScale)
            } action: { styles in
                toolbarStyleSet = styles
            }
            // Every keystroke in the toolbar field, forwarded to the list that is answering it.
            .onChange(of: goToQuery) { _, typed in palettePanel.setQuery(typed) }
            .toolbar { mainToolbar }
            // Names the window on the two surfaces that read `NSWindow.title` whether or not a
            // title bar is drawn — the Window menu and Mission Control. Zero-sized, in the
            // background, because it is a binding to AppKit and not a view.
            .background(WindowChromeBinder(subtitle: windowSubtitleText).frame(width: 0, height: 0))
        .overlay {
            // The picker wins the precedence: it is a direct answer to an action the user just
            // took on a file, where Settings and Help are ambient panels they can reopen.
            if pendingDestination != nil {
                destinationOverlay
            } else if showSettings {
                settingsOverlay
            } else if showHelp {
                helpOverlay
            } else if showSetup || shouldAutoShowSetup {
                // Wait for provider discovery to finish before showing the form. Its Sources step
                // is a list of what was discovered, and that list is empty at first render
                // (discovery runs async in onAppear) — opening early would show "SyncCloud found 0
                // places on this Mac" and then fill in behind the user's eyes.
                setupOverlay
            } else if let pair = compareDifferencePair {
                DifferencesPairCompareOverlay(pair: pair, hue: glassHue,
                                              onClose: { compareDifferencePair = nil })
            } else if let pair = compareFilePair {
                // **Last in the chain, deliberately.** The four above are either a direct answer to
                // something the user just did to a file (the picker) or an ambient panel with its
                // own entry points this window cannot gate (⌘, and ⌘? live in the App scene). A
                // compare that yields to them loses one line of state and no work: the pair is
                // `@State` HERE, so closing Settings brings the same two copies straight back.
                // Not the reading position, though — page, mode, keeper, rendered pages and the
                // verify result all live on the covered view and go with it, so the surface
                // returns at its opening state rather than where it was left. That is the price,
                // and it is the small half: refusing those panels instead would need the whole
                // latch-refusal apparatus the picker has, to protect a surface one line of state
                // reopens.
                CompareCopiesOverlay(
                    syncManager: syncManager, pair: pair,
                    scanRoot: syncManager.duplicateScanRoot,
                    providerName: lensProviderName.isEmpty ? nil : lensProviderName,
                    onClose: { compareFilePair = nil })
            }
        }
        // `designAnimation`, not `.animation`: the scrim fade is motion, and Reduce Motion has to
        // reach it. (The four `.animation` lines below predate the wrapper and are classified in
        // `ReduceMotionCoverageScanTests`; a new raw one would have to be classified too, and this
        // one has no reason to be.)
        .designAnimation(.easeOut(duration: 0.15), value: compareFilePair)
        .designAnimation(.easeOut(duration: 0.15), value: compareDifferencePair)
        .animation(.easeOut(duration: 0.15), value: showSettings)
        .animation(.easeOut(duration: 0.15), value: showHelp)
        .animation(.easeOut(duration: 0.15), value: showSetup)
        .animation(.easeOut(duration: 0.15), value: setupDismissedThisSession)
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
        // **The ambient panels are refused while a destination pick is up, whichever path asked.**
        //
        // `showSettings` and `showHelp` are plain latches and the overlay chain above renders the
        // picker in front of both, so setting either mid-pick did nothing visible and then produced
        // the panel the instant the pick was answered. Each has entry points this window cannot
        // gate — ⌘, and ⌘? live in the App scene and see none of this state — so refusing at the
        // latch is the one place that covers every caller of both.
        //
        // The toolbar buttons are ALSO disabled, which is not a contradiction: with the latch
        // refusing, an enabled button would be a control that silently does nothing, which this
        // file's own ⌘K pill calls "its own bug". Disabled says so.
        //
        // A refused open must leave nothing behind. The two deep links preset `settingsTab` before
        // flipping this latch (they have to — see `settingsTabBeforeDeepLink`), so refusing without
        // putting it back changed which page Settings shows next time from a panel that never
        // appeared. Restored here rather than at each caller because this is the one place that
        // knows whether the open was honoured.
        .onChange(of: showSettings) { _, isOpen in
            guard isOpen else { return }
            if pendingDestination != nil {
                if let displaced = settingsTabBeforeDeepLink { settingsTab = displaced }
                settingsTabBeforeDeepLink = nil
                showSettings = false
                return
            }
            settingsTabBeforeDeepLink = nil
            showHelp = false
        }
        .onChange(of: showHelp) { _, isOpen in
            // One observer rather than a clear at each dismissal: Help closes from four places
            // (its own button, the deep-link chain above, "Set Up SyncCloud…", and this refusal),
            // and three of them left `helpTopic` set — so the next ⌘? opened on the Restructure
            // page instead of the front of the book. Keying off the flag covers the next one too.
            guard isOpen else { helpTopic = nil; return }
            guard pendingDestination != nil else { return }
            showHelp = false
        }
        // Setup is the third member of the same chain. A destination pick is a direct answer to
        // something the user just did to a file, so it wins — and a form refused here must leave
        // nothing behind, which for this one means putting the session latch back rather than
        // persisting anything.
        .onChange(of: showSetup) { _, isOpen in
            guard isOpen, pendingDestination != nil else { return }
            showSetup = false
        }
        .quickLookPreview($quickLookURL)
        // An open panel follows the pane selection, Finder-style, and closes when it is cleared.
        // The rule is `CurrentSelection.previewFollow`; this only supplies the trigger.
        .onChange(of: paneQuickLookTarget) { _, _ in followPaneSelectionWithQuickLook() }
        // Dismissing the panel by hand nils the binding without going through `toggleQuickLook`,
        // so the origin flag has to be cleared here or the NEXT preview — opened from a Differences
        // row — would inherit "follows the panes" from this one and be yanked by a pane click.
        .onChange(of: quickLookURL) { _, url in if url == nil { quickLookFollowsPane = false } }
        .animation(.easeOut(duration: 0.15), value: pendingDestination?.id)
        // The theme is the one Appearance control no view can render on its own: it lives on
        // NSApp, so that the AppKit surfaces (the NSAlert prompts, NSOpenPanel, the About panel,
        // and the separate Activity Log / Sync History windows) follow it too. Applied from the
        // root view rather than from the Settings picker so it re-applies whoever writes the key
        // and whether or not the Settings overlay happens to be on screen; App.init covers launch.
        .onChange(of: appearanceModeRaw) { AppAppearance.applyPersisted() }
        .liquidGlassAppBackground(level: glassLevel, hue: glassHue, tint: surfaceTint)
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
        .onReceive(syncManager.refreshSubject) { scope in
            // The scope is the subject's, not this view's: only the sender knows whether one pane
            // moved or something changed under both. See `refreshSubject`.
            refreshAction(reloading: scope)
        }
        .onAppear {
            // Closing and Dock-reopening the single window recreates ContentView, so this
            // block runs again mid-session. PaneLogic.bootstrapSteps owns the once-per-session
            // vs per-window split: re-running the session steps would discard a mid-session
            // hidden-files toggle and re-apply the distinct-pair provider selection over panes
            // the user may have deliberately set to the same provider.
            // The quit guard needs the document, and this is the one place that runs once per
            // window with the `@StateObject` already built. Without it ⌘Q is the only way out of
            // the app that never asks about an unsaved buffer — every other route through the
            // editor prompts.
            SyncCloudAppDelegate.shared?.adoptEditorDocument(editorDocument)
            SyncCloudAppDelegate.shared?.adoptAutosavePolicy(editorAutosavePolicy)
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
                        openSettings(on: SettingsView.SettingsTab.resolvingStored(
                            UserDefaults.standard.string(forKey: SettingsView.selectedTabDefaultsKey)))
                    }
                    // `defaults write com.abhishekgirish.SyncCloud openCommandPaletteOnLaunch
                    // -bool YES` brings up ⌘K at startup. The palette is keyboard-only and its
                    // chord is a menu key equivalent, so nothing short of assistive access — which
                    // this machine refuses — can open it from a script; without this hook the one
                    // surface that most needs looking at is the one nothing but a human can reach.
                    //
                    // **Armed here, opened when provider discovery finishes** — the same wait the
                    // first-run card takes, and for a sharper reason. Discovery is async and fills
                    // `availableProviders`, so at this point `lensProviderRootExpanded` is still
                    // empty and the palette's folder index resolves to NOTHING. Opened here it
                    // logged "19 rows from 0 folders" on a tree of 3,013 — a diagnostic showing a
                    // state no user can ever be in, which is worse than no diagnostic.
                    paletteOnLaunchArmed = UserDefaults.standard.bool(forKey: "openCommandPaletteOnLaunch")
                case .createActionHandler:
                    actionHandler = FileActionHandler(syncManager: syncManager, settings: settings)
                    // The pane → source mapping is this view's state, and both linked navigation
                    // and the durable ignore store need it to tell whether the two panes are in the
                    // same place. A closure rather than two stored strings so it is read at the
                    // moment of the decision — captured values go stale on the next switch.
                    syncManager.paneOpenAt = paneOpenAtForSyncManager
                    // And which source each pane is on, which is what decides the coordinate
                    // system the durable ignore store's entries are written in — see
                    // `FileSyncManager.ignoreAnchorIsLeft`. Without it every pair is quoted
                    // against the left pane, and a swap re-reads a mixed pair's entries against
                    // the other source's root.
                    syncManager.paneSourceId = paneSourceIdForSyncManager
                    // How the manager reads a pane's search field when it parks a tab. The field is
                    // this view's `@State` and `Sync` cannot see its type — see `paneSearchSnapshot`.
                    syncManager.paneSearchSnapshot = { [self] isLeft in
                        let state = isLeft ? leftPaneSearch : rightPaneSearch
                        return (query: state.query, isExpanded: state.isExpanded)
                    }
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
                        // put each pane on its source's opening folder before the initial
                        // refresh scans.
                        await openPanesAtTheirLandingFolders()
                        // After the focus restore, deliberately: both answer "where was this pane",
                        // and the strip's own active tab is the more specific answer — it carries
                        // the column stack as well as the scope, and the parked tabs beside it.
                        // Both panes, each from its own stored strip; a pane with nothing stored
                        // keeps what the focus restore above just gave it.
                        restoreBrowseTabs(isLeft: true)
                        restoreBrowseTabs(isLeft: false)
                        if !settings.enabledProviders.isEmpty {
                            // **Recorded when it does not start.** `enabledProviders` being
                            // non-empty does not mean it holds THESE two: a folder source, or one a
                            // restored tab has just adopted, can still be on its way. The load then
                            // never happens and the pane draws whatever it had — so the attempt is
                            // remembered and finished the moment the sources arrive.
                            launchRefreshPending = !refreshAction()
                        }
                        isBootstrappingProviders = false
                    }
                case .endProviderBootstrapGuard:
                    isBootstrappingProviders = false
                }
            }
        }
        .onChange(of: leftProviderId) { _, newId in
            // **The counters are consumed BEFORE the bootstrap guard is tested, and that order is
            // load-bearing.** A counter is armed only by a writer that has already done this
            // handler's work itself, so it has to be balanced wherever the write lands. Testing the
            // guard first got this wrong in both directions: a write made during the bootstrap
            // returned without decrementing (stranding the counter, so the user's next real switch
            // was silently swallowed), and — measured, not assumed — a write made in the guard's
            // last synchronous moments arrived here with the guard already DOWN, because SwiftUI
            // evaluates `onChange` on the next view update rather than at the point of the write.
            // That is exactly `restoreBrowseTabs`, and it made a launch restore run the full
            // user-switch path below and reset the navigation it had just restored.
            //
            // A pane swap flips this id itself; its navigation was already swapped atomically, so
            // skip the reset (which would wipe it) and let swapPanesAction drive the rescan. A tab
            // switch flips it too, and the tab it switched to carries the navigation — same shape,
            // own counter, armed only by `adoptProviderForTab`, which does everything below except
            // the reset.
            switch PaneProviderChange.decide(swapPending: pendingSwapProviderChanges,
                                             tabPending: pendingTabProviderChanges,
                                             isBootstrapping: isBootstrappingProviders) {
            case .consumeSwap: pendingSwapProviderChanges -= 1; return
            case .consumeTab: pendingTabProviderChanges -= 1; return
            case .ignore: return
            case .userSwitch: break
            }
            Logger.shared.info("User switched left provider to \(newId)")
            // Ends the guided review and drops the duplicate review without restoring the
            // comparison (the user chose this switch) — but releases the review's pin from the
            // RIGHT pane if the review was no longer active, since that pin is not their choice.
            reviewCoordinator.dispatchReview(.providerSwitched(isLeft: true))
            // Stale Tidy results must not outlive their provider — every lens, from the one list
            // that owns that rule. Spelling them out here is what let the risky-name finding be
            // forgotten when Rename folded into Organize. The person gather is subject to the same
            // rule and is NOT in that list — it is this view's state, not the manager's — so it is
            // cleared from the unconditional id handler further down, which this one's early
            // returns cannot skip.
            syncManager.clearLensResultsForProviderSwitch()
            syncManager.ignoredItemsStore?.activate(
                pairKey: IgnoredItemsStore.pairKey(newId, rightProviderId))
            // retargetPane() fires refreshSubject, which onReceive above turns into a refresh — of
            // this pane only. The new source opens at its own landing folder; the other pane is
            // untouched in every sense, keeping its tree, its open columns, its selection and its
            // Back stack rather than being reset by a switch it had no part in.
            syncManager.retargetPane(isLeft: true, landing: settings.openAtIfReachable(for: newId))
        }
        .onChange(of: rightProviderId) { _, newId in
            // Through the same rule as the left handler above, which is where it is explained.
            switch PaneProviderChange.decide(swapPending: pendingSwapProviderChanges,
                                             tabPending: pendingTabProviderChanges,
                                             isBootstrapping: isBootstrappingProviders) {
            case .consumeSwap: pendingSwapProviderChanges -= 1; return
            case .consumeTab: pendingTabProviderChanges -= 1; return
            case .ignore: return
            case .userSwitch: break
            }
            Logger.shared.info("User switched right provider to \(newId)")
            // Mirror of the left handler above, releasing the pin from the LEFT pane instead.
            reviewCoordinator.dispatchReview(.providerSwitched(isLeft: false))
            syncManager.clearLensResultsForProviderSwitch()
            syncManager.ignoredItemsStore?.activate(
                pairKey: IgnoredItemsStore.pairKey(leftProviderId, newId))
            // Mirror of the left handler: the switched pane lands, the untouched one stays put.
            syncManager.retargetPane(isLeft: false, landing: settings.openAtIfReachable(for: newId))
        }
        // The Info inspector reads the selection directly, so a selection change no longer needs to
        // switch tabs — it just clears any explicit "Get Info" target so the inspector follows the
        // new selection.
        // The saved tab strip follows the live pane — see `BrowseTabPersistence`. ONE modifier
        // rather than its two `onChange`s written here: adding a second to this chain tipped the
        // body over the type-checker's budget outright ("unable to type-check this expression in
        // reasonable time"), which is a hazard this file is already close enough to feel.
        .modifier(BrowseTabPersistence(syncManager: syncManager,
                                       leftProviderId: leftProviderId,
                                       rightProviderId: rightProviderId) { saveBrowseTabs(isLeft: $0) })
        .modifier(EditorAutosaveDriver(document: editorDocument) { runAutosave() })
        .onChange(of: syncManager.selectedLeftPaths) { _, _ in infoPath = nil }
        .onChange(of: syncManager.selectedRightPaths) { _, _ in infoPath = nil }
        // The Get-Info override also goes stale when the comparison context changes underneath it:
        // a provider switch (its file is on the old provider) or a tab switch (Organize is single-source
        // and shows its own selection). Without these, `DetailsSidebar` — which prefers `overridePath`
        // over everything — keeps showing the old-provider/old-tab file, defeating the single-source
        // guard. `retargetPane` only clears a selection when non-empty, so the selection onChanges
        // above don't cover the no-selection case.
        //
        // **A person gather goes stale on the same switch, and nothing above could clear it.** The
        // gather is an answer about the whole SOURCE, read off `filingFolderProfile`, so after a
        // switch its card lists files from a tree this window no longer shows — and its "Open"
        // joins the OLD profile root to a relative path and then relativizes that against the NEW
        // `lensProviderRootExpanded`, which cannot match: the button silently degrades to a Finder
        // reveal. `clearLensResultsForProviderSwitch()` in the handler above is the list that owns
        // "no stale Tidy result outlives its provider", and it structurally cannot reach this one —
        // that list is the manager's, while the gather takes the lens slot from `ContentView`'s own
        // `@State`. So the rule is honoured here instead, exactly as the workspace switch honours it.
        //
        // **This pair, not the handler above, because this is what every writer of the ids trips.**
        // That handler returns early while providers are still being discovered and again on a pane
        // swap — and a swap moves the single lens source onto the other provider just as surely as
        // picking one from the source menu does, so a gather must not survive it either.
        .onChange(of: leftProviderId) { _, _ in
            infoPath = nil
            clearPersonScope()
        }
        .onChange(of: rightProviderId) { _, _ in
            infoPath = nil
            clearPersonScope()
        }
        .onChange(of: selectedWorkspace) { _, workspace in
            // The context every later line is read against. v4.0 added Browse as a fourth
            // workspace, and "User focused folder …" means a different thing in each — so without
            // this the log cannot tell a Browse move from a Compare one. Fires only on a real
            // change (see below), so it is one line per switch, not per re-selection.
            // `title`, not `rawValue`: the log should name what the bar names. The raw values are
            // a pinned persistence format that says "Filing" where the user reads "Organize".
            Logger.shared.info("User switched to \(workspace.title)")
            infoPath = nil
            // **A person gather does not survive leaving the workspace it was opened from.** It
            // takes the lens slot in every workspace, so without this, switching to Compare showed
            // a list of someone's files where the differences table belongs — nothing on screen
            // explaining why, and the only way out a ✕ on a view you would not connect to Compare.
            //
            // Here rather than in `workspaceSelection`'s setter, which is where it was: that
            // binding is only the *bar* (and the chords and ⌘K that route through it). Every
            // programmatic switch went around it — `show(_:)` behind "Find duplicates of this" and
            // the automation preview, `findFilingSuggestionsAction`, `buildStorageLensAction`, and
            // both duplicate coordinators — so right-clicking a file and asking for its duplicates
            // while a gather was open landed on Organize with the gather still holding the slot,
            // and the click looked dead. `onChange` fires for every writer, which is the property
            // that matters. It also fires only on a real change, so re-selecting the workspace you
            // are already on still does not throw the gather away.
            clearPersonScope()
            restoreStorageLensIfShowing()
            autoRescanLensIfShowing()
        }
        // The workspace is @AppStorage, so quitting on Storage means the next launch STARTS there
        // and `onChange` never fires — the restore has to be attempted on appearance too, or the
        // feature silently fails in exactly the case it exists for. The root is also empty until
        // provider discovery finishes, which is why its own change is a trigger as well.
        // `restoreStorageLens` declines when a build is running or results already exist, so the
        // three triggers cannot fight: whichever arrives first wins and the rest are no-ops.
        // `autoRescanLensIfShowing` rides the same trio under the same contract, for the two
        // lenses whose results are recomputed rather than restored.
        .onAppear {
            restoreStorageLensIfShowing()
            autoRescanLensIfShowing()
        }
        .onChange(of: lensScanRootExpanded) { _, _ in
            restoreStorageLensIfShowing()
            autoRescanLensIfShowing()
        }
        // **The fourth trigger, added by the Storage fold.** The trio above watches the workspace,
        // appearance and the scan root — not the rail lens, and until now nothing needed it to: the
        // two auto-rescanned lenses recompute from published arrays, so arriving at one by clicking
        // the rail had nothing to kick off. Storage breaks that assumption, because its report is
        // restored from a store rather than derived from anything on screen — switch the rail to
        // Storage and, without this, the page stays empty until some other trigger happens to fire.
        //
        // Safe to add for the reason the trio documents: whichever arrives first wins and the rest
        // are no-ops, so a fourth caller cannot start a second scan.
        .onChange(of: selectedOrganizeLens) { _, _ in
            restoreStorageLensIfShowing()
            autoRescanLensIfShowing()
        }
        // A scope change RE-SUBJECTS Storage rather than filtering it (Decision B): the report for
        // the old root is dropped and the new root's snapshot restored if there is one, leaving the
        // lens's own Analyze button aimed at the scope when there is not. Deliberately narrow: the
        // other lenses treat scope as a filter over results they already hold, and widening their
        // triggers here would turn a chip into a rescan for all five.
        .onChange(of: organizeScope?.path) { _, _ in
            restoreStorageLensIfShowing()
        }
        // Watches the enabled subset (not the full discovered list) so toggling a provider
        // off in Settings re-resolves any pane that was showing it and rescans.
        .onChange(of: settings.enabledProviders) { oldProviders, newProviders in
            let previousLeftId = leftProviderId
            let previousRightId = rightProviderId
            applyProviderSelection(preferDistinctPair: isBootstrappingProviders)
            // **Before the bootstrap guard, because that guard is what strands it.** A launch
            // refresh that could not start for want of a source has to be finished when the source
            // turns up, and that arrival is this handler — which returns below while the bootstrap
            // is still up, i.e. exactly when the pending flag is set. Only ever completes a refresh
            // that was already asked for and skipped; it starts nothing new.
            if launchRefreshPending, refreshAction() {
                launchRefreshPending = false
                Logger.shared.info("Completed the launch refresh once its sources were published")
            }
            guard !isBootstrappingProviders else { return }
            // If re-resolution switched a pane's provider, its id onChange below already
            // refreshes via retargetPane — don't schedule a second scan here.
            guard leftProviderId == previousLeftId, rightProviderId == previousRightId else { return }
            // Only rescan when a pane's own provider changed (e.g. its root path was
            // edited). Toggling or re-pathing a provider neither pane shows must not
            // reload the trees — that spurious rescan put spinners over both panes
            // on every unrelated Settings edit.
            if let edited = Self.paneRootEdits(
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
                //
                // **The same scope to both calls.** A pane whose tree is dropped here and not
                // walked by the rescan stays blank, and a pane whose root did not move needs
                // neither — editing the right source's Location used to reload the left pane
                // and flatten its columns for a root it had not touched.
                //
                // **Logged, because the scope made this reload selective and nothing else says
                // so.** The other route to a re-walk announces itself ("User switched left
                // provider to …"); this one was silent even when it reloaded both panes, and a
                // silent reload of ONE pane is worse — a pane spinning with its sibling still
                // showing rows is exactly the "why did that happen?" a reader brings to the log.
                // `[load]` lines are DEBUG and dropped at the level most sessions run at.
                Logger.shared.info("A source root changed in Settings under \(edited.describedPanes); "
                                   + "dropping the comparison and re-walking \(edited.describedPanes).")
                reviewCoordinator.dispatchReview(.comparisonRootEdited)
                syncManager.invalidateComparisonState(reloading: edited)
                refreshAction(reloading: edited)
            }
        }
        .modifier(SettingsEngineMirrors(syncManager: syncManager, settings: settings))
        // A republish can delete a folder a column stack is standing in — externally, or by the
        // user's own Delete. Re-resolve each stack against the new tree so it falls back to the
        // deepest surviving ancestor; without this the columns render nothing while
        // `currentDirectory` still names the dead folder, which is where New Folder and paste
        // would then act. `PaneTree` compares by publish stamp, so this fires once per publish.
        .modifier(ColumnStackPruning(syncManager: syncManager,
                                     leftTreeRoot: currentLeftPath,
                                     rightTreeRoot: currentRightPath))
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
                // `lastLeftFocusPath` / `lastRightFocusPath` were persisted here, on every
                // navigation, for a launch path that no longer reads them: the tab strip records a
                // folder per tab and restores it, and `openPanesAtTheirLandingFolders` now opens a
                // strip-less pane at its source's landing folder. Two defaults written on every
                // keystroke-fast pane move and read by nothing is worse than no record at all,
                // because the next reader has to prove that before trusting anything else.
        }
    }

    /// Provider display names for the two panes, disambiguated when both panes show the same provider.
    /// What this window is on, for `NSWindow.title` — both sides on Compare, the single source
    /// elsewhere.
    ///
    /// Reads the provider's `displayName` directly rather than going through `paneNames`, which
    /// substitutes "Left"/"Right" for an unresolved provider and appends "(left)"/"(right)" when
    /// both sides are the same cloud. Both are right for a pane header and wrong here: a window
    /// called "Left" says less than one called "SyncCloud", and the two paths already distinguish
    /// two tabs on one provider.
    ///
    /// Each side's location is resolved **through its own view mode**, the same way `paneContext`
    /// does it: a Tree pane's location is its scope, and its parked column stack is not part of
    /// where it is.
    var windowSubtitleText: String? {
        func source(isLeft: Bool) -> WindowSubtitle.Source {
            let id = isLeft ? leftProviderId : rightProviderId
            return WindowSubtitle.Source(
                provider: settings.availableProviders.first(where: { $0.id == id })?.displayName,
                relativePath: syncManager.paneLocation(isLeft: isLeft,
                                                       drawsColumns: resolvedViewMode(isLeft: isLeft) == .columns))
        }
        return WindowSubtitle.text(mode: layoutMode, left: source(isLeft: true), right: source(isLeft: false))
    }

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
        PaneLogic.fullPath(root: settings.rootPath(for: leftProviderId), relativePath: syncManager.leftRelativePath)
    }

    /// Builds the full path for the right pane. Uses only the right provider's root + right relative path to avoid mixing roots.
    var currentRightPath: String {
        PaneLogic.fullPath(root: settings.rootPath(for: rightProviderId), relativePath: syncManager.rightRelativePath)
    }

    // MARK: - Pane visibility & content layout

    /// The resolved arrangement of the panes and workspace, which now start directly under the
    /// window toolbar. Comparison tabs stack two panes over the workspace; the single-source
    /// workspaces dock one collapsible rail beside a workspace that's always shown.
    enum ContentLayout {
        /// Compare: panes over workspace.
        case compareSplit
        /// Single source: the source rail expanded beside the workspace.
        case singleExpanded
        /// Single source: the source rail collapsed to a spine beside the workspace.
        case singleCollapsed
        /// Browse: the source pane alone, filling the window. No workspace half, so nothing to
        /// collapse toward and no spine to collapse into.
        case browseFull
        /// Editor: a source pane, then the file rail and the open document.
        ///
        /// **Two arms, like the lens workspaces, because the source pane collapses.** The editor is
        /// where you choose a folder to write in, and the sidebar alone answers that only for
        /// folders you have already kept or visited — so the same file pane Organize docks on its
        /// left is available here to browse to anywhere. It starts collapsed to its spine
        /// (`TopPaneVisibility.defaultPanesHidden`): most sessions open a file and write in it, and
        /// the pane is one click away when they do not.
        case editorExpanded
        /// Editor with the source pane collapsed to a spine.
        case editorCollapsed

        /// Whether this arrangement draws a `FileTreeView` at all — which is the question every
        /// pane-scoped chord is really asking before it offers itself.
        ///
        /// The Editor is the first workspace to answer **no**. ⇧⌘N and ⇧⌘P were both gated on
        /// `layoutMode`, which cannot tell a workspace with a rail from one with neither, so both
        /// stayed live in a workspace with no pane to act on: ⇧⌘N put an invisible pane into a
        /// naming state, and ⇧⌘P toggled the shared preview key with nothing to show it in.
        var drawsAPaneList: Bool {
            switch self {
            case .compareSplit, .singleExpanded, .browseFull: return true
            // Expanded, a workspace with a source rail draws a real `FileTreeView` and the
            // pane-scoped chords mean what they say. **Collapsed, there is only a 34pt spine, and
            // that is true of BOTH kinds** — the editor's source pane and the lens rail collapse to
            // the same strip through the same stored override.
            //
            // The lens arm answered `true` when this member was introduced, and that was a
            // half-fix: it was written for the editor, and the collapsed-lens case is the same
            // defect in a workspace that shipped long before it. ⇧⌘N put a naming row into a pane
            // nobody can see, and ⇧⌘P toggled a preview column for a stack that was not on screen.
            // Now that Storage is a lens on Organize's rail, that rail is collapsed more often, not
            // less.
            case .editorExpanded: return true
            case .singleCollapsed, .editorCollapsed: return false
            }
        }

        /// Whether this arrangement has a source rail that can collapse to a spine — which is the
        /// question the pane header's collapse rung is really asking.
        ///
        /// **Asked of the LAYOUT rather than of the workspace**, and switched with no `default:`.
        /// The rung used to read `layoutMode == .singleSource && selectedWorkspace != .browse`: a
        /// growing exclusion list, in which every new full-window workspace has to remember to
        /// exclude itself and nothing says so if it forgets. Editor would have inherited a collapse
        /// rung it has no spine for.
        var hasCollapsibleRail: Bool {
            switch self {
            case .singleExpanded, .singleCollapsed, .editorExpanded, .editorCollapsed: return true
            case .compareSplit, .browseFull: return false
            }
        }
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
        // Browse is decided BEFORE the pane-hiding question is asked, and that ordering is the
        // point: the pane is the entire window here, so "panes hidden" would mean an empty window.
        // No control in Browse can write that override today — the header's collapse rung is nil
        // and there is no spine to click — but a stray key in the stored map must not be able to
        // blank the workspace either.
        if selectedWorkspace == .browse { return .browseFull }
        // Editor is decided here for the same reason and one more: it owns no lens, so the lens
        // mounting path answers nothing for it — `presentLensRail` early-returns on a nil lens and
        // `bottomPaneView` mounts nothing — and a workspace that fell through to `.singleExpanded`
        // would draw a source pane beside an empty half. It takes the same collapse state the lens
        // workspaces do, through the same stored override, and only the workspace half differs.
        if selectedWorkspace == .editor {
            return panesHiddenForCurrentTab ? .editorCollapsed : .editorExpanded
        }
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

    /// Entering a lens workspace from the workspace bar opens the source rail and positions it at
    /// the provider root — **the same place for every lens, Organize included.** Organize used to be
    /// the exception (it opened on the loose-files inbox); the body below says why that went, and
    /// where the inbox lives now. Fired only from the bar itself — the programmatic
    /// scan actions (Find Duplicates / loose files from a Compare menu) set the workspace directly
    /// and bypass this, so they keep scanning the folder the user picked.
    func presentLensRail(for workspace: Workspace) {
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

    /// Reloads pane trees and runs a diff scan (with re-entrancy and cancellation handled by the
    /// manager).
    ///
    /// - Parameter reloading: which panes to WALK. The scan that follows always compares both; a
    ///   pane left out contributes the tree it is already holding. Defaults to `.both`, which is
    ///   what the force refresh, the launch bootstrap and a pane swap all mean. The narrow scopes
    ///   come from the two places that know a single pane moved: `refreshSubject`, and the
    ///   enabled-providers handler, which asks `paneRootEdits` which pane's Location was edited and
    ///   must pass that same scope to `invalidateComparisonState` — a pane whose tree is dropped
    ///   there and not walked here stays blank.
    /// - Returns: whether a refresh was actually started. **The `false` is the point.**
    ///
    /// This guard returned in silence, and a pane load skipped at launch with nothing said about it
    /// is how a pane comes to draw one source's tree under another source's name for a whole
    /// session. The two ids are `@AppStorage` and are restored before discovery finishes, so at
    /// bootstrap it is ordinary for a pane to name a source `enabledProviders` has not published
    /// yet — a folder source, or one a restored tab just adopted. When that happens this does
    /// nothing, and `onChange(of: enabledProviders)` cannot pick it up either, because that handler
    /// returns early while the bootstrap guard is up. Nothing else walks the tree, so the pane
    /// keeps whatever an earlier, differently-targeted refresh happened to leave in it.
    ///
    /// Saying so is half the fix; the caller completing it when the source arrives is the other
    /// half (see `launchRefreshPending`).
    @discardableResult
    private func refreshAction(reloading: FileSyncManager.PaneReloadScope = .both) -> Bool {
        guard let leftProvider = settings.enabledProviders.first(where: { $0.id == leftProviderId }),
              let rightProvider = settings.enabledProviders.first(where: { $0.id == rightProviderId }) else {
            let missing = [leftProviderId, rightProviderId]
                .filter { id in !settings.enabledProviders.contains { $0.id == id } }
            Logger.shared.warning(
                "Skipped a refresh: \(missing.joined(separator: ", ")) "
                + "\(missing.count == 1 ? "is" : "are") not among the enabled sources yet")
            return false
        }
        Task {
            await syncManager.refreshTreesAndScan(left: leftProvider, right: rightProvider,
                                                  reloading: reloading)
        }
        return true
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
        // The window is interactive while discoverProviders() is still awaiting, and a swap there
        // would repoint panes the bootstrap is still deciding the sources of. Refused outright.
        //
        // **This used to say the counter would strand**, because both id `onChange`s bailed on the
        // bootstrap guard without decrementing. They no longer do: `PaneProviderChange` consumes a
        // counter BEFORE testing that guard, so a suppressed write is balanced wherever it lands.
        // The refusal above is still right for the reason given, but stranding is not the reason.
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
        // The swap moved the LISTS as well as the panes, so each saved strip is now the other
        // pane's. Saved explicitly rather than left to the path `onChange`, which does not fire
        // when both panes happened to be showing the same folder — and then the strips on disk are
        // the ones that just left.
        //
        // **Both sides, and that is not symmetry for its own sake.** A swap is the one move that
        // changes both strips at once, so saving only the left would leave the right's stored strip
        // naming the pane that is no longer there — and the next launch would restore the two
        // halves of a swap that never happened, one side from before it and one from after.
        saveBrowseTabs(isLeft: true)
        saveBrowseTabs(isLeft: false)
        refreshAction()
    }

    /// Opens the settings overlay preselected on the Providers tab — the fix-it action for the
    /// invalid-root / disabled-provider pane placeholders.
    private func openProviderSettings() { openSettings(on: .providers) }

    /// **The one door for every Settings deep link**, so no caller has to remember the pairing.
    ///
    /// The tab is written before the latch because the overlay renders `settingsTab` as it finds
    /// it — presetting afterwards shows the previous page for a frame and then jumps. What that
    /// ordering costs is a write that outlives a refused open, so the displaced tab is stashed here
    /// and `onChange(of: showSettings)` either forgets it (the open happened) or puts it back (the
    /// open was refused mid-destination-pick).
    /// Internal, not private: `CommandPaletteHost.swift` is another extension on this type in
    /// another file, and `.settings(tab:)` must come through this door rather than reproducing the
    /// preset-then-latch ordering the comment above spells out.
    func openSettings(on tab: SettingsView.SettingsTab) {
        // Only while the latch is actually flipping. `onChange` is what consumes the stash and it
        // does not fire for a redundant `true`, so stashing on an already-open panel would leave a
        // value to be restored later over a tab the user had since chosen by hand.
        if !showSettings { settingsTabBeforeDeepLink = settingsTab }
        settingsTab = tab
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
    /// is available on both Compare and Organize, so this no longer yanks the single-source rail over to Compare.
    func showInfo(for path: String) {
        infoPath = path
        withAnimation(.easeInOut(duration: 0.15)) { showInspector = true }
    }

    /// Opens each pane at its source's landing folder. Runs once, inside the first-appearance
    /// bootstrap, after the provider selection resolves and before the initial refresh.
    ///
    /// **It was `restoreLastPaneFocusIfEnabled`, and the name outlived the gate.** There is no
    /// `isEnabled` here any more: this is where a pane opens, not a restoration of where it was, so
    /// "Reopen panes where I left off" does not govern it — turning that setting off leaves a pane
    /// on the folder its source says it opens at, which is the same absolute folder every pane
    /// opened at before sources had roots. The setting still gates `restoreBrowseTabs`, which is
    /// the thing that actually restores a position.
    ///
    /// **The saved per-pane focus path no longer decides the launch position, deliberately.** It
    /// could not express the one position this release added: `PaneLogic.paneFocusRestores` skips a
    /// saved path of `""` and `""` is also what "never saved" reads as, so a user who navigated up
    /// to the account root and quit was bounced back down to `Documents` on every launch — the
    /// restore setting honoured for every folder except the root. Rather than teach the stored key a
    /// sentinel, the launch position is now the source's own answer to "where do panes on me open",
    /// which is what `openAt` is for.
    ///
    /// **This is the launch position only for a pane with no tab strip** — a fresh install, a newly
    /// connected account, or the first launch after upgrading from a build that predates the strip.
    /// `restoreBrowseTabs` runs next and re-points a pane that has one to its selected tab's own
    /// folder, and that is untouched: "Reopen panes where I left off" still restores where you were,
    /// through the strip that actually records it per tab.
    private func openPanesAtTheirLandingFolders() async {
        // `focusOn` rather than a history reset: it leaves the root one Back away, which on a pane
        // the user has not navigated yet is a way up, not a false step in their history.
        for isLeft in [true, false] {
            let id = isLeft ? leftProviderId : rightProviderId
            let landing = settings.openAtIfReachable(for: id)
            guard !landing.isEmpty else {
                // **The degrade is logged, because the log is what gets audited.** `openAtIfReachable`
                // answers `""` for two different reasons and only one of them is interesting: the
                // user chose a landing folder and it has since been renamed or deleted, so the pane
                // opens at the account root instead. Settings shows a sentence about it; without
                // this the log — read long after the fact, when the folder is the question — said
                // nothing at all. A source that simply has no `openAt` is the ordinary case and
                // stays quiet.
                let chosen = settings.openAt(for: id)
                if !chosen.isEmpty {
                    Logger.shared.info(
                        "\(isLeft ? "Left" : "Right") pane's source opens at \(chosen), "
                        + "which is not there — opening at the root instead.")
                }
                continue
            }
            Logger.shared.info("Opening \(isLeft ? "left" : "right") pane at its source's folder: \(landing)")
            syncManager.focusOn(relativePath: landing, isLeft: isLeft)
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

    /// The in-window Help overlay (Help ▸ SyncCloud Help / ⌘?). HelpOverlay owns the backdrop,
    /// card decoration, and the searchable topic/article layout; this just feeds it the current
    /// surface style so the Help card matches Settings and Welcome, and wires dismissal.
    @ViewBuilder
    private var helpOverlay: some View {
        HelpOverlay(
            glassHue: glassHue,
            glassLevel: glassLevel,
            surfaceTint: surfaceTint,
            openAt: helpTopic,
            onClose: { showHelp = false; helpTopic = nil }
        )
    }

    /// Whether the form opens itself, given everything this window knows.
    ///
    /// The session latch and the discovery wait are this view's business; the rest of the rule is
    /// `SetupFlow.shouldAutoShow`, where it can be tested without a window.
    private var shouldAutoShowSetup: Bool {
        !setupDismissedThisSession && !isBootstrappingProviders
            && SetupFlow.shouldAutoShow(hasCompletedSetup: hasCompletedSetup,
                                        hasSeenLegacyWelcome: hasSeenFirstRunWelcome,
                                        hasFilingProfile: syncManager.filingFolderProfile != nil)
    }

    /// The setup form (Fig. 1–6). `SetupSheet` owns the card, the rail and every step; this wires
    /// it to the live settings object, the roster where one exists, and the two ways out.
    @ViewBuilder
    private var setupOverlay: some View {
        GeometryReader { proxy in
            SetupSheet(
                settings: settings,
                peopleStore: syncManager.filingPeopleStore,
                glassHue: glassHue,
                glassLevel: glassLevel,
                surfaceTint: surfaceTint,
                availableSize: proxy.size,
                hasFilingProfile: syncManager.filingFolderProfile != nil,
                syncManager: syncManager,
                // A profile the user just produced has to take effect without a relaunch: this is
                // the same read the app does at launch, run again now that there is something new
                // on disk to read.
                // A walk just wrote a profile — a new survey, and the one moment besides launch
                // and a landing that O16's line should record.
                onProfileWritten: { FilingArtifacts.attach(to: syncManager, recordingTrend: true) },
                // Through the one door, not by writing the latch here: `openSettings(on:)` stashes
                // the tab it displaces so a refused open — one landing mid-destination-pick — can
                // put it back. Presetting the tab and raising the latch by hand is the pairing that
                // door exists to stop anyone having to remember.
                onOpenSettings: { tab in
                    dismissSetup()
                    openSettings(on: tab)
                },
                onFinish: { finishSetup() },
                onDismiss: { dismissSetup() }
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .transition(.opacity)
    }

    /// Hide the form for the rest of this session, persisting nothing.
    ///
    /// **Nothing, deliberately.** Every answer the form collected is already written — preferences
    /// and the source list are live settings, and the roster answers are in the draft — so there is
    /// no "save" to perform here. What is *not* recorded is that setup was finished, which is what
    /// lets an unanswered form offer itself again next launch.
    private func dismissSetup() {
        setupDismissedThisSession = true
        showSetup = false
    }

    /// The user reached the end of the form.
    private func finishSetup() {
        hasCompletedSetup = true
        // The retired tour's flag is set alongside it so a build that predates the form — or a
        // rollback to one — does not greet a user who has already been through all of this.
        hasSeenFirstRunWelcome = true
        dismissSetup()
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
        .overlayPanelShadow()
    }

    @ViewBuilder
    private var settingsOverlay: some View {
        // The card is sized in points and grows with the Text size setting, but the window's own
        // minimum is 760×560 — less than the card wants in both axes once `hostMargin` is off it.
        // Hand it the space it actually has so it can clamp itself rather than hang off the edge.
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
        .overlayPanelShadow()
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

    // MARK: Lens scans — Find Duplicates

    /// Whether a lens scan/inspect should target the right pane. Always false in a single-source workspace
    /// (the rail is the left pane), so a stale right-pane selection can't silently aim the scan at the
    /// hidden provider. In compare mode the focused pane wins. See `PaneLogic.lensTargetsRightPane`.
    var lensTargetIsRight: Bool {
        PaneLogic.lensTargetsRightPane(isCompare: layoutMode == .compare,
                                       focusedSide: syncManager.focusedPaneSide,
                                       activePane: activePane)
    }

    /// The provider name for the pane a lens scan targets: the single-source rail is always the left
    /// pane; in compare mode it follows the focused pane.
    ///
    /// **The PLAIN name, without "(left)"/"(right)".** This used to read `paneNames.left`, whose
    /// suffix exists to tell two visible panes apart — and a lens workspace shows one. So every
    /// breadcrumb in Organize and Storage said "iCloud (left) › Documents › …" whenever the
    /// Compare tab's two panes happened to be on the same provider, disambiguating against a pane
    /// that is not on screen. The Differences table and the duplicate-review banner, which really
    /// do show both, keep `paneNames` and its suffix.
    var lensProviderName: String {
        paneNames.plain(isLeft: !lensTargetIsRight)
    }

    /// The absolute (tilde-expanded) folder a lens scan walks: the targeted pane's current directory
    /// (always the left rail in single-source; the focused pane in compare) — **including where the
    /// pane is browsing**, so clicking through columns moves the target and the "Scan '<folder>'"
    /// offer follows in real time. See `PaneLogic.lensScanRoot`.
    var lensScanRootExpanded: String {
        PaneLogic.lensScanRoot(
            focusRootExpanded: ((lensTargetIsRight ? currentRightPath : currentLeftPath) as NSString)
                .expandingTildeInPath,
            // Only where the columns are on screen. In Tree the stack is parked state, and reading
            // it here made the "Scan '<folder>'" offer name — and then walk — a folder that pane was
            // not showing. The tree lists its scope whole, so its scope is what a scan of it covers.
            browsePath: paneDrawsColumns(isLeft: !lensTargetIsRight)
                ? (lensTargetIsRight ? syncManager.rightBrowsePath : syncManager.leftBrowsePath)
                : PaneBrowsePath())
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
    /// `lensTargetIsRight`'s focused pane: a right-click does not necessarily move focus, and a
    /// scan aimed at the other pane would answer about a different provider entirely.
    func findDuplicatesOfAction(_ node: FileNode, isLeft: Bool) {
        revealCoordinator.findDuplicates(of: node, isLeft: isLeft)
    }

    /// Switches to the Duplicates lens and kicks off a duplicate scan of **the subject** — the scope when
    /// one is set, the focused pane's folder otherwise.
    ///
    /// **The scope, not the pane, for the same reason `autoRescanLensIfShowing` targets it.**
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
        let root = organizeScope?.path ?? lensScanRootExpanded
        guard !root.isEmpty else { return }
        Logger.shared.info("User requested Find Duplicates in \(root)")
        show(.duplicates)
        let options = DuplicateFinderOptions.fromDefaults()
        syncManager.startFindDuplicates(root: URL(fileURLWithPath: root), options: options)
    }

    /// Switches to the Storage workspace and builds a read-only storage picture of the focused
    /// folder (same target-root helper as Find Duplicates). Walk + analyze only — nothing moves.
    /// Shows the saved Storage report for the current root, if Storage is what's on screen and
    /// nothing has been analyzed yet. Safe to call from any trigger — see the call sites.
    func restoreStorageLensIfShowing() {
        // **Keyed on the LENS now, not the workspace** — the same migration
        // `autoRescanLensIfShowing` made when duplicates and filing became two rail items inside
        // one workspace, and for the same reason: since the fold, `selectedWorkspace == .filing` is
        // true on six different pages and only one of them is Storage.
        guard selectedWorkspace == .filing, selectedOrganizeLens == .storage else { return }
        // **A report about somewhere else cannot stand under a declared scope, so it goes.**
        //
        // This is the half that makes Decision B true rather than merely intended. `restoreStorage-
        // Lens` refuses while a report is in hand — that guard is what stops the trigger trio
        // re-reading the store on every pane move — so without this the scope chip would change the
        // header and leave the previous root's treemap underneath it: exactly the "restored report
        // presented under a scope it was not built from" the decision exists to prevent. Clearing
        // first is what turns the restore below into the re-analysis the design promises, and
        // `clearStorageLens()` deliberately keeps the stored snapshot, so a scope you come back to
        // restores instantly instead of walking the tree again.
        //
        // **Only under a scope** — `storageReportStandsUnder` answers true when none is set, so
        // browsing the pane still keeps the report and offers to re-aim, as it always has.
        //
        // Not while a build is running: `clearStorageLens()` cancels the task, and a scope change
        // arriving mid-analysis should not kill work that may already be for the new root. The
        // narrow cost is that an analysis finishing after a scope change leaves a report for the
        // old root until the next trigger fires, which any interaction does.
        if !syncManager.isBuildingStorageLens,
           !OrganizeAim.storageReportStandsUnder(scope: organizeScope,
                                                 reportRoot: syncManager.storageLensRoot?.path) {
            syncManager.clearStorageLens()
        }
        // **The scope is the subject** (Decision B). `StorageLensStore` keys snapshots by absolute
        // root path, which is what lets a scoped report and a pane-root report coexist rather than
        // clobber one another. Same fallback `autoRescanLensIfShowing` uses.
        let root = organizeScope?.path ?? lensScanRootExpanded
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
    func autoRescanLensIfShowing() {
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
        // on a fresh lens, never replace a queue. It targeted `lensScanRootExpanded`. With a
        // scope set that is the queue-destroying failure the design rejects live-binding to
        // prevent, arriving through a different door: browse from a scoped `Legal` into some other
        // previously-scanned folder and the rescan silently replaces `filingSuggestions` with that
        // folder's files, which the Legal scope then filters to nothing. To File empties, and
        // nothing on screen says why.
        //
        // The subject is the scope, so that is what gets refreshed. The manager still declines
        // unless the target is one scanned to completion before and nothing has run this session,
        // so pointing it at a never-scanned scope is a no-op rather than a surprise scan.
        let target = organizeScope?.path ?? lensScanRootExpanded
        switch lens {
        case .duplicates:
            guard !target.isEmpty else { return }
            syncManager.autoRescanDuplicatesIfEligible(root: URL(fileURLWithPath: target),
                                                       options: DuplicateFinderOptions.fromDefaults())
        // The one filing scan publishes both of these lists — the loose files and the rename
        // backlog, risky names included — so either of them showing is a reason to refresh it.
        case .toFile, .renames:
            // The taxonomy a filing scan files against — the anchor, not the account root.
            let root = lensProviderAnchorExpanded
            guard !target.isEmpty, !root.isEmpty else { return }
            syncManager.autoRescanFilingIfEligible(
                folder: URL(fileURLWithPath: target), providerRoot: URL(fileURLWithPath: root),
                providerName: lensProviderName, nameProvider: lensProviderType)
        // **Storage is handled by `restoreStorageLensIfShowing`, not here, and the arm is written
        // out to say so.** Its results are RESTORED rather than recomputed — it is the one lens
        // whose report survives a launch — and it had a function of its own for that before the
        // rail existed. Both functions fire from the same four triggers, so calling the restore
        // here too would be the identical call with the identical argument twice per trigger:
        // harmless, because the manager declines when a build is running or a report is in hand,
        // but two paths to one behaviour is how the two come to disagree later.
        case .storage:
            break
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
            // Said in the log too, and *why*. On screen this is one sentence in the slot; to
            // someone reading `~/sync-cloud.log` afterwards the accept would otherwise leave no
            // trace at all — no "User asked…" line, because that is logged past this guard — and a
            // feature that did nothing looks identical to one that was never used.
            Logger.shared.warning("Could not gather \(person.displayName)'s files: this tree has no "
                                  + "readable survey (profile, roster or corpus missing)")
            return
        }
        Logger.shared.info("User asked for everything that is \(person.displayName)'s")
        personGatherTask?.cancel()
        personScope = PersonScope(person: person, phase: .gathering)
        // The folder the artifacts were read from, not the field inside them — the gather reads
        // `filing-corpus.json` under this id, so a disagreement finds no corpus and the accept
        // returns nothing at all. See `FileSyncManager.filingProfileDirectoryId`.
        let id = syncManager.filingProfileDirectoryId ?? profile.profileId
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
                guard !Task.isCancelled, PersonScope.awaits(person, in: personScope) else {
                    // Routine coalescing, so debug — but not silence. The "User asked…" line above
                    // opens a walk of every surveyed document and the "Gathered N file(s)…" line
                    // below closes it; with this branch mute, a superseded accept leaves an opened
                    // sweep that never closes, which reads in the log exactly like the wedged
                    // gather that line was added to rule out. Says which of the two guards fired,
                    // because a cancel and a slot that moved on are different stories about the
                    // same discarded answer.
                    Logger.shared.debug("People: discarded a finished gather for "
                                        + "\(person.displayName) — "
                                        + (Task.isCancelled ? "it was cancelled"
                                           : "the view is no longer waiting for it"))
                    return
                }
                // The sweep's own outcome. The "User asked…" line above opens a walk of every
                // surveyed document — 10,171 on the real tree — and until now nothing closed it,
                // so a slow gather and a wedged one read the same in the log. Both branches speak:
                // nil is the corpus going missing between the guard above and the read.
                if let files {
                    // "plus", not a comma: `total` is the CLAIMED rows only — `PersonFileSet`
                    // deliberately keeps review rows out of it, because they are questions rather
                    // than answers — so a phrasing that reads as "N of which R" would assert in
                    // the log the very thing the queue exists to ask.
                    Logger.shared.info("Gathered \(files.total) file(s) for \(person.displayName) "
                                       + "across \(files.folderCount) folder(s), plus "
                                       + "\(files.review.count) awaiting review")
                } else {
                    Logger.shared.warning("Gathered nothing for \(person.displayName): the survey "
                                          + "corpus could not be read")
                }
                personScope = PersonScope(
                    person: person,
                    phase: files.map { .ready($0) } ?? .failed(Self.noSurveyToGather))
            } catch is CancellationError {
                // The canceller owns the slot, so there is nothing to WRITE. There is still
                // something to say: this is the third way out of a gather, and the other two now
                // close the walk that "User asked…" opened. Left mute, a ✕ or an Esc during the
                // sweep — the common case, since the sweep is the slow part — is the one exit that
                // leaves an opened gather with no ending, which reads in the log exactly like the
                // wedged gather these lines exist to rule out. Debug, like its sibling above:
                // cancelling is routine, and the pair is a trace, not an event.
                Logger.shared.debug("People: the gather for \(person.displayName) was cancelled "
                                    + "while it was reading")
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
    /// identifies it independently of where it sits, which is the durable half of the record and
    /// the reason it is worth one read to compute. (The gather does not yet *look up* by
    /// fingerprint — see `PersonTagStore.keyKind` — so a move still re-opens the question today;
    /// what this buys now is that the verdict written down is not merely a path.) It costs one PDF read of one file, here, at the
    /// moment of the decision — never for the 10,171 documents a gather walks. Anything that is not
    /// a fingerprintable PDF (a photo, a `.docx`, a locked or image-only scan) falls back to the
    /// path, which is the weaker promise honestly made rather than no verdict at all.
    ///
    /// Nothing here moves a file. Filing stays Organize's verb.
    func recordPersonVerdict(_ person: Person, path: String, isTheirs: Bool) {
        guard let store = syncManager.filingPersonTagStore else {
            Logger.shared.warning("Could not record that “\(path)” is "
                                  + "\(isTheirs ? "" : "not ")\(person.displayName)'s: no tag store")
            return
        }
        if let scope = personScope, scope.person == person, case .ready(let files) = scope.phase {
            personScope = PersonScope(person: person,
                                      phase: .ready(files.applying(verdict: isTheirs, to: path)))
        }
        // **After the display has already moved.** Everything above this line is on screen; if the
        // profile is gone the row has changed and nothing will be written, so the verdict comes
        // back as a question next gather. Near-unreachable (the gather that produced this row
        // required the profile), which is exactly why it must not be silent when it does happen.
        guard let root = syncManager.filingFolderProfile?.root else {
            Logger.shared.warning("Recorded nothing for “\(path)”: the folder profile went away "
                                  + "mid-review, so this verdict will be asked again")
            return
        }
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
    /// - Parameters:
    ///   - providerRoot: The row's source root — what the new scope is measured against, and the
    ///     bound on what may become a scope at all.
    ///   - providerAnchor: The row's source anchor — the taxonomy the resulting scan files against.
    ///     A separate argument because the two answers differ now and this one call needs both:
    ///     passing the root for the taxonomy hands filing the whole account, and passing the anchor
    ///     for the scope makes every folder above the documents tree un-scopable.
    func organizeFolderAction(_ node: FileNode, providerRoot: String, providerAnchor: String) {
        let folder = (node.id as NSString).expandingTildeInPath
        guard !folder.isEmpty, !providerRoot.isEmpty, !providerAnchor.isEmpty else { return }
        Logger.shared.info("User requested Organize for \(folder)")
        setOrganizeScope(folder, providerRoot: providerRoot)
        show(.toFile)
        syncManager.startFindFilingSuggestions(
            folder: URL(fileURLWithPath: folder), providerRoot: URL(fileURLWithPath: providerAnchor),
            providerName: lensProviderName, nameProvider: lensProviderType)
    }

    /// §5.10's second deliberate route: the shape question, aimed at one folder — Restructure's
    /// answer already exists (it is read off the survey), so unlike its sibling above there is no
    /// scan to start. Arriving on purpose skips the reveal card, the overview's own rule: the
    /// user asked about this folder, and a card whose button says "Show findings" would charge
    /// that intent twice.
    func checkFolderShapeAction(_ node: FileNode, providerRoot: String) {
        let folder = (node.id as NSString).expandingTildeInPath
        guard !folder.isEmpty, !providerRoot.isEmpty else { return }
        Logger.shared.info("User asked for the shape of \(folder)")
        setOrganizeScope(folder, providerRoot: providerRoot)
        syncManager.hasReviewedStructure = true
        show(.restructure)
    }

    /// The one write of Organize's scope **from this view**, and the one place its callers — the
    /// folder context menu, ⌘K, "Organize This Folder…" — reach the stored form.
    ///
    /// **`nil`, an empty path, the provider root and a pane with no provider at all mean the same
    /// thing: the global view.** That collapse is not spelled here, and deliberately so: the same
    /// key is also written by `LensWorkspaceView.setScope(_:)`, which had its own copy of it under
    /// a doc claiming to be the only one. ``OrganizeScope/normalizedPath(_:providerRoot:)`` is the
    /// owner of the rule now; both writers ask it, so `scope = provider root` and `scope = cleared`
    /// cannot become two encodings of one state.
    /// **`providerRoot` is required, and that is the fix rather than a signature tidy.** It used to
    /// read `lensProviderRootExpanded` itself — the FOCUSED pane's root — while two of its three
    /// callers are row menus, and a SwiftUI context menu does not move focus. Right-clicking a
    /// folder in the pane that did not have focus therefore normalised it against the other pane's
    /// root, which for any folder outside that root answers `""`: the scope the user had set AND
    /// the folder they had just named were both gone, it survived relaunch, and the scan that
    /// followed got the right pane's folder with the left pane's root.
    ///
    /// Naming it at each call site is what makes that unwriteable rather than merely fixed: the
    /// palette genuinely means the focused pane, the row menus genuinely mean their own pane, and
    /// the compiler now asks which.
    func setOrganizeScope(_ path: String?, providerRoot: String) {
        organizeScopePath = OrganizeScope.normalizedPath(path, providerRoot: providerRoot)
    }

    /// The subtree Organize is answering about, or nil for the global view.
    ///
    /// Re-resolved on read rather than stored, exactly as `LensWorkspaceView` does: the provider can change
    /// under a persisted path, and a scope belonging to a tree that is no longer showing degrades
    /// to the global view instead of filtering every lens to nothing.
    var organizeScope: OrganizeScope? { resolvedOrganizeScope(organizeScopePath) }

    /// The read half of the round trip. It has to agree with the write that a stored provider root
    /// means "no scope", or the chip and the filter would disagree about the same string — and it
    /// does by construction rather than by inspection: ``OrganizeScope/normalizedPath(_:providerRoot:)``,
    /// which the write goes through, is defined as this same resolution with `?.path ?? ""` on the
    /// end.
    private func resolvedOrganizeScope(_ path: String?) -> OrganizeScope? {
        guard let path, !path.isEmpty else { return nil }
        return OrganizeScope(path: path, providerRoot: lensProviderRootExpanded)
    }

    /// Navigate to a lens inside Organize — both halves, always.
    ///
    /// The single place programmatic navigation names a rail item, so a caller cannot set the
    /// workspace and forget the lens and land on the overview having silently dropped the request.
    func show(_ lens: OrganizeLens) {
        selectedWorkspace = .filing
        selectedOrganizeLens = lens
    }

    func buildStorageLensAction() {
        // The scope is the subject (Decision B) — analysing the pane root while a scope chip is up
        // would put a whole-tree treemap under a narrowed header. One expression, the same fallback
        // `autoRescanLensIfShowing` uses.
        let root = organizeScope?.path ?? lensScanRootExpanded
        guard !root.isEmpty else { return }
        Logger.shared.info("Storage: requested for \(root)")
        // **Both, since the fold.** Setting the workspace alone would land on Organize's overview
        // and quietly lose the request — the same failure `Workspace.destination(for:)` exists to
        // prevent for programmatic callers.
        selectedWorkspace = .filing
        selectedOrganizeLens = .storage
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
            lensTargetIsRight: { lensTargetIsRight },
            lensProviderRootExpanded: { lensProviderRootExpanded },
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

    /// The provider root of the pane a lens action targets (the left rail in single-source;
    /// the focused pane in compare).
    var lensProviderRootExpanded: String {
        providerRootExpanded(forProviderId: lensTargetIsRight ? rightProviderId : leftProviderId)
    }

    /// The same pane's source **anchor**: the folder that everything the user authored as
    /// "provider-relative" is measured from — an automation's `Invoices/{year}` destination, the
    /// loose-files inbox, and the taxonomy a filing scan files against.
    ///
    /// The landing folder, not the root, and that is behaviour preservation rather than a
    /// preference. Every one of those values was written when a source's only path was its
    /// documents folder, so "provider-relative" meant relative to *that*. Anchoring them at the
    /// account root instead would silently repoint them: `TODO` — the inbox default — names a real
    /// folder at the top of this machine's OneDrive account as well as one inside its Documents,
    /// so the inbox would quietly change which folder it offered. It would also hand the filing
    /// taxonomy an account root full of `Teams Recordings` and a Copilot chat cache, which teaches
    /// it nothing and costs gigabytes of walking to learn.
    ///
    /// Since `openAt` is seeded to exactly the folder that used to be the root, this resolves to
    /// the same absolute path as before for every source — which is the point.
    var lensProviderAnchorExpanded: String {
        providerAnchorExpanded(forProviderId: lensTargetIsRight ? rightProviderId : leftProviderId)
    }

    /// One provider's anchor, expanded — ``lensProviderAnchorExpanded`` asked about a named
    /// provider, for the row menus that must not ask about whichever pane holds focus.
    func providerAnchorExpanded(forProviderId id: String) -> String {
        (settings.landingPath(for: id) as NSString).expandingTildeInPath
    }

    /// One provider's root, expanded — the same shape ``lensProviderRootExpanded`` answers, asked
    /// about a named provider rather than about whichever pane holds focus.
    ///
    /// Split out because "the focused pane's root" is the wrong question for anything a ROW menu
    /// starts: a SwiftUI context menu does not move focus, so a right-click in the pane that is not
    /// focused was answered with the other pane's root.
    func providerRootExpanded(forProviderId id: String) -> String {
        (settings.rootPath(for: id) as NSString).expandingTildeInPath
    }

    /// A root-relative path held by one pane, re-expressed for the OTHER — the translation every
    /// linked action needs now that two panes' roots no longer share an origin.
    ///
    /// **Named for the pane it answers about, and that is not cosmetic.** `isLeft` is the pane the
    /// result is *for*; the path comes from its sibling. Written the other way round — "translate
    /// this pane's path for the sibling" — the call in a tab verb names the pane the verb is NOT
    /// moving, which is exactly the shape `PaneTabWiringTests` refuses: a verb aims every
    /// side-taking call it makes at the one pane it moves, and that invariant is what caught the
    /// `openedFromScope:` transposition. A translation is inherently two-sided, so it is spelled
    /// once here, where both anchors can be read, rather than inline at each call site where the
    /// two-sidedness would have to be excepted from the rule.
    ///
    /// See `PathBoundary.reanchor` for what it does with a path the destination anchor cannot
    /// express: it carries it across unchanged rather than guessing.
    func relativePathForPane(_ relative: String, isLeft: Bool) -> String {
        PathBoundary.reanchor(relative,
                              from: paneOpenAt(isLeft: PaneSideChoice.sibling(isLeft)),
                              to: paneOpenAt(isLeft: isLeft))
    }

    /// A pane's landing folder as a ROOT-RELATIVE path — the origin its positions are quoted
    /// against once you stop assuming both panes share one.
    ///
    /// Read live rather than cached: it is a stored preference that discovery republishes, and a
    /// stale copy would translate a linked move onto the folder the source used to open at.
    func paneOpenAt(isLeft: Bool) -> String {
        settings.openAtIfReachable(for: isLeft ? leftProviderId : rightProviderId)
    }

    /// `paneOpenAt` in the shape `FileSyncManager.paneOpenAt` takes.
    ///
    /// A named property rather than a closure literal at the assignment: written inline, it pushed
    /// the `onAppear` chain past the Swift type-checker's budget outright ("unable to type-check
    /// this expression in reasonable time"), which this file is already close enough to feel.
    private var paneOpenAtForSyncManager: (Bool) -> String {
        { [settings] isLeft in
            settings.openAtIfReachable(for: isLeft ? self.leftProviderId : self.rightProviderId)
        }
    }

    /// The pane → source id mapping, in the shape `FileSyncManager.paneSourceId` takes. Read live
    /// for the same reason as `paneOpenAtForSyncManager`, and a named property for the same
    /// type-checker reason.
    private var paneSourceIdForSyncManager: (Bool) -> String {
        { isLeft in isLeft ? self.leftProviderId : self.rightProviderId }
    }

    /// The provider ruleset the name check runs against — the targeted pane's source (the left
    /// rail in single-source; the focused pane in compare). See `SettingsManager.nameRuleType(for:)`
    /// for the two substitutions it makes: OneDrive for an unresolvable id, and the user's
    /// `folderNameRule` for a folder source.
    var lensProviderType: CloudProvider.ProviderType {
        settings.nameRuleType(for: lensTargetIsRight ? rightProviderId : leftProviderId)
    }

    /// Toggles the shared Quick Look panel for `url`: opens a preview of that file, or — when the
    /// panel is already previewing that same file — closes it, so one button both opens and dismisses
    /// (Space and Esc close it too). Clicking a *different* file re-targets the open panel rather than
    /// closing it. `.quickLookPreview($quickLookURL)` resets the binding to nil on manual dismissal,
    /// keeping this toggle in step with the panel's real state.
    /// - Parameter followsPane: whether this preview is the PANES' — in which case it re-targets as
    ///   the pane selection moves, and closes when that selection is cleared. False for a preview a
    ///   Differences row or the Info inspector opened: both surfaces hold selections at the same
    ///   time, so a pane click is not a statement about what the other one is showing.
    func toggleQuickLook(_ url: URL, followsPane: Bool = false) {
        let closing = quickLookURL == url
        quickLookURL = closing ? nil : url
        quickLookFollowsPane = closing ? false : followsPane
    }

    /// The pane selection the open panel follows — the same resolution Space uses to pick a target
    /// in the first place, so the panel can never come to rest on a file Space would not have
    /// previewed.
    var paneQuickLookTarget: String? {
        CurrentSelection.primaryPanePath(
            left: syncManager.selectedLeftPaths,
            right: syncManager.selectedRightPaths,
            singleSource: layoutMode == .singleSource)
    }

    /// Applies `CurrentSelection.previewFollow` to the panel that is open right now.
    ///
    /// Called from an `onChange` on `paneQuickLookTarget`, which is derived from two `@Published`
    /// sets — so it fires for a click, a search reveal, a re-root and a background republish alike,
    /// and the `.stay` arms are what keep all but the first of those free.
    func followPaneSelectionWithQuickLook() {
        switch CurrentSelection.previewFollow(showing: quickLookURL?.path,
                                              followsPane: quickLookFollowsPane,
                                              panePath: paneQuickLookTarget) {
        case .retarget(let path): quickLookURL = URL(fileURLWithPath: path)
        case .close: quickLookURL = nil; quickLookFollowsPane = false
        case .stay: break
        }
    }

    /// N2 — dry-runs the enabled automation rules over the focused folder. Preview only: the manager
    /// walks + evaluates on-device and publishes what *would* happen; no file is moved. Triggered from
    /// the Automations lens's own button, so the pane is already on that lens when this runs.
    func startAutomationPreviewAction(only: UUID? = nil) {
        let root = lensScanRootExpanded
        // Destinations anchor at the source's anchor folder, not the focused subfolder — so a
        // rule's "Home/Utilities/…" template files there even when previewing inside a subfolder,
        // instead of nesting the tree under whatever folder happened to be focused. The ANCHOR and
        // not the account root: every existing template was authored against the documents folder.
        let providerRoot = lensProviderAnchorExpanded
        guard !root.isEmpty, !providerRoot.isEmpty else { return }
        Logger.shared.info("User requested Rules preview for \(root)\(only == nil ? "" : " (single rule)")")
        show(.rules)
        syncManager.startAutomationDryRun(root: URL(fileURLWithPath: root),
                                          destinationRoot: URL(fileURLWithPath: providerRoot),
                                          providerName: lensProviderName, only: only)
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
        let focused = lensScanRootExpanded
        guard !focused.isEmpty, !lensProviderRootExpanded.isEmpty else { return nil }
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
        // The ANCHOR — see `lensProviderAnchorExpanded`. `TODO`, this setting's default, names a
        // folder at the top of a OneDrive account as well as one inside its Documents, so anchoring
        // at the root would change which folder the shortcut offers without saying a word.
        let root = lensProviderAnchorExpanded
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
        let root = lensProviderAnchorExpanded
        // The provider root is the taxonomy the scan files AGAINST, so it is required whichever
        // folder is being enumerated. `filingScanTargetFolder` folded that check in; the scope
        // branch needs it stated.
        guard !root.isEmpty, let folder = organizeScope?.path ?? filingScanTargetFolder else { return }
        Logger.shared.info("User requested Filing suggestions for \(folder)"
            + (ignoringCache ? " (ignoring saved suggestions)" : ""))
        selectedWorkspace = .filing
        syncManager.startFindFilingSuggestions(folder: URL(fileURLWithPath: folder),
                                               providerRoot: URL(fileURLWithPath: root),
                                               providerName: lensProviderName,
                                               // Names come back on this pass — see
                                               // `detectRiskyNames`. The ruleset is the scanned
                                               // provider's, not whichever pane is focused later.
                                               nameProvider: lensProviderType,
                                               ignoringCache: ignoringCache)
    }

    /// Re-derives the folder memory from the provider tree as it stands now.
    ///
    /// Deliberately its own action rather than a step inside the scan. The scan is what the user
    /// clicks to get suggestions and it has to stay fast; a re-survey reads documents the scan has
    /// no interest in — every already-filed one that changed — and its payoff is the *next* scan,
    /// not this one. Tying it to Rescan would make the common act pay for the occasional one.
    func updateFolderMemoryAction() {
        // The folder memory IS the taxonomy, so it is surveyed over the anchor — the same tree the
        // scans that read it file against.
        let root = lensProviderAnchorExpanded
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
        /// How this pane presents its tree. The comparison panes, the single-source rail and Browse all
        /// reach Columns, each from its own stored key — see `resolvedViewMode(isLeft:)`.
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
        // The rail and Browse each read their OWN key, not the left pane's — same underlying pane
        // state, different surfaces, and a choice made on one must not restack the others.
        let mode: PaneViewMode = resolvedViewMode(isLeft: isLeft)
        return PaneContext(
            isLeft: isLeft,
            title: isLeft ? "Left" : "Right",
            providerId: isLeft ? leftProviderId : rightProviderId,
            // Through the mode, never the bare join: a Tree pane's location is its scope, and the
            // parked column stack is not part of where it is.
            relativePath: syncManager.paneLocation(isLeft: isLeft, drawsColumns: mode == .columns),
            canGoBack: syncManager.canGoBack(isLeft: isLeft, drawsColumns: mode == .columns),
            canGoForward: syncManager.canGoForward(isLeft: isLeft, drawsColumns: mode == .columns),
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
        // THIS pane's selection, which is a different question from `barNodes` above: that one is
        // the ACTIVE pane's, and is empty by construction on every side and workspace the floating
        // action bar does not appear on. Resolved once here and handed to the header, which needs
        // both the count (to disable its Delete) and the nodes (to act).
        let ownNodes = paneSelectionNodes(isLeft: isLeft)
        // Read the scroll-flip trigger so this column re-renders when a scroll crossing flips the
        // edge; the value itself is unused — the edge is resolved fresh below.
        _ = isLeft ? leftBarAtTop : rightBarAtTop
        // Resolve the bar's edge synchronously from the pane's live geometry and current selection.
        // Because this runs in `body`, a selection change (which re-renders here) lands the bar at
        // the correct edge in the same pass — no gate, no deferred flip.
        let placement = isLeft ? leftPlacement : rightPlacement
        let barAtTop = placement.resolveAtTop(selection: Set(barNodes.map(\.id)))
        return VStack(spacing: 0) {
            // The tab strip, and it is a SIBLING of the header and the list — never a wrapper
            // around them. Two reasons, one of them enforced: re-nesting this VStack fails
            // `PaneQuickLookScopeTests.testTheHandlerIsAttachedToTheFileList`, which requires the
            // list's exact indentation, with a message about Quick Look rather than about tabs. And
            // one insertion point here serves Browse, both Compare panes and the Organize/Storage
            // rail, because they are all this one function.
            if paneShowsTabStrip(isLeft: isLeft) {
                PaneTabStrip(
                    items: paneTabItems(isLeft: isLeft),
                    // Keep the seam's ⇄ / 🔗 capsule clear. It straddles the pane boundary at this
                    // exact height, so in Compare it lands on the left pane's ＋ and on the right
                    // pane's first chip — measured on the shipping app before this existed.
                    leadingInset: seamInset(isLeft: isLeft, leading: true),
                    trailingInset: seamInset(isLeft: isLeft, leading: false),
                    // The hue, because `Color.accentColor` inside the strip would be the SYSTEM
                    // accent — the strip's rule was blue in a green window until this was passed.
                    accent: glassHue.accentColor,
                    // The same predicate the pane's ROWS wash their selection from, so the live
                    // chip and the selected rows under it can never name different panes.
                    isActivePane: paneWearsActiveAccent(isLeft: isLeft),
                    onSelect: { selectTab(id: $0, isLeft: isLeft) },
                    onClose: { closeTab(id: $0, isLeft: isLeft) },
                    onCloseOthers: { closeOtherTabs(keeping: $0, isLeft: isLeft) },
                    onDuplicate: { duplicateTab(id: $0, isLeft: isLeft) },
                    onCopyPath: { copyTabPath(id: $0, isLeft: isLeft) },
                    onReorder: { id, index in moveTab(id: id, to: index, isLeft: isLeft) },
                    onSetPinned: { id, pinned in setTabPinned(pinned, id: id, isLeft: isLeft) },
                    onNew: { openNewTabHere(isLeft: isLeft) })
                    // The same wash the header and the list below it take, so the pane reads as
                    // one surface. The strip was the only pane-owned surface without it — at a high
                    // Tint it was a pale stripe cut through the top of the pane. Ordered before the
                    // card, which clips: `surfaceCard` clip-shapes first, so a wash applied after it
                    // would square off the rounded corners (`bottomSectionCard` stacks these the
                    // same way, and for the same reason).
                    .contentSurface(hue: glassHue, tint: surfaceTint)
                    .paneCardIfNeeded(surfaceStyle, level: glassLevel, accentBorder: paneCardAccent(isLeft: isLeft))
                    // **The strip's arrival IS the feedback for ⌘T** (roadmap Fig. 10): the new tab
                    // opens on the folder you are already in, so both chips say the same thing and
                    // nothing else on screen changes. Sliding in from the top is what tells you it
                    // worked.
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            PaneHeader(
                title: pane.title,
                provider: settings.availableProviders.first(where: { $0.id == pane.providerId }),
                rootPath: settings.rootPath(for: pane.providerId),
                relativePath: pane.relativePath,
                canGoBack: pane.canGoBack,
                canGoForward: pane.canGoForward,
                // Same resolved mode the arrows were *enabled* from, so pressing one can never take
                // the branch its enablement did not count.
                onBack: { syncManager.goBack(isLeft: isLeft, drawsColumns: pane.viewMode == .columns) },
                onForward: { syncManager.goForward(isLeft: isLeft, drawsColumns: pane.viewMode == .columns) },
                // `pane.viewMode` and not a fresh read: the crumbs this routes were drawn from the
                // same context, so a click can never be resolved against a mode the row it came
                // from was not laid out in.
                onNavigate: { syncManager.navigatePane(isLeft: isLeft, toCombinedPath: $0,
                                                       drawsColumns: pane.viewMode == .columns) },
                // The single-source rail has no visible sibling: ⌥-click (and the 🔗-linked crumb click)
                // must behave as plain navigation there, never drive the hidden right pane.
                onNavigateBoth: layoutMode == .singleSource
                    ? { syncManager.navigatePane(isLeft: isLeft, toCombinedPath: $0,
                                                 drawsColumns: pane.viewMode == .columns) }
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
                // The header card's right-click route to tabs — the one that works with no folder
                // under the pointer and no strip on screen. `nil` for Close Tab at one tab: the
                // item withholds itself rather than offering to close the window.
                onNewTab: { openNewTabHere(isLeft: isLeft) },
                onCloseTab: syncManager.paneTabs(isLeft: isLeft).count > 1
                    ? { closeTab(id: syncManager.paneTabs(isLeft: isLeft).active.id, isLeft: isLeft) }
                    : nil,
                // Only the single-source rail collapses itself (back to the spine); the two
                // comparison panes never collapse individually, and the full-window workspaces
                // cannot — the pane IS the window there, so there is no spine to collapse into and
                // nothing beside it that the space would go to. Asked of the layout, so a new
                // full-window workspace does not have to remember to exclude itself.
                onCollapse: contentLayout.hasCollapsibleRail
                    ? { withAnimation(.easeInOut(duration: 0.2)) { togglePanesForCurrentTab() } }
                    : nil,
                onRefresh: { forceRefreshAction() },
                isRefreshing: isScanning,
                // Turns the rung into Stop for as long as the scan runs. Both panes get it —
                // there is one scan behind the two of them, so stopping from either is the same
                // act, and the pane the user happens to be looking at is the one they will reach
                // for.
                onCancelScan: { syncManager.cancelScan() },
                // One switch across both panes — hidden-file visibility is `syncManager`'s, not
                // per-pane state. (The focused-pane mark is no longer a header parameter; see
                // `ActivePaneMark` on the card below.)
                showHiddenFiles: $syncManager.showHiddenFiles,
                // The rail and Browse get the switch too, each bound to its own key.
                viewMode: resolvedViewModeBinding(isLeft: isLeft),
                // The pill, on the same resolved answer the pane and ⇧⌘P use.
                previewEnabled: resolvedPreviewBinding,
                // Targets the pane's current folder, which in Columns is the deepest open column.
                // One resolution shared with ⇧⌘N — see `beginNewFolder(isLeft:)`.
                onNewFolder: { beginNewFolder(isLeft: isLeft) },
                // Trashes THIS pane's selection — `ownNodes`, never `activeSelectionNodes`. In
                // Compare both panes are on screen with a Delete each, and a button that acted on
                // "whichever pane is active" would make the two identical rungs mean different
                // things depending on where you last clicked.
                //
                // `alwaysConfirm: true` regardless of Settings ▸ Confirm before deleting: this is
                // a permanently visible rung between Hidden Files and Search, not a menu item
                // chosen by name. The row menu and ⌘⌫ still honour the setting; the tooltip says
                // this one does not, so the prompt cannot read as the setting being broken.
                // **Resolved at FIRE time, not captured.** `ownNodes` below is a snapshot taken
                // during this render, and it is the right thing for the COUNT — enabling a button
                // is a question about the render it is drawn in. It is the wrong thing for the
                // act: this same closure is what the ⋯ menu's Delete entry runs, and a menu held
                // open in menu-tracking mode is not re-armed by a republish, so a snapshot could
                // name rows a background bulk sync has since replaced. `shortcutDeleteSelection`
                // documents this for ⌘⌫ and resolves at fire for it; so does this.
                onDelete: { actionHandler?.confirmDelete(paneSelectionNodes(isLeft: isLeft),
                                                         alwaysConfirm: true) },
                selectionCount: ownNodes.count,
                // Search inside THIS pane's tree. Every workspace with a pane browser gets it from
                // here — Compare's two panes and the single-source rail — because they are all this
                // one header over this one pane component.
                searchText: paneSearchState(isLeft: isLeft).query,
                searchIsExpanded: paneSearchState(isLeft: isLeft).isExpanded,
                searchSummary: paneSearchResults(isLeft: isLeft)
                    .summary(at: paneSearchState(isLeft: isLeft).wrappedValue.hitIndex),
                // What the ▲▼ buttons are enabled by. The same collection `advancePaneSearch` walks,
                // so a disabled button and a no-op walk can never disagree.
                searchMatchCount: paneSearchResults(isLeft: isLeft).hits.count,
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
            .paneCardIfNeeded(surfaceStyle, level: glassLevel, accentBorder: paneCardAccent(isLeft: isLeft))
            treeView(pane)
                .paneCardIfNeeded(surfaceStyle, level: glassLevel, accentBorder: paneCardAccent(isLeft: isLeft))
                // Space → Quick Look, scoped to the FILE LIST — see `paneQuickLook()`.
                //
                // Left on the single-key overload deliberately. It takes modified presses and
                // fires on key-repeat like every other overload does (measured — see
                // `KeyPress.isPlainKeystroke`), and neither matters here: Quick Look opens a
                // panel, a repeat re-targets the same panel, and nothing moves on disk.
                .onKeyPress(.space) { paneQuickLook() }
                // ↩ → Rename, scoped the same way and for a stronger reason — see `paneRename()`.
                //
                // Same shape as the two decision cards, and for two of their three reasons. This
                // was `.onKeyPress(.return)`, which meant:
                //
                // - **⌘↩/⇧↩/⌥↩/⌃↩ each opened the rename editor.** No `onKeyPress` overload
                //   filters modifiers; the single-key one is not the exception it was once
                //   documented to be. ⌘↩ and ⌥↩ are chords other surfaces own, and a rename
                //   editor opening under one steals the keystroke from whoever meant it.
                // - **The keypad's Enter did nothing**, silently, while the File menu's Rename
                //   item and the pane's own affordances advertise ↩. keyCode 76 sends U+0003, not
                //   U+000D, and SwiftUI matches on the character delivered.
                //
                // The third reason does not apply, which is why this is not the cards' problem:
                // a held ↩ opening one rename editor and then re-opening the same one moves no
                // bytes. `.down` only regardless — there is no reason to want the repeats.
                // `press.isPlainKeystroke` and not `modifiers.isEmpty`: the keypad's Enter always
                // carries `.numericPad` + `.function`, so the strict spelling would refuse the
                // keycap this change exists to accept, and `.capsLock` rides on every event while
                // the lock is engaged.
                //
                // No `focused` term, unlike the cards: `paneRename` has no focusable descendants
                // of its own to be confused with, and the guard it does need — a pending
                // destination pick or the ⌘K palette owning the keyboard — is `paneChordsSuspended`,
                // asked inside `paneRename()` where the menu item's twin can be asked the same way.
                .onKeyPress(keys: [.return, .keypadEnter], phases: .down) { press in
                    guard press.isPlainKeystroke else { return .ignored }
                    return paneRename()
                }
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
                //
                // Through `designAnimation` because the transition it drives is not only a fade —
                // it carries `.move(edge:)`, so the bar slides in from the top or bottom. Under
                // Reduce Motion the whole insertion lands at once rather than travelling.
                .designAnimation(.easeOut(duration: 0.11), value: barNodes.isEmpty)
        }
        // **The pane the sidebar opens into, marked on the pane.**
        //
        // The `Left | Right` control says which pane is armed, and it lives in the sidebar's
        // header — so confirming meant looking away from the panes to a corner you were not using.
        // This is the other half: the answer sits on the destination.
        //
        // **Decoration, never layout.** Both of `PaneHeader`'s rows are pinned by measurement —
        // `PaneHeaderHeightTests` holds the header to `LiquidGlass.headerHeight` and
        // `PaneBarLadderTests` measures the top row overflowing a 250pt pane — so a chip in either
        // would burst a rung, which is exactly what that file says happened to the search field.
        // A background wash and a top edge cost nothing and cannot collide with anything.
        //
        // **Reads as a destination, not as a selection.** This marks the region's edge, where the
        // selection wash is per row (`PaneSelectionWash`) and the inactive pane's dimming is a
        // property of ROWS too — so the two signals never occupy the same surface.
        .modifier(ActivePaneMark(isFocused: paneIsFocusedPane(isLeft: isLeft),
                                accent: glassHue.accentColor,
                                surfaceStyle: surfaceStyle))
        // **Any click in this column means the user is working here.** Covers what the tab verbs
        // and the selection write cannot see between them: the empty space under the last row, the
        // header card's chrome, the breadcrumb, a right-click. Reports and declines every press, so
        // nothing below it loses a click — see `PaneClickReporter`.
        //
        // Compare only. The single-source workspaces have one pane, which `focusedPaneIsLeft`
        // already floors to, so a reporter there would write a value that was never in question.
        .overlay {
            if layoutMode == .compare {
                PaneClickReporter {
                    syncManager.noteFocusedPane(isLeft: isLeft, because: "a click in this pane")
                }
            }
        }
        // Keyed on the strip's PRESENCE, not on the tab count: a tab opening or closing while the
        // strip is already up must not animate the header and list below it.
        .designAnimation(.easeOut(duration: 0.18), value: paneShowsTabStrip(isLeft: isLeft))
        // Escape clears this pane's selection — the file lists give no deselect gesture, so
        // without this a folder picked here could never be un-picked. Only swallow the key when
        // there's actually a selection here; otherwise let it bubble (dialogs, etc.).
        //
        // The single-source rail reads its RAW selection rather than `barNodes`: the action bar (and with it
        // `barSelectionNodes`) is compare-only, so gating on it alone made Escape dead on the one
        // surface that has neither a bar nor its ✕ to fall back on. Compare's gate is unchanged —
        // see `PaneLogic.escapeClearsSelection`.
        //
        // Single-key overload, kept: like ␣ above it takes modified presses and fires on
        // key-repeat, and neither costs anything here. Clearing an already-clear selection is a
        // no-op, and the guard already returns `.ignored` when there is nothing to clear, so a
        // ⌘esc-shaped press cannot swallow a key someone else wanted. (⌘esc and ⌃esc do not reach
        // any `onKeyPress` at all — AppKit takes them as `cancelOperation:` ahead of the responder
        // chain.) Reviewed with ↩ above on 2026-08-21 and deliberately left as-is.
        .onKeyPress(.escape) {
            let paneSelection = isLeft ? syncManager.selectedLeftPaths : syncManager.selectedRightPaths
            // **The pane, not the root view.** An `onKeyPress` scopes to the subtree that has
            // focus, and the root is not focusable — a handler there would never see the key. The
            // pick's esc therefore lives with the selection's, ahead of it; the precedence is
            // `PaneLogic.escapeAction`.
            switch PaneLogic.escapeAction(
                hasComparePick: comparePick != nil,
                isSingleSource: layoutMode == .singleSource,
                hasActionBarSelection: !barNodes.isEmpty,
                paneHasSelection: !paneSelection.isEmpty
            ) {
            case .cancelComparePick:
                comparePick = nil
                return .handled
            case .clearSelection:
                clearSelection(isLeft: isLeft)
                return .handled
            case .ignore:
                return .ignored
            }
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
    /// single-source rail. `DetailsSidebar` handles the no-selection empty state itself.
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
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                verticalSplit
                if showInspector {
                    inspectorResizeHandle
                    infoInspector
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            // **The pick-mode bar TAKES SPACE, and it belongs at the BOTTOM.** Two corrections,
            // both from seeing it run.
            //
            // It began as `.overlay(alignment: .top)` on the window root, which floats above
            // everything — including the panes' own tab strips and both breadcrumb rows. On a real
            // window it drew straight across them, the prompt and the tab titles and the right
            // pane's crumbs superimposed and none of them readable. A mode indicator is chrome,
            // not a badge; chrome drawn over the controls beneath it is worse than no indicator.
            // So it became a row, which nothing can be drawn over.
            //
            // **At the top it was a row nobody looked at.** The gesture that arms it is a click in
            // the action bar at the FOOT of the pane, and the answer to it appeared at the head of
            // the window, the full height of the panes away from where the eye already was. Here
            // it sits directly under the panes, a few points from where the bar floats — the same
            // corner of the window the reader is already working in.
            //
            // Still the one wrapper every workspace's content passes through, so Browse's single
            // pane and Edit get it on the same terms as Compare's two.
            if let pick = comparePick {
                ComparePickStrip(fileName: pick.armedName, onCancel: { comparePick = nil })
                    .padding(.top, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .designAnimation(.easeOut(duration: 0.15), value: comparePick)
        // The window-edge half of every gap. Each card insets itself by the other half, so a
        // card-to-edge gap and a card-to-card gap both come to `cardGutter`. Applied once,
        // here, and nowhere else — per-container padding is what made the gaps uneven before.
        .padding(LiquidGlass.cardInset)
        // Animate the panes collapsing/expanding when the tab's pane state flips — both on
        // the manual toggle and on the auto-collapse that fires when a tab switch changes it.
        .designAnimation(.easeInOut(duration: 0.2), value: panesHiddenForCurrentTab)
        // No animation on the collapse: the differences pane snaps open/closed instantly with the
        // chevron, which is what reads as responsive here; the others keep the softer easeInOut.
        .animation(nil, value: bottomPaneIsCollapsed)
        .designAnimation(.easeInOut(duration: 0.2), value: selectedWorkspace)
        .designAnimation(.easeInOut(duration: 0.15), value: showInspector)
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
        .designAnimation(.spring(), value: syncManager.activeProgress == nil)
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
        .designAnimation(.spring(response: 0.4, dampingFraction: 0.9), value: syncManager.banner)
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
        // The menu-bar chords, on one contract, bundled into one modifier
        // (`ShortcutValuePublisher` — inlining the chained publications here broke the
        // type-checker's time budget): each value recomputes with this body, so a menu item's
        // enabled-ness tracks the same facts the control it mirrors renders from. ⌘F is in there
        // too now; it was the last one published on its own, and so the last one the picker's
        // suspension did not reach.
        .modifier(shortcutValuePublisher)
        // Feed the pane header's quick-jump "Recent" list: every folder either pane focuses — by
        // drilling in, a crumb, back/forward, or a scan — is recorded against its provider root.
        .onChange(of: syncManager.leftRelativePath) { _, rel in
            FolderJumpStore.shared.recordVisit(root: settings.rootPath(for: leftProviderId),
                                               relativePath: rel, name: (rel as NSString).lastPathComponent)
            // The visit just recorded is a row the sidebar does not have yet. Same handler rather
            // than a second `onChange` on the same value: two would fire in an order SwiftUI does
            // not promise, and the wrong one puts the sidebar one folder behind the pane.
            refreshFolderSidebarRows()
        }
        .onChange(of: syncManager.rightRelativePath) { _, rel in
            FolderJumpStore.shared.recordVisit(root: settings.rootPath(for: rightProviderId),
                                               relativePath: rel, name: (rel as NSString).lastPathComponent)
        }
        // The other moments the sidebar's answer can change: first appearance, a provider switch
        // (a different root is a different pair of lists), the set of sources changing, and the
        // store publishing a favorite made anywhere else — the pane header's jump menu and the
        // breadcrumb both write to it.
        //
        // `objectWillChange` fires BEFORE the store mutates, so the handler hops a run-loop turn;
        // reading inline would re-read the lists as they were.
        //
        // **The publisher is handed over bare, and the hop is inside the handler.** Writing it as
        // `objectWillChange.receive(on: RunLoop.main)` builds a NEW `Publishers.ReceiveOn` value on
        // every evaluation of this body, and `onReceive` has no way to see it as the same one — so
        // it tears down and re-subscribes on every render, and an event that lands in the gap is
        // simply lost. `ObservableObjectPublisher` itself is one stable instance.
        .onAppear {
            // **The launch walk**, and it is NOT redundant with the refresh beside it: that one
            // returns early wherever the column is hidden, and a card already in the reader has to
            // be recorded before it is ejected whether or not the sidebar is on screen.
            Self.rememberMountedVolumes(Self.mountedVolumes())
            refreshFolderSidebarRows()
        }
        .onChange(of: leftProviderId) { _, _ in refreshFolderSidebarRows() }
        // **The two the gate makes necessary.** `refreshFolderSidebarRows` now returns early
        // wherever the column is not on screen — which is right, because it `stat`s a provider root
        // and the other triggers fire on every workspace. But it also means switching the sidebar
        // ON, or arriving at Browse, lands on whatever was last resolved: exactly the stale list a
        // person would read as "my pins are gone". The guard and these two are one change.
        .onChange(of: browseSidebarVisible) { _, _ in refreshFolderSidebarRows() }
        .onChange(of: selectedWorkspace) { _, _ in refreshFolderSidebarRows() }
        // **The third**, added when collapsing the panes joined the gate. The paragraph above got
        // this exactly right and I still missed it: every input to
        // `FolderSidebarModel.isShowing` needs a trigger, because the guard drops whatever fires
        // while the column is hidden and nothing re-runs it on the way back. Expanding the panes
        // was landing on a list resolved before the collapse. `FolderSidebarWiringTests` now pins
        // that the set of triggers matches the set of gate inputs, since this is the second time.
        .onChange(of: panesHiddenForCurrentTab) { _, _ in refreshFolderSidebarRows() }
        // **And the set of sources itself**, which is new in v4.4 because the column now draws one
        // row per source. Adding a folder source, removing one, or switching one off in Settings
        // all change what the Sources section should say — and one of those paths is the sidebar's
        // own promotion, which would otherwise leave the row it just added still reading as a
        // local shortcut nobody has heard of. Keyed on the ids rather than the array: `CloudProvider`
        // carries a mutable `path`, so an unrelated Location edit would fire this on every keystroke.
        .onChange(of: settings.enabledProviders.map(\.id)) { _, _ in refreshFolderSidebarRows() }
        .onReceive(FolderJumpStore.shared.objectWillChange) { _ in
            DispatchQueue.main.async { refreshFolderSidebarRows() }
        }
        // **A card renamed in Finder takes its sources with it.** `didRenameVolumeNotification`
        // carries both URLs, so this is a fact and not an inference — which is what makes acting on
        // it silently safe. Nothing here treats a source that has merely gone missing as renamed:
        // an unplugged card is asleep, and the column's whole dimming rule is that asleep is not
        // gone. See `SettingsManager.followVolumeRename`.
        .onReceive(NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didRenameVolumeNotification)) { note in
                followVolumeRename(note)
        }
        // **Ejecting a card removes the sources on it**, so the row goes rather than dimming — and
        // the three subscriptions are one mechanism, not three features. The unmount notification
        // cannot say what the volume WAS, so the two before it record that while it is still there:
        // the launch walk in `onAppear` catches a card already in the reader, `didMount` catches one
        // inserted while the app runs, and `willUnmount` is the last chance before it goes.
        .onReceive(NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didMountNotification)) { _ in
                Self.rememberMountedVolumes(Self.mountedVolumes())
                refreshFolderSidebarRows()
        }
        .onReceive(NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.willUnmountNotification)) { _ in
                Self.rememberMountedVolumes(Self.mountedVolumes())
        }
        .onReceive(NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didUnmountNotification)) { note in
                forgetFolderSidebarSourcesOnUnmount(note)
        }
    }

    /// Moves everything keyed to a renamed volume's old mount point onto the new one.
    ///
    /// **Both URLs or nothing.** `DidRenameVolumeMessage` is AppKit's own typed reading of the
    /// notification's `userInfo`, and it answers nil rather than half a pair — a notification that
    /// says a volume was renamed without saying from what to what has no safe half to act on, so it
    /// is logged and dropped rather than guessed at from whichever sources have stopped answering.
    ///
    /// **A rename can also move nothing.** The notification fires for a name change *and/or* a
    /// mount-path change, and a volume whose path did not move needs no work — both followers no-op
    /// on an unchanged path, so that case costs a comparison rather than a special branch here.
    private func followVolumeRename(_ note: Notification) {
        guard let renamed = NSWorkspace.DidRenameVolumeMessage.makeMessage(note) else {
            Logger.shared.warning("A volume was renamed but the notification did not say from what to what — nothing moved")
            return
        }
        let old = renamed.oldVolumeURL.path, new = renamed.volumeURL.path
        settings.followVolumeRename(from: old, to: new)
        FolderJumpStore.shared.followVolumeRename(from: old, to: new)
        refreshFolderSidebarRows()
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
    /// (the lens workspace pattern) — livelier than a spinning button glyph.
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
                // Through the manager's one door, which holds the "changed or nothing" test and
                // writes the line that says the chords moved. The empty-write case answers with
                // `current`, so it is a no-op there and stays silent.
                syncManager.noteFocusedPane(
                    side, because: "a row was picked in the \(isLeft ? "left" : "right") pane")

                // **A pick completes HERE, because this is the one door both view modes go
                // through.** Tree selects through a `List` binding and Columns through its own tap
                // gestures, and they meet at exactly this setter — hooking the click anywhere else
                // would mean hooking it twice and keeping the two in step for ever.
                //
                // Deferred for the reason the sibling pane's clear is: opening the overlay writes
                // `@State` on this view, and publishing into the window this commit is still in
                // reloaded the clicked List and dropped the click outright (`aa9d407`). One tick
                // later the commit has landed and the pair opens over a pane that registered the
                // selection normally.
                //
                // Exactly one path, because a click is one row. A ⌘-click extending to two while a
                // pick is armed is not "the file to compare with" and leaves the mode standing —
                // the reader can still click one row, or cancel.
                if let pick = comparePick, newSelection.count == 1, let path = newSelection.first {
                    let nodes = isLeft ? syncManager.leftNodes(for: [path])
                                       : syncManager.rightNodes(for: [path])
                    if let node = nodes.first {
                        DispatchQueue.main.async {
                            resolveComparePick(pick, clicked: node, inLeftPane: isLeft)
                        }
                    }
                }
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

    /// Opens the shared file-pair viewer on two files picked in the panes.
    ///
    /// **The same `@State` and the same overlay the Differences list already uses** — this is a
    /// second door onto one surface, not a second surface. Nothing joins the mutually exclusive
    /// overlay chain, and nothing new is animated.
    ///
    /// The ordering rule is ``PaneComparePairMenu/pair(clicked:counterpart:counterpartIsInOtherPane:clickedPaneIsLeft:leftPaneName:rightPaneName:)``,
    /// which is where it can be tested.
    func compareFilePairAction(_ first: FileNode, _ second: FileNode,
                               secondIsInOtherPane: Bool, clickedPaneIsLeft: Bool) {
        compareDifferencePair = PaneComparePairMenu.pair(
            clicked: first, counterpart: second,
            counterpartIsInOtherPane: secondIsInOtherPane,
            clickedPaneIsLeft: clickedPaneIsLeft,
            leftPaneName: paneNames.left, rightPaneName: paneNames.right)
    }

    /// Arms a file for comparison, replacing any pick already standing.
    ///
    /// Replacing rather than refusing: a reader who arms the wrong file and then arms another has
    /// said what they meant, and a mode that had to be cancelled first would be a mode that
    /// punishes a correction.
    func armComparePick(_ node: FileNode, isLeft: Bool) {
        comparePick = ComparePick(armed: node, armedPaneIsLeft: isLeft)
    }

    /// Resolves a click made while a pick is armed — see ``ComparePick/outcome(clicking:inLeftPane:leftPaneName:rightPaneName:)``.
    ///
    /// The three outcomes are the three ways the mode can end or not: the pair opens and the mode
    /// is done, the armed row was clicked again and the mode is cancelled, or a folder was clicked
    /// and the mode stands while the reader keeps looking.
    func resolveComparePick(_ pick: ComparePick, clicked: FileNode, inLeftPane: Bool) {
        switch pick.outcome(clicking: clicked, inLeftPane: inLeftPane,
                            leftPaneName: paneNames.left, rightPaneName: paneNames.right) {
        case .cancelled:
            comparePick = nil
        case .standing:
            break
        case .paired(let pair):
            comparePick = nil
            compareDifferencePair = pair
        }
    }

    /// The row menu's and the file list's delegate for one pane.
    ///
    /// Lifted out of the file list's call site, where it used to sit as one 870-character argument.
    /// That line was load-bearing in an unwanted way: `QuickLookOriginTests` reads a fixed window of
    /// source after the list's opening paren to check the pane's row menu is routed to the host's
    /// Quick Look panel, and one more argument on the delegate pushed `onQuickLook:` out of that
    /// window — a test failing about Quick Look because a tab handler was added three arguments
    /// earlier. (Naming that view here in prose would break the same scan, since it anchors on the
    /// literal: this comment deliberately does not.)
    /// Internal rather than private: File ▸ Organize's verbs build one for the active pane, so the
    /// menu items and the row menu route through the same delegate. See `shortcutOrganizeVerbs`.
    func paneActionDelegate(for pane: PaneContext) -> PaneActionDelegate {
        PaneActionDelegate(
            handler: actionHandler, syncManager: syncManager, settings: settings,
            isLeft: pane.isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId,
            isSingleSource: layoutMode == .singleSource,
            // Not `layoutMode == .singleSource`: Browse and Storage answer that too.
            ownsOrganizeScope: selectedWorkspace == .filing,
            forceRefreshAction: forceRefreshAction,
            onGetInfo: { showInfo(for: $0) },
            onChooseDestination: { nodes, isMove in requestDestination(for: nodes, isMove: isMove) },
            onOpenInEditor: { path in handOffToEditor(path) },
            ignoreStateToken: syncManager.effectiveIgnoredPaths,
            keptNamesToken: syncManager.keptNamesStore?.names ?? [],
            homeBadgeCoverage: homeBadgeCoverage(forProviderId: pane.providerId),
            onFindDuplicatesOf: { node in findDuplicatesOfAction(node, isLeft: pane.isLeft) },
            // The ROW's pane, not the focused one — see `setOrganizeScope(_:providerRoot:)`.
            onOrganizeFolder: { node in
                organizeFolderAction(node,
                                     providerRoot: providerRootExpanded(forProviderId: pane.providerId),
                                     providerAnchor: providerAnchorExpanded(forProviderId: pane.providerId)) },
            onCheckFolderShape: { node in
                checkFolderShapeAction(node,
                                       providerRoot: providerRootExpanded(forProviderId: pane.providerId)) },
            onOrganizeScope: { node in
                setOrganizeScope(node.id, providerRoot: providerRootExpanded(forProviderId: pane.providerId)) },
            onOpenInNewTab: { node in openInNewTab(absolutePath: node.id, isLeft: pane.isLeft) },
            onNewTabHere: { path in openInNewTab(absolutePath: path, isLeft: pane.isLeft) },
            // Resolved at fire time, not captured: a menu held open is not re-armed by a republish,
            // and the active tab can have moved under it.
            onCloseTab: { closeTab(id: syncManager.paneTabs(isLeft: pane.isLeft).active.id,
                                   isLeft: pane.isLeft) },
            onToggleFolderFavorite: { node in toggleFavorite(forPaneFolder: node, isLeft: pane.isLeft) },
            onCompareFilePair: { first, second, secondIsInOtherPane in
                compareFilePairAction(first, second, secondIsInOtherPane: secondIsInOtherPane,
                                      clickedPaneIsLeft: pane.isLeft) },
            onArmComparePick: { node in armComparePick(node, isLeft: pane.isLeft) },
            armedComparePath: comparePick?.armed.id)
    }

    @ViewBuilder
    private func treeView(_ pane: PaneContext) -> some View {
        // The single-source rail is the only pane on screen: it shows no action bar, so it takes no placement
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
            delegate: paneActionDelegate(for: pane),
            diffIndex: pane.diffIndex,
            otherPaneName: pane.otherPaneName,
            rootPathIsValid: settings.isPathValid(for: pane.providerId),
            providerIsEnabled: settings.isEnabled(pane.providerId),
            hasOnlyHiddenEntries: pane.hasOnlyHiddenEntries,
            rootPath: settings.rootPath(for: pane.providerId),
            onOpenSettings: openProviderSettings,
            // The single-source rail has no opposite pane, so its row menu drops the
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
            // What matched, and where the walk has got to. The pane draws its emphasis, dimming and
            // annotations from the first and reveals the hit named by the second — see
            // `FileTreeView.revealInTree` / `revealInColumns`.
            search: paneSearchResults(isLeft: pane.isLeft),
            searchHitIndex: paneSearchState(isLeft: pane.isLeft).wrappedValue.hitIndex,
            searchRevealNonce: paneSearchState(isLeft: pane.isLeft).wrappedValue.revealNonce,
            // Which pane the action bar is acting on — the same predicate that decides where the bar
            // renders, so the strong selection wash and the bar can never point at different panes.
            // The tab strip above takes it too, from the same helper.
            isActivePane: paneWearsActiveAccent(isLeft: pane.isLeft),
            viewMode: pane.viewMode,
            // The same resolved answer the header's pill writes, so the pane and the pill can never be
            // looking at different keys — and so Browse's preview survives being turned off in Compare.
            previewEnabled: resolvedPreviewBinding,
            childrenIndex: pane.childrenIndex,
            browsePath: pane.isLeft ? $syncManager.leftBrowsePath : $syncManager.rightBrowsePath,
            onColumnNavigate: { applyColumnNavigation($0, isLeft: pane.isLeft) },
            // A column opened past `FileSyncManager.paneNodeBudget` has no rows and never would
            // have — the walk stopped before reaching it. This is what fills it in, one directory
            // listing at a time. Without this wiring the budget would trade a hang for a pane that
            // silently cannot navigate a large tree.
            onNeedChildren: { syncManager.loadColumnChildren(atPath: $0, isLeft: pane.isLeft) },
            // So a column can say "reading this" rather than "can't be read" while it waits.
            graftsInFlight: syncManager.columnGraftsInFlightPaths(isLeft: pane.isLeft),
            onBackgroundDeselect: { handleBackgroundDeselect(depth: $0, isLeft: pane.isLeft) },
            // The row menu's preview goes through the HOST's panel, not the pane's own: there is
            // one Quick Look panel and only the host can keep it pointed at the current file.
            onQuickLook: { toggleQuickLook($0, followsPane: true) }
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
                // Re-home the rail on every entry into a lens, including lens→lens: every lens opens
                // at the provider root, so carrying the folder one lens was left in over into the
                // next would scan wherever the user last browsed instead of the source. Narrowing
                // is the scope's job now — it is sticky and visible, unlike a pane position.
                if newWorkspace != previous {
                    presentLensRail(for: newWorkspace)
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

    /// The gather's card, as its own member because **two layouts mount it**.
    ///
    /// `bottomPaneView` is one of them. The other is Browse, which draws no bottom pane at all —
    /// and so, while this lived inline here, an offer accepted from Browse's pane search started
    /// the whole-source sweep and rendered nowhere: no list, no ✕, no Esc target, and switching
    /// workspace to look for it cleared the scope. The one surface that exists to stop an accept
    /// from doing nothing visible was doing exactly that. See `browseLayout`.
    @ViewBuilder
    func personGatherSection(_ scope: PersonScope) -> some View {
        PersonView(displayName: scope.person.displayName,
                   phase: scope.phase,
                   accent: glassHue.accentColor,
                   // **Open opens it here**, which is what the button says and what this
                   // parameter has always been documented to do ("reveals a folder in the pane").
                   // It was wired to the identical Finder call as `onReveal` below, so the two
                   // differently named, differently documented callbacks did one thing — and
                   // "Open" on a folder selected it in its Finder *parent* without the app's own
                   // file view moving at all. Falls back to Finder for a folder outside the pane's
                   // provider, where there is no pane to open it in.
                   onOpenFolder: { relative in
                       guard let root = syncManager.filingFolderProfile?.root else { return }
                       let full = ((root as NSString).expandingTildeInPath as NSString)
                           .appendingPathComponent(relative)
                       let paneRoot = lensProviderRootExpanded
                       guard !paneRoot.isEmpty,
                             let inPane = PathBoundary.relativize(full, under: paneRoot) else {
                           // Outside this pane's provider — there is no pane to open it in.
                           NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: full)])
                           return
                       }
                       // **Open the rail if it is closed**, or this is a dead click: the lens
                       // workspaces can collapse the source pane to a spine, `focusOn` only pushes
                       // history, and the Finder fallback above does not fire for a folder that IS
                       // under the root. Nothing on screen changed — which is worse than the Finder
                       // reveal this replaced.
                       //
                       // Asked as `contentLayout`, not as `panesHiddenForCurrentTab`: that flag is
                       // only honoured by the single-source layout. Compare and Browse resolve
                       // their layout before it is consulted, so keying on it would write a
                       // remembered layout preference — persisted, for the whole workspace — that
                       // changes nothing anyone can see.
                       //
                       // It does discard a deliberate collapse, and permanently: the override is
                       // `@AppStorage` and nothing restores it when the gather clears. That is the
                       // same trade `presentLensRail` already makes on entering a lens from the
                       // bar, and the alternative is a click that does nothing.
                       if contentLayout == .singleCollapsed { togglePanesForCurrentTab() }
                       syncManager.focusOn(relativePath: inPane, isLeft: !lensTargetIsRight)
                   },
                   // Expanded, like every other reader of `FolderProfile.root` — it is stored
                   // tilde-form ("~/Documents"), so the unexpanded join produced a path that
                   // `URL(fileURLWithPath:)` resolved against the process's working directory and
                   // Finder could not find: Reveal did nothing at all. Missed when its sibling
                   // above was fixed, which is how the two came to differ in the other direction.
                   onReveal: { relative in
                       guard let root = syncManager.filingFolderProfile?.root else { return }
                       let full = ((root as NSString).expandingTildeInPath as NSString)
                           .appendingPathComponent(relative)
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
    }

    /// The tabbed workspace at the bottom of the file explorer.
    /// It dynamically switches between `DifferencesView` and `DetailsSidebar`.
    @ViewBuilder
    /// The sentence for an incomplete comparison, or nil when the last scan read both sides in
    /// full — which is every ordinary scan.
    ///
    /// Named off `lastScanProviders`, the pair the ROWS came from, so navigating a pane after the
    /// scan cannot make the banner name a source that was never compared. Nil once there is no
    /// scan to describe: `invalidateDifferencesForPaneRetarget` clears the coverage with the rows.
    var partialComparisonMessage: String? {
        guard syncManager.hasScanned, let pair = syncManager.lastScanProviders else { return nil }
        return syncManager.lastScanCoverage.message(leftName: pair.left.displayName,
                                                    rightName: pair.right.displayName)
    }

    /// **A warning, not an error, and not dismissible.** Nothing failed — the scan ran and the rows
    /// it produced are correct; what is wrong is the ones it could not know about. A dismiss button
    /// would let the qualifier be closed while the number it qualifies stays on screen, which is
    /// the state this exists to prevent.
    @ViewBuilder
    func partialComparisonBanner(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(syncManager.lastScanCoverage.title)
                    .scaledFont(.system(size: 12, weight: .semibold))
                Text(message)
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        // No fill or divider of its own — the host mounts it as a `bottomSectionCard`, the same
        // way `duplicateReviewBanner` is mounted directly above.
    }

    var bottomPaneView: some View {
        // Stable outer container: keeps this bottom pane's identity constant across tab
        // switches, so selecting Details doesn't reset the vertical split or collapse the panes.
        VStack(spacing: 0) {
        // Keep-left / trash-right banner for a duplicate-copy review handed off from the Duplicates lens. Sits
        // above the diff so it shows even when the two copies are identical (empty diff → the
        // "Everything is in sync" placeholder). Hidden the moment either pane is navigated away
        // from the reviewed copies, so the scoped trash can't fire against the wrong folder.
        if selectedWorkspace == .compare, let review = duplicateReview, reviewCoordinator.duplicateReviewActive(review) {
            reviewCoordinator.duplicateReviewBanner(review)
                .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
        }
        // **A count that is a floor has to say so.** Above the table rather than beside the count,
        // because the fact is about every row that is NOT there — see `PartialComparison`.
        if selectedWorkspace == .compare, let message = partialComparisonMessage {
            partialComparisonBanner(message)
                .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
        }
        // **A person gather takes the slot from whatever was in it**, in every workspace. It is
        // an answer about the whole source rather than about one lens, so showing it beside a lens
        // would invite reading it as that lens's output; and it is temporary, so it takes the slot
        // rather than replacing anything. Clearing gives the slot straight back.
        if let scope = personScope {
            personGatherSection(scope)
        } else if let lens = selectedLens {
            // The lens workspaces' right-hand slot. ONE construction site for all of them, and
            // deliberately so: a `switch` with a branch per lens would give each its own view
            // identity, and LensWorkspaceView's @State — the per-lens parked queries, the expanded search,
            // the reclaim tally, the filed/dismissed session flags — would reset on every switch.
            // Storage renders its own read-only surface beneath the shared header card.
            LensWorkspaceView(
                syncManager: syncManager,
                lens: lens,
                providerName: lensProviderName,
                scanTargetFolder: lensScanRootExpanded,
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
                onConfigureCloudRefine: { openSettings(on: .cloudRefineSetup) },
                // The app's ONE Help front door, opened at a named page — Settings and Help
                // never stack, and this must not grow a second overlay to sit beside them.
                onOpenHelp: { topic in
                    helpTopic = topic
                    showHelp = true
                },
                restructureVerbRequest: $restructureVerbRequest,
                onNormalizeNames: { names in Task { await syncManager.normalizeNames(names) } },
                onApplyRenames: { plans in Task { await syncManager.applyRenamePlans(plans) } },
                onPreviewAutomations: { only in startAutomationPreviewAction(only: only) },
                // Both, and they are not the same folder. The anchor is the taxonomy every lens
                // files against and scans; the root is what can bound a scope. Handing the root to
                // the anchor's consumers made rule destinations resolve one level too deep and made
                // an unscoped scan never cover its own subject — see `LensWorkspaceView`.
                providerAnchor: lensProviderAnchorExpanded,
                providerRoot: lensProviderRootExpanded,
                filingInboxFolder: filingInboxFolder,
                onQuickLook: { toggleQuickLook($0) },
                onBuildStorage: buildStorageLensAction,
                // The single lens source is the left provider; its picker shows in the workspace only
                // while the rail is collapsed (expanded, the rail header owns the provider dropdown).
                showSourcePicker: panesHiddenForCurrentTab,
                providers: settings.enabledProviders,
                currentProviderId: leftProviderId,
                onSelectProvider: { leftProviderId = $0 },
                onManageProviders: openProviderSettings,
                onChooseFolder: { chooseFolderSource { leftProviderId = $0 } },
                onCompareCopies: reviewCoordinator.compareCopies,
                onCompareFilePair: { compareFilePair = $0 },
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
            // DifferencesView renders its own two cards (toolbar + table); the workspace bar lives in
            // the window toolbar.
            DifferencesView(syncManager: syncManager, reviewStore: reviewStore, paneNames: paneNames, paneRules: paneRules, onQuickLook: { toggleQuickLook($0) }, onGetInfo: { showInfo(for: $0) }, isCollapsed: $bottomPaneCollapsed, shortcutsSuspended: pendingDestination != nil, onCompareFilePair: { compareDifferencePair = $0 })
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

