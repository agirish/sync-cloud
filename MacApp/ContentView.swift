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
    /// Whose cloud app isn't syncing — the amber bar under a pane's header.
    @ObservedObject var cloudApps = CloudAppMonitor.shared
    /// One-way sync: the toolbar's chip, the panes' role line, Compare's strip, its sheets.
    @ObservedObject var oneWaySync = OneWaySyncController.shared
    /// Read here rather than in `ContentView+Toolbar`, which is an extension and cannot declare
    /// stored properties. Gates the sidebar toggle's reveal — see `withDesignAnimation`.
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    /// Drives the in-window settings overlay (owned by the App so ⌘, can open it).
    @Binding var showSettings: Bool
    /// Drives the in-window Help overlay (owned by the App so the Help ▸ SyncCloud Help / ⌘?
    /// menu command can open it). ContentView renders it and owns dismissal.
    @Binding var showHelp: Bool
    /// The topic Help opens on when a surface pointed here. Cleared on close, so the next ⌘? opens
    /// the book at its front.
    @State private var helpTopic: String?

    /// What the last plan found, and in which tree.
    ///
    /// State, not computed, because the honest answer costs a whole-tree walk. The offer card shows
    /// no count until a plan is really built: the profile's summed `fileCount` would overstate the
    /// work in the one sentence a person decides on. Seeded by the walk, then stands until the next
    /// one.
    @State var documentSurveyPlan: DocumentSurveyPlanFacts?
    /// The folder verbs, written by the menu and carried out by the workspace — see
    /// ``RestructureVerbRequest`` for why it is a value rather than a call. Not `private`: the
    /// verbs are built in `ShortcutCommands`' extension of this view.
    @State var restructureVerbRequest: RestructureVerbRequest?
    /// Whether the once-per-session part of the `onAppear` bootstrap has run. Owned by the App
    /// (session-scoped, never persisted) so it outlives this view: a close and Dock reopen re-runs
    /// `onAppear`, and a view-owned flag would forget if SwiftUI rebuilt the view. See
    /// `SyncCloudApp.hasBootstrappedSession`.
    @Binding var hasBootstrappedSession: Bool
    /// Which settings tab the overlay shows. Owned here so it persists across open/close and can
    /// be preset (e.g. the invalid-pane fix-it action jumps straight to Providers).
    @State private var settingsTab: SettingsView.SettingsTab = .appearance

    /// The tab a deep link displaced, held until the open it asked for is honoured or refused.
    ///
    /// A deep link writes the tab before the latch, and the latch can say no. `openSettings(on:)`
    /// must preset the tab, because the overlay reads `settingsTab` as it appears, but
    /// `onChange(of: showSettings)` refuses the open while a destination pick is up. Without this,
    /// the refused open would still leave Settings moved, and the next plain ⌘, would land on a
    /// page nobody asked for. Non-nil means a deep link is mid-flight; a plain open leaves it nil.
    @State private var settingsTabBeforeDeepLink: SettingsView.SettingsTab?
    /// Browse ▸ Panes' "Customize Pane Bar…": the pane bar's own sheet, over Settings, which stays
    /// open beneath it so closing the sheet lands back on the page it came from.
    @State private var showPaneBarCustomizer = false
    /// The remembered pages a deep link displaced (`SettingsSubTabMemory`), put back with the tab
    /// when the open is refused, so a refused link leaves no page changed either.
    @State private var settingsPagesBeforeDeepLink: String?

    // MARK: The Editor workspace

    /// The one open document, owned by the app — see ``SyncCloudApp/editorDocument``. Held here as
    /// an `@ObservedObject` so the workspace is a rendering of it and nothing else.
    @ObservedObject var editorDocument: EditorDocument
    /// The PDF open in Edit, beside the text document and never at the same time — see
    /// ``EditorPDFDocument`` and `EditorOpenRoute`. Owned by the app for the document's reason.
    /// Observed for its identity only: the reader's position lives on its `view`, which only the
    /// PDF card observes, so a page turn does not re-render this window.
    @ObservedObject var editorPDF: EditorPDFDocument
    /// What the last look at the editor's folder found: the rail's rows, and the count its empty
    /// caption needs. One piece of state, not two, so the "did anything change" guard in
    /// ``refreshEditorRail()`` stays a single comparison; held apart, a folder whose only change
    /// was a PDF arriving would keep a caption claiming it was empty.
    @State var editorRailSurvey = EditorRail.Survey(rows: [], otherFileCount: nil)
    /// The folder `editorRailSurvey` was read from — `editorFolder` moves at once, the survey only
    /// when its walk returns, and the folder menu must not pair the one with the other.
    @State var editorRailSurveyFolder: String?
    /// Counts rail refreshes so only the latest may write. A box, not a value: bumping it must not
    /// re-render the window.
    @State var editorRailRefreshes = RefreshCounter()

    /// Which folders each pane has open in its Tree presentation. Held here, since
    /// `paneColumn(isLeft:)` is mounted by four arms of `verticalSplit`, giving Browse's pane and
    /// Organize's rail different identities over one folder. Per side, not per workspace (all of
    /// Browse, the rail and Compare's left are the left pane); not persisted. Plain `@State`:
    /// opening a folder re-renders this body, as a row click already does.
    @State var leftTreeExpanded: Set<String> = []
    @State var rightTreeExpanded: Set<String> = []

    /// How the reader had Organize's results narrowed — see `LensWorkspaceSession`.
    ///
    /// `@State` holding a reference type, deliberately not `@StateObject`: this view must own the
    /// object (so it survives the workspace switches that destroy `LensWorkspaceView`) without
    /// observing it. A `@StateObject` would re-render this whole window on every keystroke in
    /// Organize's search field and every duplicate resolve. `@State` on a class stores without
    /// subscribing; `LensWorkspaceView` observes it and re-renders alone.
    @State var lensSession = LensWorkspaceSession()

    /// How the reader had the differences table narrowed — see `DifferencesSession`. Held like
    /// `lensSession` above: owned here so it survives the switch, `@State` so the window is not
    /// subscribed to Compare's search field.
    @State var differencesSession = DifferencesSession()
    /// Bumped when the Never show Claude list changes, so the row menus' Hide or Show label is
    /// rebuilt with it: nothing else the window draws from moves.
    @State var askClaudePrivacyChanges = 0
    /// The PDF tools run from a pane's row menu — see `PanePDFTools`. Owned app-wide by
    /// `ActivityCenter`, so the Activity window lists its runs too; observed only by the layer that
    /// draws its sheet, so a run's progress re-renders that layer and not this window.
    var panePDFTools: PanePDFTools { ActivityCenter.shared.panePDFTools }
    /// Save as PDF from a pane's row menu or File ▸ — see `PaneSaveAsPDF`. Owned as the tools are.
    var paneSaveAsPDF: PaneSaveAsPDF { ActivityCenter.shared.paneSaveAsPDF }
    /// Whether the rail's inline naming row is open. Held here because ⌘N opens it from any
    /// workspace, including ones where the editor is not on screen yet.
    @State var editorIsNaming = false
    /// The name being typed in that row. Held here, beside the flag that says the row is open: as
    /// view `@State` it would be thrown away by a workspace switch while the flag survived, and the
    /// row would come back open with the `Untitled` prefill.
    @State var editorTypedName = ""
    /// Bumped by ⌘N so the naming row takes focus even when it is already open — a pure signal,
    /// never read for its value.
    @State var editorNamingFocus = 0
    /// Bumped by Text ▸ Go to Line… (⌃⌘L) so Edit opens the status line's field — a pure signal
    /// like the one above, never read for its value.
    @State var editorGoToLineRequest = 0
    /// What the file the open naming row will make does to the pane, when it goes to Notes. Set by
    /// each ⌘N from the workspace it was pressed in (`ExternalOpen.pane`): from Compare or during a
    /// guided review the left pane is half of the comparison and stays put; from Organize it
    /// follows only on its own source.
    @State var editorNewFilePane: EditorHandOffRun.Pane = .followsTheFile
    /// A file the left pane owes a selection — the document just opened, created, revealed or shown
    /// — paid once the pane lists it. See ``owePaneSelection(_:)``. `nil` whenever nothing is owed.
    @State var editorPaneSelectionOwed: PaneSelectionDebt?
    /// The path the app last wrote into the left pane's selection for the open document, until the
    /// selection change it causes has been seen — so the pane's one-click open does not answer the
    /// app's own write as a click. See `paneSelectionOpens`.
    @State var editorPaneSelectionPaid: String?
    /// Set when that same write cleared the RIGHT pane's selection, until the change it causes has
    /// been seen — so the clear does not retire a Get Info target as a click there would. See
    /// `clearInfoTargetAfterRightSelection`.
    @State var editorPaneRightClearPaid = false
    /// The left pane's standing row reveal — the row the app selected on the user's behalf, to be
    /// scrolled into view. Retired once the pane has answered it (`retireAnsweredRowReveal`), or
    /// when the selection moves off it. See `PaneRowReveal`.
    @State var paneRowReveal: PaneRowReveal?
    /// Makes each reveal a new request, even for the same path.
    @State var paneRowRevealToken = 0
    /// What is typed into the rail's filter, and whether its field is showing. Held here for
    /// `editorTypedName`'s reason: both are typed by the user, and the editor's view is rebuilt
    /// from nothing by every workspace switch.
    @State var editorRailFilter = ""
    @State var editorRailFilterIsExpanded = false
    /// The filter's search inside files: its Names | Contents switch and its results. Beside the
    /// filter's text for the same reason; held, not observed, so its progress redraws the rail's
    /// results and not this window.
    @State var editorContentSearch = EditorContentSearchModel()
    /// The folder the rail last listed, where that filter was typed. A different folder clears it:
    /// a filter carried into a new folder would make the folder look empty.
    @State var editorRailListedFolder: String?
    /// Which half of the rail is showing. Held here for the filter's reason, and because ⌘N puts it
    /// back on the files from workspaces where the editor's view does not exist yet. Not persisted
    /// — it describes a reading session, as ``EditorMode`` does.
    @State var editorRailTab: EditorRailTab = .files
    /// Where each document's outline was last scrolled to, keyed by path. Held here because the
    /// rail's outline is destroyed by a tab switch as well as a workspace switch, and the memory is
    /// the point.
    @State var editorOutlineAnchors: [String: Int] = [:]

    /// Why autosave has stopped writing, or `nil` while it is working.
    ///
    /// A latch, for the alert's sake. Autosave stops the moment it finds the file changed under the
    /// buffer, but its attempt restarts on every keystroke, so without a record of "already asked
    /// and declined" the alert would return seconds after each dismissal. Cleared by a successful
    /// write, by discarding the buffer, and by nothing else.
    @State var editorAutosaveStop: EditorAutosaveStop?
    /// The divergence question, detoured into the diff overlay and waiting for an answer.
    ///
    /// Not a fourth answer or a second state machine: `editorAutosaveStop` is still the latch and
    /// still set while this is non-nil, so autosave stays stopped and the header says so. This only
    /// records that the question is being asked with both versions on screen instead of in a modal.
    /// See `applyDivergenceAnswer`.
    @State var editorDivergenceReview: EditorDivergenceReview?
    /// Whether an autosave write is out on a background thread right now.
    ///
    /// Not a lock, and not what makes the write safe: `EditorFileStore`'s write order does that,
    /// because ⌘S and the quit flush write synchronously and cannot wait. This only stops a second
    /// background write being dispatched over the first.
    @State var editorIsWritingInBackground = false
    /// Whether the PDF reader's pages have the keyboard — `EditorPDFViewState.hasFocus`, copied
    /// here by `onReceive` so ⌘+ ⌘− ⌘0 can follow it (`shortcutPDFZoom`). Copied rather than read
    /// through the view state, which this window must not observe: it moves on every scroll.
    @State var editorPDFReaderFocused = false
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
    /// What happened to the open document's file elsewhere — a reload, a banner, a move followed.
    /// Owned by the app beside the document it watches; see `EditorDiskWatch`.
    @ObservedObject var editorDiskWatch: EditorDiskWatch
    /// Source / Preview / Split for the open document.
    ///
    /// Window state, not a persisted preference: the mode is a fact about the file you are looking
    /// at, and remembering it would open the next document in whatever mode the last was left in.
    /// Held here, not in the workspace view, because that view is torn down on every tab switch.
    @State var editorMode: EditorMode = .edit
    /// How the editor's split divides its column. Beside `editorMode` because the two describe the
    /// same reading session, and the workspace view that draws them is rebuilt on every tab switch.
    @State var editorSplitFraction: CGFloat = EditorLayoutMetrics.splitStart

    // MARK: The ⌘K palette (ROADMAP 14)

    /// Raises and dismisses the palette. A `@StateObject` because it owns an `NSPanel` and a set of
    /// observers that must outlive a body pass — see `CommandPalettePanel.swift` for why the
    /// palette is a window rather than an overlay on this view.
    @StateObject var palettePanel = CommandPalettePanelController()
    /// Whether the palette is up. Not the source of truth — the panel is — but the menu chords are
    /// suspended off it (`ShortcutValuePublisher.suspended`), so the controller's single
    /// `onDismiss` keeps it in step. The query and selection live with the panel; a copy here would
    /// be a second answer to what was typed.
    @State var showCommandPalette = false
    /// Ask Claude's panel and its chat. One chat for the window: it follows the person across
    /// workspaces and tabs. Held without observing it: see `AskClaudeChatHolder`.
    @StateObject var askClaudeHolder = AskClaudeChatHolder()

    /// Organize's rail selection, as `@AppStorage` rather than raw `UserDefaults`: `@AppStorage`
    /// keeps a process-wide storage location per (store, key) and can lose a raw standard-domain
    /// write outright, and `LensWorkspaceView` holds this key in `@AppStorage`. Writing through the
    /// same wrapper puts both on one location.
    ///
    /// The scope's write goes through ``setOrganizeScope(_:providerRoot:)``, the one writer;
    /// `theRouteCannotMintASecondEncodingOfTheGlobalView` pins that.
    @AppStorage(OrganizeLens.defaultsKey) var paletteRailLens: OrganizeLens?

    @AppStorage("selectedLeftProviderId") var leftProviderId: String = "iCloud"
    /// To File's File Into choices, source id → folder, as JSON. See `ContentView+FileInto`.
    @AppStorage(FilingDestinationRoot.storedKey) var toFileDestinationsJSON: String = ""
    /// Text ▸ Edit in Preview (Experimental): whether Preview has a text view for the Markup and
    /// find items to act on — read here so the menus follow the switch at once.
    @AppStorage(EditorTextSettings.editsInPreviewKey) var editsInPreviewSetting = EditorTextSettings.editsInPreviewDefault
    /// The workspace's 256 KB decision for the open note, handed up when it is taken, so the menus
    /// agree with the Preview they act on without this view observing the buffer.
    @State var editorPreviewLengthHold: PreviewLengthHold?
    @AppStorage("selectedRightProviderId") var rightProviderId: String = "iCloud"
    @State var isScanning = false
    /// `syncManager.isScanShown`, mirrored like `isScanning` so the swap animates: what Compare's
    /// busy surfaces draw from — the scanning card and the panes' Stop rung. A scan that ends
    /// inside `FileSyncManager.defaultScanShownAfter` reaches neither. `isScanning` stays what the
    /// commands decide by, because whether ⌘R may start a scan is not a question of display.
    @State var isScanShown = false

    /// The retired welcome tour's seen flag, still read and never written.
    ///
    /// It now means "this person has already been greeted": every machine that ran a build before
    /// the setup form carries it, so `SetupFlow.shouldAutoShow` uses it to refuse to open the form
    /// over somebody's working app. A fresh install has it false and gets the form; Help ▸ Set Up
    /// SyncCloud… ignores it.
    @AppStorage(SetupFlow.legacyWelcomeSeenDefaultsKey) private var hasSeenFirstRunWelcome: Bool = false
    /// Set when the user reaches the end of the setup form. Persisted, so it never auto-opens twice.
    @AppStorage(SetupFlow.hasCompletedDefaultsKey) private var hasCompletedSetup: Bool = false
    /// Whether setup has been dismissed for the rest of this session. App-owned (a binding) like
    /// `hasBootstrappedSession`, so a form answered *Not Now* does not come back when the window
    /// reopens.
    ///
    /// Separate from `hasCompletedSetup`: *Not Now* hides it for this session and leaves the
    /// persisted flag alone, so the form offers itself again on the next launch of a machine still
    /// not set up.
    @Binding var setupDismissedThisSession: Bool
    /// Whether Help ▸ Set Up SyncCloud… asked for the form explicitly. App-owned so the menu
    /// command, which lives in the App scene, can set it.
    ///
    /// The explicit latch is what makes the form reachable after it has been completed: the
    /// auto-show gate refuses a machine already set up, which is right for a launch and wrong for a
    /// menu item.
    @Binding var showSetup: Bool

    /// Number of provider-id `onChange` notifications still expected from an in-flight pane swap. A
    /// swap flips both @AppStorage ids at once, which would fire both onChanges and drive two
    /// navigation resets that wipe the focus and selection the swap just moved. Each suppressed
    /// onChange decrements this; the swap seeds it with the number of ids that actually change (2,
    /// or 0 when both panes share a provider), so later real provider switches are never
    /// suppressed.
    @State private var pendingSwapProviderChanges: Int = 0

    /// The same counter for a tab switch, which also writes a provider id behind the user's back
    /// and must not have `retargetPane()` run over the navigation it just restored.
    ///
    /// Separate from the swap's, and not private because `ContentView+PaneTabs` writes it: one
    /// shared counter would let a swap consume a tab switch's suppression, or the reverse.
    @State var pendingTabProviderChanges: Int = 0

    /// View ▸ Tab Bar. Off by default: the strip appears when a second tab does, as in Finder, so
    /// an install that never opens one is unchanged. Ticking it keeps a one-tab strip (and its ＋)
    /// on screen.
    ///
    /// App-wide rather than per pane, like the shared column width: "do I want a tab bar" is a
    /// question about the app.
    @AppStorage(BrowseWindowSettings.tabBarVisibleKey) var tabBarVisible: Bool = BrowseWindowSettings.tabBarVisibleDefault
    /// View ▸ Status Bar. On by default, unlike the tab bar: the strip states facts the window has
    /// nowhere else to put (how many items are here, how much of the tree lives in the cloud), and
    /// costs one 10pt row.
    ///
    /// App-wide, for the tab bar's reason. It is drawn only in Browse (see `PaneStatusBar`); a bar
    /// drawn elsewhere later should read this same key.
    @AppStorage(BrowseWindowSettings.statusBarVisibleKey) var statusBarVisible: Bool = BrowseWindowSettings.statusBarVisibleDefault
    /// The folder sidebar's column. On by default, so the pinned and recent lists are discoverable.
    ///
    /// One preference across every workspace that draws the column
    /// (`Workspace.supportsFolderSidebar`); `folderSidebarIsShowing` is the one rule that reads it.
    /// The key keeps its `browse` spelling: renaming it would re-default the column to `true` for
    /// everyone who switched it off.
    @AppStorage(BrowseWindowSettings.sidebarVisibleKey) var browseSidebarVisible: Bool = BrowseWindowSettings.sidebarVisibleDefault
    /// Edit's own sidebar switch, off until shown: Edit opens on the strip and the text, and ⌃⌘S
    /// there does not move the sidebar in Browse, Compare or Organize, which share
    /// `browseSidebarVisible` above. See `folderSidebarPreference`.
    @AppStorage("editorSidebarVisible") var editorSidebarVisible: Bool = false
    /// Edit's side-column width, one for the pane and the list's three tabs: dragged at the open
    /// column's edge, so whichever is showing, the column is the same width. Floor and default
    /// `EditorLayoutMetrics.railWidth`; see `editorColumnWidth(in:)`.
    @AppStorage("editorColumnWidth") var editorColumnWidthRaw: Double = Double(EditorLayoutMetrics.railWidth)
    /// The width at the start of a drag of that edge — `folderSidebarDragOrigin`'s reason.
    @State var editorColumnDragOrigin: CGFloat?
    /// The sidebar's width, dragged by the user and clamped to
    /// `FolderSidebarView.minWidth ... .maxWidth`. Stored as a `Double` because `@AppStorage`
    /// has no `CGFloat` overload.
    @AppStorage("browseSidebarWidth") var browseSidebarWidthRaw: Double = 180
    /// Which sections are folded, comma-joined — see `folderSidebarCollapsedSections`.
    @AppStorage("browseSidebarCollapsed") var browseSidebarCollapsed: String = ""
    /// Which list the sidebar's Recents heading shows — `RecentsMode`'s raw value. One sidebar-wide
    /// setting, remembered across launches like the folded sections.
    @AppStorage(BrowseWindowSettings.sidebarRecentsModeKey) var browseSidebarRecentsMode: String = RecentsMode.recents.rawValue
    /// Which places sit in Favorites, JSON-encoded — see `SidebarFavoritePlaces`. Empty means the
    /// key has never been written, which is not the same as "no favorites"; that distinction is
    /// what lets a first run get Desktop, Documents and Downloads while someone who removed all
    /// three keeps them removed.
    @AppStorage("browseSidebarFavoritePlaces") var browseSidebarFavoritePlacesRaw: String = ""
    /// The sidebar's rows, resolved rather than recomputed in `body`.
    ///
    /// `FolderJumpStore.reachable` touches the disk, one `stat` per folder, and the root's can
    /// block for seconds under a network mount that has gone away. Fine once per ⌘K open; in a view
    /// body it would run on every render. Refreshed at the four moments the answer can change
    /// instead: appearing, the provider changing, the pane moving, and the store publishing a pin
    /// or a visit.
    @State var folderSidebarRows: [FolderSidebarRow] = []
    @State var folderSidebarLocationRows: [SidebarSourceRow] = []
    /// The mount points a row may be ejected from, resolved with the rows rather than in the view
    /// body.
    ///
    /// Inline, a `mountedVolumeURLs` call plus a `resourceValues` read per volume would run on
    /// every evaluation of the sidebar's body (hover, drag, selection change), and a resource read
    /// can block under an unresponsive network mount. Resolved on the rows' pass, it runs when the
    /// volumes can actually have changed.
    @State var folderSidebarEjectablePaths: Set<String> = []
    /// The narrower half: where an unmount actually forgets the sources.
    ///
    /// Eject is offered on anything Finder would eject, network shares included; a share is not
    /// local, so unmounting it leaves its sources in place. The confirmation must know which it is
    /// looking at, or it promises a removal that will not happen. Resolved on the rows' walk, from
    /// `SidebarSourceModel.Volume.losesItsSourcesOnUnmount`, so the sentence the user reads and the
    /// rule `MountedVolumeMemory` applies are one rule.
    @State var folderSidebarDetachablePaths: Set<String> = []
    @State var folderSidebarShortcutRows: [SidebarSourceRow] = []
    /// The comparison Compare owes, and why — one record for every way Compare's list falls behind
    /// the disk, paid in one place (`payOwedComparisonIfNeeded`). See `OwedComparison`.
    ///
    /// View `@State` rather than manager state because it records a fact about the workspace:
    /// nothing in `FileSyncManager` knows which workspace is on screen, and the debt exists only
    /// because a single-source workspace cannot display the answer.
    @State var owedComparison = OwedComparison()

    /// The switch the sidebar refresh coalesces on, in a box rather than a `@State` value: it is
    /// written and read back across a main-actor hop, and SwiftUI's `@State` storage promises only
    /// about rendering, while a reference's property reads back what was written. `@State` still
    /// holds the box, for this view's lifetime.
    @State var sidebarRefresh = SidebarRefreshState()

    /// The box behind ``ContentView/sidebarRefresh``.
    final class SidebarRefreshState {
        /// The ticket the sidebar refresh coalesces on. Bumped by every call to
        /// `refreshFolderSidebarRows` and checked twice by the call that wins: after the hop to the
        /// next main-actor turn, which collapses the calls one workspace switch fires into one
        /// walk, and after the walk returns, so an overtaken answer is not drawn over a newer one.
        ///
        /// `&+=` rather than `+=`: it is bumped on every pane move for the window's life, and
        /// trapping at `Int.max` for an "is this still the newest" comparison would be a crash
        /// standing in for a harmless wrap.
        var ticket = 0
    }

    /// A promotion that can still be taken back, until the next one or a workspace change.
    @State var folderSidebarNotice: FolderSidebarNotice?
    /// The sidebar width when the current resize drag began — see `folderSidebarResizeHandle`.
    @State var folderSidebarDragOrigin: CGFloat?

    /// Active "compare two duplicate copies" handoff from the Duplicates lens: the keeper (left
    /// pane) and the redundant copy (right pane) open in Compare, plus the duplicate scan root to
    /// re-scan once the right copy is trashed. Drives the keep-left / trash-right banner over
    /// Compare; nil when no review is in progress. App-owned (a binding) so it outlives this view:
    /// losing the review while its provider pins persist in @AppStorage would strand the panes on
    /// the duplicate's provider with no banner, no Done button and no restore snapshot.
    @Binding var duplicateReview: DuplicateCompareContext?

    /// The app's text scale. Read here rather than off `UserDefaults` in the toolbar because the
    /// workspace bar's shedding rule depends on it: a direct defaults read never invalidates, so
    /// raising Settings ▸ Text size would leave the bar claiming its labels still fit.
    @Environment(\.appFontScale) var appFontScale
    @Environment(\.undoManager) var undoManager
    @Environment(\.openWindow) var openWindow

    /// Shared geometry for the workspace bar's selected-segment fill, so the accent capsule travels
    /// between segments instead of being cut out of one and into the next. Declared here because
    /// `@Namespace` is a stored property and the bar lives in an extension (`ContentView+Toolbar`).
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
    /// Guided-review state, owned by the App (like `duplicateReview`) so it outlives
    /// DifferencesView — which unmounts on a Details-tab peek and whenever the differences list
    /// goes empty, while the session and any in-flight copy's outcome must survive — and this view,
    /// should it be rebuilt (see `hasBootstrappedSession`).
    @ObservedObject var reviewStore: ReviewSessionStore
    /// Files handed over from Finder, the Dock or `open -a`, waiting for this window to open them in
    /// Edit. The app delegate's, because it outlives the window — see ``ExternalOpenQueue``.
    @ObservedObject var externalOpens: ExternalOpenQueue
    /// Whether this run's launch bootstrap has finished — the delegate's, because this view's own
    /// `isBootstrappingProviders` can be lowered early by a second `onAppear`. See ``LaunchBootstrap``.
    @ObservedObject var launchBootstrap: LaunchBootstrap

    /// Read here purely to drive the theme applier below — unlike the other Appearance keys,
    /// nothing in this view renders from it; the appearance lives on NSApp, not in the view tree.
    @AppStorage(LiquidGlass.appearanceModeKey) private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    // Not `private`: the split-layout extension lives in another file and reads it for the rail
    // spine's card, and `private` is invisible to a same-type extension across files.
    @AppStorage(LiquidGlass.tintKey) var surfaceTint: Double = 0

    /// Left pane's share of the pane row's width (0…1), persisted across relaunches. Drives a
    /// custom two-pane split rather than HSplitView, whose NSSplitView divider bleeds up through
    /// the `.hiddenTitleBar` toolbar band; an HStack and divider respect the toolbar's safe area,
    /// so the divider starts at the pane headers.
    @AppStorage("mainPaneSplitFraction") var paneSplitFraction: Double = 0.5
    /// Live split fraction while the divider is dragged; nil when idle. Kept in @State so a drag
    /// updates smoothly without rewriting @AppStorage every frame; persisted once, on drag end.
    /// `mainContentView` reads this in preference to `paneSplitFraction` mid-drag.
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

    /// The single-source rail's share of the content width when expanded (the lens workspaces).
    /// Persisted like the other split fractions; the workspace fills the rest.
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
    // Not `private`: the split-layout extension (ContentView+SplitLayout.swift) paints its seam
    // chrome (swap button, rail spine) with the same user-selected hue.
    var glassHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: glassHueRaw) ?? .blue
    }

    /// The selected workspace, persisted so a session resumes where it left off, stored by
    /// ``Workspace`` raw value (pinned by `WorkspaceTests`). Internal for the toolbar's workspace
    /// bar.
    ///
    /// `.browse`: where a first run lands and where an unreadable stored value lands, one constant
    /// for both. The welcome strip leads with Browse to match (`theWelcomeStripOpensWhereTheAppDoes`).
    @AppStorage(Workspace.defaultsKey) var selectedWorkspace: Workspace = .browse
    /// Which lens is showing inside Organize, or `nil` for its overview.
    ///
    /// Lives beside the workspace rather than in `LensWorkspaceView` because programmatic
    /// navigation writes it: "Find duplicates of this" names a lens, which is one rail item inside
    /// Organize. `LensWorkspaceView` reads the same key through its own `@AppStorage`, so the two
    /// cannot disagree.
    @AppStorage(OrganizeLens.defaultsKey) var selectedOrganizeLens: OrganizeLens?
    /// Set while a ⌘F query has been turned into a person gather. Clearing it returns the pane to
    /// whatever it was showing — the gather is a lens over the source, not a place you navigate to.
    @State var personScope: PersonScope?

    /// The subtree Organize is answering about; empty is the global view, and the default. Beside
    /// the lens selection because programmatic callers set it before any scan runs.
    /// `LensWorkspaceView` reads the same key through its own `@AppStorage`.
    ///
    /// Never written directly — see ``setOrganizeScope(_:providerRoot:)``, which stores
    /// ``OrganizeScope/normalizedPath(_:providerRoot:)`` so the global view has one representation.
    @AppStorage(OrganizeScopeDefaults.pathKey) var organizeScopePath: String = ""

    /// The lens the selected workspace shows, or `nil` on Compare. Derived, not stored: a second
    /// copy of the selection would be a second thing to keep in step.
    var selectedLens: WorkspaceLensKind? { selectedWorkspace.lens }

    /// The file a pane row's "Find duplicates of this" asked the Duplicates lens to reveal.
    ///
    /// Held here, not in `LensWorkspaceView`, because the workspace switch that carries the user
    /// there mounts that view: state set on the way in has to outlive the mount. Not persisted — it
    /// names a scan that exists only in this session.
    @State var duplicateRevealRequest: DuplicateRevealRequest?

    /// The file pair the Compare Copies surface is open on, if any. Held at the window because
    /// macOS clamps a sheet to its host window's width, and the lens is only part of it (1080×760
    /// with room, 712×512 at the floor). Not private: a file opened from Finder closes it
    /// (`closeViewersForExternalOpen`).
    @State var compareFilePair: DuplicateComparePair?

    /// The same surface, opened on a changed row from the Differences list. Two states rather than
    /// one sum type: the two hosts carry different payloads and mean different verdict bars, and a
    /// shared case would be unwrapped at every use anyway. Not private: a file opened from Finder
    /// closes it (`closeViewersForExternalOpen`).
    @State var compareDifferencePair: DifferencePair?

    /// The file armed for comparison, waiting for the click that names its counterpart — see
    /// ``ComparePick``. Kept out of every selection, because `PaneLogic.applySelectionWrite`'s
    /// one-pane-selected invariant would clear it on the very click meant to complete it.
    @State private var comparePick: ComparePick?

    /// Both rungs of the toolbar row, resolved together from the window's width — see
    /// `WorkspaceBarMetrics.styleSet`.
    ///
    /// One value, so the workspace bar and the Go-to control cannot each conclude they fit the
    /// width the other is spending; the closed/open pair, because the field opens on a keystroke
    /// and its answer must already be in hand. The styles, not the width, so a live resize writes
    /// this only when the labels shed. `.onGeometryChange` rather than a `GeometryReader`
    /// preference: it fires outside layout, avoiding AppKit's constraint-loop crash.
    @State var toolbarStyleSet = ToolbarBarStyleSet(
        closed: ToolbarBarStyles(workspace: .iconOnly, search: .compact),
        open: ToolbarBarStyles(workspace: .iconOnly, search: .compact,
                               field: GoToFieldLayout(width: GoToFieldMetrics.floorWidth,
                                                      placeholder: .short)))
    /// Whichever of the two the row is actually wearing right now.
    var toolbarStyles: ToolbarBarStyles {
        if let held = activityPopoverStyles { return held }
        return toolbarStyleSet.resolved(fieldOpen: showCommandPalette, runShowing: runCapsuleShowing,
                                        messageShowing: capsuleShowsMessage)
    }
    /// The row as it was when Activity's popover opened under the capsule, held until it closes:
    /// nothing moves under the popover, not when its last run ends and not when its message leaves.
    @State var activityPopoverStyles: ToolbarBarStyles?
    /// A pane-launched PDF tool run or Save as PDF showing in the toolbar capsule — reported by
    /// `RunCapsulePresence`, so this view need not observe the PDF models.
    @State var paneRunShowing = false
    /// Whether the capsule holds a message — its own, or a run's ending it mirrors from a pane.
    var capsuleShowsMessage: Bool {
        guard let banner = syncManager.banner else { return false }
        return resultMessageHome == .toolbar || capsuleMirrorID == banner.id
    }
    /// Whether the toolbar seats the progress capsule.
    var runCapsuleShowing: Bool { syncManager.activeProgress != nil || paneRunShowing }
    /// Why writes wait while a long run is going — "Wait for the merge to finish" — or `nil`. Read
    /// from the run itself; published to every write control as `runWriteLock`. The pane PDF runs
    /// and Save as PDF do not lock: they only add a file of their own beside its original.
    var runWriteLockReason: String? {
        syncManager.activeProgress.map { $0.runLockReason ?? Progress.genericRunLockReason }
    }
    /// A write reached by a route the lock cannot grey — a key, or a menu item whose own item stays
    /// live — refused with the reason in the banner, as `FileActionHandler` does for its own.
    func refusedWhileRunLocked() -> Bool {
        guard let reason = runWriteLockReason else { return false }
        syncManager.banner = .warning(reason)
        return true
    }
    /// What is typed in the toolbar's Go-to field. Held here rather than in the panel's state so
    /// the field can redraw (its trailing key becomes a clear button), and in an object this view
    /// holds but does not observe, so a keystroke redraws the field and not the window.
    /// `GoToFieldHost` is its only observer.
    @State var goToQuery = GoToQuery()
    /// Bumped to claim the caret: on open, and again on ⌘K while already open — where it also
    /// selects what is there, so the next keystroke replaces it.
    @State var goToFocusToken = 0

    /// Per-workspace override of the top-pane visibility, a JSON map (workspace raw value →
    /// hidden). Empty means "no overrides — every workspace uses its default". Persisted, so
    /// deliberately showing or hiding the panes on a workspace sticks across launches.
    @AppStorage(TopPaneVisibility.overridesKey) private var topPaneOverridesRaw: String = ""

    /// "Just the text": the editor's file rail withheld, Expand's bit. Read only while the editor's
    /// source pane is collapsed (`TopPaneVisibility.editorRailIsDrawn`); opening the pane by hand
    /// clears it, which ends Expand (`EditorExpand.paneOpenedByHand`). Persisted like the pane
    /// override above.
    @AppStorage(TopPaneVisibility.editorRailHiddenKey) var editorRailHidden: Bool = false
    /// The Text Files list folded into the strip by hand — the strip's buttons, the list's fold
    /// button and View ▸ Text Files move it. Separate from Expand's bit, so folding the list does
    /// not light Expand, and leaving Expand gives back a list folded by hand still folded.
    @AppStorage(TopPaneVisibility.editorRailFoldedKey) var editorRailFolded: Bool = TopPaneVisibility.editorRailFoldedDefault
    /// Expand's record of what it put away — see `EditorExpand`, the only thing that writes them.
    @AppStorage(TopPaneVisibility.editorExpandSidebarPutAwayKey) var editorExpandSidebarPutAway: Bool = false
    @AppStorage(TopPaneVisibility.editorExpandFoldedPaneKey) var editorExpandFoldedPane: Bool = false


    /// Whether the Compare Info inspector is shown: a toggleable right-side panel with metadata
    /// (and both-sides status) for the current selection. Persisted across launches. Internal, not
    /// private: its toggle sits in the window toolbar (ContentView+Toolbar.swift).
    @AppStorage("showCompareInspector") var showInspector: Bool = false
    /// Ask Claude pinned as the window's right-hand column, and its width. Both are the pin's own
    /// settings, apart from the floating panel's place and width. The 📌, View ▸ Pin Ask Claude and
    /// Settings ▸ Ask Claude turn it on.
    @AppStorage(AskClaudePanelSettings.pinnedKey) var askClaudePinned: Bool = false
    @AppStorage(AskClaudePanelSettings.pinnedWidthKey) var askClaudePinnedWidth: Double = 372
    @State var askClaudePinnedDragWidth: Double?
    /// The width the workspace and the pinned column share, measured, and whether the column
    /// fits in it (`PaneLogic.pinRoom`). Floating until the first measure.
    @State var askClaudeRowWidth: CGFloat = 0
    @State var askClaudePinState = PaneLogic.PinVerdict.floating
    /// The window's own edge is being dragged: the panel does not switch until it is let go.
    @State var askClaudeWindowResizing = false
    /// The pin is folding Organize's folder pane or Edit's list (its fold is computed, never stored):
    /// the person opened it by hand, which ends the pin's fold until the column goes or there is
    /// room again, and the sidebar they brought back alone while Organize's pane is folded.
    @State var askClaudePinFoldReleased = false
    @State var askClaudePinSidebarShown = false
    /// The Info inspector's persisted width, resizable by dragging its leading edge. 360pt until
    /// dragged, wide enough for the preview to read a page. Clamped to
    /// `PaneLogic.inspector{Min,Max}Width` whenever it's written.
    @AppStorage("compareInspectorWidth") var inspectorWidth: Double = 360
    /// The inspector preview's downloads, owned here so a "Downloading…" outlives the preview,
    /// which is taken down whenever the inspector shows a folder or folds the picture away.
    /// `@State` on a class, for `lensSession`'s reason: owned, not observed.
    @State private var inspectorDownloads = InspectorDownloads()
    /// The Get Info target as a node of its own, for one no pane's tree holds — a differences row
    /// outside the folder the pane is in, a file the pane's filter hides. Made when Get Info is
    /// chosen, never in `body`, and read only while its path is still the target.
    @State private var infoNode: FileNode?
    /// The live width during a resize drag; `nil` when idle. Mirrors the pane splits' pattern —
    /// the layout reads `inspectorDragWidth ?? inspectorWidth`, and the drag commits to
    /// `inspectorWidth` only on release, so `inspectorWidth` stays the stable drag-start base.
    @State var inspectorDragWidth: Double? = nil
    /// The preview's share of the Info inspector's height: set by dragging the bar under it, kept
    /// across launches, and most of the panel until the user says otherwise.
    @AppStorage("infoInspectorPreviewFraction") private var inspectorPreviewFraction: Double =
        DetailsSidebar.defaultPreviewFraction
    /// Per-pane action-bar placement scratch space. `FileTreeView` fills each with live row/viewport
    /// geometry; `paneColumn` reads the resolved edge straight from `body`, so the bar's edge is
    /// known synchronously the instant the selection changes — no gate, no show-then-flip.
    @State var leftPlacement = PaneBarPlacement()
    @State var rightPlacement = PaneBarPlacement()
    /// Where each pane's columns were scrolled, kept here for `leftTreeExpanded`'s reason: this
    /// view outlives a workspace switch and the pane does not. See `PaneScrollMemory`.
    @State private var paneScrollMemory = PaneScrollMemory()
    /// Orders the deferred cross-pane selection clears, so a clear queued by one pane's click can
    /// never wipe a selection a later click made in the other pane. See
    /// `PaneLogic.applySelectionWrite`.
    @State private var selectionSequencer = PaneSelectionSequencer()
    /// A pure re-render trigger for scroll-driven edge flips: `FileTreeView` mutates the placement
    /// (a class, so no invalidation) and calls back to toggle this, which re-renders `paneColumn`
    /// so it re-reads the flipped edge, animated. Selection changes re-render on their own.
    @State var leftBarAtTop = false
    @State var rightBarAtTop = false
    /// The tab strip kept under the pointer after a click closed it down to one tab — see
    /// `PaneTabStripHold`.
    @State var tabStripHold = PaneTabStripHold()
    /// Whether the pointer is on each pane's strip — a reference, so crossing a strip re-renders
    /// nothing. Read only when a close asks whether to hold.
    @State var tabStripPointer = PaneTabStripPointer()
    /// An explicit "Get Info" target for the inspector, from a pane or differences-row right-click.
    /// Overrides the pane selection; cleared when the pane selection changes so the inspector then
    /// follows the selection again.
    @State private var infoPath: String? = nil

    @State var bannerDismissScheduler = BannerDismissScheduler()
    /// Where the reader last clicked in Organize and Edit — their source pane, or the lens or
    /// editor beside it — so a result message shows where they were working. See
    /// `ResultMessageRoute`.
    @State var resultMessageInPane = false
    /// The doors a pane-launched PDF tool's or Save as PDF's result hands to its message's
    /// follow-up buttons, for the message it was posted as. See `postPaneToolResult`.
    @State var paneToolResultDoors: PaneToolResult?
    /// The message the toolbar's capsule shows instead of a pane: a long run's ending after the
    /// reader moved to another workspace.
    @State var capsuleMessageID: UUID?
    /// The capsule message folding into its ring on its way into Activity (`retireResultMessage`).
    @State var capsuleFoldingID: UUID?
    /// A run's ending a pane shows, which the capsule mirrors until it goes (`mirrorsInCapsule`).
    @State var capsuleMirrorID: UUID?
    /// Where each long run was started, for its ending's route.
    @State var fileOperationOrigin: Workspace?
    @State var paneToolOrigin: Workspace?
    @State var saveAsPDFOrigin: Workspace?
    /// The origin of the pane result being posted, read once by `resultMessageChanged`.
    @State var pendingResultOrigin: Workspace?
    /// Whether "Save as rule…"'s offer is open over its message — the message is held until it
    /// closes (`BannerDismissScheduler.holdChanged`).
    @State var ruleOfferIsOpen = false

    // Per-pane diff lookups for the tree rows, rebuilt only when the differences or pane roots
    // change, not per render: the panes re-render per file during bulk sync, and a rebuild walks
    // every difference's ancestor chain.
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
    /// The results those queries produced, recomputed off the debounce rather than per render: a
    /// query runs over the whole loaded tree, and this `body` is re-evaluated by any of the
    /// manager's many published properties.
    @State var leftSearchResults: PaneSearchResults = .empty(side: .left)
    @State var rightSearchResults: PaneSearchResults = .empty(side: .right)
    /// The recomputation counter behind `PaneSearchResults.generation`. One per side, like the
    /// manager's own publish counters, so a stamp is only compared against its own pane's.
    @State var leftSearchGeneration = 0
    @State var rightSearchGeneration = 0
    /// Each pane's file-type counts while it has no type filter, for the type list. With a filter
    /// on, the manager's pass counts instead. See `ContentView+TypeFilter.swift`.
    @State var leftTypeCensus: PaneTypeFilterFacts?
    @State var rightTypeCensus: PaneTypeFilterFacts?

    /// Each pane's presentation, stored per side so one can be a deep tree while the other is flat.
    /// Defaults to Columns, which rests as a single full-pane column.
    @AppStorage(PaneViewMode.defaultsKey(isLeft: true)) private var leftViewModeRaw = PaneViewMode.default.rawValue
    @AppStorage(PaneViewMode.defaultsKey(isLeft: false)) private var rightViewModeRaw = PaneViewMode.default.rawValue
    /// The single-source rail's own presentation, on its own key so switching a comparison pane
    /// never restacks the rail. Columns by default, like the panes: a resting Columns pane is one
    /// full-width column, so one click opens a folder instead of needing the row menu's Open.
    @AppStorage(PaneViewMode.railDefaultsKey) private var railViewModeRaw = PaneViewMode.default.rawValue
    /// Browse's own presentation, on its own key for the rail's reason: Browse draws the same pane
    /// at full window width instead of in a 220pt column, and a stack chosen for one is not a
    /// choice about the other. Sharing the rail's key would let flipping Browse to Tree silently
    /// restack Organize.
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
    /// One member, deliberately: three surfaces draw `FileTreeView` (the comparison panes, the
    /// single-source rail, and Browse), and a ternary restated at each call site invites missing
    /// one, which would show Browse in the rail's stack and write the user's choice into the rail's
    /// key.
    func resolvedViewMode(isLeft: Bool) -> PaneViewMode {
        viewMode(in: selectedWorkspace, isLeft: isLeft)
    }

    /// The presentation `workspace` draws its pane in, whichever workspace is on screen — for acts
    /// that move the pane on another workspace's behalf: a hand-off into Edit asks Edit's
    /// (`railViewMode`), Reveal in Browse asks Browse's. `resolvedViewMode` would answer for the
    /// workspace being left, and the two can disagree about the same pane: the column stack is
    /// shared and only parked while Tree is drawn.
    func viewMode(in workspace: Workspace, isLeft: Bool) -> PaneViewMode {
        if workspace == .browse { return browseViewMode }
        return TopPaneVisibility.mode(for: workspace) == .singleSource ? railViewMode : paneViewMode(isLeft: isLeft)
    }

    /// Whether that presentation draws the pane's column stack. The header's path, the tab chip,
    /// crumb and quick-jump routing, `‹`/`›`, the lens scan target and New Folder all turn on it
    /// (see `FileSyncManager.paneLocation(isLeft:drawsColumns:)`): in Tree the stack is parked and
    /// describes a folder not on screen.
    func paneDrawsColumns(isLeft: Bool) -> Bool {
        resolvedViewMode(isLeft: isLeft) == .columns
    }

    /// The destination question on screen, if any. Held here because both surfaces that raise it —
    /// the single-source rail's row menu and an Organize card's "Choose folder…" — are children of
    /// this view.
    @State var pendingDestination: PendingDestination?
    /// The recents the on-screen picker was opened with.
    ///
    /// Snapshotted when the card is raised, not read in its body: `DestinationRecents.load` stats
    /// every stored path to prune dead ones, and a body reads on every render. The list also must
    /// not shift under the user mid-decision; a destination is recorded on commit, when the card is
    /// gone.
    @State var pendingRecents: [String] = []
    /// The sidebar's Favorites, Recents and Locations the on-screen picker was opened with,
    /// snapshotted with the recents and for the same reason.
    @State var pendingPlaces: [DestinationPlaceSection] = []

    /// Raises the picker, whoever asked for it. The one place `pendingDestination` is set, so the
    /// recents snapshot can never drift out of step with the request it belongs to.
    func presentDestination(_ pending: PendingDestination) {
        // The palette is a real window that holds key, while the picker is an overlay inside the
        // host, so raising one under the other would leave the picker unable to take a keystroke or
        // a click: its buttons, ↩ and esc would go to the palette's field.
        //
        // Both current callers are mouse gestures inside the content, which land on the panel and
        // dismiss it already. This line keeps a new caller, or a keyboard route to the picker, from
        // inverting the ownership silently. `toggleCommandPalette` blocks the other order.
        palettePanel.dismiss()
        pendingRecents = DestinationRecents.load(providerRoot: pending.request.providerRoot)
        pendingPlaces = destinationPlaceSections()
        pendingDestination = pending
    }

    /// Raises the picker for a rail selection, and runs the transfer into whatever it returns.
    ///
    /// Routes through `moveItems(_:toPath:)` / `pasteItems(_:toPath:isCut:)`, the
    /// explicit-destination entry points drag-and-drop uses, rather than the cross-pane transfer,
    /// which derives its own destination and would ignore the folder just chosen.
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
        // No provider root (an unconfigured provider path) means there is nothing to browse:
        // `subfolders` refuses an empty root, and the column stack resolves one against "/", so the
        // card would offer the whole filesystem with a permanently empty first column. The system
        // panel is the honest surface for that, and costs the user nothing.
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
                // The selection's own parent, not the rail's current directory. In Columns,
                // clicking a folder drills into it, so the current directory is the folder being
                // moved, and opening there would land the picker inside the selection with the
                // nesting refusal. The parent is never inside the selection and is one click from
                // anywhere else.
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
    /// is held) — the rule the breadcrumb and the tree's drill-in follow, so all three ways of
    /// walking into a folder obey one setting.
    ///
    /// The mirror is pruned against the other pane's tree rather than copied outright. The two
    /// sides differ, so the folder just opened may not exist over there; pruning walks that pane as
    /// deep as it can and stops on the deepest folder the two still share, not on an empty column
    /// claiming a folder that isn't there.
    func applyColumnNavigation(_ path: PaneBrowsePath, isLeft: Bool) {
        // Walking onto another source's own root re-roots the pane there instead of showing it
        // nested under this one. Takes the navigation whole when it fires, so nothing below runs.
        if adoptSourceWalkedInto(path, isLeft: isLeft) { return }
        // Only the comparison layout has a sibling to mirror into; the single-source rail has none.
        // The link-or-⌥ test is the one the breadcrumb and the tree's drill-in apply.
        let mirror = layoutMode == .compare
            && (PaneLinkPreference.isLinked || NSEvent.modifierFlags.contains(.option))
        let otherRoot = isLeft ? currentRightPath : currentLeftPath
        syncManager.applyColumnNavigation(
            path,
            isLeft: isLeft,
            mirror: mirror,
            // The sibling's tree before its type filter: a folder that filter hides is still there.
            otherIndex: syncManager.mirrorChildrenIndex(isLeft: !isLeft, treeRoot: otherRoot),
            otherTreeRoot: otherRoot
        )
    }

    /// A column drill that walks into another source: point the pane at that source instead.
    ///
    /// `Home folder ▸ Dropbox ▸ Backup` carries Home folder's root, so the breadcrumb ceiling, scan
    /// scope and "source root" would belong to the wrong source. `PaneLogic.sourceRootedAt` holds
    /// the four conditions.
    ///
    /// Drills only, hence the depth check: ⌘↑, a crumb click and `handleBackgroundDeselect` come
    /// through the same door, and a click on empty space must never change the pane's source.
    ///
    /// A plain provider write, not the armed `adoptProviderForTab`: this wants exactly what
    /// `retargetPane()` does, so the pane ends up as if Dropbox were picked from the source menu
    /// (old Back stack gone, columns cleared, tree reloaded, selection dropped). Only this pane
    /// moves; the seam link does not apply, since the sibling is on a different source. Returns
    /// whether it took the navigation.
    func adoptSourceWalkedInto(_ path: PaneBrowsePath, isLeft: Bool) -> Bool {
        guard path.depth > paneStack(isLeft: isLeft).depth else { return false }
        let providerId = paneProviderId(isLeft: isLeft)
        // The pane's location as one absolute path: its root, its scope, its new stack. The scope
        // is joined in because a pane focused inside its source browses relative to that focus; the
        // stack alone names a folder too shallow.
        let absolute = PaneLogic.fullPath(
            root: settings.rootPath(for: providerId),
            relativePath: PathBoundary.joinRelative(paneScope(isLeft: isLeft), path.relativePath))
        guard let adopted = PaneLogic.sourceRootedAt(absolute,
                                                     currentProviderId: providerId,
                                                     among: settings.enabledProviders,
                                                     resolve: Self.resolved) else { return false }
        // Logged because this is the one navigation the user did not ask for by name: they clicked
        // a folder and the pane changed source. The provider handler's own "User switched …
        // provider" line, on its own, would describe a menu pick that never happened.
        let from = settings.availableProviders.first { $0.id == providerId }?.displayName ?? providerId
        Logger.shared.info(
            "The \(PaneSideChoice.name(isLeft)) pane walked into \(adopted.displayName)'s own root "
            + "at \(absolute) — re-rooting it there rather than showing it nested under \(from)")
        setFolderSidebarProvider(adopted.id, isLeft: isLeft)
        return true
    }

    /// A crumb click that must move both panes: the ⌥-click, and every plain click while the seam
    /// link is on. Hands the sibling's tree to the manager so the mirrored stack is pruned against
    /// the folders that pane really has, as a mirrored column drill is above.
    ///
    /// The root captured here is the sibling's root before the navigation, the one its current tree
    /// was loaded for; `navigateBothPanes` ignores it when that pane re-roots.
    func navigateBothPanes(toCombinedPath combined: String, from isLeft: Bool) {
        let otherRoot = isLeft ? currentRightPath : currentLeftPath
        syncManager.navigateBothPanes(
            toCombinedPath: combined,
            // Translated, because the two sources need not open at the same depth: iCloud lands at
            // its root and OneDrive two components in. The clicked pane's spelling would send the
            // sibling to a wrong or unrelated folder, and the comparison would diff the wrong pair.
            otherCombinedPath: relativePathForPane(combined, isLeft: !isLeft),
            from: isLeft,
            // Each side answers for itself — the presentation is a per-pane setting, so a linked
            // click can be a browse move on one side and a re-root on the other.
            drawsColumns: paneDrawsColumns(isLeft: isLeft),
            otherDrawsColumns: paneDrawsColumns(isLeft: !isLeft),
            // The sibling's tree before its type filter: a folder that filter hides is still there.
            otherIndex: syncManager.mirrorChildrenIndex(isLeft: !isLeft, treeRoot: otherRoot),
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

    /// The write side of ``resolvedViewMode(isLeft:)``, for the same reason: a reader that resolved
    /// Browse correctly paired with a writer that did not would show the right stack and store it
    /// in the wrong key.
    func resolvedViewModeBinding(isLeft: Bool) -> Binding<PaneViewMode> {
        if selectedWorkspace == .browse { return browseViewModeBinding }
        return layoutMode == .singleSource ? railViewModeBinding : paneViewModeBinding(isLeft: isLeft)
    }

    /// Everything the tree diff indices are derived from, as one Equatable value so a single
    /// task(id:) covers scan results, navigation, and provider switches.
    private struct DiffIndexInputs: Equatable, Sendable {
        let differences: [FileDifference]
        let leftRoot: String
        let rightRoot: String
    }

    private var diffIndexInputs: DiffIndexInputs {
        DiffIndexInputs(differences: syncManager.differences, leftRoot: currentLeftPath, rightRoot: currentRightPath)
    }

    /// Resolves the left and right provider IDs from the current list (after a provider list change
    /// or bootstrap).
    /// - Parameter preferDistinctPair: If `true`, when both sides would be the same, pick a
    ///   different provider for the right.
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

    /// Which panes a provider-list edit re-roots, or `nil` for neither. Compares identity fields
    /// only (id, root path, type): a rename must not read as a root edit, which would tear down an
    /// in-flight duplicate review and force a rescan. A side, not a Bool, so editing one pane's
    /// source never takes the other pane down.
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
            // The root, deliberately not the landing folder. A pane's tree is rooted at `rootPath`,
            // so moving that is a root edit and must tear the comparison down. Where a source opens
            // decides only where the next pane starts, so treating it as a root edit would throw
            // away an in-flight duplicate review for a preference the current panes never read.
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
    /// modifier chain stays under the Swift type-checker's budget: `mainContentView` is a heavy
    /// `some View`, and chaining everything on it in one expression times the checker out.
    private var chromedContent: some View {
        // No provider sidebar: provider choice rides on each pane and source header (ProviderMenu),
        // so the window is a single content column.
        mainContentView
            // The window's floor; `.windowResizability(.contentMinSize)` makes this frame a floor
            // rather than a suggestion.
            //
            // The width keeps the workspace bar's labels at every text size: a toolbar that does
            // not fit is folded behind an overflow chevron, hiding the workspace switch with no
            // error. Four labels need at most 785.6pt (Largest, counting
            // `WorkspaceBarMetrics.reservedChrome`'s 44pt for Ask Claude's button), leaving 18.4pt;
            // a fifth segment would need a wider floor. The icon-only rung is therefore unreachable
            // at any legal width (`testTheIconOnlyRungIsOutOfTheShippingBarsReachButStillLive`).
            //
            // The height keeps it a window: 560 less the header card's 86
            // (`LiquidGlass.headerHeight` 81 in 2×`cardInset`) and the action bar's 44 leaves the
            // file list about 430, and clears the 428pt below which `SettingsLayout` overflows the
            // window (`floorSize` 380 + `hostMargin` 48).
            .frame(minWidth: 804, minHeight: 560)
            // Resolved in the transform, so the action and the state write behind it fire only when
            // the answer changes. See `workspaceBarStyle`. The label widths are measured rather
            // than tabulated because the app scales its own type (Settings ▸ Text size): reading
            // `appFontScale` here rebuilds this closure on a scale change, where a constant would
            // be right at one setting only.
            .onGeometryChange(for: ToolbarBarStyleSet.self) { proxy in
                WorkspaceBarMetrics.styleSet(
                    contentWidth: proxy.size.width,
                    labelWidths: Self.workspaceLabelWidths(scale: appFontScale),
                    searchLabelWidth: CommandPaletteBarMetrics.labelWidth(CommandPaletteBar.label,
                                                                          scale: appFontScale),
                    searchKeycapWidth: CommandPaletteBarMetrics.keycapWidth(
                        symbol: AppChord.commandPalette.display, scale: appFontScale),
                    // The open field's key is `esc`, not ⌘K, measured from the same string the
                    // field draws so the reserve cannot be right for one and wrong for the other.
                    fieldKeycapWidth: CommandPaletteBarMetrics.keycapWidth(
                        symbol: GoToFieldMetrics.closeKeycap, scale: appFontScale),
                    scale: appFontScale)
            } action: { styles in
                toolbarStyleSet = styles
            }
            .toolbar { mainToolbar }
            .oneWaySyncSheets(host: .main)
            // A synced Dropbox file is changed in iCloud: the panes' rename, move and delete ask
            // first.
            .task {
                syncManager.oneWaySyncRefusal = { paths in OneWaySyncController.shared.refusal(forChanging: paths) }
                oneWaySync.onOpenActivity = { openActivityOnNow() }
                oneWaySync.onOpenHistory = {
                    ActivityCenter.shared.tab = .history
                    openWindow(id: ActivityCenter.windowID)
                }
                oneWaySync.onOpenSettings = { openSettings(on: SettingsPlace(.oneWaySync)) }
                // The sync's own writes are this process's, which the watcher doesn't report: the
                // walks listing them are dropped and the panes read again.
                oneWaySync.onWrote = { paths in
                    for path in paths { syncManager.prepareReread(afterWritingAt: path) }
                    // Only the pane that shows what was written reads again: usually Dropbox's.
                    let roots = [true, false].map { isLeft in
                        OneWaySyncDisk.canonicalPath(URL(fileURLWithPath:
                            (settings.rootPath(for: paneContext(isLeft: isLeft).providerId) as NSString).expandingTildeInPath))
                    }
                    func shows(_ isLeft: Bool) -> Bool {
                        let root = roots[isLeft ? 0 : 1]
                        return paths.contains { path in
                            let canonical = OneWaySyncDisk.canonicalPath(URL(fileURLWithPath: path))
                            return canonical == root || canonical.hasPrefix(root + "/") || root.hasPrefix(canonical + "/")
                        }
                    }
                    switch (shows(true), shows(false)) {
                    case (true, true): _ = refreshAction()
                    case (true, false): _ = refreshAction(reloading: .leftOnly)
                    case (false, true): _ = refreshAction(reloading: .rightOnly)
                    case (false, false): break
                    }
                }
            }
            // Ask Claude's panel is a child window over the content (AskClaudeWindow.swift). It
            // steps aside while Settings, Help, setup, a destination pick, a question or a sheet is
            // up, and ⌘J and its toolbar button are off then.
            .modifier(askClaudeHost)
            // Names the window on the two surfaces that read `NSWindow.title` whether or not a
            // title bar is drawn: the Window menu and Mission Control. Zero-sized and in the
            // background, because it is a binding to AppKit, not a view.
            .background(WindowChromeBinder(subtitle: windowSubtitleText).frame(width: 0, height: 0))
        // A PDF tool run from a row's menu: its sheet, and its progress at the window's foot; its
        // ending is the pane's result message. Ahead of the overlay chain below, so every panel in
        // it covers the progress, and not in the chain, because the sheet must not yield to them
        // (see `PanePDFToolsPresenter`).
        .modifier(PanePDFToolsPresenter(model: panePDFTools, saveAsPDF: paneSaveAsPDF,
                                        accent: glassHue.accentColor,
                                        onResult: { postPaneToolResult($0) }))
        .overlay {
            // The divergence diff leads, ahead of even the picker. Everything below is something
            // the user opened; this is a question they are in the middle of answering, with
            // autosave stopped by the latch until they do. A panel covering it would leave the
            // document silently not saving with its question drawn nowhere. Escape and a click on
            // the scrim answer Cancel, as the alert's Cancel does, so nobody is stuck behind it.
            if editorDivergenceReview != nil {
                // Use Disk Version is the undoable take while the banner stands — see
                // `applyDivergenceAnswer` — and its tooltip says ⌘Z brings the typing back only
                // then.
                EditorDivergenceDiffOverlay(document: editorDocument,
                                            takingDiskIsUndoable: editorDiskWatch.banner == .changed,
                                            onAnswer: { answerEditorDivergenceDiff($0) })
            } else if pendingDestination != nil {
                destinationOverlay
            } else if showSettings {
                settingsOverlay
            } else if showHelp {
                helpOverlay
            } else if showSetup || shouldAutoShowSetup {
                // Wait for provider discovery to finish before showing the form. Its Sources step
                // lists what was discovered, which is empty at first render (discovery runs async
                // in onAppear), so opening early would show "SyncCloud found 0 places on this Mac"
                // and then fill in behind the user's eyes.
                setupOverlay
            } else if let pair = compareDifferencePair {
                DifferencesPairCompareOverlay(pair: pair, hue: glassHue,
                                              onClose: { compareDifferencePair = nil })
            } else if let pair = compareFilePair {
                // Last in the chain, deliberately. The ones above are a direct answer to something
                // the user just did (the picker) or ambient panels with entry points this window
                // cannot gate (⌘, and ⌘? live in the App scene). Yielding to them loses no work:
                // the pair is `@State` here, so closing Settings brings the same two copies back.
                // The reading position (page, mode, keeper, rendered pages, verify result) lives on
                // the covered view and is lost, which is cheaper than giving this surface the
                // picker's whole latch-refusal apparatus.
                CompareCopiesOverlay(
                    syncManager: syncManager, pair: pair,
                    scanRoot: syncManager.duplicateScanRoot,
                    providerName: lensProviderName.isEmpty ? nil : lensProviderName,
                    onClose: { compareFilePair = nil })
            }
        }
        // `designAnimation`, not `.animation`: the scrim fade is motion, and Reduce Motion has to
        // reach it. The raw `.animation` lines below are classified in
        // `ReduceMotionCoverageScanTests`; a new raw one would have to be classified too.
        .designAnimation(.easeOut(duration: 0.15), value: editorDivergenceReview)
        .designAnimation(.easeOut(duration: 0.15), value: compareFilePair)
        .designAnimation(.easeOut(duration: 0.15), value: compareDifferencePair)
        .animation(.easeOut(duration: 0.15), value: showSettings)
        .animation(.easeOut(duration: 0.15), value: showHelp)
        .animation(.easeOut(duration: 0.15), value: showSetup)
        .animation(.easeOut(duration: 0.15), value: setupDismissedThisSession)
        // A sheet, not a member of the overlay chain above: it is the pane bar's own (its right-
        // click menu opens the same one), and it drops over Settings rather than replacing it.
        .sheet(isPresented: $showPaneBarCustomizer) {
            PaneBarCustomizeSheet()
                .presentedNativeControlAccent()
        }
        .animation(.easeOut(duration: 0.15), value: isBootstrappingProviders)
        // The armed launch diagnostic, fired once discovery has given the palette a root to index.
        .onChange(of: isBootstrappingProviders) { _, bootstrapping in
            // The arm is consumed only when it is actually spent. Discovery can land anywhere from
            // a fraction of a second to hours after launch, so a destination picker may be up when
            // it does; clearing the flag before `toggleCommandPalette` could refuse would burn the
            // session's one shot silently.
            guard !bootstrapping, paletteOnLaunchArmed, pendingDestination == nil else { return }
            paletteOnLaunchArmed = false
            toggleCommandPalette()
        }
        // The launch has finished. Lowers this view's guard too, for a view that appeared while
        // discovery was running and so kept it up (see `.endProviderBootstrapGuard`), then lets a
        // file from Finder through.
        .onChange(of: launchBootstrap.isFinished) {
            if launchBootstrap.isFinished { isBootstrappingProviders = false }
            openExternalArrivals()
        }
        // A file from Finder: on arrival, and again when anything holding one back clears — a
        // destination pick, or the question about the open file's two versions. A window that
        // appears with one already waiting asks at the end of `onAppear`. See `ExternalOpen.Hold`.
        .onChange(of: externalOpens.arrivals) { openExternalArrivals() }
        .onChange(of: pendingDestination == nil) { openExternalArrivals() }
        .onChange(of: editorDivergenceReview == nil) { openExternalArrivals() }
        // The quit alert's cause line reads it; the delegate is outside the view layer.
        .onChange(of: editorAutosaveStop, initial: true) { _, stop in SyncCloudAppDelegate.editorAutosaveStop = stop }
        // The overlays are mutually exclusive; Settings wins. Opening Settings closes Help from
        // every entry point, so it can't linger underneath.
        //
        // While a destination pick is up, Settings and Help are refused at the latch, whichever
        // path asked: the picker renders in front of both, so a mid-pick open would appear the
        // instant the pick was answered, and ⌘, and ⌘? live in the App scene, out of this view's
        // reach. A refused deep link restores the tab it preset (`settingsTabBeforeDeepLink`); this
        // is the one place that knows whether the open was honoured.
        .onChange(of: showSettings) { _, isOpen in
            guard isOpen else { return }
            if pendingDestination != nil {
                if let displaced = settingsTabBeforeDeepLink { settingsTab = displaced }
                if let pages = settingsPagesBeforeDeepLink {
                    UserDefaults.standard.set(pages, forKey: SettingsSubTabMemory.defaultsKey)
                }
                settingsTabBeforeDeepLink = nil
                settingsPagesBeforeDeepLink = nil
                showSettings = false
                return
            }
            settingsTabBeforeDeepLink = nil
            settingsPagesBeforeDeepLink = nil
            showHelp = false
        }
        .onChange(of: showHelp) { _, isOpen in
            // One observer rather than a clear at each dismissal: Help closes from four places (its
            // own button, the deep-link chain above, "Set Up SyncCloud…", and this refusal), and
            // each must clear `helpTopic` or the next ⌘? opens on a topic instead of the front of
            // the book.
            guard isOpen else { helpTopic = nil; return }
            guard pendingDestination != nil else { return }
            showHelp = false
        }
        // Setup is the third member of the same chain. A destination pick answers something the
        // user just did to a file, so it wins; a form refused here leaves nothing behind, which for
        // this one means putting the session latch back rather than persisting anything.
        .onChange(of: showSetup) { _, isOpen in
            guard isOpen, pendingDestination != nil else { return }
            showSetup = false
        }
        .quickLookPreview($quickLookURL)
        // An open panel follows the pane selection, Finder-style, and closes when it is cleared.
        // The rule is `CurrentSelection.previewFollow`; this only supplies the trigger.
        .onChange(of: paneQuickLookTarget) { _, _ in followPaneSelectionWithQuickLook() }
        // In Edit with the source pane open, the pane is the file list, so a single selected text
        // file opens. The rule and its guards are `paneSelectionOpens`; this only supplies the
        // trigger.
        .onChange(of: syncManager.selectedLeftPaths) { _, paths in
            // FIRST: it reads the paid marker, which the next line consumes.
            clearInfoTargetAfterLeftSelection(paths)
            openSelectedPaneFileInEditor(paths)
            // A selection the user moved retires what the app owed or was revealing.
            retirePaneSelectionDebts(after: paths)
        }
        // The open document is selected in the pane once the pane lists it, so the tree is what is
        // watched. The rule is `owedPaneSelection`; this only supplies the trigger, and returns at
        // once when nothing is owed.
        .onChange(of: syncManager.leftPaneTree) { _, _ in settleOwedPaneSelection() }
        // Dismissing the panel by hand nils the binding without going through `toggleQuickLook`, so
        // the origin flag is cleared here, or the next preview (opened from a Differences row)
        // would inherit "follows the panes" and be yanked by a pane click.
        .onChange(of: quickLookURL) { _, url in if url == nil { quickLookFollowsPane = false } }
        .animation(.easeOut(duration: 0.15), value: pendingDestination?.id)
        // The theme is the one Appearance control no view can render on its own: it lives on NSApp,
        // so the AppKit surfaces (NSAlert prompts, NSOpenPanel, the About panel, the Activity Log
        // and Sync History windows) follow it too. Applied from the root view rather than the
        // Settings picker so it re-applies whoever writes the key; App.init covers launch.
        .onChange(of: appearanceModeRaw) { AppAppearance.applyPersisted() }
        .liquidGlassAppBackground(level: glassLevel, hue: glassHue, tint: surfaceTint)
        // Render the glass as if the window were always key. SwiftUI materials and `glassEffect`
        // thin out and desaturate to gray when the window loses focus; pinning the active state
        // keeps the panes and chrome identical whether or not the app is frontmost.
        .environment(\.controlActiveState, .active)
    }

    var body: some View {
        chromedContent
        // Every write control below reads this and greys itself, with the reason as its tooltip,
        // while a long run is going. Reading stays live.
        .environment(\.runWriteLock, runWriteLockReason)
        // Whether a pane PDF run or Save as PDF is in the toolbar capsule — the toolbar's width
        // ladder has to seat it (`runCapsuleShowing`).
        .background(RunCapsulePresence(center: .shared, onChange: { showing in
            paneRunShowing = showing
        }, onPopoverChange: { open in
            activityPopoverStyles = open ? toolbarStyles : nil
        }))
        // Edit's own PDF tool and Fill & Sign results, which never pass through the window's
        // message, into Activity's Recent.
        .background(ActivityEditRecorder(tools: editorPDF.tools))
        // Opens the Activity window when something outside a view asks — a notification's click.
        .background(ActivityWindowOpener(center: .shared))
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
        .onReceive(syncManager.$isScanShown) { shown in
            withAnimation { isScanShown = shown }
        }
        .onReceive(syncManager.refreshSubject) { scope in
            // The scope is the subject's, not this view's: only the sender knows whether one pane
            // moved or something changed under both. See `refreshSubject`. Every pane move
            // compares.
            refreshAction(reloading: scope)
            // The app's own file operations end here: a rename, a move, a delete, Organize filing
            // the open note. Edit's rail lists the folder those touched, and the open document may
            // be one of the files they moved; the disk watch hears it anyway, but this looks at
            // once rather than after the events settle.
            refreshEditorAfterFileOperation()
        }
        .onAppear {
            // This runs again mid-session on the same view (a Dock reopen, an open from Finder), so
            // `PaneLogic.bootstrapSteps` splits once-per-session from per-window steps: re-running
            // the session steps would discard a hidden-files toggle and re-pair providers the user
            // set deliberately. The delegate adopts the document here so ⌘Q can ask about an
            // unsaved buffer.
            SyncCloudAppDelegate.shared?.adoptEditorDocument(editorDocument)
            SyncCloudAppDelegate.shared?.adoptAutosavePolicy(editorAutosavePolicy)
            SyncCloudAppDelegate.shared?.adoptDiskWatch(editorDiskWatch)
            SyncCloudAppDelegate.shared?.adoptPDFTools(editorPDF.tools)
            SyncCloudAppDelegate.shared?.adoptPanePDFTools(panePDFTools)
            attachEditorDiskWatch()
            let isFirstAppearance = !hasBootstrappedSession
            hasBootstrappedSession = true
            for step in PaneLogic.bootstrapSteps(isFirstAppearance: isFirstAppearance) {
                switch step {
                case .resetShowHiddenFilesFromDefault:
                    // General setting: start the session with hidden files shown when the user
                    // asked for it.
                    syncManager.showHiddenFiles = UserDefaults.standard.bool(forKey: GeneralSettings.showHiddenByDefaultKey)
                case .honorLaunchOverlayDiagnostics:
                    // Diagnostic hook:
                    // `defaults write com.abhishekgirish.SyncCloud openSettingsOnLaunch -bool YES`
                    // opens the Settings overlay at startup, so automated verification can reach it
                    // without synthesizing input. No-op unless armed; honours `settingsSelectedTab`
                    // for the initial tab.
                    if UserDefaults.standard.bool(forKey: "openSettingsOnLaunch") {
                        // Through `resolvingStored` rather than spelling the fallback here: this
                        // file is in no SPM package, so an inline `??` would be reachable by no
                        // test. See `StoredTabResolutionTests`.
                        openSettings(on: SettingsPlace.resolvingStored(
                            UserDefaults.standard.string(forKey: SettingsView.selectedTabDefaultsKey)))
                    }
                    // `openCommandPaletteOnLaunch` set to YES in the defaults domain brings up ⌘K
                    // at startup, so a script can reach the keyboard-only palette. Armed here and
                    // opened when provider discovery finishes: until then
                    // `lensProviderRootExpanded` is empty and the palette's folder index would show
                    // a state no user can be in.
                    paletteOnLaunchArmed = UserDefaults.standard.bool(forKey: "openCommandPaletteOnLaunch")
                case .createActionHandler:
                    actionHandler = FileActionHandler(syncManager: syncManager, settings: settings,
                                                      defaults: .standard, pasteboard: .general)
                    // The pane → source mapping is this view's state, and linked navigation and the
                    // durable ignore store both need it to tell whether the two panes are in the
                    // same place. A closure rather than two stored strings, so it is read at the
                    // moment of the decision; captured values go stale on the next switch.
                    syncManager.paneOpenAt = paneOpenAtForSyncManager
                    // And which source each pane is on, which decides the coordinate system the
                    // durable ignore store's entries are written in — see
                    // `FileSyncManager.ignoreAnchorIsLeft`. Without it every pair is quoted against
                    // the left pane, and a swap re-reads a mixed pair's entries against the other
                    // source's root.
                    syncManager.paneSourceId = paneSourceIdForSyncManager
                    // How the manager reads a pane's search field when it parks a tab. The field is
                    // this view's `@State`, and `Sync` cannot see its type — see
                    // `paneSearchSnapshot`.
                    syncManager.paneSearchSnapshot = { [self] isLeft in
                        let state = isLeft ? leftPaneSearch : rightPaneSearch
                        return (query: state.query, isExpanded: state.isExpanded)
                    }
                    // What the folder watcher's news turns into, when the user has asked for it.
                    syncManager.onPanesChangedOnDisk = { [self] scope in
                        rescanAfterDiskChange(scope)
                    }
                case .rewireUndoManager:
                    syncManager.undoManager = undoManager
                    // A Recent row's Undo is live only while its step is the newest here.
                    ActivityCenter.shared.watchUndo(undoManager)
                    ActivityCenter.shared.doors = activityDoors
                case .syncProviderQuirkSettings:
                    syncManager.ignoreGoogleDriveNewerDateOnly = settings.ignoreGoogleDriveNewerDateOnly
                    syncManager.sortOption = settings.defaultSortOption
                    syncManager.dateToleranceSeconds = settings.dateToleranceSeconds
                    syncManager.autoVerifySameSizeDuringScan = settings.autoVerifySameSizeDuringScan
                    syncManager.rememberIgnoredItems = settings.rememberIgnoredItems
                    syncManager.ignorePatterns = settings.ignorePatterns
                    // The durable ignore store lives on the manager, so it outlives this view
                    // whatever the window does; create once, re-key on provider changes.
                    if syncManager.ignoredItemsStore == nil {
                        syncManager.ignoredItemsStore = IgnoredItemsStore()
                    }
                    syncManager.ignoredItemsStore?.activate(
                        pairKey: IgnoredItemsStore.pairKey(leftProviderId, rightProviderId))
                    // The names the user has said they meant. Created once, beside the ignore store
                    // and for the same reason. No pair key: a keep is a decision about a name, not
                    // a comparison (see `KeptNamesStore`), so there is nothing to re-key on a
                    // provider change.
                    if syncManager.keptNamesStore == nil {
                        syncManager.keptNamesStore = KeptNamesStore()
                    }
                    // What the cross-person rule has refused. Created here for the same reason, and
                    // keyed on nothing: a refusal is a fact about a document and a person, not
                    // about the pair being compared.
                    if syncManager.filingPersonVetoLog == nil {
                        syncManager.filingPersonVetoLog = PersonVetoLog()
                    }
                case .discoverProvidersAndApplyInitialSelection:
                    Task { @MainActor in
                        await settings.discoverProviders()
                        applyProviderSelection(preferDistinctPair: true)
                        syncManager.ignoredItemsStore?.activate(
                            pairKey: IgnoredItemsStore.pairKey(leftProviderId, rightProviderId))
                        // First appearance only (this step never runs on a window reopen):
                        // put each pane on its source's opening folder before the initial
                        // refresh scans.
                        await openPanesAtTheirLandingFolders()
                        // After the focus restore, deliberately: both answer "where was this pane",
                        // and the strip's active tab is the more specific answer, carrying the
                        // column stack, the scope and the parked tabs beside it. Each pane reads
                        // its own stored strip; a pane with nothing stored keeps what the focus
                        // restore gave it.
                        restoreBrowseTabs(isLeft: true)
                        restoreBrowseTabs(isLeft: false)
                        if !settings.enabledProviders.isEmpty {
                            // Recorded when it does not start: a non-empty `enabledProviders` need
                            // not hold these two, since a folder source, or one a restored tab just
                            // adopted, can still be on its way. The attempt is remembered and
                            // finished the moment the sources arrive.
                            launchRefreshPending = !refreshAction()
                        }
                        isBootstrappingProviders = false
                        // For the session as well as this view, and last: every view that appears
                        // from now on reads it. See `LaunchBootstrap`.
                        launchBootstrap.finish()
                    }
                case .endProviderBootstrapGuard:
                    // Only once the launch's discovery is done. A re-appearance during it is
                    // SwiftUI re-presenting the window (same view) for a file opened from Finder,
                    // and lowering the guard there would hand every provider write still to come to
                    // the user-switch path. `onChange(of: launchBootstrap.isFinished)` lowers it
                    // when discovery ends.
                    isBootstrappingProviders = !launchBootstrap.isFinished
                }
            }
            // A window brought back for a file from Finder appears with it already queued, and
            // nothing else will announce it to this view.
            openExternalArrivals()
        }
        .onChange(of: leftProviderId) { _, newId in
            // The counters are consumed before the bootstrap guard is tested, and that order
            // matters. A counter is armed only by a writer that already did this handler's work, so
            // it must be balanced wherever the write lands, and SwiftUI evaluates `onChange` on the
            // next view update: a write in the guard's last moments (`restoreBrowseTabs`) arrives
            // with the guard already down. Testing the guard first would strand counters and run
            // the user-switch reset over restored navigation.
            //
            // A swap or a tab switch flips this id with its navigation already in place, so the
            // reset is skipped; each has its own counter (`adoptProviderForTab` arms the tab's).
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
            // comparison (the user chose this switch), but releases the review's pin from the right
            // pane if the review was no longer active, since that pin is not their choice.
            reviewCoordinator.dispatchReview(.providerSwitched(isLeft: true))
            // Stale lens results must not outlive their provider: every lens, from the one list
            // that owns that rule, so none can be forgotten here. The person gather is subject to
            // the same rule but is this view's state, not the manager's, so it is cleared from the
            // unconditional id handler further down, which this one's early returns cannot skip.
            syncManager.clearLensResultsForProviderSwitch()
            syncManager.ignoredItemsStore?.activate(
                pairKey: IgnoredItemsStore.pairKey(newId, rightProviderId))
            // retargetPane() fires refreshSubject, which onReceive above turns into a refresh of
            // this pane only. The new source opens at its own landing folder; the other pane keeps
            // its tree, open columns, selection and Back stack.
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
        // The saved tab strip follows the live pane — see `BrowseTabPersistence`. One modifier
        // rather than its two `onChange`s here, because another `onChange` in this chain pushes the
        // body past the type-checker's budget ("unable to type-check this expression in reasonable
        // time").
        .modifier(BrowseTabPersistence(syncManager: syncManager,
                                       leftProviderId: leftProviderId,
                                       rightProviderId: rightProviderId) { saveBrowseTabs(isLeft: $0) })
        .modifier(EditorAutosaveDriver(document: editorDocument,
                                       buffer: editorDocument.buffer) { runAutosave() })
        // The left pane's clear is in the selection handler above, where it can tell the app's own
        // write from the user's — see `clearInfoTargetAfterLeftSelection`; this one skips the clear
        // that same write makes here.
        .onChange(of: syncManager.selectedRightPaths) { _, paths in clearInfoTargetAfterRightSelection(paths) }
        // The Get Info override and any person gather go stale when the comparison context changes
        // under them: a provider switch (the file is on the old provider) or a tab switch.
        // `DetailsSidebar` prefers `overridePath` over everything, and `retargetPane` clears only a
        // non-empty selection, so neither clears here on its own. A gather's card would list a tree
        // no longer shown and its "Open" would silently degrade to a Finder reveal;
        // `clearLensResultsForProviderSwitch()` cannot reach it (it is this view's `@State`).
        //
        // This pair, not the handler above, because that handler returns early during discovery and
        // on a pane swap, and a swap moves the lens source just as surely as the source menu.
        .onChange(of: leftProviderId) { _, _ in
            infoPath = nil
            clearPersonScope()
        }
        .onChange(of: rightProviderId) { _, _ in
            infoPath = nil
            clearPersonScope()
        }
        .onChange(of: selectedWorkspace) { _, workspace in
            // The context every later line is read against: "User focused folder …" means a
            // different thing in each workspace. Fires only on a real change, so one line per
            // switch. `title`, not `rawValue`: the log should name what the bar names, and the raw
            // values are a pinned persistence format that says "Filing" where the user reads
            // "Organize".
            Logger.shared.info("User switched to \(workspace.title)")
            infoPath = nil
            // A person gather does not survive leaving the workspace it was opened from: it takes
            // the lens slot everywhere, so Compare would show someone's files instead of the
            // differences. Here, not in `workspaceSelection`'s setter, because programmatic
            // switches (`show(_:)`, the duplicate coordinators) go around it; `onChange` fires for
            // every writer, and only on a real change.
            clearPersonScope()
            restoreStorageLensIfShowing()
            autoRescanLensIfShowing()
            // Compare is the only workspace that displays a comparison, so an owed one is paid on
            // arriving; a no-op when nothing is owed. Here rather than in `workspaceSelection`'s
            // setter, because the programmatic switches that land on Compare go around that
            // binding.
            if workspace == .compare { payOwedComparisonIfNeeded() }
            // A selection the left pane still owes belongs to the workspace it was owed in, so
            // leaving that workspace drops it now (with its line), rather than at the next publish.
            // A debt recorded after a switch (Reveal in Browse switches first, then owes) is for
            // this workspace, and may pay here. See `owedPaneSelection`.
            settleOwedPaneSelection()
        }
        // The workspace is @AppStorage, so quitting on Storage means the next launch starts there
        // and `onChange` never fires: the restore must also be attempted on appearance. The root is
        // empty until provider discovery finishes, so its change is a trigger too.
        // `restoreStorageLens` declines when a build is running or results already exist, so the
        // triggers cannot fight: the first wins and the rest are no-ops. `autoRescanLensIfShowing`
        // rides the same triggers under the same contract, for the two lenses whose results are
        // recomputed rather than restored.
        .onAppear {
            restoreStorageLensIfShowing()
            autoRescanLensIfShowing()
        }
        .onChange(of: lensScanRootExpanded) { _, _ in
            restoreStorageLensIfShowing()
            autoRescanLensIfShowing()
        }
        // The rail lens is a trigger too. The two auto-rescanned lenses recompute from published
        // arrays, but Storage's report is restored from a store, so switching the rail to Storage
        // would otherwise leave the page empty until another trigger fired. Safe for the reason
        // above: the first trigger wins and the rest are no-ops, so this cannot start a second
        // scan.
        .onChange(of: selectedOrganizeLens) { _, _ in
            restoreStorageLensIfShowing()
            autoRescanLensIfShowing()
        }
        // A scope change re-subjects Storage rather than filtering it: the old root's report is
        // dropped and the new root's snapshot restored if there is one, leaving the lens's Analyze
        // button aimed at the scope when there is not. Deliberately narrow: the other lenses treat
        // scope as a filter over results they hold, and adding them here would turn a chip into a
        // rescan.
        .onChange(of: organizeScope?.path) { _, _ in
            restoreStorageLensIfShowing()
        }
        // The cloud app status reports on every source not turned off in Settings.
        .onChange(of: settings.availableProviders, initial: true) { _, providers in
            cloudApps.setProviders(providers, disabled: settings.disabledProviderIds)
            cloudApps.start()
        }
        .onChange(of: settings.disabledProviderIds) { _, disabled in
            cloudApps.setProviders(settings.availableProviders, disabled: disabled)
        }
        // Settings ▸ Sources on screen is asking about every source: checked at once.
        .onChange(of: showSettings && settingsTab == .providers) { _, showsSources in
            if showsSources { cloudApps.checkNow(settings.availableProviders.map(\.id)) }
        }
        // Watches the enabled subset, not the full discovered list, so turning a provider off in
        // Settings re-resolves any pane that was showing it and rescans.
        .onChange(of: settings.enabledProviders) { oldProviders, newProviders in
            let previousLeftId = leftProviderId
            let previousRightId = rightProviderId
            applyProviderSelection(preferDistinctPair: isBootstrappingProviders)
            // Before the bootstrap guard, because that guard would strand it. A launch refresh that
            // could not start for want of a source must finish when the source turns up, and that
            // arrival is this handler, which returns below while the bootstrap is up, exactly when
            // the pending flag is set. Only completes a refresh already asked for; starts nothing
            // new.
            if launchRefreshPending, refreshAction() {
                launchRefreshPending = false
                Logger.shared.info("Completed the launch refresh once its sources were published")
            }
            guard !isBootstrappingProviders else { return }
            // If re-resolution switched a pane's provider, its id onChange already refreshes via
            // retargetPane; don't schedule a second scan here.
            guard leftProviderId == previousLeftId, rightProviderId == previousRightId else { return }
            // Only rescan when a pane's own provider changed (its root path was edited, say).
            // Toggling or re-pathing a provider neither pane shows must not reload the trees and
            // spin both panes.
            if let edited = Self.paneRootEdits(
                old: oldProviders,
                new: newProviders,
                leftId: previousLeftId,
                rightId: previousRightId
            ) {
                // Same pane ids, different root: the trees and differences were built against the
                // old root, so drop them before the rescan rather than leave stale absolute paths
                // clickable. The review teardown goes through the reducer, which also clears a
                // duplicate review under that root. Both calls take the same scope: a pane dropped
                // and not walked stays blank. Logged, because a selective reload (one pane
                // spinning, its sibling still showing rows) is otherwise unexplained; `[load]`
                // lines are DEBUG.
                Logger.shared.info("A source root changed in Settings under \(edited.describedPanes); "
                                   + "dropping the comparison and re-walking \(edited.describedPanes).")
                reviewCoordinator.dispatchReview(.comparisonRootEdited)
                syncManager.invalidateComparisonState(reloading: edited)
                refreshAction(reloading: edited)
            }
        }
        .modifier(SettingsEngineMirrors(syncManager: syncManager, settings: settings))
        // A republish can delete a folder a column stack is standing in, externally or by the
        // user's own Delete. Re-resolve each stack against the new tree so it falls back to the
        // deepest surviving ancestor; otherwise the columns render nothing while `currentDirectory`
        // still names the dead folder, where New Folder and paste would act. `PaneTree` compares by
        // publish stamp, so this fires once per publish.
        .modifier(ColumnStackPruning(syncManager: syncManager,
                                     leftTreeRoot: currentLeftPath,
                                     rightTreeRoot: currentRightPath))
        // Rebuilding the indices walks every difference's ancestor chain, which with tens of
        // thousands of differences would freeze the main thread after every scan, so the work runs
        // detached and only the results land on main. task(id:) also cancels a stale rebuild when
        // the inputs change mid-flight.
        .task(id: diffIndexInputs) {
            let inputs = diffIndexInputs
            let (left, right) = await Task.detached(priority: .userInitiated) {
                // Per-pane case-fold gating for the folded badge fallback: a missing row's expected
                // path carries the source side's ancestor casing, so a destination folder differing
                // only in case would show no contained-diff badge. One stat per rebuild, on the
                // detached walk.
                func foldsCase(_ root: String) -> Bool {
                    // Only a definite insensitive answer enables folding: the ??-false helper would
                    // read a vanished or unmounted root as "insensitive", enabling merges on a
                    // volume of unknown semantics.
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
    
    /// The settings→engine mirror handlers, extracted as a modifier: chaining them inline pushes
    /// the body expression past the type-checker's budget.
    private struct SettingsEngineMirrors: ViewModifier {
        @ObservedObject var syncManager: FileSyncManager
        @ObservedObject var settings: SettingsManager

        func body(content: Content) -> some View {
            content
                .onChange(of: settings.ignoreGoogleDriveNewerDateOnly) { _, new in
                    syncManager.ignoreGoogleDriveNewerDateOnly = new
                }
                // The remaining Sync-tab settings mirror the same way; the manager's didSets decide
                // whether a change needs a refilter (ignores) or a rescan (tolerance,
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
                // Sort mirrors both ways: the Settings picker drives the panes, and a pane
                // sort-menu change persists as the new default (the equality guards stop the
                // ping-pong after one hop).
                .onChange(of: settings.defaultSortOption) { _, new in
                    syncManager.sortOption = new
                }
                .onChange(of: syncManager.sortOption) { _, new in
                    if settings.defaultSortOption != new {
                        settings.defaultSortOption = new
                    }
                }
        }
    }

    /// What this window is on, for `NSWindow.title`: both sides on Compare, the single source
    /// elsewhere.
    ///
    /// The provider's `displayName`, not `paneNames`, whose "Left"/"Right" and "(left)"/"(right)"
    /// suit a pane header and not a window title. Each side's location goes through its own view
    /// mode, as in `paneContext`: a Tree pane's location is its scope.
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
    /// `SettingsManager.nameRuleType(for:)` owns both substitutions: OneDrive, the strictest, for a
    /// provider id that won't resolve, so an unresolved source over-reports rather than leaving a
    /// name that will break a sync pass unflagged; and the user's `folderNameRule` for a folder
    /// source, which has no rules of its own.
    var paneRules: PaneProviderRules {
        PaneProviderRules(left: settings.nameRuleType(for: leftProviderId),
                          right: settings.nameRuleType(for: rightProviderId))
    }

    /// Builds the full path for the left pane from the left provider's root and left relative path
    /// only, so roots never mix.
    var currentLeftPath: String {
        PaneLogic.fullPath(root: settings.rootPath(for: leftProviderId), relativePath: syncManager.leftRelativePath)
    }

    /// Builds the full path for the right pane from the right provider's root and right relative
    /// path only, so roots never mix.
    var currentRightPath: String {
        PaneLogic.fullPath(root: settings.rootPath(for: rightProviderId), relativePath: syncManager.rightRelativePath)
    }

    // MARK: - Pane visibility & content layout

    /// The resolved arrangement of the panes and workspace, which start directly under the window
    /// toolbar. Comparison tabs stack two panes over the workspace; the single-source workspaces
    /// dock one collapsible rail beside a workspace that's always shown.
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
        /// Two arms, like the lens workspaces, because the source pane collapses. The sidebar alone
        /// reaches only folders already kept or visited, so the same file pane Organize docks is
        /// available here to browse anywhere. It starts collapsed to its spine
        /// (`TopPaneVisibility.defaultPanesHidden`): most sessions open a file and write in it, and
        /// the pane is one click away when they do not.
        case editorExpanded
        /// Editor with the source pane collapsed to a spine.
        case editorCollapsed

        /// Whether this arrangement draws a `FileTreeView` at all, which is what every pane-scoped
        /// chord asks before it offers itself. `layoutMode` cannot tell a workspace with a rail
        /// from one with neither, so a chord gated on it (⇧⌘N, say) would stay live with no pane to
        /// act on and put an invisible pane into a naming state.
        var drawsAPaneList: Bool {
            switch self {
            case .compareSplit, .singleExpanded, .browseFull: return true
            // Expanded, a workspace with a source rail draws a real `FileTreeView` and the
            // pane-scoped chords mean what they say. Collapsed, there is only a 34pt spine, for
            // both kinds: the editor's source pane and the lens rail collapse to the same strip
            // through the same stored override.
            case .editorExpanded: return true
            case .singleCollapsed, .editorCollapsed: return false
            }
        }

        /// Whether this arrangement has a source rail that can collapse to a spine — what the pane
        /// header's collapse rung asks.
        ///
        /// Asked of the layout rather than of the workspace, and switched with no `default:`, so a
        /// new full-window workspace cannot inherit a collapse rung it has no spine for by
        /// forgetting to exclude itself.
        var hasCollapsibleRail: Bool {
            switch self {
            case .singleExpanded, .singleCollapsed, .editorExpanded, .editorCollapsed: return true
            case .compareSplit, .browseFull: return false
            }
        }
    }

    /// The current tab's layout mode (compare vs single-source).
    var layoutMode: TopPaneVisibility.Mode { TopPaneVisibility.mode(for: selectedWorkspace) }

    /// Whether the current workspace's panes are hidden: its default plus any stored override.
    /// Computed, so a workspace switch applies its remembered state with no plumbing. Read through
    /// `TopPaneVisibility.overrides`' one-entry memo rather than `decodeOverrides`, because it is
    /// read from dozens of sites per body pass and each direct read would parse the JSON again.
    /// The panes as DRAWN: the stored fold, or the one the pinned Ask Claude column makes for itself.
    /// Everything that lays out or enables a control reads this. What records or writes a fold reads
    /// `panesStoredHiddenForCurrentTab`, so the pin's fold is never stored over a fold made by hand.
    var panesHiddenForCurrentTab: Bool {
        PaneLogic.panesDrawnHidden(stored: panesStoredHiddenForCurrentTab,
                                   pinFoldWanted: askClaudePinFoldWanted, releasedByHand: askClaudePinFoldReleased)
    }

    /// The stored fold: the workspace's default plus any override.
    var panesStoredHiddenForCurrentTab: Bool {
        TopPaneVisibility.panesHidden(
            for: selectedWorkspace,
            override: TopPaneVisibility.overrides(in: topPaneOverridesRaw)[selectedWorkspace.rawValue]
        )
    }

    /// Resolves the content layout from the tab's mode and its pane/workspace visibility.
    var contentLayout: ContentLayout {
        // Browse is decided before the pane-hiding question is asked, deliberately: the pane is the
        // whole window here, so "panes hidden" would mean an empty window. No control in Browse
        // writes that override, but a stray key in the stored map must not blank the workspace
        // either.
        if selectedWorkspace == .browse { return .browseFull }
        // Editor is decided here for the same reason and one more: it owns no lens, so the lens
        // mounting path answers nothing for it (`presentLensRail` early-returns on a nil lens and
        // `bottomPaneView` mounts nothing), and falling through to `.singleExpanded` would draw a
        // source pane beside an empty half. It takes the lens workspaces' collapse state, through
        // the same stored override.
        if selectedWorkspace == .editor {
            return panesHiddenForCurrentTab ? .editorCollapsed : .editorExpanded
        }
        switch layoutMode {
        case .compare:
            // The comparison panes and the workspace are both always shown (you resize with the
            // divider; no control writes a hidden override for a compare tab), so compare is always
            // the split.
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
        // The pin is holding the pane folded: opening it by hand ends the pin's fold and writes
        // nothing, so the stored fold, and Expand's record, stay as they were.
        if askClaudeReleasePinFold() { return }
        // Opening Edit's pane by hand ends Expand and spends its record (`paneOpenedByHand`).
        if selectedWorkspace == .editor && panesStoredHiddenForCurrentTab {
            var expand = editorExpand
            expand.paneOpenedByHand()
            editorExpand = expand
            return
        }
        let overrides = TopPaneVisibility.settingOverride(
            TopPaneVisibility.decodeOverrides(topPaneOverridesRaw),
            workspace: selectedWorkspace,
            hidden: !panesStoredHiddenForCurrentTab
        )
        topPaneOverridesRaw = TopPaneVisibility.encodeOverrides(overrides)
    }

    /// Whether Edit's file pane is folded to its strip — closed by the pane toggle, by Just the
    /// text, or by a launch from Finder. Edit's override by name, whichever workspace is on screen.
    var editorPaneIsFolded: Bool {
        TopPaneVisibility.panesHidden(for: .editor,
                                      override: TopPaneVisibility.decodeOverrides(topPaneOverridesRaw)[Workspace.editor.rawValue])
    }

    /// Edit's Expand state, read from and written back to the four places its bits live. Edit's
    /// pane is written by name, like `openEditWideForLaunchFromFinder`, so the answer does not
    /// depend on which workspace is on screen. Only changed bits are written: each is
    /// `@AppStorage`, and an identical write is still a change to SwiftUI.
    var editorExpand: EditorExpand {
        get {
            EditorExpand(railHidden: editorRailHidden, paneFolded: editorPaneIsFolded,
                         sidebarPutAway: editorExpandSidebarPutAway,
                         paneFoldedByExpand: editorExpandFoldedPane)
        }
        nonmutating set {
            if newValue.paneFolded != editorPaneIsFolded {
                topPaneOverridesRaw = TopPaneVisibility.encodeOverrides(
                    TopPaneVisibility.settingOverride(TopPaneVisibility.decodeOverrides(topPaneOverridesRaw),
                                                      workspace: .editor, hidden: newValue.paneFolded))
            }
            if newValue.railHidden != editorRailHidden { editorRailHidden = newValue.railHidden }
            if newValue.sidebarPutAway != editorExpandSidebarPutAway {
                editorExpandSidebarPutAway = newValue.sidebarPutAway
            }
            if newValue.paneFoldedByExpand != editorExpandFoldedPane {
                editorExpandFoldedPane = newValue.paneFoldedByExpand
            }
        }
    }

    /// A launch from Finder opens Edit wide, through Expand's own entry (`EditorExpand.enter`): the
    /// Text Files rail hidden, the file pane collapsed, the sidebar put away, until Edit is left.
    /// Written for `.editor` by name, never through `togglePanesForCurrentTab`, which toggles
    /// whatever workspace is on screen.
    func openEditWideForLaunchFromFinder() {
        let before = editorExpand
        var expand = before
        expand.enter(sidebarShowing: editorSidebarIsShowing)
        editorExpand = expand
        Logger.shared.info("[open] Launched from Finder — Edit opens wide"
            + (expand == before ? ", as it already was"
                                : " (closed \(EditorExpand.moved(from: before, to: expand)))"))
    }

    /// Entering a lens workspace from the workspace bar opens the source rail and leaves the left
    /// pane where it was: Browse, Organize's rail and Compare's left pane are one pane over one
    /// folder. Fired only from the bar; the programmatic scan actions set the workspace directly
    /// and keep their folder.
    ///
    /// Arriving starts no scan the user has not already run: with no scope the lenses follow the
    /// rail (`lensScanRootExpanded`), and the auto-rescan repeats only a completed scan of that
    /// folder. The loose-files inbox is never opened unasked; the overview offers it as a one-click
    /// scope (`filingInboxFolder`).
    func presentLensRail(for workspace: Workspace) {
        // The lens no longer decides where the rail opens; it guards that this is a lensed
        // workspace at all, which makes the early return correct for Compare.
        guard workspace.lens != nil else { return }
        // Show the rail for this workspace (remembered per workspace, like the manual toggle). It
        // arrives with the switch, unanimated, like the switch itself.
        let overrides = TopPaneVisibility.settingOverride(
            TopPaneVisibility.decodeOverrides(topPaneOverridesRaw),
            workspace: workspace,
            hidden: false
        )
        topPaneOverridesRaw = TopPaneVisibility.encodeOverrides(overrides)
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
    /// - Parameter reloading: which panes to walk; the scan always compares both. Defaults to
    ///   `.both`. A narrow scope must also be what `invalidateComparisonState` was given, or a
    ///   dropped pane stays blank.
    /// - Parameter comparing: whether the reload is followed by the two-pane comparison. Only
    ///   Edit's re-read outside Compare passes `false`; `owedComparison` makes that skip owed, not
    ///   lost.
    /// - Returns: whether a refresh started. At bootstrap a pane can name a source not yet
    ///   published; the warning says so, and `launchRefreshPending` finishes the refresh when it
    ///   arrives.
    @discardableResult
    func refreshAction(reloading: FileSyncManager.PaneReloadScope = .both,
                               comparing: Bool = true) -> Bool {
        guard let leftProvider = settings.enabledProviders.first(where: { $0.id == leftProviderId }),
              let rightProvider = settings.enabledProviders.first(where: { $0.id == rightProviderId }) else {
            let missing = [leftProviderId, rightProviderId]
                .filter { id in !settings.enabledProviders.contains { $0.id == id } }
            Logger.shared.warning(
                "Skipped a refresh: \(missing.joined(separator: ", ")) "
                + "\(missing.count == 1 ? "is" : "are") not among the enabled sources yet")
            return false
        }
        // Written on the way out, both ways: a refresh that compares settles the whole debt, and
        // one that does not takes the comparison on, so the record always describes what has
        // happened since the last comparison.
        var reloading = reloading
        if comparing {
            // And it walks every pane holding such a file, not only the panes it was asked to: the
            // drop below takes that pane's walk too, so a pane left out would keep showing the file
            // as it was, its folder compared cold, with the debt gone. A source or tab switch is
            // the usual case: it asks for the moved pane alone, and the file is usually under the
            // other one.
            if let because = owedComparison.reasonToWalkBoth(insteadOf: reloading,
                                                            leftFolder: currentLeftPath, rightFolder: currentRightPath,
                                                            leftLinkTargets: syncManager.leftTreeLinkTargets,
                                                            rightLinkTargets: syncManager.rightTreeLinkTargets) {
                Logger.shared.info("Walking both panes, not only \(reloading.describedPanes): \(because)")
                reloading = .both
            }
            // Its scan reads every file the editor wrote: the cached walks listing their folders go
            // first, or the scan's in-memory fast path would compare the walk taken before the
            // write.
            for path in owedComparison.unreadWrites { syncManager.prepareReread(afterWritingAt: path) }
            owedComparison = OwedComparison()
        } else if owedComparison.skipped == nil {
            owedComparison.skipped = OwedComparison.skippedByARefresh
        }
        Task { [reloading] in
            await syncManager.refreshTreesAndScan(left: leftProvider, right: rightProvider,
                                                  reloading: reloading, comparing: comparing)
        }
        return true
    }

    /// What Compare's list owes the disk, and why — one record for every way the list falls behind,
    /// paid in one place (`payOwedComparisonIfNeeded`). Two things leave it behind:
    ///
    /// - A refresh that skipped its comparison (`refreshAction(comparing: false)`, Edit's re-read
    ///   outside Compare): the trees are current, only the comparison is owed (`skipped`). Unpaid,
    ///   Compare would draw stale rows under correct pane headers.
    /// - A file the editor wrote over (`noteEditorWrote`): its cached walks still hold the old size
    ///   and date, so the panes holding it are re-read first (`unreadWrites`), or a row would offer
    ///   to overwrite what was just written.
    ///
    /// ⌘N's new file and an exported PDF re-read their pane at once, so they owe only a `skipped`.
    /// A write under neither compared folder is not recorded (`recordWrite`); its caller drops its
    /// walks at the moment of the write instead. Any refresh that compares settles all of it.
    struct OwedComparison: Equatable {
        /// Why a refresh skipped the comparison, for the line that pays it — `nil` when none did.
        var skipped: String?
        /// Files the editor wrote over since the last comparison that nothing has re-read.
        var unreadWrites: Set<String> = []

        /// Records a file the editor wrote over, only when it is under either compared folder
        /// (`ContentView.panesHolding`, links included, and the folder links the panes' walks
        /// followed), since nothing else can change what Compare shows. Returns whether it was
        /// recorded; a caller told `false` owns the write's stale cached walks itself.
        mutating func recordWrite(_ path: String, leftFolder: String, rightFolder: String,
                                  leftLinkTargets: Set<String> = [], rightLinkTargets: Set<String> = [],
                                  links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders) -> Bool {
            guard ContentView.panesHolding(path, leftFolder: leftFolder, rightFolder: rightFolder,
                                           leftLinkTargets: leftLinkTargets, rightLinkTargets: rightLinkTargets,
                                           links: links) != nil else { return false }
            unreadWrites.insert(path)
            return true
        }

        /// The reason `refreshAction` records for a refresh that skipped its comparison.
        static let skippedByARefresh = "the pane moved outside Compare without a comparison"

        /// The reason for a file the editor wrote — the one `payOwedComparisonIfNeeded` logs.
        static func editorWrote(_ path: String) -> String {
            "the editor wrote \(path) since the last comparison"
        }

        enum Payment: Equatable {
            /// The editor wrote files under the compared folders: re-read the panes holding them,
            /// and compare. That refresh settles a skipped comparison with it.
            case reread(FileSyncManager.PaneReloadScope, because: String)
            /// Only the comparison — a refresh skipped it, and the trees it loaded are current.
            case compare(because: String)

            var because: String {
                switch self {
                case .reread(_, let because), .compare(let because): return because
                }
            }
        }

        /// What arriving in Compare pays, or `nil` when nothing is owed there: nothing recorded, or
        /// only writes outside both compared folders (a pane moved off them since). Each pane is
        /// re-read when it holds any written file (`ContentView.panesHolding`, which knows iCloud
        /// Drive's linked `Documents`, and the folder links the panes' walks followed); the first
        /// such file in path order is the one named, so the line does not depend on set order.
        func payment(leftFolder: String, rightFolder: String,
                     leftLinkTargets: Set<String> = [], rightLinkTargets: Set<String> = [],
                     links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders) -> Payment? {
            var scope: FileSyncManager.PaneReloadScope?
            var named: String?
            for path in unreadWrites.sorted() {
                guard let held = ContentView.panesHolding(path, leftFolder: leftFolder, rightFolder: rightFolder,
                                                          leftLinkTargets: leftLinkTargets,
                                                          rightLinkTargets: rightLinkTargets, links: links)
                else { continue }
                named = named ?? path
                scope = scope.map { $0 == held ? $0 : .both } ?? held
            }
            if let scope, let named { return .reread(scope, because: Self.editorWrote(named)) }
            return skipped.map { .compare(because: $0) }
        }

        /// Why a refresh that compares, asked to walk `requested`, has to walk both panes — the
        /// write under a pane it would leave alone — or nil when `requested` covers every pane
        /// holding an unread write. Asked of `payment(…)`, so the two cannot disagree about which
        /// pane holds a file.
        ///
        /// Settling drops the cached walks listing each written folder (`prepareReread`), so a pane
        /// holding one that the refresh does not walk would keep showing the file as it was while
        /// its folder is compared cold.
        func reasonToWalkBoth(insteadOf requested: FileSyncManager.PaneReloadScope,
                              leftFolder: String, rightFolder: String,
                              leftLinkTargets: Set<String> = [], rightLinkTargets: Set<String> = [],
                              links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders) -> String? {
            guard requested != .both,
                  case .reread(let held, let because)? = payment(leftFolder: leftFolder, rightFolder: rightFolder,
                                                                 leftLinkTargets: leftLinkTargets,
                                                                 rightLinkTargets: rightLinkTargets, links: links),
                  held != requested else { return nil }
            return because
        }
    }

    /// Pays the comparison Compare owes, once, with one line saying why. Called on arriving in
    /// Compare and on each editor write while Compare is on screen (an autosave's debounce can fire
    /// after the switch). See `OwedComparison`.
    ///
    /// A re-read goes through `refreshAction`, which settles the record. A skipped comparison alone
    /// is `scanDirectories`, which walks both folders itself. Nothing is cleared until the
    /// providers resolve, or a debt dropped during bootstrap would leave Compare stale for the
    /// session.
    func payOwedComparisonIfNeeded() {
        guard let payment = owedComparison.payment(leftFolder: currentLeftPath, rightFolder: currentRightPath,
                                                   leftLinkTargets: syncManager.leftTreeLinkTargets,
                                                   rightLinkTargets: syncManager.rightTreeLinkTargets)
        else { return }
        switch payment {
        case .reread(let scope, _):
            guard refreshAction(reloading: scope) else { return }
        case .compare:
            guard let leftProvider = settings.enabledProviders.first(where: { $0.id == leftProviderId }),
                  let rightProvider = settings.enabledProviders.first(where: { $0.id == rightProviderId })
            else { return }
            owedComparison = OwedComparison()
            Task {
                await syncManager.scanDirectories(left: leftProvider, leftPath: currentLeftPath,
                                                  right: rightProvider, rightPath: currentRightPath)
            }
        }
        Logger.shared.info("Compare rescans: \(payment.because)")
    }

    /// Swaps the left and right panes entirely — providers, focused folders, selections,
    /// back/forward history, trees, and the differences list (remapped, so every row's arrows flip
    /// with the pane labels). The manager's paired state is swapped first, so the single post-swap
    /// rescan reads swapped focus and selection, then the @AppStorage provider ids. Both id
    /// onChanges fire but are suppressed via `pendingSwapProviderChanges`, so they don't reset the
    /// swapped navigation; this method drives the one rescan. The manager refuses the swap while
    /// file operations are in flight, and the provider ids must then stay put too, or the pane
    /// labels would flip over unswapped state.
    func swapPanesAction() {
        // The window is interactive while discoverProviders() is still awaiting, and a swap there
        // would repoint panes whose sources the bootstrap is still deciding. Refused outright. (The
        // suppression counter cannot strand: `PaneProviderChange` consumes it before testing the
        // bootstrap guard.)
        guard !isBootstrappingProviders else { return }
        guard syncManager.swapPanes() else { return }
        reviewCoordinator.dispatchReview(.panesSwapped)   // the swap redefines the comparison; end the guided review + drop any duplicate review (no restore)
        let swapped = PaneLogic.swappedProviderIds(
            leftProviderId: leftProviderId,
            rightProviderId: rightProviderId
        )
        // Both ids change together (unless the panes already share a provider, when the plan is
        // empty and neither onChange fires), so the suppression counter is seeded with the plan's
        // exact change count. `=` rather than `+=`: a swap resets the counter.
        let plan = ProviderPinPlan.make(
            currentLeft: leftProviderId, currentRight: rightProviderId,
            targetLeft: swapped.leftProviderId, targetRight: swapped.rightProviderId)
        if !plan.assignments.isEmpty {
            pendingSwapProviderChanges = plan.suppressCount
        }
        applyProviderPinAssignments(plan)
        // The swap moved the lists as well as the panes, so each saved strip is now the other
        // pane's. Saved explicitly rather than left to the path `onChange`, which does not fire
        // when both panes show the same folder. Both sides, because a swap changes both strips at
        // once: saving one would make the next launch restore one side from before the swap and one
        // from after.
        saveBrowseTabs(isLeft: true)
        saveBrowseTabs(isLeft: false)
        refreshAction()
    }

    /// Opens the settings overlay on Sources — the fix-it action for the invalid-root /
    /// disabled-provider pane placeholders, and the source menus' manage item — on the page that
    /// lists the source: Local Folders for a folder, Cloud Providers otherwise. Name Checks holds
    /// neither, so a remembered page is never the answer here.
    private func openProviderSettings(for providerId: String? = nil) {
        let isFolder = providerId.flatMap { id in settings.availableProviders.first { $0.id == id } }?.isLocalFolder ?? false
        openSettings(on: SettingsPlace(isFolder ? .localFolders : .cloudProviders))
    }

    /// The one door for every Settings deep link. The tab is preset before the latch, because the
    /// overlay reads `settingsTab` as it appears; the displaced tab is stashed so
    /// `onChange(of: showSettings)` can put it back if the open is refused mid-destination-pick.
    /// A place's page is remembered first (`SettingsSubTabMemory`), so the tab opens on it.
    /// Internal for `CommandPaletteHost.swift`'s `.settings(tab:)`.
    func openSettings(on place: SettingsPlace) {
        // Only while the latch is actually flipping. `onChange` consumes the stash and does not
        // fire for a redundant `true`, so stashing on an already-open panel would leave a value to
        // be restored later over a tab the user had since chosen by hand.
        if !showSettings {
            settingsTabBeforeDeepLink = settingsTab
            settingsPagesBeforeDeepLink = UserDefaults.standard.string(forKey: SettingsSubTabMemory.defaultsKey) ?? ""
        }
        SettingsSubTabMemory.remember(place)
        settingsTab = place.tab
        showSettings = true
    }

    /// "Choose Folder…" from a source menu: pick a folder, make it a source and hand back its id,
    /// so the caller points its pane at it (Settings ▸ Sources ▸ Add Folder… selects nothing). An
    /// existing source is returned rather than duplicated (`addFolderSource`). Internal for the ⌘K
    /// palette's "Choose Folder…", so there is one prompt.
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

    /// "Get Info" from a pane or differences-row right-click: show the in-app Info inspector for
    /// the path (not Finder's Get Info). Opens the inspector in place on the current tab; it is
    /// available on both Compare and Organize.
    func showInfo(for path: String) {
        infoPath = path
        infoNode = nil
        withAnimation(.easeInOut(duration: 0.15)) { showInspector = true }
        // Off the main thread, with its date: a stat on a provider that has stopped answering would
        // hang the app at the click, and without the date a file previewed this way would not
        // refresh when it changed.
        Task { @MainActor in
            let node = await Task.detached(priority: .userInitiated) { () -> FileNode? in
                let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
                guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys) else { return nil }
                return FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: values.isDirectory ?? false,
                                modificationDate: values.contentModificationDate)
            }.value
            guard infoPath == path else { return }
            infoNode = node
        }
    }

    /// A change of the left pane's selection retires an explicit Get Info target, so the inspector
    /// follows the new selection — unless the change is the app's own payment of an owed selection,
    /// marked `editorPaneSelectionPaid` before it is written. That payment can land a moment after
    /// the open it was owed for, when the user may have used a rail row's Get Info on another file,
    /// and a write they did not make must not jump the inspector. **Called before
    /// `openSelectedPaneFileInEditor`**, which consumes the marker.
    func clearInfoTargetAfterLeftSelection(_ paths: Set<String>) {
        if Self.leftSelectionClearsInfoTarget(paths, paidSelection: editorPaneSelectionPaid) {
            infoPath = nil
        }
    }

    /// The rule: every change but the one the app marked as its own write.
    static func leftSelectionClearsInfoTarget(_ paths: Set<String>, paidSelection: String?) -> Bool {
        guard let paidSelection else { return true }
        return paths != [paidSelection]
    }

    /// The right pane's half. Paying an owed selection clears the right pane, whatever it holds, as
    /// a left-pane click would, and that clear is not the user's either, so it keeps a Get Info
    /// target as the left-pane write does. The marker is one-shot: consumed by the change it
    /// announced.
    func clearInfoTargetAfterRightSelection(_ paths: Set<String>) {
        let paid = editorPaneRightClearPaid
        editorPaneRightClearPaid = false
        if Self.rightSelectionClearsInfoTarget(paths, clearWasPaid: paid) { infoPath = nil }
    }

    /// The rule: every change but the app's own clear.
    static func rightSelectionClearsInfoTarget(_ paths: Set<String>, clearWasPaid: Bool) -> Bool {
        !(clearWasPaid && paths.isEmpty)
    }

    /// Opens each pane at its source's landing folder (`openAt`). Runs once, inside the
    /// first-appearance bootstrap, after the provider selection resolves and before the initial
    /// refresh.
    ///
    /// Where a pane opens, not a restoration of where it was, so "Reopen panes where I left off"
    /// does not govern it; `restoreBrowseTabs` runs next and re-points a pane that has a tab strip.
    private func openPanesAtTheirLandingFolders() async {
        // `focusOn` rather than a history reset: it leaves the root one Back away, which on a pane
        // not yet navigated is a way up, not a false step in its history.
        for isLeft in [true, false] {
            let id = isLeft ? leftProviderId : rightProviderId
            let landing = settings.openAtIfReachable(for: id)
            guard !landing.isEmpty else {
                // The degrade is logged, because the log is what gets audited. `openAtIfReachable`
                // answers `""` for two reasons and only one is interesting: the chosen landing
                // folder has been renamed or deleted, so the pane opens at the account root.
                // Settings shows a sentence about it, and this puts it in the log too. A source
                // with no `openAt` is the ordinary case and stays quiet.
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

    /// The full reset behind Settings → Advanced. `resetAllSettings()` clears the defaults domain
    /// (all but `SettingsResetKeeps`) and republishes, and the `.onChange` mirrors re-seed the
    /// engine; the log gate and the in-memory ignore sets don't flow through those and are reset
    /// here.
    ///
    /// Static so a test can pin all three steps and their order: `resetAllSettings()` re-seeds the
    /// log gate from the cleared defaults, so the `.debug` write must follow it. `setLogLevel` is a
    /// seam so the test need not mutate the process-wide `Logger.shared` gate.
    @MainActor
    static func applyFullSettingsReset(
        settings: SettingsManager,
        syncManager: FileSyncManager,
        // Optional rather than a defaulted closure: a default argument is evaluated in a
        // nonisolated context, so `{ Logger.shared.minimumLevel = $0 }` there would mutate
        // main-actor state from outside the actor (an error under Swift 6). Resolving the fallback
        // inside this `@MainActor` body keeps the write isolated.
        setLogLevel: ((LogLevel) -> Void)? = nil
    ) {
        settings.resetAllSettings()
        (setLogLevel ?? { Logger.shared.minimumLevel = $0 })(.debug)
        syncManager.clearAllIgnoredItems()
        // The one thing the defaults domain does not carry. `resetAllSettings()` drops all three
        // setup flags with the rest of the domain, so the alert's "SyncCloud forgets that setup has
        // run" needs no code here (setup then offers itself only where no folder profile exists,
        // `SetupFlow.shouldAutoShow`). But the draft is a file beside the profiles, and leaving it
        // would open setup on a fresh machine with a household already in it.
        if let draft = SetupDraftStore.defaultURL() { SetupDraftStore.clear(at: draft) }
    }

    func resetAllSettingsAction() {
        Self.applyFullSettingsReset(settings: settings, syncManager: syncManager)
    }

    /// Forgets that setup has run, and opens it at the beginning.
    ///
    /// The three keys and the draft, which is everything that says "this machine has been through
    /// setup". Nothing else is touched: the profile, the roster and every preference stay.
    func resetSetupAction() {
        hasCompletedSetup = false
        hasSeenFirstRunWelcome = false
        UserDefaults.standard.removeObject(forKey: SetupFlow.primarySourceDefaultsKey)
        if let draft = SetupDraftStore.defaultURL() { SetupDraftStore.clear(at: draft) }
        Logger.shared.info("Setup reset — the guided sheet will offer itself again")
        showSettings = false
        setupDismissedThisSession = false
        showSetup = true
    }

    /// The in-window Help overlay (Help ▸ SyncCloud Help / ⌘?). HelpOverlay owns the backdrop, card
    /// decoration and the searchable topic/article layout; this feeds it the current surface style
    /// so the Help card matches Settings, and wires dismissal.
    @ViewBuilder
    private var helpOverlay: some View {
        HelpOverlay(
            glassHue: glassHue,
            glassLevel: glassLevel,
            surfaceTint: surfaceTint,
            // A page something pointed at, or else the workspace's own.
            openAt: helpTopic ?? HelpBook.topicID(for: selectedWorkspace, pdfIsOpen: editorPDF.path != nil),
            onClose: { showHelp = false; helpTopic = nil }
        )
    }

    /// Whether the form opens itself, given everything this window knows.
    ///
    /// The session latch and the discovery wait are this view's business; the rest of the rule is
    /// `SetupFlow.shouldAutoShow`, where it can be tested without a window.
    ///
    /// Not private: a file opened from Finder says in the log that it opened under the form
    /// (`closeViewersForExternalOpen`).
    var shouldAutoShowSetup: Bool {
        !setupDismissedThisSession && !isBootstrappingProviders
            && SetupFlow.shouldAutoShow(hasCompletedSetup: hasCompletedSetup,
                                        hasSeenLegacyWelcome: hasSeenFirstRunWelcome,
                                        hasFilingProfile: syncManager.filingFolderProfile != nil)
    }

    /// The setup form. `SetupSheet` owns the card, the rail and every step; this wires it to the
    /// live settings object, the roster where one exists, and the two ways out.
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
                // `showSetup` is the explicit route (the Help menu item and Settings' "Run setup
                // again…"); `shouldAutoShowSetup` is the app offering itself on launch. Only an
                // explicit ask opens on the welcome card.
                wasAskedFor: showSetup,
                // A profile the user just produced takes effect without a relaunch: the same read
                // the app does at launch, run again now there is something new on disk. A new
                // survey is one of the moments the profile trend should record.
                onProfileWritten: { FilingArtifacts.attach(to: syncManager, recordingTrend: true) },
                // Setup writes the profile and then offers to read the documents in it. The scope
                // moves with it, so the strip on every Organize lens reports the run setup started.
                onStartSurvey: { root in startDocumentSurvey(learnedRoot: root) },
                // Through the one door, not by writing the latch here: `openSettings(on:)` stashes
                // the tab it displaces so a refused open (one landing mid-destination-pick) can put
                // it back.
                onOpenSettings: { tab in
                    dismissSetup()
                    openSettings(on: tab)
                },
                onFinish: { finishSetup() },
                onDismiss: { dismissSetup() },
                onStartWith: { start in openAfterSetup(start) }
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .transition(.opacity)
    }

    /// Hide the form for the rest of this session without marking setup finished, so an unanswered
    /// form offers itself again next launch. The answers are already kept: preferences are live,
    /// and the sheet commits the open screen first (`SetupModel.commitBeforeClosing`).
    private func dismissSetup() {
        setupDismissedThisSession = true
        showSetup = false
    }

    /// What a Start-with button on setup's Summary opens.
    ///
    /// The workspace is set before the sheet closes, so the app already shows what the button named
    /// as the card fades. Compare is offered only when two locations are enabled; the button is
    /// hidden otherwise rather than opening two copies of one account.
    private func openAfterSetup(_ start: SetupStart) {
        switch start {
        case .toFile:
            selectedWorkspace = .filing
            selectedOrganizeLens = .toFile
        case .compare:
            let enabled = settings.enabledProviders
            guard enabled.count >= 2 else { return }
            selectedWorkspace = .compare
            leftProviderId = enabled[0].id
            rightProviderId = enabled[1].id
        }
    }

    /// The user reached the end of the form.
    private func finishSetup() {
        hasCompletedSetup = true
        // The retired tour's flag is set too, so a build that predates the form (a rollback, say)
        // does not greet a user who has already been through setup.
        hasSeenFirstRunWelcome = true
        dismissSetup()
    }

    /// The destination picker, floated over the window on a scrim, like the Settings overlay: a
    /// card that wants the app's glass needs the app behind it, and a sheet's own opaque window
    /// backing would composite every material onto white. Inside the main window it also floats
    /// over the content in full screen without moving the user to another Space.
    @ViewBuilder
    private var destinationOverlay: some View {
        if let pending = pendingDestination {
            GeometryReader { proxy in
                ZStack {
                    // `overlayScrimOpacity`'s Clear value at every level, which in Light is no
                    // dimming at all. This card takes the app's level verbatim, so a heavy scrim
                    // would leave clear material with nothing to reveal. Enough to focus the card,
                    // not enough to switch the window off.
                    OverlayScrim(level: .clear)
                        .ignoresSafeArea()
                        // Clicking away cancels, like every other overlay. Nothing has moved yet,
                        // so dismissing loses nothing.
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
            places: pendingPlaces,
            showHidden: syncManager.showHiddenFiles,
            onCommit: { destination in
                DestinationRecents.record(destination, providerRoot: destinationRecentsRoot(
                    for: destination, requestRoot: pending.request.providerRoot))
                pending.onCommit(destination)
                pendingDestination = nil
            },
            onChooseOther: {
                pendingDestination = nil
                // Deferred a runloop turn: `onOther` runs a modal NSOpenPanel, and AppKit handles a
                // modal raised while the overlay that launched it is still animating out
                // unpredictably. Let the card go first.
                DispatchQueue.main.async {
                    guard let chosen = pending.onOther() else { return }
                    DestinationRecents.record(chosen, providerRoot: pending.request.providerRoot)
                    pending.onCommit(chosen)
                }
            },
            onCancel: { pendingDestination = nil },
            // A new folder is on disk whether or not the transfer after it goes ahead, so the pane
            // showing its parent lists it now, as ⌘N's new file is listed. Not compared at once in
            // Compare: the transfer refreshes and compares both panes itself, and a rescan now
            // would only be superseded.
            onFolderCreated: { rereadPanesAfterEditorWrite($0, writer: "The destination picker made", comparesInCompare: false) }
        )
        .contentSurface(hue: glassHue, tint: surfaceTint)
        // The level at face value, with a ground under the content — see `groundedGlassCard`, which
        // also owns the hairline in both schemes. Flooring this to Frosted would make Clear and
        // Frosted indistinguishable.
        .groundedGlassCard(level: glassLevel)
        .overlayPanelShadow()
    }

    @ViewBuilder
    private var settingsOverlay: some View {
        // The card is sized in points and grows with the Text size setting, but the window's own
        // minimum is 804×560, less than the card wants once `hostMargin` is off it. Hand it the
        // space it has so it can clamp itself rather than hang off the edge.
        GeometryReader { proxy in
            ZStack {
                OverlayScrim(level: glassLevel)
                    // Lightens for `.clear` (`overlayScrimOpacity`), so the window stays visible
                    // through the card; the card's own ground keeps its text legible.
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

    /// The Settings card. It takes the accent tint and the glass material like every other surface,
    /// at the level's face value: `groundedGlassCard` rather than `glassCardStyle`. Clear glass
    /// over live content would be two layers of text competing; the ground under the content solves
    /// that without flooring Clear to Frosted, which would make the two levels draw the identical
    /// card.
    @ViewBuilder
    private func settingsCard(available: CGSize) -> some View {
        SettingsView(
            selection: $settingsTab,
            onClose: { showSettings = false },
            syncManager: syncManager,
            onResetAllSettings: { resetAllSettingsAction() },
            // Unconditional, like the Help entry: setup has things to offer a machine already
            // through it, and finding it should not depend on the gate.
            onRunSetup: {
                showSettings = false
                setupDismissedThisSession = false
                showSetup = true
            },
            onResetSetup: { resetSetupAction() },
            // Organize ▸ People's "Show Their Files": the same gather ⌘K's People rows reach, with
            // the sheet closed first so the answer lands on a pane the user can see.
            onShowPerson: { person in
                showSettings = false
                acceptPersonScope(person)
            },
            // Organize ▸ Suggestions' pointer at "Reading your documents". Settings and Help are
            // mutually exclusive in the latch chain above, so the sheet closes on the way rather
            // than staying behind the article, the same hand-off `onShowPerson` makes.
            onOpenHelp: { topic in
                showSettings = false
                helpTopic = topic
                showHelp = true
            },
            // To File's "Open Rules": the Organize workspace on its Rules, with the sheet closed
            // so the answer is on screen.
            onOpenRules: {
                showSettings = false
                show(.rules)
            },
            availableSize: available,
            oneWaySync: AnyView(OneWaySyncSettingsView()),
            onCustomizePaneBar: { showPaneBarCustomizer = true },
            savedSignatures: AnyView(EditorPDFSavedSignaturesList())
        )
        .environment(\.cloudAppStatusLabels, cloudApps.problems.mapValues(\.shortLabel))
        .environmentObject(settings)
        .contentSurface(hue: glassHue, tint: surfaceTint)
        .groundedGlassCard(level: glassLevel)
        // The hairline comes from `groundedGlassCard` (`.quaternary` in light, the specular edge in
        // dark), so a card adds none of its own, or the dark border doubles. The floating-modal
        // drop shadow, deeper than a content card's: this panel should read as lifted off the
        // window, whatever material it resolved to.
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
            // Capture the handler when the button is built, not when it's clicked: SwiftUI may run
            // the alert's isPresented setter (which clears currentError and, via its didSet, nils
            // currentErrorRetry) before the button action — the unspecified ordering documented at
            // FileSyncManager.verifiedCopyDialogDismissed. Read at click time, Retry would silently
            // no-op.
            let retry = syncManager.currentErrorRetry
            Button("Retry") {
                syncManager.currentError = nil
                retry?()
            }
            // Deliberately the Return-key default (it's also listed first): retrying is safe to
            // mash because every destructive operation in this app confirms separately. Escape
            // stays on Dismiss via its .cancel role.
            //
            // No `.shortcutKeycap` here: `.alert` renders its buttons through the native alert
            // machinery, which drops custom modifiers, so a keycap would never reach the screen or
            // the accessibility tree. The alert's default-button highlight is the system's version
            // of the same badge.
            .keyboardShortcut(.defaultAction)
        case .dismiss:
            Button("Dismiss", role: .cancel) {
                syncManager.currentError = nil
            }
        }
    }

    /// The alert body: the human message, then the underlying reason and affected path when known.
    /// The path is labelled and tilde-abbreviated, matching the "From:/To:" convention in
    /// `SyncOperationAlerts`.
    private func errorAlertMessage(_ error: SyncError) -> String {
        var lines = [error.message]
        if let reason = error.reason, !reason.isEmpty { lines.append(reason) }
        if let path = error.path {
            // "Location:" deliberately, with no File/Folder distinction. Deciding one would need a
            // stat, on the main thread on every alert re-render, against the path most likely to
            // sit on a dead volume (it just failed). A neutral label is also the only honest one:
            // createFolderFailed carries the parent directory and bulkFailed only the first item's
            // path.
            lines.append("Location: \((path as NSString).abbreviatingWithTildeInPath)")
        }
        return lines.joined(separator: "\n")
    }

    /// User-triggered refresh: clears prefetch cache so new files on disk appear immediately.
    func forceRefreshAction() {
        Logger.shared.info("User requested a force refresh")
        // Drop the cache and bump the scan-config epoch so this supersedes any same-target refresh
        // already in flight: a bare cache clear leaves the RefreshKey identical, and the forced
        // rescan would be deduped away, silently doing nothing.
        syncManager.prepareForcedRescan()
        refreshAction()
    }

    /// The folder watcher's opt-in step: the panes in `scope` changed on disk and Settings ▸ Browse ▸
    /// "Rescan when files change" is on, so re-read them. Off (the default), the scan age says
    /// "changed since" instead, so rows never move mid-review. No cache drop: the manager already
    /// dropped the stale walks and bumped the epoch, and never calls this while another refresh
    /// runs.
    func rescanAfterDiskChange(_ scope: FileSyncManager.PaneReloadScope) {
        guard settings.rescanWhenFilesChange else { return }
        Logger.shared.info("Rescanning \(scope.describedPanes): files changed there on disk")
        refreshAction(reloading: scope)
    }

    // MARK: Lens scans — Find Duplicates

    /// Whether a lens scan or inspect should target the right pane. Always false in a single-source
    /// workspace (the rail is the left pane), so a stale right-pane selection can't silently aim
    /// the scan at the hidden provider. In compare mode the focused pane wins. See
    /// `PaneLogic.lensTargetsRightPane`.
    var lensTargetIsRight: Bool {
        PaneLogic.lensTargetsRightPane(isCompare: layoutMode == .compare,
                                       focusedSide: syncManager.focusedPaneSide,
                                       activePane: activePane)
    }

    /// The provider name for the pane a lens scan targets: the single-source rail is always the
    /// left pane; in compare mode it follows the focused pane.
    ///
    /// The plain name, without "(left)"/"(right)": that suffix tells two visible panes apart, and a
    /// lens workspace shows one, so it would disambiguate against a pane that is not on screen. The
    /// Differences table and the duplicate-review banner, which do show both, keep `paneNames` and
    /// its suffix.
    var lensProviderName: String {
        paneNames.plain(isLeft: !lensTargetIsRight)
    }

    /// The absolute (tilde-expanded) folder a lens scan walks: the targeted pane's current
    /// directory (always the left rail in single-source; the focused pane in compare), including
    /// where the pane is browsing, so clicking through columns moves the target and the "Scan
    /// '<folder>'" offer follows in real time. See `PaneLogic.lensScanRoot`.
    var lensScanRootExpanded: String {
        PaneLogic.lensScanRoot(
            focusRootExpanded: ((lensTargetIsRight ? currentRightPath : currentLeftPath) as NSString)
                .expandingTildeInPath,
            // Only where the columns are on screen. In Tree the stack is parked state, and reading
            // it would make the "Scan '<folder>'" offer name and walk a folder the pane is not
            // showing. The tree lists its scope whole, so its scope is what a scan of it covers.
            browsePath: paneDrawsColumns(isLeft: !lensTargetIsRight)
                ? (lensTargetIsRight ? syncManager.rightBrowsePath : syncManager.leftBrowsePath)
                : PaneBrowsePath())
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

    /// Opens Duplicates on one row's file. Aimed at the row's own side rather than at
    /// `lensTargetIsRight`'s focused pane: a right-click does not necessarily move focus, and a
    /// scan aimed at the other pane would answer about a different provider.
    func findDuplicatesOfAction(_ node: FileNode, isLeft: Bool) {
        revealCoordinator.findDuplicates(of: node, isLeft: isLeft)
    }

    /// Switches to the Duplicates lens and scans the subject: the scope when set, the focused
    /// pane's folder otherwise.
    ///
    /// The scope, because every control that starts this is captioned for the scope, while the
    /// pane's target moves on every column click; a pane-targeted scan would replace the duplicate
    /// list (results are never merged) with one the scope then shows as clean. The header's Rescan
    /// hides once the pane leaves the subject (`targetMoved`).
    func findDuplicatesAction() {
        let root = organizeScope?.path ?? lensScanRootExpanded
        guard !root.isEmpty else { return }
        Logger.shared.info("User requested Find Duplicates in \(root)")
        show(.duplicates)
        let options = DuplicateFinderOptions.fromDefaults()
        syncManager.startFindDuplicates(root: URL(fileURLWithPath: root), options: options)
    }

    /// Shows the saved Storage report for the current root, if Storage is what's on screen and
    /// nothing has been analyzed yet. Safe to call from any trigger — see the call sites.
    func restoreStorageLensIfShowing() {
        // Keyed on the lens, not the workspace, as in `autoRescanLensIfShowing`:
        // `selectedWorkspace == .filing` is true on six pages and only one of them is Storage.
        guard selectedWorkspace == .filing, selectedOrganizeLens == .storage else { return }
        // A report about somewhere else cannot stand under a declared scope, so it goes.
        //
        // `restoreStorageLens` refuses while a report is in hand, so without this a scope change
        // would leave the previous root's treemap under the new header. Clearing first turns the
        // restore below into a re-analysis; `clearStorageLens()` keeps the stored snapshot, so a
        // scope you return to restores instantly. Only under a scope (`storageReportStandsUnder` is
        // true without one). Not while a build runs: `clearStorageLens()` cancels it, and the work
        // may already be for the new root.
        if !syncManager.isBuildingStorageLens,
           !OrganizeAim.storageReportStandsUnder(scope: organizeScope,
                                                 reportRoot: syncManager.storageLensRoot?.path) {
            syncManager.clearStorageLens()
        }
        // The scope is the subject. `StorageLensStore` keys snapshots by absolute root path, so a
        // scoped report and a pane-root report coexist rather than clobber one another. Same
        // fallback as `autoRescanLensIfShowing`.
        let root = organizeScope?.path ?? lensScanRootExpanded
        guard !root.isEmpty else { return }
        syncManager.restoreStorageLens(root: URL(fileURLWithPath: root))
    }

    /// Re-runs the showing lens's scan on open, for Duplicates and Organize, whose results are
    /// never restored (their rows carry destructive applies; see `StorageLensSnapshot`). The
    /// manager declines unless the target was scanned to completion before, still exists, and
    /// nothing has run this session, so the rows are always live. Organize's cost question lives
    /// inside the scan, so this stays a plain synchronous call.
    func autoRescanLensIfShowing() {
        // Keyed on the lens, not the workspace: duplicates and filing are two rail items inside one
        // workspace. The overview deliberately rescans nothing: it reports what each lens already
        // knows.
        guard selectedWorkspace == .filing, let lens = selectedOrganizeLens else { return }
        // A scope makes the auto-rescan refresh the subject, not the pane. This fires on every
        // column click; targeting the pane under a scope would let browsing into another
        // previously-scanned folder replace `filingSuggestions` with files the scope then filters
        // to nothing. The manager still declines unless the target was scanned to completion before
        // and nothing has run this session.
        let target = organizeScope?.path ?? lensScanRootExpanded
        switch lens {
        case .duplicates:
            guard !target.isEmpty else { return }
            syncManager.autoRescanDuplicatesIfEligible(root: URL(fileURLWithPath: target),
                                                       options: DuplicateFinderOptions.fromDefaults())
        // The one filing scan publishes both of these lists (the loose files and the rename
        // backlog, risky names included), so either showing is a reason to refresh it.
        case .toFile, .renames:
            // The taxonomy a filing scan files against — File Into's folder, which is the anchor
            // unless the source is a folder or the user chose another.
            let root = lensFilingDestinationRoot
            guard !target.isEmpty, !root.isEmpty else { return }
            syncManager.autoRescanFilingIfEligible(
                folder: URL(fileURLWithPath: target), providerRoot: URL(fileURLWithPath: root),
                providerName: lensFilingProviderName, nameProvider: lensProviderType,
                reportsTreeFindings: lensFilingReportsTreeFindings)
        // Storage is handled by `restoreStorageLensIfShowing`, not here, and the arm is written out
        // to say so. Its results are restored rather than recomputed (the one lens whose report
        // survives a launch), and both functions fire from the same triggers, so calling the
        // restore here too would be a second path to one behaviour.
        case .storage:
            break
        // Restructure reads the profile rather than the disk, and rules are configuration —
        // neither goes stale because a folder changed.
        case .restructure, .rules:
            break
        }
    }

    /// The person the find was turned into a gather for, and where the gather is. Held here, not in
    /// the pane, because a gather collects across the whole source. Carries the phase, so the slot
    /// is taken the moment the offer is accepted instead of reading as "nothing happened" during
    /// the sweep.
    struct PersonScope: Equatable {
        let person: Person
        /// `let`, like `person`: every write replaces the whole scope, and nothing mutates a phase
        /// in place.
        let phase: PersonGatherPhase

        /// Whether a finished sweep for `person` may still write its answer into the slot.
        ///
        /// The slot must be the same person and still waiting. This is the last-write-wins half of
        /// the double-accept race: cancellation stops the loser's sweep, but a sweep that left the
        /// loop before the cancel lands would otherwise write over the winner's answer.
        static func awaits(_ person: Person, in current: PersonScope?) -> Bool {
            current?.person == person && current?.phase == .gathering
        }

        /// Whether accepting an offer for `person` should start a sweep, given what is in the slot.
        /// A second ⌘↩ on the same offer must not restart a sweep already partway through; anything
        /// else starts one.
        ///
        /// Exactly `!awaits`, not a restatement: both ends of the race ask "is a gather for this
        /// person in flight?", and two copies could drift while every test passes.
        static func shouldStart(_ person: Person, given current: PersonScope?) -> Bool {
            !awaits(person, in: current)
        }
    }

    /// The in-flight sweep behind `personScope`, held so a successor or a clear can cancel it;
    /// otherwise accepting twice would race two gathers with last-write-wins.
    ///
    /// Deliberately not cleared when a gather finishes. A completed `Task` retains nothing that
    /// matters, and `personGatherTask = nil` at the end of the task body would be a race: task 1
    /// finishing after task 2 was assigned would null task 2's handle, leaving the next accept or
    /// clear nothing to cancel. Every writer is on the main actor and outside the task body; keep
    /// it that way. Cancelling a finished task is a no-op.
    @State private var personGatherTask: Task<Void, Never>?

    /// Accepts the ⌘F offer: compute what is theirs and show it. On accept, never per keystroke:
    /// the gather walks every surveyed document, while the offer row is one tokenize. The corpus
    /// read and the sweep run off the main actor in
    /// ``gatherOffMainActor(personId:profileId:directory:profile:registry:)``; this task only waits
    /// and writes the result.
    func acceptPersonScope(_ person: Person) {
        guard PersonScope.shouldStart(person, given: personScope) else { return }
        guard let profile = syncManager.filingFolderProfile,
              let registry = syncManager.filingPersonRegistry,
              let directory = syncManager.filingProfilesDirectory else {
            // Cancel first, like every other path that takes the slot: a sweep for the previous
            // person can no longer be shown once this write lands, and would sweep every document
            // for an answer `awaits` then discards.
            personGatherTask?.cancel()
            personGatherTask = nil
            // Said, not swallowed. The offer needs only the roster (`personOffer` guards on
            // `filingPersonRegistry` alone) while the gather needs the survey too, and
            // `FilingProfileStore.personRegistry` reads a roster on a machine with no profile. A
            // roster that outlives its survey would otherwise put an offer on screen whose accept
            // does nothing, silently.
            personScope = PersonScope(person: person, phase: .failed(Self.noSurveyToGather))
            // Said in the log too, and why. The "User asked…" line is logged past this guard, so
            // without this the accept would leave no trace in `~/sync-cloud.log`, and a feature
            // that did nothing would look like one never used.
            Logger.shared.warning("Could not gather \(person.displayName)'s files: this tree has no "
                                  + "readable survey (profile, roster or corpus missing)")
            return
        }
        Logger.shared.info("User asked for everything that is \(person.displayName)'s")
        personGatherTask?.cancel()
        personScope = PersonScope(person: person, phase: .gathering)
        // The folder the artifacts were read from, not the field inside them: the gather reads
        // `filing-corpus.json` under this id, so a disagreement would find no corpus and the accept
        // would return nothing. See `FileSyncManager.filingProfileDirectoryId`.
        let id = syncManager.filingProfileDirectoryId ?? profile.profileId
        // Snapshotted here on the main actor rather than read inside the sweep: the store is
        // `@MainActor` and the sweep deliberately is not. A verdict recorded while a gather runs
        // lands in the next gather, which is right: the one in flight answers the question as it
        // stood when asked.
        let tags = syncManager.filingPersonTagStore?.index ?? PersonTagIndex(tags: [])
        personGatherTask = Task {
            do {
                let files = try await Self.gatherOffMainActor(
                    personId: person.id, profileId: id, directory: directory,
                    profile: profile, registry: registry, tags: tags)
                // Both checks, for different holes. `Task.isCancelled`: a cancel that lands after
                // the sweep returned raises no error, and the slot may now be a second gather for
                // the same person, which `awaits` alone would accept. `awaits`: the slot must still
                // be waiting for this person at all.
                guard !Task.isCancelled, PersonScope.awaits(person, in: personScope) else {
                    // Routine coalescing, so debug, but not silence. The "User asked…" line opens a
                    // walk and the "Gathered N file(s)…" line closes it; a mute branch would leave
                    // an opened sweep that never closes, which reads in the log like a wedged
                    // gather. Says which guard fired, because a cancel and a slot that moved on are
                    // different stories.
                    Logger.shared.debug("People: discarded a finished gather for "
                                        + "\(person.displayName) — "
                                        + (Task.isCancelled ? "it was cancelled"
                                           : "the view is no longer waiting for it"))
                    return
                }
                // The sweep's own outcome, closing the walk "User asked…" opened, so a slow gather
                // and a wedged one read differently in the log. Both branches speak: nil is the
                // corpus going missing between the guard above and the read.
                if let files {
                    // "plus", not a comma: `total` is the claimed rows only (`PersonFileSet` keeps
                    // review rows out of it, because they are questions rather than answers), so "N
                    // of which R" would assert in the log what the queue exists to ask.
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
                // The canceller owns the slot, so there is nothing to write, but there is something
                // to say: this is the third way out of a gather. A ✕ or Esc during the sweep, the
                // common case, would otherwise leave an opened gather with no ending in the log.
                // Debug, like its sibling above: cancelling is routine.
                Logger.shared.debug("People: the gather for \(person.displayName) was cancelled "
                                    + "while it was reading")
            } catch {
                // Nothing below throws anything but cancellation today. Swallowing this anyway
                // would leave the spinner turning forever, so an unexpected failure ends the wait
                // out loud. Same pair of checks as the success path: a dead gather must not write
                // its failure into a live one's slot.
                guard !Task.isCancelled, PersonScope.awaits(person, in: personScope) else { return }
                Logger.shared.warning("The person gather failed: \(error.localizedDescription)")
                personScope = PersonScope(person: person, phase: .failed(
                    "Something went wrong gathering these files: \(error.localizedDescription)"))
            }
        }
    }

    /// What the slot says when there is no survey to gather from, one string because the remedy is
    /// the same: survey the tree. "No readable survey", not "not read yet":
    /// `FilingSurveyStore.corpus` also returns nil for a corpus that fails to decode, when the tree
    /// has been surveyed.
    static let noSurveyToGather =
        "No readable survey of this tree was found, so there is nothing to gather."

    /// Reads the corpus and sweeps it off the main actor: `nonisolated`, so awaiting it from the
    /// main-actor task above hops to the cooperative pool. A `nonisolated` async function called
    /// from a `@MainActor` context does not run on the main thread and inherits cancellation
    /// without a handler, which is why there is no `Task.detached` here.
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
        // these are the two points where a gather cancelled during it can stop.
        try Task.checkCancellation()
        guard let corpus = FilingSurveyStore.corpus(id: profileId, in: directory) else { return nil }
        try Task.checkCancellation()
        return try PersonFiles.gather(personId: personId, corpus: corpus,
                                      profile: profile, registry: registry, tags: tags)
    }

    /// Records a verdict on a review row, and takes the row off the screen.
    ///
    /// The display updates first and synchronously, so the press has an effect in the same frame;
    /// the durable half follows on a task, because deciding the key reads the document. The key is
    /// the PDF's content fingerprint where it has one, so the verdict is not merely a path (the
    /// gather does not yet look up by fingerprint — see `PersonTagStore.keyKind`); anything else
    /// falls back to the path. One PDF read, at the moment of decision. Nothing here moves a file.
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
        // After the display has already moved. If the profile is gone, nothing is written and the
        // verdict comes back as a question next gather. Near-unreachable (the gather that produced
        // this row needed the profile), which is why it must not be silent when it happens.
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

    /// The one way out of a person gather, from every exit — the ✕, Esc, and leaving the workspace.
    /// Cancels a sweep still running so it stops walking documents nobody will see.
    ///
    /// The only place `personScope` is set back to nil. Clearing it by hand would leave the sweep
    /// running, and `PersonScope.awaits` would then discard its answer silently after paying for
    /// it.
    func clearPersonScope() {
        personGatherTask?.cancel()
        personGatherTask = nil
        personScope = nil
    }

    /// Point Organize at one folder: select the filing queue, set the scope, and scan that folder.
    /// Every other lens narrows to the scope for free. The provider root clears the scope — see
    /// ``setOrganizeScope(_:providerRoot:)``.
    /// - Parameters:
    ///   - providerRoot: The row's source root — what the scope is measured against and bounded by.
    ///   - providerAnchor: The row's source anchor — the taxonomy the scan files against. Separate,
    ///     because the root as taxonomy would hand filing the whole account.
    func organizeFolderAction(_ node: FileNode, providerRoot: String, providerAnchor: String) {
        let folder = (node.id as NSString).expandingTildeInPath
        guard !folder.isEmpty, !providerRoot.isEmpty, !providerAnchor.isEmpty else { return }
        Logger.shared.info("User requested Organize for \(folder)")
        setOrganizeScope(folder, providerRoot: providerRoot)
        show(.toFile)
        // Files into the row's source's File Into folder — its anchor, unless it is a folder source
        // or the user chose another.
        let into = filingDestinationRoot(forAnchor: providerAnchor)
        syncManager.startFindFilingSuggestions(
            folder: URL(fileURLWithPath: folder), providerRoot: URL(fileURLWithPath: into),
            providerName: filingProviderName(into: into, anchor: providerAnchor),
            nameProvider: lensProviderType, reportsTreeFindings: into == providerAnchor)
    }

    /// The second deliberate route: the shape question, aimed at one folder. Restructure's answer
    /// already exists (it is read off the survey), so unlike its sibling above there is no scan to
    /// start. Arriving on purpose skips the reveal card, the overview's own rule: the user asked
    /// about this folder, and a "Show findings" card would charge that intent twice.
    func checkFolderShapeAction(_ node: FileNode, providerRoot: String) {
        let folder = (node.id as NSString).expandingTildeInPath
        guard !folder.isEmpty, !providerRoot.isEmpty else { return }
        Logger.shared.info("User asked for the shape of \(folder)")
        setOrganizeScope(folder, providerRoot: providerRoot)
        syncManager.hasReviewedStructure = true
        show(.restructure)
    }

    /// The one write of Organize's scope from this view.
    /// ``OrganizeScope/normalizedPath(_:providerRoot:)`` owns the global-view rule (nil, empty or
    /// the provider root) for both writers, so one state has one encoding. `providerRoot` is
    /// required because a row menu does not move focus: normalizing against the focused pane's root
    /// would drop a folder in the other pane.
    func setOrganizeScope(_ path: String?, providerRoot: String) {
        organizeScopePath = OrganizeScope.normalizedPath(path, providerRoot: providerRoot)
    }

    /// The subtree Organize is answering about, or nil for the global view.
    ///
    /// Re-resolved on read rather than stored, as `LensWorkspaceView` does: the provider can change
    /// under a persisted path, and a scope belonging to a tree no longer showing degrades to the
    /// global view instead of filtering every lens to nothing.
    var organizeScope: OrganizeScope? { resolvedOrganizeScope(organizeScopePath) }

    /// The read half of the round trip. It must agree with the write that a stored provider root
    /// means "no scope", or the chip and the filter would disagree about the same string, and it
    /// does by construction: ``OrganizeScope/normalizedPath(_:providerRoot:)``, which the write
    /// goes through, is this same resolution with `?.path ?? ""` on the end.
    private func resolvedOrganizeScope(_ path: String?) -> OrganizeScope? {
        guard let path, !path.isEmpty else { return nil }
        return OrganizeScope(path: path, providerRoot: lensProviderRootExpanded)
    }

    /// Navigate to a lens inside Organize — both halves, always.
    ///
    /// The single place programmatic navigation names a rail item, so a caller cannot set the
    /// workspace, forget the lens, and land on the overview having silently dropped the request.
    func show(_ lens: OrganizeLens) {
        selectedWorkspace = .filing
        selectedOrganizeLens = lens
    }

    func buildStorageLensAction() {
        // The scope is the subject: analysing the pane root while a scope chip is up would put a
        // whole-tree treemap under a narrowed header. The same fallback `autoRescanLensIfShowing`
        // uses.
        let root = organizeScope?.path ?? lensScanRootExpanded
        guard !root.isEmpty else { return }
        Logger.shared.info("Storage: requested for \(root)")
        // Both halves: setting the workspace alone would land on Organize's overview and quietly
        // lose the request, the failure `Workspace.destination(for:)` exists to prevent for
        // programmatic callers.
        selectedWorkspace = .filing
        selectedOrganizeLens = .storage
        syncManager.startBuildStorageLens(root: URL(fileURLWithPath: root))
    }

    /// The duplicate-review flow's coordinator: `compareCopies`, the keep-left / trash-right
    /// banner, and the `CompareReviewReducer` effect execution live there. Stateless by design: it
    /// closes over this view's App-owned bindings and live computed context, so a fresh value per
    /// access is fine, and the review state still survives a window cycle (see `duplicateReview`).
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
    /// `pendingSwapProviderChanges` with `plan.suppressCount` first: the plan contains only writes
    /// that really change an id, so each fires exactly one onChange to suppress.
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

    /// The same pane's source anchor: what everything the user authored as "provider-relative" is
    /// measured from — an automation's `Invoices/{year}`, the loose-files inbox, the filing
    /// taxonomy.
    ///
    /// The landing folder, not the root, because those values were written against the documents
    /// folder: from the account root, `TODO` could name a different folder, and the taxonomy would
    /// walk gigabytes of recordings and caches. `openAt` is seeded to the documents folder, so
    /// existing sources resolve as before.
    var lensProviderAnchorExpanded: String {
        providerAnchorExpanded(forProviderId: lensTargetIsRight ? rightProviderId : leftProviderId)
    }

    /// One provider's anchor, expanded — ``lensProviderAnchorExpanded`` asked about a named
    /// provider, for the row menus that must not ask about whichever pane holds focus.
    func providerAnchorExpanded(forProviderId id: String) -> String {
        (settings.landingPath(for: id) as NSString).expandingTildeInPath
    }

    /// One provider's root, expanded — the shape ``lensProviderRootExpanded`` answers, asked about
    /// a named provider rather than whichever pane holds focus.
    ///
    /// Split out because "the focused pane's root" is the wrong question for anything a row menu
    /// starts: a SwiftUI context menu does not move focus, so a right-click in the unfocused pane
    /// would be answered with the other pane's root.
    func providerRootExpanded(forProviderId id: String) -> String {
        (settings.rootPath(for: id) as NSString).expandingTildeInPath
    }

    /// A root-relative path held by one pane, re-expressed for the other, whose root may differ.
    ///
    /// Named for the pane it answers about (`isLeft` is the pane the result is for), because
    /// `PaneTabWiringTests` requires every side-taking call in a tab verb to name the pane it
    /// moves. A translation is two-sided, so it is spelled once here. See `PathBoundary.reanchor`:
    /// a path the destination cannot express is carried across unchanged.
    func relativePathForPane(_ relative: String, isLeft: Bool) -> String {
        PathBoundary.reanchor(relative,
                              from: paneOpenAt(isLeft: PaneSideChoice.sibling(isLeft)),
                              to: paneOpenAt(isLeft: isLeft))
    }

    /// A pane's landing folder as a root-relative path — the origin its positions are quoted
    /// against.
    ///
    /// Read live rather than cached: it is a stored preference that discovery republishes, and a
    /// stale copy would translate a linked move onto the folder the source used to open at.
    func paneOpenAt(isLeft: Bool) -> String {
        settings.openAtIfReachable(for: isLeft ? leftProviderId : rightProviderId)
    }

    /// `paneOpenAt` in the shape `FileSyncManager.paneOpenAt` takes.
    ///
    /// A named property rather than a closure literal at the assignment: written inline, it pushes
    /// the `onAppear` chain past the Swift type-checker's budget ("unable to type-check this
    /// expression in reasonable time").
    private var paneOpenAtForSyncManager: (Bool) -> String {
        { [settings] isLeft in
            settings.openAtIfReachable(for: isLeft ? self.leftProviderId : self.rightProviderId)
        }
    }

    /// The pane → source id mapping, in the shape `FileSyncManager.paneSourceId` takes. Read live
    /// for `paneOpenAtForSyncManager`'s reason, and a named property for the same type-checker
    /// reason.
    private var paneSourceIdForSyncManager: (Bool) -> String {
        { isLeft in isLeft ? self.leftProviderId : self.rightProviderId }
    }

    /// The provider ruleset the name check runs against — the targeted pane's source (the left rail
    /// in single-source; the focused pane in compare). See `SettingsManager.nameRuleType(for:)` for
    /// its two substitutions: OneDrive for an unresolvable id, and the user's `folderNameRule` for
    /// a folder source.
    var lensProviderType: CloudProvider.ProviderType {
        settings.nameRuleType(for: lensTargetIsRight ? rightProviderId : leftProviderId)
    }

    /// Toggles the shared Quick Look panel for `url`: opens it, or closes it when it already shows
    /// that file; a different file re-targets it. `.quickLookPreview($quickLookURL)` nils the
    /// binding on manual dismissal, keeping this in step.
    /// - Parameter followsPane: whether the preview follows the pane selection (re-targets as it
    ///   moves, closes when it clears). False for previews from a Differences row or the Info
    ///   inspector, which hold their own selections.
    func toggleQuickLook(_ url: URL, followsPane: Bool = false) {
        let closing = quickLookURL == url
        quickLookURL = closing ? nil : url
        quickLookFollowsPane = closing ? false : followsPane
    }

    /// The pane selection the open panel follows: the resolution Space uses to pick a target, so
    /// the panel can never rest on a file Space would not have previewed.
    var paneQuickLookTarget: String? {
        CurrentSelection.primaryPanePath(
            left: syncManager.selectedLeftPaths,
            right: syncManager.selectedRightPaths,
            singleSource: layoutMode == .singleSource)
    }

    /// Applies `CurrentSelection.previewFollow` to the panel that is open right now.
    ///
    /// Called from an `onChange` on `paneQuickLookTarget`, derived from two `@Published` sets, so
    /// it fires for a click, a search reveal, a re-root and a background republish alike; the
    /// `.stay` arms keep all but the first free.
    func followPaneSelectionWithQuickLook() {
        switch CurrentSelection.previewFollow(showing: quickLookURL?.path,
                                              followsPane: quickLookFollowsPane,
                                              panePath: paneQuickLookTarget) {
        case .retarget(let path): quickLookURL = URL(fileURLWithPath: path)
        case .close: quickLookURL = nil; quickLookFollowsPane = false
        case .stay: break
        }
    }

    /// Dry-runs the enabled automation rules over the focused folder. Preview only: the manager
    /// walks and evaluates on-device and publishes what would happen; no file is moved. Triggered
    /// from the Automations lens's own button, so the pane is already on that lens when this runs.
    func startAutomationPreviewAction(only: UUID? = nil) {
        let root = lensScanRootExpanded
        // Destinations anchor at File Into's folder, not the focused subfolder, so a rule's
        // "Home/Utilities/…" template files there even when previewing inside a subfolder: the same
        // tree To File files into, so a rule previewed from Home ▸ Downloads lands where its
        // suggestions would.
        let providerRoot = lensFilingDestinationRoot
        guard !root.isEmpty, !providerRoot.isEmpty else { return }
        Logger.shared.info("User requested Rules preview for \(root)\(only == nil ? "" : " (single rule)")")
        show(.rules)
        syncManager.startAutomationDryRun(root: URL(fileURLWithPath: root),
                                          destinationRoot: URL(fileURLWithPath: providerRoot),
                                          providerName: lensProviderName, only: only)
    }

    /// The folder a Filing scan targets right now: the focused folder, always.
    ///
    /// Never silently the loose-files inbox, even at the provider root: the subject is something
    /// the user sets, not something the pane's position implies. The inbox is a visible one-click
    /// scope on Organize's overview instead (``filingInboxFolder``), and it would be the wrong
    /// default for every lens but To File.
    var filingScanTargetFolder: String? {
        let focused = lensScanRootExpanded
        guard !focused.isEmpty, !lensProviderRootExpanded.isEmpty else { return nil }
        return focused
    }

    /// The loose-files inbox, when it exists — the path only, with no opinion about when to use it.
    ///
    /// The one reader of the inbox setting. The existence check stays because a shortcut offering a
    /// missing folder is worse than no shortcut. nil when the setting is blank or the folder is
    /// missing.
    var filingInboxFolder: String? {
        // The anchor — see `lensProviderAnchorExpanded`. `TODO`, this setting's default, can name a
        // folder at the top of a OneDrive account as well as one inside its Documents, so anchoring
        // at the root would silently change which folder the shortcut offers.
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

    /// Starts a Filing scan for loose files, with the whole provider as the taxonomy.
    ///
    /// Aimed at the subject (the scope when set) for the reasons on ``findDuplicatesAction()``. The
    /// miss would be sharper here, because the filing pass enumerates the direct children of one
    /// folder: scoped to `TODO` from a pane at the root, a pane-targeted click would scan the
    /// root's loose files, and To File would then report "Nothing to do in TODO" without TODO ever
    /// being enumerated.
    func findFilingSuggestionsAction(ignoringCache: Bool = false) {
        // File Into's folder: the anchor for a cloud source, the folder survey's root for a folder
        // source, or whatever the user chose.
        let root = lensFilingDestinationRoot
        // The provider root is the taxonomy the scan files against, so it is required whichever
        // folder is enumerated. `filingScanTargetFolder` folds that check in; the scope branch
        // needs it stated.
        guard !root.isEmpty, let folder = organizeScope?.path ?? filingScanTargetFolder else { return }
        Logger.shared.info("User requested Filing suggestions for \(folder)"
            + (ignoringCache ? " (ignoring saved suggestions)" : ""))
        selectedWorkspace = .filing
        syncManager.startFindFilingSuggestions(folder: URL(fileURLWithPath: folder),
                                               providerRoot: URL(fileURLWithPath: root),
                                               providerName: lensFilingProviderName,
                                               // Names come back on this pass — see
                                               // `detectRiskyNames`. The ruleset is the scanned
                                               // provider's, not whichever pane is focused later.
                                               nameProvider: lensProviderType,
                                               ignoringCache: ignoringCache,
                                               reportsTreeFindings: lensFilingReportsTreeFindings)
    }

    /// Re-derives the folder memory from the provider tree as it stands now.
    ///
    /// Its own action rather than a step inside the scan: the scan must stay fast, a re-survey
    /// reads documents the scan has no interest in (every already-filed one that changed), and its
    /// payoff is the next scan. Tying it to Rescan would make the common act pay for the occasional
    /// one.
    func updateFolderMemoryAction() {
        // The survey covers the folder the profile was built from, whatever this pane shows;
        // `resurveyFilingMemory` decides that and logs which folder it read. The anchor goes along
        // so that line can say when the pane is somewhere else.
        let root = lensProviderAnchorExpanded
        guard !root.isEmpty else { return }
        Logger.shared.info("User requested a folder-memory re-survey from \(root)")
        Task { await syncManager.resurveyFilingMemory(root: URL(fileURLWithPath: root)) }
    }

    /// The per-side values a pane is built from, resolved once per render by `paneContext` so the
    /// header and tree builders don't each repeat the same `isLeft ?` pairs, which could drift when
    /// an argument changes on one side only.
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
        /// How this pane presents its tree. The comparison panes, the single-source rail and Browse
        /// all reach Columns, each from its own stored key — see `resolvedViewMode(isLeft:)`.
        let viewMode: PaneViewMode
        /// Path → children for the columns presentation, cached per publish by the manager. `nil`
        /// in Tree mode: building it walks the whole tree, and a pane that will never draw a column
        /// should not pay that on every publish.
        let childrenIndex: PaneChildrenIndex?
    }

    /// Internal rather than private so `ContentView+PaneSearch.swift` resolves the pane it searches
    /// from the same place `paneColumn` does; a second copy of "which tree is this pane showing"
    /// could run a search against the other side's nodes.
    func paneContext(isLeft: Bool) -> PaneContext {
        // The rail and Browse each read their own key, not the left pane's: same pane state,
        // different surfaces, and a choice made on one must not restack the others.
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

    /// Runs a close aimed at the strip with the pointer, and keeps the strip if it would go, so the
    /// header and list do not jump up 34pt under the pointer. The strip shows the one tab left
    /// until the pointer leaves it, then slides away. A close from the header's or a row's menu
    /// holds it too while the pointer stays where the menu stood (`PaneMenuOrigin`). Not a tab verb
    /// itself: the close it runs is, and the focus rule
    /// (`everyTabVerbTheHostWiresReachesTheFocusDoorUnconditionally`) follows that close.
    private func holdingTabStrip(isLeft: Bool, _ close: () -> Void) {
        let wasShown = paneShowsTabStrip(isLeft: isLeft)
        close()
        guard wasShown && !paneShowsTabStrip(isLeft: isLeft) else { return }
        if tabStripPointer.isOver(isLeft: isLeft) {
            tabStripHold.hold(isLeft: isLeft)
        } else if let area = PaneMenuOrigin.shared.justChosenArea(at: NSEvent.mouseLocation),
                  area.contains(NSEvent.mouseLocation) {
            tabStripHold.hold(isLeft: isLeft)
            PaneMenuOrigin.shared.watch(area, stillHeld: { tabStripHold.holds(isLeft: isLeft) },
                                        pointerOnStrip: { tabStripPointer.isOver(isLeft: isLeft) },
                                        release: { tabStripHold.release(isLeft: isLeft) })
        }
    }

    /// One resizable file pane: provider header stacked over its file tree.
    ///
    /// No `@ViewBuilder`: the body computes its locals and then has a single `return`, which
    /// disables the builder anyway (the compiler says so).
    func paneColumn(isLeft: Bool) -> some View {
        let pane = paneContext(isLeft: isLeft)
        // Resolve the action-bar selection once per render (a tree walk over tens of thousands of
        // nodes) and reuse it for the overlay gate and the layout animation below; reading
        // `activeSelectionNodes` in each spot would re-walk the tree several times per render and
        // lag the selection.
        let barNodes = barSelectionNodes(isLeft: isLeft)
        // This pane's selection, a different question from `barNodes`: that one is the active
        // pane's, and empty on every side and workspace the floating action bar does not appear on.
        // Resolved once and handed to the header, which needs the count (to disable its Delete) and
        // the nodes (to act).
        let ownNodes = paneSelectionNodes(isLeft: isLeft)
        // Read the scroll-flip trigger so this column re-renders when a scroll crossing flips the
        // edge; the value itself is unused — the edge is resolved fresh below.
        _ = isLeft ? leftBarAtTop : rightBarAtTop
        // Resolve the bar's edge synchronously from the pane's live geometry and current selection.
        // Because this runs in `body`, a selection change (which re-renders here) lands the bar at
        // the correct edge in the same pass — no gate, no deferred flip.
        let placement = isLeft ? leftPlacement : rightPlacement
        // The result message, when this pane is where it shows. It docks in one stack with the bar,
        // so the edge is resolved for both, guarding the bar's selection or, with no bar (Browse,
        // after a delete), this pane's own, whose last on-screen position the placement keeps as
        // the anchor once a delete has taken it.
        let message = paneResultMessage(isLeft: isLeft)
        let barAtTop = placement.resolveAtTop(
            guarding: Set((barNodes.isEmpty ? ownNodes : barNodes).map(\.id)),
            bar: !barNodes.isEmpty, message: message != nil)
        return VStack(spacing: 0) {
            // The tab strip is a sibling of the header and the list, never a wrapper around them.
            // Re-nesting this VStack fails
            // `PaneQuickLookScopeTests.testTheHandlerIsAttachedToTheFileList`, which requires the
            // list's exact indentation. One insertion point here serves Browse, both Compare panes
            // and the Organize rail, because they are all this one function.
            if paneShowsTabStrip(isLeft: isLeft) {
                PaneTabStrip(
                    items: paneTabItems(isLeft: isLeft),
                    // Keep the seam's ⇄ / 🔗 capsule clear. It straddles the pane boundary at this
                    // height, so in Compare it would land on the left pane's ＋ and on the right
                    // pane's first chip.
                    leadingInset: seamInset(isLeft: isLeft, leading: true),
                    trailingInset: seamInset(isLeft: isLeft, leading: false),
                    // The hue, because `Color.accentColor` inside the strip would be the system
                    // accent, not the window's.
                    accent: glassHue.accentColor,
                    // The same predicate the pane's rows wash their selection from, so the live
                    // chip and the selected rows under it can never name different panes.
                    isActivePane: paneWearsActiveAccent(isLeft: isLeft),
                    onSelect: { selectTab(id: $0, isLeft: isLeft) },
                    // Closes aimed with the pointer, so the strip stays under it.
                    onClose: { id in holdingTabStrip(isLeft: isLeft) { closeTab(id: id, isLeft: isLeft) } },
                    onCloseOthers: { id in
                        holdingTabStrip(isLeft: isLeft) { closeOtherTabs(keeping: id, isLeft: isLeft) }
                    },
                    onDuplicate: { duplicateTab(id: $0, isLeft: isLeft) },
                    onCopyPath: { copyTabPath(id: $0, isLeft: isLeft) },
                    onReorder: { id, index in moveTab(id: id, to: index, isLeft: isLeft) },
                    onSetPinned: { id, pinned in setTabPinned(pinned, id: id, isLeft: isLeft) },
                    onNew: { openNewTabHere(isLeft: isLeft) })
                    // The same wash the header and the list take, so the pane reads as one surface
                    // rather than with a pale stripe across its top at a high Tint. Ordered before
                    // the card, which clips: `surfaceCard` clip-shapes first, so a wash applied
                    // after it would square off the rounded corners (`bottomSectionCard` stacks
                    // these the same way).
                    .contentSurface(hue: glassHue, tint: surfaceTint)
                    .paneCardIfNeeded(surfaceStyle, level: glassLevel, accentBorder: paneCardAccent(isLeft: isLeft))
                    // Where the pointer is, for the hold above; leaving lets a held strip go.
                    .onHover { inside in
                        tabStripPointer.setOver(inside, isLeft: isLeft)
                        if !inside, tabStripHold.holds(isLeft: isLeft) { tabStripHold.release(isLeft: isLeft) }
                    }
                    // A strip that goes from under the pointer reports no exit.
                    .onDisappear { tabStripPointer.setOver(false, isLeft: isLeft) }
                    // The strip's arrival is the feedback for ⌘T: the new tab opens on the folder
                    // you are already in, so both chips say the same thing and nothing else
                    // changes. Sliding in from the top is what tells you it worked.
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            PaneHeader(
                title: pane.title,
                provider: settings.availableProviders.first(where: { $0.id == pane.providerId }),
                rootPath: settings.rootPath(for: pane.providerId),
                relativePath: pane.relativePath,
                canGoBack: pane.canGoBack,
                canGoForward: pane.canGoForward,
                // The same resolved mode the arrows were enabled from, so pressing one can never
                // take a branch its enablement did not count.
                onBack: { syncManager.goBack(isLeft: isLeft, drawsColumns: pane.viewMode == .columns) },
                onForward: { syncManager.goForward(isLeft: isLeft, drawsColumns: pane.viewMode == .columns) },
                // `pane.viewMode`, not a fresh read: the crumbs this routes were drawn from the
                // same context, so a click is never resolved against a mode its row was not laid
                // out in.
                onNavigate: { syncManager.navigatePane(isLeft: isLeft, toCombinedPath: $0,
                                                       drawsColumns: pane.viewMode == .columns) },
                // The single-source rail has no visible sibling: nil says so, and the crumbs then
                // treat ⌥-click (and the 🔗-linked crumb click) as plain navigation, never driving
                // the hidden right pane, and drop "both panes" from their tooltips.
                onNavigateBoth: layoutMode == .singleSource
                    ? nil
                    : { navigateBothPanes(toCombinedPath: $0, from: isLeft) },
                providers: settings.enabledProviders,
                onSelectProvider: { id in
                    if isLeft { leftProviderId = id } else { rightProviderId = id }
                },
                onManageProviders: { openProviderSettings() },
                onChooseFolder: { chooseFolderSource { id in
                    if isLeft { leftProviderId = id } else { rightProviderId = id }
                } },
                sortOption: $syncManager.sortOption,
                // The header card's right-click route to tabs, which works with no folder under the
                // pointer and no strip on screen. `nil` for Close Tab at one tab: the item
                // withholds itself rather than offering to close the window.
                onNewTab: { openNewTabHere(isLeft: isLeft) },
                onCloseTab: syncManager.paneTabs(isLeft: isLeft).count > 1
                    ? { holdingTabStrip(isLeft: isLeft) {
                        closeTab(id: syncManager.paneTabs(isLeft: isLeft).active.id, isLeft: isLeft)
                    } }
                    : nil,
                // Edit's pane is one column wide by default: past what fits, the trail keeps the
                // current folder's name and folds the rest into its ellipsis.
                compactsBreadcrumbWhenNarrow: selectedWorkspace == .editor,
                // Only the single-source rail collapses itself (back to the spine). The comparison
                // panes never collapse individually, and in the full-window workspaces the pane is
                // the window, with no spine to collapse into. Asked of the layout, so a new
                // full-window workspace need not exclude itself. Not in Edit: Edit's strip stays
                // beside the open pane and its lit cloud folds it, so a ⇤ in the pane's bar would
                // be a second control for one act.
                onCollapse: contentLayout.hasCollapsibleRail && selectedWorkspace != .editor
                    ? { togglePanesForCurrentTab() }
                    : nil,
                onRefresh: { forceRefreshAction() },
                isRefreshing: isScanShown,
                // Turns the rung into Stop for as long as the scan is shown as running — from
                // `defaultScanShownAfter` in, so a scan too quick to stop does not flash it. Both
                // panes get it: one scan is behind both, so stopping from either is the same act.
                onCancelScan: { syncManager.cancelScan() },
                // One switch across both panes: hidden-file visibility is `syncManager`'s, not
                // per-pane state. The focused-pane mark is `ActivePaneMark` on the card below.
                showHiddenFiles: $syncManager.showHiddenFiles,
                // The rail and Browse get the switch too, each bound to its own key.
                viewMode: resolvedViewModeBinding(isLeft: isLeft),
                // Targets the pane's current folder, which in Columns is the deepest open column.
                // One resolution shared with ⇧⌘N — see `beginNewFolder(isLeft:)`.
                onNewFolder: { beginNewFolder(isLeft: isLeft) },
                // Trashes this pane's selection — `ownNodes`, never `activeSelectionNodes`: in
                // Compare each pane has a Delete, and both must not mean "whichever pane is
                // active".
                //
                // `alwaysConfirm: true` regardless of Settings ▸ Confirm before deleting: this rung
                // is always visible, not a menu item chosen by name; the tooltip says so. Resolved
                // at fire time, not captured: the ⋯ menu's Delete runs this closure too, and a menu
                // held open is not re-armed by a republish, so a snapshot could name rows a
                // background sync has replaced (as `shortcutDeleteSelection` does for ⌘⌫).
                onDelete: { actionHandler?.confirmDelete(paneSelectionNodes(isLeft: isLeft),
                                                         alwaysConfirm: true) },
                selectionCount: ownNodes.count,
                // Search inside this pane's tree. Every workspace with a pane browser gets it from
                // here, because they are all this one header over this one pane component.
                searchText: paneSearchState(isLeft: isLeft).query,
                searchIsExpanded: paneSearchState(isLeft: isLeft).isExpanded,
                searchSummary: paneSearchResults(isLeft: isLeft)
                    .summary(at: paneSearchState(isLeft: isLeft).wrappedValue.hitIndex),
                // What the ▲▼ buttons are enabled by: the same collection `advancePaneSearch`
                // walks, so a disabled button and a no-op walk can never disagree.
                searchMatchCount: paneSearchResults(isLeft: isLeft).hits.count,
                onSearchAdvance: { reverse in advancePaneSearch(isLeft: isLeft, reverse: reverse) },
                personOffer: { query in
                    guard let registry = syncManager.filingPersonRegistry else { return nil }
                    return PersonSearchOffer.person(matching: query, registry: registry)
                },
                onAcceptPerson: { person in acceptPersonScope(person) },
                typeFilter: typeFilterControl(isLeft: isLeft)
            )
            // Cards gives the provider header its own card, the [toolbar][gap][content] rhythm the
            // bottom workspace has; each card insets by half a gutter, so header↔list is one
            // `cardGutter`. In Unified `paneCardIfNeeded` is a no-op, and `columnHeaderRule` draws
            // the hairline every workspace column's header carries on the same line.
            .columnHeaderRule(surfaceStyle)
            .paneCardIfNeeded(surfaceStyle, level: glassLevel, accentBorder: paneCardAccent(isLeft: isLeft))
            treeView(pane)
                .paneCardIfNeeded(surfaceStyle, level: glassLevel, accentBorder: paneCardAccent(isLeft: isLeft))
                // Space → Quick Look, scoped to the file list — see `paneQuickLook()`.
                //
                // The single-key overload, deliberately. It takes modified presses and fires on
                // key-repeat like every overload (see `KeyPress.isPlainKeystroke`), and neither
                // matters here: Quick Look opens a panel, a repeat re-targets the same panel, and
                // nothing moves on disk.
                .onKeyPress(.space) { paneQuickLook() }
                // ↩ → Rename, scoped like Space — see `paneRename()`.
                //
                // `.onKeyPress(keys:phases:)` with `isPlainKeystroke`, because no overload filters
                // modifiers (a plain `.return` handler would steal ⌘↩, ⌥↩ and the rest), and the
                // keypad's Enter sends U+0003, not U+000D. `isPlainKeystroke`, not
                // `modifiers.isEmpty`: the keypad's Enter always carries `.numericPad` +
                // `.function`, and `.capsLock` rides on every event while engaged. `.down` only.
                //
                // No `focused` term: the guard it needs (a destination pick or the ⌘K palette
                // owning the keyboard) is `paneChordsSuspended`, asked inside `paneRename()` as the
                // menu item's twin asks it.
                .onKeyPress(keys: [.return, .keypadEnter], phases: .down) { press in
                    guard press.isPlainKeystroke else { return .ignored }
                    return paneRename()
                }
                // The file actions (Compare/Copy/Move/Delete) on whichever pane holds the
                // selection, so the buttons name their target. Scoped to the list, not the column,
                // so at the top it lands under the header; it flips to the top when a selected row
                // nears the bottom. The result message shares the stack on the list's side, so it
                // never covers the bar, the header or the row acted on.
                .overlay(alignment: barAtTop ? .top : .bottom) {
                    VStack(spacing: 0) {
                        if barAtTop { paneBarPiece(isLeft: isLeft, barNodes: barNodes, atTop: barAtTop, placement: placement) }
                        if let message {
                            paneMessagePiece(isLeft: isLeft, message: message, atTop: barAtTop,
                                             besideBar: !barNodes.isEmpty, placement: placement)
                        }
                        if !barAtTop { paneBarPiece(isLeft: isLeft, barNodes: barNodes, atTop: barAtTop, placement: placement) }
                    }
                }
                // Quick fade on appear and disappear only (keyed on presence, not the edge), so
                // clicking a file shows the bar at once and clearing the selection fades it out.
                //
                // Through `designAnimation` because the transition is not only a fade: it carries
                // `.move(edge:)`, so the bar slides in from the top or bottom. Under Reduce Motion
                // the insertion lands at once.
                .designAnimation(.easeOut(duration: 0.11), value: barNodes.isEmpty)
                // The message's own arrival and departure, keyed on its identity: a replacement
                // slides in for the one it replaces.
                .designAnimation(.spring(response: 0.4, dampingFraction: 0.9), value: message?.id)
        }
        // The pane the sidebar opens into, marked on the pane, where the eye is, not only in the
        // sidebar's `Left | Right` control.
        //
        // Decoration, never layout: both `PaneHeader` rows are pinned by measurement
        // (`PaneHeaderHeightTests`, `PaneBarLadderTests`), so a chip would burst a rung. A
        // background wash and a top edge mark the region, while selection and dimming stay
        // properties of rows (`PaneSelectionWash`), so the two signals never share a surface.
        .modifier(ActivePaneMark(isFocused: paneIsFocusedPane(isLeft: isLeft),
                                accent: glassHue.accentColor,
                                surfaceStyle: surfaceStyle))
        // Any click in this column means the user is working here, including what the tab verbs and
        // selection write cannot see (empty space, the header chrome, the breadcrumb, a
        // right-click). `PaneClickReporter` reports and declines every press, so nothing loses a
        // click. In Compare it moves the focus; in Organize and Edit it records whether the reader
        // is in their source pane, which decides where the next result message shows
        // (`ResultMessageRoute`).
        .overlay {
            if layoutMode == .compare {
                PaneClickReporter {
                    syncManager.noteFocusedPane(isLeft: isLeft, because: "a click in this pane")
                }
            } else if contentLayout.hasCollapsibleRail {
                PaneClickReporter { noteResultRegion(inPane: true) }
            }
        }
        // Keyed on the strip's presence, not the tab count: a tab opening or closing while the
        // strip is up must not animate the header and list below it.
        .designAnimation(.easeOut(duration: 0.18), value: paneShowsTabStrip(isLeft: isLeft))
        // Escape clears this pane's selection, since the file lists give no deselect gesture; it is
        // swallowed only when there is a selection to clear. The rail reads its raw selection, not
        // `barNodes`, because the action bar is compare-only (`PaneLogic.escapeClearsSelection`).
        // The single-key overload is fine here: clearing is idempotent, and ⌘esc and ⌃esc never
        // reach `onKeyPress` (AppKit takes them as `cancelOperation:`).
        .onKeyPress(.escape) {
            let paneSelection = isLeft ? syncManager.selectedLeftPaths : syncManager.selectedRightPaths
            // The pane, not the root view: an `onKeyPress` scopes to the subtree that has focus,
            // and the root is not focusable, so a handler there would never see the key. The pick's
            // esc therefore lives with the selection's, ahead of it; the precedence is
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
        // The debounce. `.task(id:)` cancels and restarts whenever the key moves, so the sleep
        // below is the debounce: no timer to own, and a keystroke mid-sleep replaces the pending
        // recomputation rather than queueing a second.
        //
        // The tree version is part of the key: a result set names paths in a tree that may since
        // have been rebuilt (a scan, a delete, a hidden-files toggle), and stale hits would reveal
        // nothing and select a ghost. It costs nothing when no query is typed: `recomputeSearch`
        // returns before stamping a new generation, so an idle republish publishes nothing.
        .task(id: PaneSearchRecomputeKey(isLeft: isLeft,
                                         query: paneSearchState(isLeft: isLeft).wrappedValue.query,
                                         treeVersion: pane.tree.version,
                                         otherTreeVersion: pane.otherTree.version)) {
            try? await Task.sleep(for: ContentView.searchDebounce)
            guard !Task.isCancelled else { return }
            // Where the walk lands afterwards is decided inside, past the staleness guard — see
            // `recomputeSearch` — so results dropped as stale never move the user's position.
            await recomputeSearch(isLeft: isLeft)
        }
    }

    /// The Info inspector: a toggleable right-side panel showing metadata for the current
    /// selection. Available on Compare (with both-sides status) and on the single-source rail.
    /// `DetailsSidebar` handles the no-selection empty state itself.
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
                .help("Hide the Info inspector")
                // CloseButton deliberately names itself nowhere; every caller says what it closes.
                .accessibilityLabel("Hide the Info inspector")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            // Which pane the inspector is describing, in Compare, where it follows the pane you are
            // working in. A Get Info target names no pane, so it gets no line.
            if layoutMode == .compare, infoPath == nil {
                Text(inspectorFollowsLeft ? "Left pane · \(paneNames.left)" : "Right pane · \(paneNames.right)")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                Divider()
            }
            let previewTarget = inspectorPreviewTarget
            DetailsSidebar(syncManager: syncManager, leftPath: currentLeftPath, rightPath: currentRightPath, overridePath: infoPath, singleSource: layoutMode == .singleSource, cloudCoverage: settings.cloudCoverage,
                           // The app answers what the editor opens, because the app is where every
                           // other door asks it: `EditableText.opensInEdit` is the row menu's own
                           // gate, so the inspector cannot disagree with the menu about a file.
                           editorHandOff: EditorHandOff(isOffered: { EditableText.opensInEdit(path: $0) },
                                                       open: { handOffToEditor($0) }),
                           // The picture over the details, at the height last dragged to.
                           previewFraction: $inspectorPreviewFraction,
                           preview: previewTarget.map { target in
                               AnyView(InspectorFilePreview(
                                   node: target.node,
                                   paneToken: PaneToken(isLeft: target.isLeft,
                                                        isSingleSource: layoutMode == .singleSource),
                                   paneWatches: paneIsWatching(isLeft: target.isLeft),
                                   downloads: inspectorDownloads))
                           },
                           previewPath: previewTarget?.node.id,
                           // The pane you are working in, the same answer the preview reads.
                           followsRight: !inspectorFollowsLeft)
        }
        .frame(width: inspectorDragWidth ?? inspectorWidth)
        // A card like every other surface, not a docked `.bar` panel: an opaque bar fill would be a
        // solid band down a window Clear asks to see through, and its zero inset would break the
        // gap model.
        .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
    }

    /// Whether the inspector describes the left pane's selection: the pane the user is working in
    /// (`focusedPane`), or the other one when that holds nothing. `DetailsSidebar` alone reads the
    /// left pane first, so in Compare a click in the right pane would be described only once the
    /// left pane's selection was empty.
    private var inspectorFollowsLeft: Bool {
        PaneLogic.inspectorFollowsLeft(isCompare: layoutMode == .compare,
                                       focusedIsLeft: focusedPane == .left,
                                       leftHasSelection: !syncManager.selectedLeftPaths.isEmpty,
                                       rightHasSelection: !syncManager.selectedRightPaths.isEmpty)
    }

    /// The one file the inspector previews, and which pane's tree it was found in — nil for a
    /// folder, several items, nothing selected, or the document Edit has open beside it.
    private var inspectorPreviewTarget: (node: FileNode, isLeft: Bool)? {
        guard let target = Self.inspectorPreview(
            infoPath: infoPath, infoNode: infoNode, followsLeft: inspectorFollowsLeft,
            selectedLeft: syncManager.selectedLeftPaths, selectedRight: syncManager.selectedRightPaths,
            leftNodes: { syncManager.leftNodes(for: $0) }, rightNodes: { syncManager.rightNodes(for: $0) },
            rightRoot: currentRightPath)
        else { return nil }
        // Not the document Edit has open. Opening a file selects it in the pane, so the inspector
        // beside the editor would preview the very file being edited (as Quick Look first read it,
        // not as the editor has it) and parse a PDF a second time in the shared lane. Its icon
        // stands in.
        if selectedWorkspace == .editor, target.node.id == editorOpenPath { return nil }
        return target
    }

    /// `inspectorPreviewTarget`'s rule, pure: a Get Info target first, in whichever tree holds it,
    /// or as its own node (`infoNode`) when neither does, filed with the right pane only under the
    /// right pane's root; otherwise the one item selected in the pane the inspector follows. Files
    /// only: a folder has no preview.
    static func inspectorPreview(infoPath: String?, infoNode: FileNode?, followsLeft: Bool,
                                 selectedLeft: Set<String>, selectedRight: Set<String>,
                                 leftNodes: (Set<String>) -> [FileNode],
                                 rightNodes: (Set<String>) -> [FileNode],
                                 rightRoot: String) -> (node: FileNode, isLeft: Bool)? {
        if let infoPath {
            let found: (node: FileNode, isLeft: Bool)?
            if let node = leftNodes([infoPath]).first {
                found = (node, true)
            } else if let node = rightNodes([infoPath]).first {
                found = (node, false)
            } else if let infoNode, infoNode.id == infoPath {
                let underRight = !rightRoot.isEmpty
                    && (infoPath == rightRoot || infoPath.hasPrefix(rightRoot.hasSuffix("/") ? rightRoot : rightRoot + "/"))
                found = (infoNode, !underRight)
            } else {
                found = nil
            }
            guard let found, !found.node.isDirectory else { return nil }
            return found
        }
        let paths = followsLeft ? selectedLeft : selectedRight
        guard paths.count == 1 else { return nil }
        let node = (followsLeft ? leftNodes(paths) : rightNodes(paths)).first
        guard let node, !node.isDirectory else { return nil }
        return (node, followsLeft)
    }

    /// Whether the pane on that side is on screen to watch a download its token posts. Not when the
    /// workspace's panes are folded away (Edit starts so), nor the right pane outside Compare.
    private func paneIsWatching(isLeft: Bool) -> Bool {
        guard contentLayout.drawsAPaneList, !panesHiddenForCurrentTab else { return false }
        return isLeft || layoutMode == .compare
    }

    /// The draggable seam between the panes and the Info inspector: a 1pt strip with a 10pt hit
    /// target, clear in Cards and the hairline in Unified. `inspectorWidth` holds still until
    /// release, so it is the stable base for `PaneLogic.inspectorDragWidth`.
    ///
    /// The drag reads `.global`, not `.local`: the handle moves as the inspector widens, so a local
    /// `translation` feeds back on itself and collapses to ~0 (see `ResizeHandle`).
    private var inspectorResizeHandle: some View {
        // In Cards a clear 1pt strip, not a visible Divider: the inspector is a floating card, so
        // the seam is the gap between cards (2.5 + 1 + 2.5) and only the hit target remains. In
        // Unified the strip IS the hairline between the two.
        Color.clear.frame(width: 1)
            .unifiedSeam(surfaceStyle, edge: .leading)
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
                // Claude, pinned: the last column, after Info. Empty unless it is open and pinned.
                askClaudeColumn
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { askClaudeRowWidth = $0 }
            // Unified is one box: the only outline under the toolbar, round every workspace's
            // content and the inspector beside it, which meet inside at hairlines. A no-op in
            // Cards, where each area is its own card. See `windowRegionFrame`.
            .windowRegionFrame(surfaceStyle, level: glassLevel)
            // The pick-mode bar is a row at the bottom, not an overlay: an overlay would draw over
            // the panes' tab strips and breadcrumbs, and at the bottom it sits beside the action
            // bar whose click armed it. Every workspace's content passes through this wrapper, so
            // all of them get it.
            if let pick = comparePick {
                ComparePickStrip(fileName: pick.armedName, onCancel: { comparePick = nil })
                    .padding(.top, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .designAnimation(.easeOut(duration: 0.15), value: comparePick)
        // The window-edge half of every gap. Each card insets itself by the other half, so a
        // card-to-edge gap and a card-to-card gap both come to `cardGutter`. Applied once, here;
        // per-container padding would make the gaps uneven.
        .padding(LiquidGlass.cardInset)
        // No animation on a workspace switch or a pane collapse. An animation around a layout swap
        // keeps the outgoing layout mounted and drawn until the fade ends: leaving Compare would
        // keep two panes, the differences table and the sidebar alive under the next workspace, and
        // a collapse would show both copies of Organize or Edit at once. The workspace bar slides
        // its own pill; the layout snaps. The differences pane snaps open and closed with the
        // chevron too.
        .animation(nil, value: bottomPaneIsCollapsed)
        // And the snap is structural, not just the absence of a modifier: a `withAnimation` around
        // a switch or collapse would animate the swap again (and ignore Reduce Motion). These strip
        // it for the layout below. The workspace bar's pill is in the window toolbar, outside this
        // subtree, and keeps its slide; the tab strip's own animations sit nearer their views and
        // still win.
        .animation(nil, value: selectedWorkspace)
        .animation(nil, value: panesHiddenForCurrentTab)
        .designAnimation(.easeInOut(duration: 0.15), value: showInspector)
        // No dimming overlay during a long run: the window stays live for reading, progress is the
        // toolbar capsule's (`mainToolbar`), and writes are greyed through `runWriteLock`. No
        // window-top result message either, which would cover the pane header's Delete; each pane's
        // list docks it (`paneMessagePiece`), and `ResultMessageRoute` says which surface shows it.
        //
        // A banner already showing when this view appears gets its auto-dismiss armed here, since
        // `onChange` never fires for an unchanged value. `adoptExistingBanner` no-ops when there's
        // no banner or it already tracks one, so a re-appearance can't restart the countdown.
        .onAppear {
            bannerDismissScheduler.adoptExistingBanner(syncManager.banner, inCapsule: resultMessageHome == .toolbar,
                                                       shownOn: resultMessageSurfaces) {
                retireResultMessage()
            }
        }
        .onChange(of: syncManager.banner) { oldValue, newValue in
            // Routed first: the capsule's message gets a longer window than a pane's.
            let inCapsule = resultMessageChanged(from: oldValue, to: newValue)
            bannerDismissScheduler.bannerChanged(to: newValue, inCapsule: inCapsule, shownOn: resultMessageSurfaces) {
                retireResultMessage()
            }
            // Messages vanish with the window; when the app is in the background, mirror the
            // outcome as a system notification (General setting, default off).
            if let banner = newValue {
                let ended = fileRunEnded(by: banner).map { (title: $0.title, ended: $0.ended) }
                OperationNotifier.postIfEnabled(for: banner, runTitle: OperationNotifier.runTitle(lastFinished: ended))
            }
        }
        // The same message moving — a workspace switch — leaves a resting pointer behind it.
        .onChange(of: resultMessageSurfaces) { _, surfaces in bannerDismissScheduler.surfacesChanged(to: surfaces) }
        // Where a long file operation was started, for its ending's route.
        .onChange(of: syncManager.activeProgress != nil) { _, running in
            if running { fileOperationOrigin = selectedWorkspace }
        }
        // Edit ▸ Undo and ⌘Z wait during a run, on the file operations' stack only.
        .onChange(of: runWriteLockReason, initial: true) { _, reason in
            let gate = RunUndoGate.shared
            gate.reason = reason
            gate.fileStack = { [weak manager = syncManager] in manager?.undoManager }
            gate.refuse = { [weak manager = syncManager] reason in
                Logger.shared.info("Undo refused while a run is going — \(reason)")
                manager?.banner = .warning(reason)
            }
        }
        // "Save as rule…"'s offer holds its message open while it is up — see `holdChanged`.
        .onChange(of: ruleOfferIsOpen) { _, isOpen in bannerDismissScheduler.holdChanged(isHeld: isOpen) }
        .onChange(of: syncManager.showHiddenFiles) { _, newValue in
            Logger.shared.info("User toggled hidden files to: \(newValue)")
        }
        // The menu-bar chords, on one contract, bundled into one modifier
        // (`ShortcutValuePublisher`; inlining the publications here breaks the type-checker's time
        // budget). Each value recomputes with this body, so a menu item's enabled-ness tracks the
        // same facts the control it mirrors renders from, and the picker's suspension reaches every
        // chord, ⌘F included.
        .modifier(shortcutValuePublisher)
        .onReceive(editorPDF.view.$hasFocus.removeDuplicates()) { editorPDFReaderFocused = $0 }
        // Feed the pane header's quick-jump "Recent" list: every folder either pane focuses — by
        // drilling in, a crumb, back/forward, or a scan — is recorded against its provider root.
        .onChange(of: syncManager.leftRelativePath) { _, rel in
            FolderJumpStore.shared.recordVisit(root: settings.rootPath(for: leftProviderId),
                                               relativePath: rel, name: (rel as NSString).lastPathComponent)
            noteFolderArrival(pane: "left", root: settings.rootPath(for: leftProviderId), relativePath: rel)
            // The visit just recorded is a row the sidebar does not have yet. The same handler
            // rather than a second `onChange` on the same value: two would fire in an order SwiftUI
            // does not promise, and the wrong one would leave the sidebar one folder behind the
            // pane.
            refreshFolderSidebarRows()
        }
        .onChange(of: syncManager.rightRelativePath) { _, rel in
            FolderJumpStore.shared.recordVisit(root: settings.rootPath(for: rightProviderId),
                                               relativePath: rel, name: (rel as NSString).lastPathComponent)
            noteFolderArrival(pane: "right", root: settings.rootPath(for: rightProviderId), relativePath: rel)
        }
        // The other moments the sidebar's answer can change: first appearance, a provider switch,
        // the set of sources changing, and the store publishing a favorite made elsewhere.
        //
        // `objectWillChange` fires before the store mutates, so the handler hops a run-loop turn.
        // The hop is inside the handler, not `.receive(on:)`: that would build a new publisher on
        // every body evaluation, re-subscribing on every render and losing events in the gap.
        // `ObservableObjectPublisher` is one stable instance.
        .onAppear {
            // The launch walk, not redundant with the refresh beside it: that one returns early
            // wherever the column is hidden, and a card already in the reader must be recorded
            // before it is ejected whether or not the sidebar is on screen. It fills
            // `knownMountedVolumes`, which the refresh reads, so launch walks the volumes once.
            Self.rememberMountedVolumes(Self.mountedVolumesAsLastSeen())
            refreshFolderSidebarRows()
        }
        .onChange(of: leftProviderId) { _, _ in refreshFolderSidebarRows() }
        // The triggers the gate makes necessary. `refreshFolderSidebarRows` returns early wherever
        // the column is not on screen, which is right, because it `stat`s a provider root and the
        // other triggers fire in every workspace. But then switching the sidebar on, or arriving at
        // Browse, would land on whatever was last resolved, which reads as "my pins are gone". The
        // guard and these triggers are one change.
        .onChange(of: browseSidebarVisible) { _, _ in refreshFolderSidebarRows() }
        .onChange(of: browseSidebarRecentsMode) { _, _ in refreshFolderSidebarRows() }
        .onChange(of: editorSidebarVisible) { _, _ in refreshFolderSidebarRows() }
        .onChange(of: selectedWorkspace) { _, _ in refreshFolderSidebarRows() }
        // Every input to `FolderSidebarModel.isShowing` needs a trigger, because the guard drops
        // whatever fires while the column is hidden and nothing re-runs it on the way back;
        // expanding the panes would otherwise land on a list resolved before the collapse.
        // `FolderSidebarWiringTests` pins that the triggers match the gate's inputs.
        .onChange(of: panesHiddenForCurrentTab) { _, _ in refreshFolderSidebarRows() }
        // Expand's hold is a gate input too: leaving Expand can bring the column back with no pane,
        // workspace or preference change to trigger the refresh above.
        .onChange(of: folderSidebarHeldByExpand) { _, _ in refreshFolderSidebarRows() }
        // And the set of sources itself, since the column draws one row per source. Adding,
        // removing or switching off a folder source all change what the Sources section says, and
        // one of those paths is the sidebar's own promotion, whose new row would otherwise still
        // read as a local shortcut. Keyed on the ids rather than the array: `CloudProvider` carries
        // a mutable `path`, so an unrelated Location edit would fire this on every keystroke.
        .onChange(of: settings.enabledProviders.map(\.id)) { _, _ in refreshFolderSidebarRows() }
        .onReceive(FolderJumpStore.shared.objectWillChange) { _ in
            DispatchQueue.main.async { refreshFolderSidebarRows() }
        }
        // A card renamed in Finder takes its sources with it. `didRenameVolumeNotification` carries
        // both URLs, so this is a fact and not an inference, which makes acting on it silently
        // safe. Nothing here treats a source that has merely gone missing as renamed: an unplugged
        // card is asleep, and the column's dimming rule is that asleep is not gone. See
        // `SettingsManager.followVolumeRename`.
        .onReceive(NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didRenameVolumeNotification)) { note in
                followVolumeRename(note)
        }
        // Ejecting a card removes the sources on it, so the row goes rather than dimming. The three
        // subscriptions are one mechanism: the unmount notification cannot say what the volume was,
        // so the earlier ones record that while it is still there. The launch walk in `onAppear`
        // catches a card already in the reader, `didMount` one inserted while the app runs, and
        // `willUnmount` is the last chance before it goes.
        .onReceive(NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didMountNotification)) { _ in
                // A volume arrived, so the cached walk is out of date: dropped first, then re-taken
                // by the record below and reused by the refresh after it.
                Self.forgetMountedVolumes()
                Self.rememberMountedVolumes(Self.mountedVolumesAsLastSeen())
                refreshFolderSidebarRows()
        }
        .onReceive(NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.willUnmountNotification)) { _ in
                // From the cached walk, deliberately. This is the last chance to record what a
                // volume was, and it arrives while that volume is being torn down: a fresh
                // `mountedVolumeURLs` plus a `resourceValues` read per volume, synchronously on the
                // main thread at that moment, is the walk most likely to block. The cached answer
                // was taken while the volume was healthy. The cache is not dropped here, because
                // the volume has not gone yet and dropping it would send the next reader back to
                // the wedged filesystem.
                Self.rememberMountedVolumes(Self.mountedVolumesAsLastSeen())
        }
        .onReceive(NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didUnmountNotification)) { note in
                // The volume has gone: the cached walk still lists it, so it is dropped before the
                // handler's own refresh, which re-takes it.
                Self.forgetMountedVolumes()
                forgetFolderSidebarSourcesOnUnmount(note)
        }
    }

    /// Moves everything keyed to a renamed volume's old mount point onto the new one.
    ///
    /// Both URLs or nothing. `DidRenameVolumeMessage` is AppKit's typed reading of the
    /// notification's `userInfo`, and it answers nil rather than half a pair; a rename that does
    /// not say from what to what has no safe half to act on, so it is logged and dropped rather
    /// than guessed at.
    ///
    /// A rename can also move nothing: the notification fires for a name change and/or a mount-path
    /// change, and both followers no-op on an unchanged path, so that case needs no special branch.
    private func followVolumeRename(_ note: Notification) {
        guard let renamed = NSWorkspace.DidRenameVolumeMessage.makeMessage(note) else {
            Logger.shared.warning("A volume was renamed but the notification did not say from what to what — nothing moved")
            return
        }
        let old = renamed.oldVolumeURL.path, new = renamed.volumeURL.path
        settings.followVolumeRename(from: old, to: new)
        FolderJumpStore.shared.followVolumeRename(from: old, to: new)
        // A rename moves the mount point, so the cached walk names a path that no longer exists.
        Self.forgetMountedVolumes()
        refreshFolderSidebarRows()
    }


    /// What the not-scanned card says. The rule is `PaneLogic.notScannedMessage`, where it can be
    /// tested; this supplies the live facts. `hasScanned` is false whenever this renders, so there
    /// is no live result to contradict: this is the cold-open card and nothing else.
    private var notScannedMessage: String {
        PaneLogic.notScannedMessage(
            summary: syncManager.lastScanSummary,
            leftProviderID: leftProviderId, leftPath: currentLeftPath,
            rightProviderID: rightProviderId, rightPath: currentRightPath,
            now: Date()
        )
    }

    /// The Compare busy state: the whole placeholder becomes the scan while the first one runs.
    ///
    /// It reports elapsed time only, the one honest number: a percentage needs a total, and
    /// counting in `FileDiffEngine.getFilesInDirectory` would put a callback in the app's hottest
    /// loop. Its Stop matches the pane rung's, the other door to `cancelScan()`.
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

    /// Selection binding for one pane that enforces the one-pane-selected invariant: the clicked
    /// pane commits synchronously so the click lands first time, and the other pane's clear is
    /// deferred a tick and stands down if a newer click landed. The ordering lives in
    /// `PaneLogic.applySelectionWrite`, where it is tested. Private: the app's own selection writes
    /// go through `PaneLogic.payOwedSelection`, since this setter also resolves a pick and moves
    /// focus.
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
                // it moves the keyboard's focus there too; otherwise ⌃⇥ and the click would be two
                // notions of "the focused pane" that drift apart. The empty-write case must not
                // move it; that rule lives in `PaneLogic` where a test can hold it.
                //
                // After `applySelectionWrite`, never before. That call's first act is the commit
                // the clicked List is waiting on, and publishing anything else into that window
                // reloads the List mid-commit and drops the click. This is another `@Published`
                // write on the same manager, so it goes after the commit lands.
                let side = PaneLogic.focusedSideAfterSelectionWrite(
                    newSelection, isLeft: isLeft, current: syncManager.focusedPaneSide)
                // Through the manager's one door, which holds the "changed or nothing" test and
                // writes the line that says the chords moved. The empty-write case answers with
                // `current`, so it is a silent no-op.
                syncManager.noteFocusedPane(
                    side, because: "a row was picked in the \(isLeft ? "left" : "right") pane")

                // A pick completes here, the one door both view modes go through (Tree's `List`
                // binding and Columns' tap gestures). Deferred a tick for the sibling clear's
                // reason: writing `@State` mid-commit would reload the clicked List and drop the
                // click. Exactly one path: a ⌘-click extending to two leaves the mode standing.
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

    /// Clears the selection in one pane. The single-pane-selected invariant means at most one side
    /// is populated, so this is what the Escape key and the action bar's ✕ both call; the file
    /// lists offer no deselect gesture.
    func clearSelection(isLeft: Bool) {
        if isLeft {
            if !syncManager.selectedLeftPaths.isEmpty { syncManager.selectedLeftPaths = [] }
        } else {
            if !syncManager.selectedRightPaths.isEmpty { syncManager.selectedRightPaths = [] }
        }
    }

    /// Opens the shared file-pair viewer on two files picked in the panes: a second door onto the
    /// Differences list's surface and `@State`, joining no overlay chain. The ordering rule,
    /// tested, is
    /// ``PaneComparePairMenu/pair(clicked:counterpart:counterpartIsInOtherPane:clickedPaneIsLeft:leftPaneName:rightPaneName:)``.
    func compareFilePairAction(_ first: FileNode, _ second: FileNode,
                               secondIsInOtherPane: Bool, clickedPaneIsLeft: Bool) {
        compareDifferencePair = PaneComparePairMenu.pair(
            clicked: first, counterpart: second,
            counterpartIsInOtherPane: secondIsInOtherPane,
            clickedPaneIsLeft: clickedPaneIsLeft,
            leftPaneName: paneNames.left, rightPaneName: paneNames.right)
    }

    /// Arms a file for comparison, replacing any pick already standing. Replacing rather than
    /// refusing: a reader who arms another file has said what they meant, and a mode that had to be
    /// cancelled first would punish a correction.
    func armComparePick(_ node: FileNode, isLeft: Bool) {
        comparePick = ComparePick(armed: node, armedPaneIsLeft: isLeft)
    }

    /// Resolves a click made while a pick is armed — see
    /// ``ComparePick/outcome(clicking:inLeftPane:leftPaneName:rightPaneName:)``.
    ///
    /// The three outcomes: the pair opens and the mode is done, the armed row was clicked again and
    /// the mode is cancelled, or a folder was clicked and the mode stands while the reader keeps
    /// looking.
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

    /// The row menu's and the file list's delegate for one pane, lifted out of the file list's call
    /// site so that call stays short. Internal rather than private: File ▸ Organize's verbs build
    /// one for the active pane, so the menu items and the row menu route through the same delegate.
    /// See `shortcutOrganizeVerbs`.
    func paneActionDelegate(for pane: PaneContext) -> PaneActionDelegate {
        PaneActionDelegate(
            handler: actionHandler, syncManager: syncManager, settings: settings,
            isLeft: pane.isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId,
            isSingleSource: layoutMode == .singleSource,
            // Not `layoutMode == .singleSource`: Browse and the other single-source workspaces
            // answer that too.
            ownsOrganizeScope: selectedWorkspace == .filing,
            servesEditor: selectedWorkspace == .editor,
            forceRefreshAction: forceRefreshAction,
            onGetInfo: { showInfo(for: $0) },
            onChooseDestination: { nodes, isMove in requestDestination(for: nodes, isMove: isMove) },
            onOpenInEditor: { path in handOffToEditor(path) },
            ignoreStateToken: syncManager.effectiveIgnoredPaths,
            keptNamesToken: syncManager.keptNamesStore?.names ?? [],
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
            // and the active tab can have moved under it. Held while the pointer stays where the
            // menu stood (`holdingTabStrip`).
            onCloseTab: { holdingTabStrip(isLeft: pane.isLeft) {
                closeTab(id: syncManager.paneTabs(isLeft: pane.isLeft).active.id, isLeft: pane.isLeft)
            } },
            onToggleFolderFavorite: { node in toggleFavorite(forPaneFolder: node, isLeft: pane.isLeft) },
            onCompareFilePair: { first, second, secondIsInOtherPane in
                compareFilePairAction(first, second, secondIsInOtherPane: secondIsInOtherPane,
                                      clickedPaneIsLeft: pane.isLeft) },
            onArmComparePick: { node in armComparePick(node, isLeft: pane.isLeft) },
            onPDFTool: { request, paths in startPanePDFTool(request, paths: paths) },
            onSaveAsPDF: { paths in startSaveAsPDF(paths) },
            armedComparePath: comparePick?.armed.id,
            canAskClaude: true,
            onAskClaude: { askClaudeAttach($0) },
            askClaudeRefusalFor: { askClaudeRowRefusal($0) },
            hiddenFromClaude: { askClaudeIsHidden($0) },
            hiddenFromClaudeCover: { askClaudeHiddenCover($0) },
            onSetHiddenFromClaude: { node, hidden in askClaudeSetHidden(node.id, name: node.name, hidden) },
            hiddenFromClaudeToken: { _ = askClaudePrivacyChanges; return AskClaudePrivacy.hiddenFolders(in: .standard) }())
    }

    @ViewBuilder
    /// The pane's file list, with the line that says its cloud app isn't syncing along its top,
    /// inside the list's own card, so in Cards it is part of the pane, not a card of its own.
    private func treeView(_ pane: PaneContext) -> some View {
        VStack(spacing: 0) {
            // Which side of one-way sync this pane shows.
            if let role = oneWaySync.role(ofFolder: shownFolder(isLeft: pane.isLeft)) {
                OneWaySyncRoleLine(role: role)
                Divider()
            }
            if let problem = cloudApps.problem(for: pane.providerId) {
                CloudAppWarningBar(
                    problem: problem,
                    sourceName: settings.availableProviders.first { $0.id == pane.providerId }?.displayName ?? "This source",
                    canOpen: { cloudApps.canOpen($0) },
                    onAction: { cloudApps.perform($0) })
                Divider()
            }
            fileList(pane)
        }
    }

    private func fileList(_ pane: PaneContext) -> some View {
        // The single-source rail is the only pane on screen, with no sibling to be subordinate to,
        // so its selection wears the full-strength wash. It shows no action bar but does show the
        // result message, so it takes placement scratch space like a Compare pane.
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
            onOpenSettings: { openProviderSettings(for: pane.providerId) },
            // The single-source rail has no opposite pane, so its row menu drops the
            // comparison-only items and renames "Compare only this folder" to "Open".
            isSingleSource: layoutMode == .singleSource,
            // Placement scratch space this pane fills from live geometry; `paneColumn` reads the
            // edge from it synchronously. The flip callback fires only when a scroll crossing
            // changes the edge, re-rendering the column inside `withAnimation`. The single-source
            // rail measures too, with no bar, because the result message docks by the same rule and
            // needs a deleted row's last position.
            placement: pane.isLeft ? leftPlacement : rightPlacement,
            onBarEdgeFlip: paneOverlayFlip(isLeft: pane.isLeft),
            // What matched, and where the walk has got to. The pane draws its emphasis, dimming and
            // annotations from the first and reveals the hit named by the second — see
            // `FileTreeView.revealInTree` / `revealInColumns`.
            search: paneSearchResults(isLeft: pane.isLeft),
            searchHitIndex: paneSearchState(isLeft: pane.isLeft).wrappedValue.hitIndex,
            searchRevealNonce: paneSearchState(isLeft: pane.isLeft).wrappedValue.revealNonce,
            // The row the app selected on the user's behalf (the open document), brought into view.
            // The left pane's alone: it is the only pane Edit reads and moves.
            rowReveal: pane.isLeft ? paneRowReveal : nil,
            // Answered once: the pane says when it has scrolled to the row, and the request is
            // retired, so its next appearance does not scroll back (see `retireAnsweredRowReveal`).
            onRowRevealed: pane.isLeft ? { retireAnsweredRowReveal($0) } : nil,
            // Which pane the action bar is acting on — the predicate that decides where the bar
            // renders, so the strong selection wash and the bar can never point at different panes.
            // The tab strip above takes it too, from the same helper.
            isActivePane: paneWearsActiveAccent(isLeft: pane.isLeft),
            viewMode: pane.viewMode,
            childrenIndex: pane.childrenIndex,
            browsePath: pane.isLeft ? $syncManager.leftBrowsePath : $syncManager.rightBrowsePath,
            onColumnNavigate: { applyColumnNavigation($0, isLeft: pane.isLeft) },
            // A column opened past `FileSyncManager.paneNodeBudget` has no rows: the walk stopped
            // before reaching it. This fills it in, one directory listing at a time; without it the
            // budget would trade a hang for a pane that silently cannot navigate a large tree.
            onNeedChildren: { syncManager.loadColumnChildren(atPath: $0, isLeft: pane.isLeft, passive: $1) },
            // So a column can say "reading this" rather than "can't be read" while it waits.
            graftsInFlight: syncManager.columnGraftsInFlightPaths(isLeft: pane.isLeft),
            // The background menus' Sort By ticks the order the panes are in.
            sortOption: syncManager.sortOption,
            onBackgroundDeselect: { handleBackgroundDeselect(depth: $0, isLeft: pane.isLeft) },
            // The row menu's preview goes through the host's panel, not the pane's own: there is
            // one Quick Look panel, and only the host can keep it pointed at the current file.
            onQuickLook: { toggleQuickLook($0, followsPane: true) },
            // The open folders are held here, because this view outlives the switch and the pane
            // does not — see `leftTreeExpanded`. Per side rather than per workspace: Browse, the
            // lens rail and Compare's left are all the left pane, so a folder opened in one is open
            // in the others.
            hostExpanded: pane.isLeft ? $leftTreeExpanded : $rightTreeExpanded,
            typeFilter: typeFilterDecor(isLeft: pane.isLeft),
            typeFilterEmptied: typeFilterEmptied(isLeft: pane.isLeft),
            typeFilterFolderName: typeFilterFolderName(isLeft: pane.isLeft),
            onClearTypeFilter: { typeFilterBinding(isLeft: pane.isLeft).wrappedValue = nil }
        )
        // The point of `FileTreeView: Equatable`. Without this the conformance is inert (SwiftUI
        // consults a view's `==` only through `EquatableView`), and this view is rebuilt on every
        // `ContentView` render, which any of the manager's many published properties can trigger.
        // See the note on `FileTreeView`.
        .equatable()
        // After `.equatable()`, which must sit on the pane itself. The type list's counts while
        // this pane has no filter, once per publish, off-main.
        .task(id: TypeFilterCensusKey(version: pane.tree.version,
                                      filterOn: typeFilterBinding(isLeft: pane.isLeft).wrappedValue != nil)) {
            await typeFilterCensusTask(isLeft: pane.isLeft)
        }
        // The folders open in this pane, which its type filter keeps in place.
        .onChange(of: typeFilterOpenFolders(pane), initial: true) { _, folders in
            syncManager.setTypeFilterOpenFolders(folders, isLeft: pane.isLeft)
        }
        // The pane's scroll offsets, kept across it being rebuilt. The surface is the workspace and
        // the side (unlike `hostExpanded`, per side only), because the stack's sideways offset
        // depends on the pane's width, and Browse's pane is not the width of Organize's rail. The
        // per-folder vertical offsets are shared by every surface and side, since a folder's rows
        // are one height everywhere — see `PaneScrollMemory`.
        .environment(\.paneScrollMemory,
                     PaneScrollMemorySlot(memory: paneScrollMemory,
                                          surface: "\(selectedWorkspace.rawValue).\(pane.isLeft ? "left" : "right")"))
    }

    /// A plain click on a pane's empty space: let the selection go and, in Columns, close the
    /// columns to the right of the one clicked in, as Finder does.
    ///
    /// Both panes are cleared: the selection usually lives in the pane not clicked, so clearing one
    /// side would look dead. Not through `paneSelectionBinding`, whose empty write leaves the other
    /// pane alone to keep the right-click "Copy N items from other pane" menu working (right-click
    /// never reaches here). Synchronous writes are safe: the recognizer fires on mouse-up, outside
    /// `NSTableView`'s selection-commit loop. The truncation goes through `applyColumnNavigation`
    /// so it obeys the seam link as opening does.
    func handleBackgroundDeselect(depth: Int?, isLeft: Bool) {
        PaneLogic.clearBothSelections(state: syncManager)
        let browsePath = isLeft ? syncManager.leftBrowsePath : syncManager.rightBrowsePath
        guard let path = PaneLogic.backgroundDeselectPath(from: browsePath, depth: depth) else { return }
        applyColumnNavigation(path, isLeft: isLeft)
    }

    /// Binding for the workspace bar that, on entering a lens workspace, opens the source rail.
    /// Wrapping the binding (rather than observing `selectedWorkspace` globally) confines this to
    /// the bar's own control: the programmatic scan actions assign `selectedWorkspace` directly and
    /// never trip it, keeping their chosen scan folder intact. Internal so the toolbar
    /// (ContentView+Toolbar.swift) can drive it.
    var workspaceSelection: Binding<Workspace> {
        Binding(
            get: { selectedWorkspace },
            set: { newWorkspace in
                let previous = selectedWorkspace
                selectedWorkspace = newWorkspace
                // All duplicate-review and guided-review teardown and restore decisions go through
                // the reducer (CompareReviewReducer): an abandoned review (left Compare while
                // inactive, banner and Done button gone) is torn down like Done, ending the guided
                // review and restoring the auto-pinned provider; returning to Compare re-focuses
                // the two copies (the shared left pane may have moved while away).
                reviewCoordinator.dispatchReview(
                    .tabSwitched(toCompare: newWorkspace == .compare, fromCompare: previous == .compare)
                )
                // Show the source rail on entry into a lens. The left pane stays where it is — see
                // `presentLensRail`.
                if newWorkspace != previous {
                    presentLensRail(for: newWorkspace)
                }
            }
        )
    }

    /// True when the Compare bottom pane shows the differences list, not a placeholder. Collapse
    /// applies only then: the header strip belongs to `DifferencesView`. Internal for the
    /// split-layout extension.
    ///
    /// False while a person gather owns the slot: `bottomPaneView` tries `personScope` first, and
    /// the collapse height and `shortcutDifferencesList` must not act on a list that is not there.
    var compareBottomListActive: Bool {
        selectedWorkspace == .compare && personScope == nil
            && (!syncManager.differences.isEmpty || reviewStore.isReviewing)
    }

    /// The Compare bottom pane is collapsed to its header strip right now: the user asked for it,
    /// the differences list (which owns that strip) is on screen, and no guided review is running.
    /// The review override is not restated here: it comes from
    /// `DifferencesView.isCollapsedToHeaderStrip`, the function the view renders against, so the
    /// height and the content cannot disagree.
    var bottomPaneIsCollapsed: Bool {
        compareBottomListActive && DifferencesView.isCollapsedToHeaderStrip(
            storedCollapse: bottomPaneCollapsed, isReviewing: reviewStore.isReviewing)
    }

    /// The gather's card, as its own member because two layouts mount it: `bottomPaneView`, and
    /// Browse, which draws no bottom pane. Inline here, an offer accepted from Browse's pane search
    /// would start the whole-source sweep and render nowhere, with no list, ✕ or Esc target. See
    /// `browseLayout`.
    @ViewBuilder
    func personGatherSection(_ scope: PersonScope) -> some View {
        PersonView(displayName: scope.person.displayName,
                   phase: scope.phase,
                   accent: glassHue.accentColor,
                   // Open opens it here, as the button says, by moving the pane to the folder.
                   // Finder's reveal is `onReveal` below; this falls back to Finder only for a
                   // folder outside the pane's provider, where there is no pane to open it in.
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
                       // Open the rail if it is closed, or this is a dead click: `focusOn` only
                       // pushes history, and the Finder fallback does not fire for a folder under
                       // the root.
                       //
                       // Asked of `contentLayout`, not `panesHiddenForCurrentTab`: only the
                       // single-source layout honours that flag, so keying on it elsewhere would
                       // persist a preference that changes nothing visible. It does discard a
                       // deliberate collapse permanently (`@AppStorage`), as `presentLensRail`
                       // does; the alternative is a click that does nothing.
                       if contentLayout == .singleCollapsed { togglePanesForCurrentTab() }
                       syncManager.focusOn(relativePath: inPane, isLeft: !lensTargetIsRight)
                   },
                   // Expanded, like every other reader of `FolderProfile.root`: it is stored
                   // tilde-form ("~/Documents"), and an unexpanded join would resolve against the
                   // process's working directory, leaving Reveal finding nothing.
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
            // Esc clears it, as the ✕'s tooltip promises.
            .onExitCommand { clearPersonScope() }
            .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
    }

    @ViewBuilder
    /// The sentence for an incomplete comparison, or nil when the last scan read both sides in
    /// full, which is every ordinary scan.
    ///
    /// Named off `lastScanProviders`, the pair the rows came from, so navigating a pane after the
    /// scan cannot make the banner name a source never compared. Nil once there is no scan to
    /// describe: `invalidateDifferencesForPaneRetarget` clears the coverage with the rows.
    var partialComparisonMessage: String? {
        guard syncManager.hasScanned, let pair = syncManager.lastScanProviders else { return nil }
        return syncManager.lastScanCoverage.message(leftName: pair.left.displayName,
                                                    rightName: pair.right.displayName)
    }

    /// A warning, not an error, and not dismissible. Nothing failed: the scan ran and its rows are
    /// correct; what is missing is the ones it could not know about. A dismiss button would let the
    /// qualifier close while the number it qualifies stays on screen.
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
        // No fill or divider of its own: the host mounts it as a `bottomSectionCard`, as
        // `duplicateReviewBanner` is mounted directly above.
    }

    var bottomPaneView: some View {
        // Stable outer container: keeps this bottom pane's identity constant across tab switches,
        // so selecting Details doesn't reset the vertical split or collapse the panes.
        VStack(spacing: 0) {
        // Keep-left / trash-right banner for a duplicate-copy review handed off from the Duplicates
        // lens. Above the diff, so it shows even when the two copies are identical (empty diff →
        // the "Everything is in sync" placeholder). Hidden the moment either pane navigates away
        // from the reviewed copies, so the scoped trash can't fire against the wrong folder.
        if selectedWorkspace == .compare, let review = duplicateReview, reviewCoordinator.duplicateReviewActive(review) {
            reviewCoordinator.duplicateReviewBanner(review)
                .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
                .unifiedSeam(surfaceStyle, edge: .bottom)
        }
        // A count that is a floor has to say so. Above the table rather than beside the count,
        // because the fact is about every row that is not there — see `PartialComparison`.
        if selectedWorkspace == .compare, let message = partialComparisonMessage {
            partialComparisonBanner(message)
                .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
                .unifiedSeam(surfaceStyle, edge: .bottom)
        }
        // A person gather takes the slot from whatever was in it, in every workspace. It answers
        // about the whole source rather than one lens, so showing it beside a lens would read as
        // that lens's output; it is temporary, so it takes the slot rather than replacing anything.
        // Clearing gives it back.
        if let scope = personScope {
            personGatherSection(scope)
        } else if let lens = selectedLens {
            // The lens workspaces' right-hand slot. One construction site for all of them,
            // deliberately: a `switch` with a branch per lens would give each its own view
            // identity, and LensWorkspaceView's @State would reset on every lens switch. Storage
            // renders its own read-only surface beneath the shared header card.
            LensWorkspaceView(
                syncManager: syncManager,
                lens: lens,
                providerName: lensProviderName,
                scanTargetFolder: lensScanRootExpanded,
                onFindDuplicates: findDuplicatesAction,
                onFindFilingSuggestions: { findFilingSuggestionsAction() },
                onFindFilingSuggestionsFresh: { findFilingSuggestionsAction(ignoringCache: true) },
                // Withheld when this machine has no filing profile: the re-survey rebuilds an
                // artifact that does not exist, so offering it would offer nothing.
                onUpdateFolderMemory: syncManager.filingMemory == nil && syncManager.filingFolderProfile == nil
                    ? nil : { updateFolderMemoryAction() },
                // The way in to the paid pass for someone who has never set it up: Organize's
                // results offer it, and this deep-links Organize ▸ Suggestions, where the toggle and
                // model are, with a jump to the key (`theCloudRefineOfferLandsOnThePageThatHoldsItsSwitch`).
                onConfigureCloudRefine: { openSettings(on: SettingsView.SettingsTab.cloudRefineSetup) },
                // The app's one Help front door, opened at a named page: Settings and Help never
                // stack, and this must not grow a second overlay beside them.
                onOpenHelp: { topic in
                    helpTopic = topic
                    showHelp = true
                },
                restructureVerbRequest: $restructureVerbRequest,
                onNormalizeNames: { names in Task { await syncManager.normalizeNames(names) } },
                onApplyRenames: { plans in Task { await syncManager.applyRenamePlans(plans) } },
                onPreviewAutomations: { only in startAutomationPreviewAction(only: only) },
                // Both, and they are not the same folder. The anchor is the taxonomy every lens
                // files against and scans; the root is what can bound a scope. The root in the
                // anchor's place would resolve rule destinations one level too deep and leave an
                // unscoped scan never covering its own subject — see `LensWorkspaceView`.
                providerAnchor: lensProviderAnchorExpanded,
                providerRoot: lensProviderRootExpanded,
                filingInboxFolder: filingInboxFolder,
                fileInto: fileIntoChoice,
                onQuickLook: { toggleQuickLook($0) },
                onBuildStorage: buildStorageLensAction,
                documentSurveyCard: documentSurveyCardState,
                onStartDocumentSurvey: startDocumentSurveyAction,
                onStartDocumentSurveyOver: startDocumentSurveyOverAction,
                onResumeDocumentSurvey: resumeDocumentSurveyAction,
                onPauseDocumentSurvey: pauseDocumentSurveyAction,
                onStopDocumentSurvey: stopDocumentSurveyAction,
                // The single lens source is the left provider; its picker shows in the workspace
                // only while the rail is collapsed (expanded, the rail header owns the provider
                // dropdown).
                showSourcePicker: panesHiddenForCurrentTab,
                // The rail's strip, so the lens header stays level with the pane's toolbar card,
                // the answer Edit's document column is given; false while the rail is collapsed.
                paneShowsTabStrip: sourcePaneShowsTabStrip,
                providers: settings.enabledProviders,
                currentProviderId: leftProviderId,
                onSelectProvider: { leftProviderId = $0 },
                onManageProviders: { openProviderSettings() },
                onChooseFolder: { chooseFolderSource { leftProviderId = $0 } },
                onCompareCopies: reviewCoordinator.compareCopies,
                onCompareFilePair: { compareFilePair = $0 },
                // A duplicate copy's row menu hands a text copy to Edit through the same act as
                // every other door: settle, re-root the left pane, switch, open.
                onOpenInEditor: { handOffToEditor($0) },
                onRequestDestination: { presentDestination($0) },
                revealRequest: duplicateRevealRequest,
                // Retire an answered request. The lens's own applied-id is @State and dies with it,
                // so a request left standing here would replay its whole plan (filter reset, parked
                // query overwritten, the old group re-marked) on every return to a lens workspace.
                // The id check keeps a retirement racing a newer ask from clearing the newer
                // request.
                onRevealHandled: { id in
                    if duplicateRevealRequest?.id == id { duplicateRevealRequest = nil }
                },
                // The notScanned recovery button: the same door as the context menu, so it scans a
                // folder that actually contains the file. `onFindDuplicates` scans the lens's
                // focused root, which for a handoff from the other pane may not contain it, and
                // would re-run the same unanswerable scan forever.
                onFindDuplicatesOf: { path in revealCoordinator.findDuplicates(ofPath: path) },
                // Held here because this view outlives the workspace switch and that one does not.
                // One construction site keeps the lens's state across a lens change, but a
                // workspace change tears down this whole arm, so everything the reader set (the
                // filter, parked queries, folds, tallies, session flags) lives in an object mounted
                // once for the window.
                session: lensSession
            )
        } else if compareBottomListActive {
            // DifferencesView renders its own two cards (toolbar and table); the workspace bar
            // lives in the window toolbar. Its Open in Edit leaves the left pane where it is
            // (`.staysPut`): that pane is half of the comparison this list is, and re-rooting it
            // would re-scope the comparison, re-run its scan and drop the session's "Ignore in
            // comparison" entries.
            DifferencesView(syncManager: syncManager, reviewStore: reviewStore, paneNames: paneNames, paneRules: paneRules, onQuickLook: { toggleQuickLook($0) }, onGetInfo: { showInfo(for: $0) }, onOpenInEditor: { handOffToEditor($0, pane: .staysPut) }, isCollapsed: $bottomPaneCollapsed, shortcutsSuspended: pendingDestination != nil, onCompareFilePair: { compareDifferencePair = $0 }, session: differencesSession,
                            // One-way sync's pill beside the count; before setup, only for an
                            // iCloud pane compared with a Dropbox one.
                            accessory: OneWaySyncStatusPill.isShown(controller: oneWaySync, paneTypes: [true, false].map { isLeft in
                                settings.availableProviders.first { $0.id == (isLeft ? leftProviderId : rightProviderId) }?.type
                            }) ? AnyView(OneWaySyncStatusPill(onSetUp: { openOneWaySyncSetup() })) : nil,
                            accessoryWidth: OneWaySyncStatusPill.width(controller: oneWaySync, scale: appFontScale),
                            askClaude: DifferencesAskClaude(refusal: { askClaudeRowRefusal($0) }, ask: { askClaudeAttach($0) }))
        } else {
            // Compare with nothing to list yet: scanning / all-in-sync / not-scanned placeholder.
                Group {
                    if isScanShown {
                        scanningPlaceholder
                    } else if syncManager.hasScanned {
                        EmptyStateView(
                            icon: "checkmark.seal.fill",
                            tint: .green,
                            title: "Everything is in sync",
                            message: "No differences found between the two panes’ folders.",
                            secondary: .init("Scan Again", systemImage: "arrow.clockwise",
                                             help: "Scan both panes’ folders again and compare them") { forceRefreshAction() }
                        )
                    } else {
                        // Same symbol as the toolbar's Compare button, one glyph for "compare these
                        // two panes"; ⇄ stays reserved for swap.
                        EmptyStateView(
                            icon: PaneGlyph.compare,
                            tint: glassHue.accentColor,
                            title: "Compare \(paneNames.left) ↔ \(paneNames.right)",
                            message: notScannedMessage,
                            primary: .init("Scan", systemImage: "arrow.clockwise",
                                           help: "Scan both panes’ folders and compare them") { forceRefreshAction() }
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
        }
        }
    }

}

