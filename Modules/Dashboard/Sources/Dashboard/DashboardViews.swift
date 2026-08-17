import Settings
import FileExplorer
import Events
import SwiftUI
import Sync
import Design

/// Header above each file tree pane: provider logo and name on the left, this pane's
/// back/forward buttons on the right, and a clickable breadcrumb (provider root +
/// relative-path segments) below. Clicking a crumb navigates this pane; ⌥-clicking
/// navigates both panes to the same relative path.
public struct PaneHeader: View {
    /// The app's text size, for the labels that have to stay a `Text` (see `providerCapsule`).
    @Environment(\.appFontScale) private var appFontScale
    public let title: String
    public let provider: CloudProvider?
    public let rootPath: String
    public let relativePath: String
    public let canGoBack: Bool
    public let canGoForward: Bool
    public let onBack: () -> Void
    public let onForward: () -> Void
    public let onNavigate: (String) -> Void
    public let onNavigateBoth: (String) -> Void
    /// The enabled providers this pane can switch between — the provider name is now a dropdown
    /// (replacing the old Left/Right sidebar). Empty hides the dropdown affordance.
    public let providers: [CloudProvider]
    /// Switches this pane to the chosen provider id.
    public let onSelectProvider: (String) -> Void
    /// Opens Settings ▸ Providers (the "Manage providers…" menu item).
    public let onManageProviders: () -> Void
    /// Picks a folder and points this pane at it as a source. nil hides "Choose Folder…".
    public let onChooseFolder: (() -> Void)?
    /// The (global) sort order, surfaced per-pane now that the titlebar's file actions have moved
    /// onto the panes.
    @Binding public var sortOption: SortOption
    /// When set, shows a collapse button in the nav cluster — used by the single-source rail to
    /// collapse itself back to the spine directly (not only via the titlebar pane toggle). nil on the
    /// comparison panes, which don't collapse individually.
    /// A new tab on this pane's folder, and closing its active one — the header card's own
    /// right-click route to the tab strip.
    ///
    /// **The bar itself does not change**: no new glyph, no new `PaneBarItem`, nothing in the
    /// customize sheet (v4.x roadmap companion §1's Fig. 9 is explicit about that). This is the menu you get
    /// by right-clicking the card, which is where a Mac user reaches for "act on this pane" — and
    /// it is the only tab route that works with no folder under the pointer AND no strip on screen.
    ///
    /// Optional so every other host of this header — the tests, and any surface with no tabs behind
    /// it — simply gets no items rather than a door onto a no-op.
    public let onNewTab: (() -> Void)?
    /// `nil` at one tab: what is left to close then is the window, and an item reading "Close Tab"
    /// that closes the window is a trap.
    public let onCloseTab: (() -> Void)?
    public let onCollapse: (() -> Void)?
    /// Triggers a scan/refresh — moved off the titlebar into each pane's nav cluster. nil hides it.
    public let onRefresh: (() -> Void)?
    /// Spins the refresh glyph while a scan is running.
    public let isRefreshing: Bool
    /// Stops the running scan. When this is present the scan rung becomes a Stop button for as
    /// long as `isRefreshing` holds, instead of a disabled spinner — the control that started the
    /// scan is the one place a user looks to stop it. `nil` keeps the old disabled-while-running
    /// behaviour, which is what every caller outside the app passes.
    public let onCancelScan: (() -> Void)?
    /// Whether this is the pane the pane-scoped chords act on — ⌃⇥, ⌘F, ⌘[ / ⌘], ⇧⌘N, ⇧⌘P.
    ///
    /// Rings the provider capsule. Without it the focused side is state with no carrier at all:
    /// ⌃⇥ shipped changing no pixel, and the panes' only existing "which one is active" cue is
    /// `PaneSelectionWash`, which modulates *selected rows* — so it says nothing in exactly the
    /// case that matters, a pane with nothing selected.
    ///
    /// `false` for a lone pane. The single-source rail is the only pane on screen, so a ring there
    /// would distinguish it from nothing.
    public let isFocused: Bool
    /// Whether hidden files are shown. A per-pane control for the (global) setting, so it lives
    /// right next to each pane's navigation buttons.
    @Binding public var showHiddenFiles: Bool
    /// This pane's presentation. `nil` hides the switch entirely — the single-source rail has no Columns
    /// mode, so it gets no control for one.
    public var viewMode: Binding<PaneViewMode>?
    /// The preview toggle's state — the pill, and its twin in the ⋯ menu.
    ///
    /// It used to be read here as `@AppStorage`, on the grounds that it was one shared preference with
    /// one key that a binding would make every call site restate. There are two keys now (Browse keeps
    /// its own; see `PaneViewMode.previewColumnKey(isBrowse:)`), and this header is drawn on every
    /// surface, so reading a key here would mean this header deciding for itself which surface it is on
    /// — the mistake `shortcutPreviewColumn` documents. The host resolves it once and hands the same
    /// binding to the pill, the column context menu and ⇧⌘P.
    public var previewEnabled: Binding<Bool> = .constant(PaneViewMode.previewColumnDefault)
    /// Creates a folder in the pane's current folder — in Columns that is the deepest open column,
    /// which is the one genuinely unambiguous answer the tree view could never give. `nil` hides it.
    public let onNewFolder: (() -> Void)?
    /// Trashes THIS pane's selection. `nil` hides the control — which is what every caller outside
    /// the app passes, and what keeps the bar, the ladder and the snapshots exactly as they were.
    ///
    /// "This pane's", not "the active pane's", and the distinction is the whole point of putting it
    /// here: Compare's floating action bar acts on whichever side is active, which is unambiguous
    /// only because that bar appears on one side at a time. A control in a pane's own header is
    /// visible on both sides at once, so inheriting `activePane` would give two identical buttons
    /// two different meanings.
    public let onDelete: (() -> Void)?
    /// How many items THIS pane has selected, so the button can be disabled with none and say how
    /// many it would take with some.
    ///
    /// A count rather than a Bool because the tooltip needs the number, and it is the first thing
    /// on this bar whose state comes from the selection rather than from the pane or a preference.
    public let selectionCount: Int

    // MARK: Search inside this pane's tree
    //
    // All four arrive together or not at all. `nil` is a header with no search — which is what every
    // caller outside the app passes, and what keeps `availableItems` (and therefore the bar, the
    // ladder and the snapshots) exactly as they were.

    /// The live query for this pane. Host-owned: the results are computed against the pane's tree,
    /// which only the host can see.
    public var searchText: Binding<String>?
    /// Whether the field is showing. Host-owned so ⌘F can open it from the menu bar, which is the
    /// only entry point that survives focus sitting in a file table (see `SyncCloudApp`).
    public var searchIsExpanded: Binding<Bool>?
    /// The “2 of 7” the field carries, or nil while nothing is being searched. A string rather than
    /// a count pair because the empty-result case is a sentence, not a number.
    public var searchSummary: String?
    /// How many hits that summary is counting. Passed alongside the sentence rather than parsed back
    /// out of it: the ▲▼ buttons need to know whether there is anything to walk, and “No matches”
    /// contains no number to read.
    public var searchMatchCount: Int = 0
    /// Walks to the next (`false`) or previous (`true`) hit — ↩ and ⇧↩.
    public var onSearchAdvance: ((Bool) -> Void)?
    /// The person this query names, if it names exactly one — see `PersonSearchOffer`. Supplied as
    /// a closure rather than a registry so this view keeps knowing nothing about how the roster is
    /// loaded, and so a host with no roster simply passes nothing and the offer never appears.
    public var personOffer: ((String) -> Person?)?
    /// Accepts the offer: the find becomes a gather.
    public var onAcceptPerson: ((Person) -> Void)?
    // No surface style here: the header's shape comes from its container, its material from the
    // glass level. This view only paints the tint. It does read the level back, though — the nav
    // cluster stopped needing it when it was drawn in-house (6bb7bdf), but the provider capsule
    // needs it again: at Clear the header is see-through to the desktop, and the capsule has to
    // floor itself to frosted so the logo and name keep a ground (`chromePillSurface`).
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    /// The bar's arrangement and icon size. App-wide keys, not per-pane: one arrangement is shared by
    /// both Compare panes and the single-source rail, so that the two panes stay the same instrument pointed
    /// at two providers. Every header reads the same string, so customizing from either pane moves
    /// both — including live, while the sheet is open.
    @AppStorage(PaneBar.arrangementKey) private var arrangementRaw: String =
        PaneBarArrangement.default.encoded
    @AppStorage(PaneBar.iconSizeKey) private var iconSizeRaw: String = PaneBarIconSize.regular.rawValue
    /// Defaults to `iconAndText`: the words are the feature, and a preference that ships off is one
    /// nobody finds. It costs nothing to turn back off, and at Large or Larger text the ladder
    /// declines it on its own — see `PaneBarTitleMetrics.rowFits`.
    @AppStorage(PaneBar.labelModeKey) private var labelModeRaw: String =
        PaneBarLabelMode.iconAndText.rawValue
    /// Whether this header is showing the customize sheet. Per-header on purpose: the sheet edits
    /// shared state, but only the pane you invoked it from should sprout a sheet.
    @State private var isCustomizing = false
    /// The modifiers a search submission is read as carrying, or `nil` — the shipped default — to
    /// ask the keyboard. See `paneSearchSubmitModifiers`.
    @Environment(\.paneSearchSubmitModifiers) private var pinnedSubmitModifiers
    /// Only the dark appearance drops the provider name's brand tint — see `ChromeInk`.
    @Environment(\.colorScheme) private var colorScheme
    private var glassHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: glassHueRaw) ?? .blue
    }
    private var glassLevel: GlassLevel {
        GlassLevel(rawValue: glassLevelRaw) ?? .frosted
    }

    public init(
        title: String,
        provider: CloudProvider?,
        rootPath: String,
        relativePath: String,
        canGoBack: Bool,
        canGoForward: Bool,
        onBack: @escaping () -> Void,
        onForward: @escaping () -> Void,
        onNavigate: @escaping (String) -> Void,
        onNavigateBoth: @escaping (String) -> Void,
        providers: [CloudProvider] = [],
        onSelectProvider: @escaping (String) -> Void = { _ in },
        onManageProviders: @escaping () -> Void = {},
        onChooseFolder: (() -> Void)? = nil,
        sortOption: Binding<SortOption>,
        onNewTab: (() -> Void)? = nil,
        onCloseTab: (() -> Void)? = nil,
        onCollapse: (() -> Void)? = nil,
        onRefresh: (() -> Void)? = nil,
        isRefreshing: Bool = false,
        onCancelScan: (() -> Void)? = nil,
        isFocused: Bool = false,
        showHiddenFiles: Binding<Bool>,
        viewMode: Binding<PaneViewMode>? = nil,
        previewEnabled: Binding<Bool> = .constant(PaneViewMode.previewColumnDefault),
        onNewFolder: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        selectionCount: Int = 0,
        searchText: Binding<String>? = nil,
        searchIsExpanded: Binding<Bool>? = nil,
        searchSummary: String? = nil,
        searchMatchCount: Int = 0,
        onSearchAdvance: ((Bool) -> Void)? = nil,
        personOffer: ((String) -> Person?)? = nil,
        onAcceptPerson: ((Person) -> Void)? = nil
    ) {
        self.title = title
        self.provider = provider
        self.rootPath = rootPath
        self.relativePath = relativePath
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.onBack = onBack
        self.onForward = onForward
        self.onNavigate = onNavigate
        self.onNavigateBoth = onNavigateBoth
        self.providers = providers
        self.onSelectProvider = onSelectProvider
        self.onManageProviders = onManageProviders
        self.onChooseFolder = onChooseFolder
        self._sortOption = sortOption
        self.onNewTab = onNewTab
        self.onCloseTab = onCloseTab
        self.onCollapse = onCollapse
        self.onRefresh = onRefresh
        self.isRefreshing = isRefreshing
        self.onCancelScan = onCancelScan
        self.isFocused = isFocused
        self._showHiddenFiles = showHiddenFiles
        self.viewMode = viewMode
        self.previewEnabled = previewEnabled
        self.onNewFolder = onNewFolder
        self.onDelete = onDelete
        self.selectionCount = selectionCount
        self.searchText = searchText
        self.searchIsExpanded = searchIsExpanded
        self.searchSummary = searchSummary
        self.searchMatchCount = searchMatchCount
        self.onSearchAdvance = onSearchAdvance
        self.personOffer = personOffer
        self.onAcceptPerson = onAcceptPerson
    }

    public var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                if let provider = provider {
                    // In a narrow pane the provider NAME is the identity anchor: with the whole
                    // capsule at the row's highest layoutPriority it is offered width before the
                    // nav cluster's full-size variant, so under constraint the cluster steps down
                    // to `.mini` first, then the name middle-truncates, and only then (below the
                    // logo variant's readable floor) the logo drops.
                    ViewThatFits(in: .horizontal) {
                        providerCapsule(provider, showsLogo: true)
                        providerCapsule(provider, showsLogo: false)
                    }
                    .layoutPriority(2)
                } else {
                    // The sparse state — a pane whose provider was disabled or has not loaded — gets
                    // the same degradation ladder the capsule has, and for the same reason: the glyph
                    // yields first, the name is the identity anchor and only truncates.
                    //
                    // It had none, and it did not fit. As two bare `HStack` children with no line
                    // limit, the title wrapped rather than truncating (so its minimum width was its
                    // longest WORD) and the icon never yielded at all, which put 233pt of content in a
                    // 250pt pane's 222pt of space: the bar ran 10.5pt past the pane's trailing edge —
                    // the one failure the ladder exists to prevent, in the one state nothing tested.
                    // Truncation alone cannot close it (icon + spacings + the bar's 171pt minimum
                    // exceed 222 whatever the title does), so the icon has to be sheddable too.
                    //
                    // Pre-existing, not a regression: the ten-rung ladder drew this identically.
                    // `PaneBarLadderTests.theHeaderWithNoProviderStillFitsItsPane` is what caught it.
                    // `.layoutPriority(2)`, exactly as the capsule above carries it, is the load-bearing
                    // half. Without it this content is sized in the same pass as the greedy bar
                    // container, so it simply takes its IDEAL width, the bar is handed whatever is
                    // left, and a greedy child that is offered less than its minimum overflows in
                    // silence rather than pushing back. The priority is what makes the row offer this
                    // side `available - the bar's minimum` — which is the width the ladder above then
                    // steps down through.
                    ViewThatFits(in: .horizontal) {
                        sparseTitle(showsIcon: true)
                        sparseTitle(showsIcon: false)
                    }
                    .layoutPriority(2)
                }
                // There was a `Spacer` here, and it was what welded the bar to the trailing edge:
                // while it existed, no arrangement could put a control next to the provider name.
                // The job moved *into* the arrangement as `PaneBarItem.flexibleSpace`, which the
                // default arrangement carries at its head — so an untouched bar looks exactly as it
                // did, and a customized one can pack left.
                //
                // `.leading`, so a bar with no flexible space hugs the capsule; when the arrangement
                // does carry one, the inner `Spacer` is greedy, fills the offered width, and the
                // alignment never comes into it.
                //
                // The 12pt replaces the `HStack` gap the removed `Spacer` used to contribute. Without
                // it the row is 12pt richer, and that is not free at the narrowest rung: the extra
                // width re-crosses a threshold in the *capsule's* own ladder, which starts choosing
                // its logo variant again and renders the provider name as a bare ellipsis where it
                // used to manage a letter. The header's rule is that the name is the identity anchor
                // and the logo yields first, so the row keeps the width it was tuned at — and the
                // default arrangement stays pixel-identical to the bar it replaces.
                // The field takes the bar's track while it is open, and the bar comes back when it
                // closes.
                //
                // **This row, not a new one.** The header is pinned to `LiquidGlass.headerHeight` so
                // its bottom edge lands on the same 83.5 as the lens header card, and it holds two rows
                // inside that: this one (a 34pt provider capsule) and the breadcrumb (~15pt). The
                // field is ~33pt of text and padding — it fits this row with room and would burst
                // the breadcrumb's, compressing the whole header off the rung `PaneHeaderHeightTests`
                // pins. Taking the bar's own track also means the field gets the full width from the
                // provider capsule to the pane's trailing edge, which is as much room as this
                // header has to give.
                //
                // The breadcrumb below is deliberately left alone: while you are searching, where
                // you ARE is still worth reading — it is the thing the hit is about to move you
                // away from.
                if let searchText, let searchIsExpanded, searchIsExpanded.wrappedValue {
                    HStack(spacing: 0) {
                        searchField(text: searchText, isExpanded: searchIsExpanded)
                            // The floor is load-bearing, not defensive. `Color.clear` below is
                            // greedy in both axes, so the two are both flexible and the row splits
                            // between them — with only the cap, that left the field **6.5pt wide**
                            // in a 250pt pane, which is exactly where the split clamps a pane.
                            // (A `.layoutPriority(1)` here was tried and removed: with the floor in
                            // place it changed no measurement, and a line that changes nothing is a
                            // claim nothing checks.)
                            .frame(minWidth: Self.searchFieldMinWidth,
                                   maxWidth: Self.searchFieldMaxWidth)
                        // **The way out that is not a control.** The field is capped rather than
                        // greedy precisely so this exists: a stretch of bar to click when you are
                        // done. Reported as "NO way to exit" — the field had taken the whole track,
                        // and with an EMPTY query it has no clear button either (that one is
                        // conditional), so a pane whose focus had moved to the file list offered
                        // nothing at all to click. The ✕ in the field is the affordance; this is the
                        // dismissal people reach for first, the same way clicking outside a popover
                        // closes it.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { dismissSearch() }
                            .accessibilityHidden(true)
                    }
                    .padding(.leading, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                } else {
                    navCluster
                        .padding(.leading, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // Without this the row is only hit-testable where it has *content* — so right-clicking
            // the bar worked on a pill and nowhere else, and the empty stretch between the provider
            // name and the controls (which is most of the bar, and the obvious place to aim for "the
            // bar itself") did nothing at all. An `HStack` claims no hit area of its own.
            .contentShape(Rectangle())
            .contextMenu { barContextMenu() }
            .sheet(isPresented: $isCustomizing) {
                PaneBarCustomizeSheet(availableHere: Set(availableItems))
            }
            PaneBreadcrumb(
                rootPath: rootPath,
                providerName: provider?.displayName,
                providerIsLocalFolder: provider?.isLocalFolder ?? false,
                relativePath: relativePath,
                showHidden: showHiddenFiles,
                onNavigate: onNavigate,
                onNavigateBoth: onNavigateBoth
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // Pinned, not intrinsic — this header and the lens workspaces' `LensHeaderCard` both read
        // `headerHeight`, so the pane's header↔list boundary and the card's bottom edge land on
        // the same rule (83.5 = cardInset + headerHeight) instead of merely happening to agree.
        //
        // They did NOT agree before this: measured, the intrinsic height was 80 at a comfortable
        // width, 68 once the nav cluster stepped down to `.mini` in a ~250pt pane, and 66 with no
        // provider — so the line the two surfaces were supposed to share drifted by up to 15pt,
        // worst exactly when panes are narrow. The extra point (80 → 81) is slack absorbed by the
        // symmetric vertical padding; the narrow cases gain real air and stop breaking the line.
        .frame(height: LiquidGlass.headerHeight)
        .contentSurface(hue: glassHue, tint: surfaceTint)
    }

    /// The no-provider header's leading content: a folder glyph and the pane's title.
    ///
    /// Two rungs, mirroring the provider capsule's: `showsIcon` false is what a 250pt pane gets, where
    /// the icon plus its 12pt gap is the difference between fitting and running the bar off the
    /// trailing edge. The title carries a line limit so it truncates instead of wrapping — a wrapping
    /// `Text` reports its longest word as its minimum width and so cannot compress at all.
    private func sparseTitle(showsIcon: Bool) -> some View {
        HStack(spacing: 12) {
            if showsIcon {
                Image(systemName: "folder")
                    .scaledFont(.title2)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .scaledFont(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// The provider capsule. UX H2's hue washes behind it (`hue.soft`) in both appearances so the
    /// two panes are distinguishable — and visibly matching — at a glance. The NAME wears the brand
    /// tint on light and the standard label colour on dark.
    ///
    /// H2 tinted the name in both, and `ProviderHue`'s dark variants were lifted to clear AA "on the
    /// app's dark surfaces". Measured against the surface a hue wash actually produces, they do not:
    /// sampled from the running app at the green hue, the pane reads `#4d7f68` — a mid-tone, not a
    /// dark one — and on it iCloud's `#6FB6FF` is 2.16:1 and OneDrive's `#3E9BE0` is 1.53:1, against
    /// 4.5 for text. Plain white is 4.61:1, which is why the folder names in the list below read
    /// perfectly on the same pixels while the provider name above them did not. The wash was tuned
    /// as a background and then had text put on it.
    ///
    /// Only on dark. The light hexes are the on-brand ones read against the light ground they were
    /// picked for, so light keeps H2 whole; dark moves identity onto the logo and the wash and buys
    /// the name legibility with lightness instead of chroma. `ProviderHue.tint` remains right for a
    /// hairline or a fill in either appearance — this is only about text on a washed dark surface,
    /// which is equally true of `PaneBreadcrumb`'s root crumb.
    ///
    /// The name + chevron is the menu trigger;
    /// the logo stays a plain image OUTSIDE the menu label (a resizable image inside one balloons
    /// to its native size). ViewThatFits compares each variant's IDEAL width against the offer,
    /// so the logo variant wins only while the full name fits alongside it; once the name would
    /// have to give up characters, the logo yields first and the logo-less variant truncates the
    /// name as far as an ellipsis — the name is the identity anchor, the logo is decoration.
    private func providerCapsule(_ provider: CloudProvider, showsLogo: Bool) -> some View {
        let hue = ProviderHue.classify(provider.displayName, isLocalFolder: provider.isLocalFolder)
        return HStack(spacing: 10) {
            if showsLogo {
                ProviderLogo(provider.imageName, size: 28)
            }
            ProviderMenu(
                providers: providers,
                currentId: provider.id,
                onSelect: onSelectProvider,
                onManage: onManageProviders,
                onChooseFolder: onChooseFolder
            ) {
                Text(provider.displayName)
                    // `Text.scaledFont(_:scale:)`, not the View modifier: this is a `Menu`
                    // label, and AppKit renders it itself — a wrapped Text loses both the
                    // weight and the colour below.
                    .scaledFont(.headline.weight(.semibold), scale: appFontScale)
                    .foregroundStyle(ChromeInk.label(colorScheme, light: hue.tint))
                    // A long custom provider name must truncate, not wrap the
                    // header taller in a narrow pane. Middle truncation is the intent, but the
                    // menu style's AppKit-backed label ignores the preference and elides the
                    // tail (verified in the 250/400 pt snapshots; setting the environment value
                    // on the Menu itself changes nothing either) — the load-bearing part is
                    // that the name truncates at all instead of ballooning the row.
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentShape(Rectangle())
            }
            .help("Switch this pane's cloud provider")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .chromePillSurface(glassLevel, wash: hue.soft)
        // The focused pane's ring. `.overlay` and not a border or a padding change: an overlay
        // takes its size FROM the host and gives none back, which is the whole reason this can be
        // added to a header whose height is pinned (`PaneHeaderHeightTests`, and `LensHeaderCard`
        // shares that line from the other side). A ring that cost even a point would push the
        // pinned rung out of its rail.
        //
        // On the capsule because that is the pane's identity chip — the thing already saying
        // *which* pane this is — so "and it is the one the keyboard is in" lands on the same
        // object rather than inventing a second marker. The raw accent rather than
        // `accentFillColor`: the deepening exists to keep a LABEL legible on a fill, and a stroke
        // carries no label; what a line needs is saturation.
        .overlay {
            if isFocused {
                Capsule().strokeBorder(glassHue.accentColor, lineWidth: 2)
            }
        }
    }

    /// This pane's bar: the track running from the provider capsule to the pane's trailing edge.
    ///
    /// Rendered through `ViewThatFits` so that at the narrowest pane widths (the split clamps panes
    /// at 250 pt, where small-size controls plus the provider capsule physically exceed the row) the
    /// bar steps down to `.mini` controls and then sheds pills into ⋯ instead of overflowing the
    /// trailing edge — every control stays reachable, nothing is pushed out of view.
    ///
    /// The rung is **computed, not searched**. This used to be a ten-child `ViewThatFits`, and
    /// `ViewThatFits` builds every child in order to measure it: ten full bars of up to eight
    /// hover-affordance controls, twice over for two panes, on every layout pass — which is to say on
    /// every re-evaluation of `ContentView`'s body. Measured with `MainThreadHitchMonitor` over
    /// opening and closing Settings three times, that search was 4,805 ms of main-thread work and an
    /// 831 ms worst stall, against 1,002 ms / 175 ms for a ladder cut to one rung. It was the pane
    /// header's dominant cost, and the cause of a whole class of reported slowness.
    ///
    /// `PaneBarLadder` does the same job with arithmetic — see it for why the ladder is not monotonic
    /// and must therefore be walked in order rather than sorted by width.
    ///
    /// The `GeometryReader` reads the width the bar is actually offered: the row hands the provider
    /// capsule its width first (it holds the higher `layoutPriority`) and this container takes what is
    /// left, so the proxy is measuring exactly what `ViewThatFits` used to be handed. It replaces a
    /// `ViewThatFits`, which reported the *narrowest* rung as its minimum width — the number the row
    /// reserves for the bar before the capsule may grow into it — so `minWidth` restates that.
    ///
    /// The computed rung is still handed to `ViewThatFits` with the narrowest rung behind it, so the
    /// layout engine keeps the final say: if the arithmetic ever overestimates what fits, the bar
    /// steps down instead of overflowing the pane's trailing edge. Two children, not ten.
    /// The ladder this header actually builds, from its own preferences and its own item list.
    ///
    /// Internal, and the single source: `PaneBarLadderTests` measures the drawn bar against *this*
    /// rather than re-assembling one from `.default` and the ceiling. Re-assembly is how a test
    /// stays green against a ladder the header stopped building — which is not hypothetical, it is
    /// what happened the moment `labelMode` was added: the test's ladder defaulted to `iconOnly`
    /// while the header read `iconAndText` from `@AppStorage`, and every width assertion compared
    /// two different bars.
    var barLadder: PaneBarLadder {
        PaneBarLadder(arrangement: PaneBarArrangement(encoded: arrangementRaw),
                      available: availableItems,
                      ceiling: iconSize.ceiling,
                      labelMode: labelMode,
                      scale: appFontScale)
    }

    private var navCluster: some View {
        let ladder = barLadder
        return Group {
            if provider == nil {
                searchedLadder(ladder)
            } else {
                GeometryReader { proxy in
                    let rung = ladder.rung(fitting: proxy.size.width)
                    // `.leading` is (leading, centre): a `GeometryReader` parks its content at the
                    // top-left corner, where the row used to hand the bar the enclosing `HStack`'s
                    // vertical centring and the container frame's leading alignment. A bar carrying a
                    // flexible space fills the width either way; one packed hard left does not, and
                    // would drift to the middle.
                    hedged(rung, ladder)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
                }
                // A `GeometryReader` is greedy in both axes and reports nothing about its content, so
                // the two things the `ViewThatFits` it replaced *did* report have to be restated:
                // the narrowest rung's width, which is what the row reserves for the bar before the
                // capsule may grow into it, and a height — pinned, or the row would stretch to the
                // tallest it could ever be.
                //
                // Pinning the height to the narrowest rung is exact only because something else in
                // the row is always taller: the provider capsule is a 28pt logo (34 with its padding)
                // or a headline-sized name, against 26pt for the widest rung. That is precisely why
                // the header WITHOUT a capsule takes the searched ladder above — there the bar is the
                // row's own height authority, and a pinned container reports the wrong row height.
                .frame(minWidth: ladder.width(forRung: ladder.terminal),
                       minHeight: ladder.height(forRung: ladder.terminal),
                       maxHeight: ladder.height(forRung: ladder.terminal))
            }
        }
    }

    /// The original ladder, searched by `ViewThatFits`, for the header that has no provider capsule.
    ///
    /// Kept for the one case the computed rung cannot serve — see `navCluster` — and it must declare
    /// enough literal children to cover the deepest ladder ANY arrangement can build, because
    /// `ViewThatFits` takes a `ViewBuilder` and a `ForEach` over rungs is a SINGLE child (the ladder
    /// silently collapses to one rung). `PaneBarLadder.searchedSlotCount` owns that arithmetic and
    /// MUST match the literal count here; `PaneBarLadderTests.theSearchedLadderDeclaresOneChildPerSlot`
    /// counts the children of this very view rather than trusting this sentence.
    ///
    /// **Only the slots that draw a different bar build one.** A slot past `terminal` would redraw
    /// the terminal rung, and `ViewThatFits` can never choose it: an identical-width child sits
    /// ahead of it and wins first-fit. So those slots are `Color.clear` stand-ins of exactly the
    /// terminal rung's size — they measure like the bar they replace and cost nothing to build. The
    /// LAST slot always draws for real, because `ViewThatFits` renders its last child when nothing
    /// fits, and that fallback has to be a bar rather than a hole. `PaneBarLadder.searchedSlotDrawsBar`
    /// is the rule; `searchedSlotIsInert` is why it is safe.
    ///
    /// This matters because the provider-less header is not the rare case the slot count implies:
    /// `provider` is nil for BOTH panes until `discoverProviders()` fills `availableProviders`, and
    /// indefinitely for a pane pointed at a disabled or unmounted provider — so this path runs at
    /// launch, when a stall is most visible, and rebuilds on every `ContentView` body evaluation.
    /// Seventeen bars per pane there is precisely the cost `navCluster`'s computed rung exists to
    /// avoid (see its 4,805 ms / 831 ms note). Measured offscreen in Release — one whole body
    /// evaluation and layout of this header with the DEFAULT arrangement, whose `terminal` is 6, so
    /// seven rungs differ and eight slots draw. Best of three interleaved A/B rounds, each the
    /// minimum of 60 passes (this Mac is also the CI runner, and contention only ever adds time):
    ///
    ///     250pt   120 ms -> 34 ms      600pt   232 -> 129      900pt   252 -> 137
    ///
    /// The header WITH a capsule, which this change does not touch, measured 10–18 ms throughout and
    /// is the control that says the harness is comparing like with like.
    ///
    /// Why not compute the rung here as `navCluster` does? Because that needs the offered width
    /// before the height is settled, and here the bar is the row's own height authority — there is
    /// no provider capsule to be the taller thing, so a container pinned to one rung's height
    /// reports the wrong row height for every other rung. A `GeometryReader` cannot supply it
    /// (greedy in both axes, and reports nothing about its content), and taking the width through
    /// `.onGeometryChange` into `@State` would write view state from a layout callback — which in
    /// this codebase has already produced an AppKit layout loop, and would genuinely feed back here:
    /// the bar's minimum width is what the row offers `sparseTitle`, whose own `ViewThatFits` then
    /// changes the width the bar is offered.
    func searchedLadder(_ ladder: PaneBarLadder) -> some View {
        ViewThatFits(in: .horizontal) {
            searchedSlot(0, ladder)
            searchedSlot(1, ladder)
            searchedSlot(2, ladder)
            searchedSlot(3, ladder)
            searchedSlot(4, ladder)
            searchedSlot(5, ladder)
            searchedSlot(6, ladder)
            searchedSlot(7, ladder)
            searchedSlot(8, ladder)
            searchedSlot(9, ladder)
            searchedSlot(10, ladder)
            searchedSlot(11, ladder)
            searchedSlot(12, ladder)
            searchedSlot(13, ladder)
            searchedSlot(14, ladder)
            searchedSlot(15, ladder)
            searchedSlot(16, ladder)
            // Added with titles: `titledRungs` puts one more rung at the head of the ladder, so
            // `searchedSlotCount` grew from `maxItems + 1` to `maxItems + 2`. A `ForEach` here
            // would collapse all eighteen into one child — see this function's note —
            // and a missing literal child has no error, only a rung the search can never reach.
            searchedSlot(17, ladder)
        }
    }

    /// One child of the searched ladder: the bar at this slot's rung, or — where that bar would be a
    /// duplicate `ViewThatFits` can never choose — a stand-in that measures the same and draws
    /// nothing. See `searchedLadder` for why the duplicates are unreachable and why the last slot
    /// never becomes one.
    ///
    /// An `if` inside a `ViewBuilder` is one `_ConditionalContent` child either way, so this stays
    /// one child per slot and the ladder keeps its rungs — unlike a `ForEach`, which would collapse
    /// all seventeen into one.
    @ViewBuilder
    private func searchedSlot(_ slot: Int, _ ladder: PaneBarLadder) -> some View {
        if ladder.searchedSlotDrawsBar(slot) {
            barVariant(ladder.searchedRung(forSlot: slot), ladder)
        } else {
            Color.clear
                .frame(width: ladder.width(forRung: ladder.terminal),
                       height: ladder.height(forRung: ladder.terminal))
        }
    }

    /// The computed rung, with the narrowest rung behind it as the layout engine's veto.
    ///
    /// The fallback is the NARROWEST rung, not the next one down: if the arithmetic ever overestimates
    /// what fits, the bar does not step down one rung, it drops all the way to compact. That is the
    /// deliberate trade — a bar that over-compacts is visibly wrong and every control stays reachable
    /// in ⋯, whereas a bar that overflows the pane's trailing edge has no symptom at all. Widening
    /// this to `{rung, rung + 1, terminal}` would soften the landing at the cost of building a third
    /// bar on every layout pass, which is the cost this whole change exists to remove; the arithmetic
    /// is checked against the drawn bar by `PaneBarLadderTests` instead.
    ///
    /// Branched rather than always emitting both, because at the narrowest pane widths the computed
    /// rung *is* the terminal one, and a `ViewThatFits` of two identical children would build the bar
    /// twice for nothing. The branch is outside the `ViewThatFits` on purpose: an `if` inside its
    /// `ViewBuilder` is one `_ConditionalContent` child, not two, and the ladder would collapse.
    @ViewBuilder
    private func hedged(_ rung: Int, _ ladder: PaneBarLadder) -> some View {
        if rung >= ladder.terminal {
            barVariant(ladder.terminal, ladder)
        } else {
            ViewThatFits(in: .horizontal) {
                barVariant(rung, ladder)
                barVariant(ladder.terminal, ladder)
            }
        }
    }

    /// Rung `rung` of the ladder: rung 0 is the chosen icon size unfolded, rung 1 drops to `.mini`,
    /// and every rung after that sheds one more item into ⋯.
    ///
    /// The icon-size preference is a **ceiling**: choosing Small starts at rung 1's size, but the
    /// shedding rungs still apply, because a bar that overflows the pane is worse than small glyphs.
    /// The terminal rung sheds everything sheddable, so an arrangement of any length still has a
    /// variant that fits rather than falling off the end.
    ///
    /// Internal rather than private for the same reason `availableItems` is: `PaneBarLadderTests`
    /// checks that the searched ladder draws *this* bar at each rung by comparing the two laid out,
    /// which is only an honest check if it is the view's own variant and not a restatement of it.
    func barVariant(_ rung: Int, _ ladder: PaneBarLadder) -> some View {
        barContent(ladder.controlSize(forRung: rung),
                   depth: ladder.depth(forRung: rung),
                   arrangement: ladder.arrangement,
                   available: ladder.available,
                   titled: ladder.isTitled(forRung: rung))
    }

    /// Which items this particular header can offer at all. A header with no view-mode binding has
    /// no View control to place; the single-source rail has no Columns mode, so no preview to toggle.
    ///
    /// Internal rather than private so `PaneBarLadderTests` can build its ladder from the same list
    /// the view does. Restated by hand, a test keeps passing against a ladder the header stopped
    /// building the moment this list changes — and the arithmetic it is checking is per-ladder.
    var availableItems: [PaneBarItem] {
        var available: [PaneBarItem] = [.backForward, .sort, .hiddenFiles]
        if viewMode != nil { available.append(.viewMode) }
        if onCollapse != nil { available.append(.collapse) }
        if onRefresh != nil { available.append(.scan) }
        if onNewFolder != nil { available.append(.newFolder) }
        if showsPreviewToggle { available.append(.preview) }
        // Same gate, same reason as search below: a header with no delete handler has nothing to
        // trash, so it offers no trash — and so builds precisely the bar it built before this
        // control existed. That is what keeps `PaneHeaderHeightTests` and the 250pt snapshots
        // measuring what they were written to measure.
        if onDelete != nil { available.append(.delete) }
        // A header with no search bindings has no field to reveal, so it offers no magnifier — and
        // so builds precisely the bar it built before search existed. That is what keeps every
        // existing header test, snapshot and ladder measurement untouched by this feature.
        if searchText != nil, searchIsExpanded != nil { available.append(.search) }
        return available
    }

    private var iconSize: PaneBarIconSize {
        PaneBarIconSize(rawValue: iconSizeRaw) ?? .regular
    }

    private var labelMode: PaneBarLabelMode {
        PaneBarLabelMode(rawValue: labelModeRaw) ?? .iconAndText
    }

    private func barContent(_ controlSize: ControlSize,
                            depth: Int,
                            arrangement: PaneBarArrangement,
                            available: [PaneBarItem],
                            titled: Bool = false) -> some View {
        let plan = PaneBarLayout.plan(arrangement: arrangement, available: available, depth: depth)
        // Gaps are placed by hand rather than by `HStack(spacing:)`, because a flexible space must
        // cost *nothing*. As a stack child it would otherwise earn a 6pt gap of its own, the bar's
        // minimum width would grow by that much for every bar carrying one — which is every default
        // bar — and the provider capsule would lose the 6pt at the narrowest rung. Measured: it
        // shaved a character off the name in the 250pt snapshot.
        // `.top`, so every pill shares one edge and therefore every title shares one baseline. The
        // default centring would hang the shorter items' words at their own heights.
        return HStack(alignment: .top, spacing: 0) {
            ForEach(Array(plan.visible.enumerated()), id: \.offset) { index, item in
                if PaneBarLayout.needsGap(before: index, in: plan.visible) {
                    Color.clear.frame(width: PaneNavMetrics.itemGap(titled: titled), height: 1)
                }
                titled
                    ? AnyView(titledItem(item, controlSize: controlSize,
                                         compactViewMode: plan.compactsViewMode))
                    : AnyView(barItem(item, controlSize: controlSize,
                                      compactViewMode: plan.compactsViewMode))
            }
            if !plan.overflow.isEmpty {
                if plan.visible.last.map({ $0 != .flexibleSpace }) ?? false {
                    Color.clear.frame(width: PaneNavMetrics.itemGap(titled: titled), height: 1)
                }
                // Untitled in both modes, and aligned with the pill row rather than centred in it.
                // Finder labels its Action menu, but that is a fixed contextual menu; our analogue
                // is Finder's unlabelled `»`, whose contents depend on what happened to fit.
                viewOptionsMenu(controlSize: controlSize, overflow: plan.overflow)
            }
        }
        .controlSize(controlSize)
    }

    /// One bar item with its word underneath.
    ///
    /// The box is as wide as the wider of the pill and the word — `PaneBarLayout.titledWidth` is
    /// the same rule in arithmetic, and the ladder picks its rung by that number, so the two must
    /// agree or the bar on screen is not the bar that was measured.
    ///
    /// Scan takes its word from `ScanRungMode` rather than from `PaneBarItem`, because that rung's
    /// word swaps with its glyph; every other item's word is fixed.
    @ViewBuilder
    private func titledItem(_ item: PaneBarItem, controlSize: ControlSize,
                            compactViewMode: Bool) -> some View {
        if item.isSpacer {
            barItem(item, controlSize: controlSize, compactViewMode: compactViewMode)
        } else {
            let pill = PaneNavMetrics.pill(controlSize)
            let title = item == .scan
                ? ScanRungMode.resolve(isRefreshing: isRefreshing,
                                       canCancel: onCancelScan != nil).barTitle
                : item.barTitle
            let box = PaneBarLayout.titledWidth(of: item, pill: pill,
                                                compactsViewMode: compactViewMode,
                                                scale: appFontScale)
            VStack(spacing: PaneBarTitleMetrics.gap) {
                barItem(item, controlSize: controlSize, compactViewMode: compactViewMode)
                Text(title)
                    .scaledFont(PaneBarTitleMetrics.font, scale: appFontScale)
                    .foregroundStyle(ChromeInk.label(colorScheme, light: .primary.opacity(0.75)))
                    .lineLimit(1)
                    .fixedSize()
                    // **Hidden, which is what the note below always claimed and never did.** The
                    // pill carries the control's own label and hint, and this word repeats it, so
                    // leaving both visible to VoiceOver reads every item on the bar twice — "Scan,
                    // button. Scan." `children: .contain` does not prevent that: it makes this a
                    // container and *keeps* its children as separate elements, which is the opposite
                    // of merging or suppressing them. Only hiding the duplicate does the job.
                    .accessibilityHidden(true)
            }
            .frame(width: box)
            // Kept so the pill inside stays its own focusable element with its button traits; the
            // word above is hidden rather than combined, so nothing here is read twice.
            .accessibilityElement(children: .contain)
        }
    }

    /// One item of the arrangement, drawn.
    ///
    /// Every branch here existed before as a line in one long `HStack`; what changed is that the
    /// order comes from the arrangement rather than from this function's shape.
    @ViewBuilder
    private func barItem(_ item: PaneBarItem, controlSize: ControlSize, compactViewMode: Bool) -> some View {
        switch item {
        case .flexibleSpace:
            // What used to be the `Spacer` that welded the cluster to the trailing edge. It is an
            // item now, so it can sit anywhere — or nowhere, which is how a bar packs left.
            Spacer(minLength: 0)

        case .space:
            Color.clear.frame(width: PaneNavMetrics.pill(controlSize).width, height: 1)

        case .viewMode:
            if let viewMode {
                if compactViewMode {
                    // One pill showing the current mode; the alternatives live in its menu. This is
                    // the deepest rung's economy — two pills' worth of ability in one pill's width.
                    Menu {
                        Picker("View", selection: viewMode) {
                            ForEach(PaneViewMode.allCases) { mode in
                                Label(mode.displayName, systemImage: mode.symbol).tag(mode)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        Image(systemName: viewMode.wrappedValue.symbol)
                            .paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
                    }
                    .menuIndicator(.hidden)
                    .menuStyle(.button)
                    .buttonStyle(navButtonStyle)
                    .fixedSize()
                    .help("Choose how this pane shows its files")
                } else {
                    viewModeSwitch(viewMode, controlSize: controlSize)
                }
            }

        case .collapse:
            if let onCollapse {
                Button(action: onCollapse) {
                    Image(systemName: "sidebar.left").paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
                }
                .buttonStyle(navButtonStyle)
                .help("Collapse the source pane")
            }

        case .backForward:
            // One arrangement item, two pills — they move and fold together, as they do in Finder.
            // The stack restates the 6pt the bar's outer spacing no longer supplies.
            //
            // Known trade, inherited from the ⌘F badge below: BOTH panes' rungs wear the chord
            // during the ⌥ reveal, but the menu equivalent acts on the FOCUSED pane — so the
            // unfocused pane's badge names a chord that navigates the other pane. Focus-gating
            // the badges would need pane identity threaded into this shared header and would
            // make keycaps appear and vanish as selection moves mid-reveal; the button itself
            // always acts on its own pane, so the click the badge decorates is never wrong.
            HStack(spacing: PaneNavMetrics.pairSpacing) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
                }
                .buttonStyle(navButtonStyle)
                .shortcutKeycap(AppChord.paneBack.display)
                .disabled(!canGoBack)
                .help(ShortcutHint.tooltip("Go back to this pane's previous folder", AppChord.paneBack.display))

                Button(action: onForward) {
                    Image(systemName: "chevron.right").paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
                }
                .buttonStyle(navButtonStyle)
                .shortcutKeycap(AppChord.paneForward.display)
                .disabled(!canGoForward)
                .help(ShortcutHint.tooltip("Go forward to this pane's next folder", AppChord.paneForward.display))
            }

        case .scan:
            // Scan/refresh used to live INSIDE the pane's freshness badge, pairing the action
            // with the state it acted on, and this standalone button existed only for the
            // pre-scan window where that badge had no date to show. Freshness has since moved to
            // the differences count pill — a toggle, so it cannot also be the scan button — which
            // makes this the pane's one scan control at every point in the lifecycle. That is also
            // why `PaneBarItem.pinned` refuses to remove or fold it: a gate here means a pane that
            // can never be scanned.
            if let onRefresh {
                // Mid-scan this rung becomes Stop, when the host supplied one. The scan it would
                // start is the one already running, so the button was disabled anyway — a live
                // Stop occupies dead chrome rather than adding any. The rung keeps its position
                // and size, so nothing after it moves when the swap happens.
                //
                // The spinning arrow goes with it, and that is the trade: "something is happening"
                // is still carried by the differences count pill's "scanning…" and by both panes'
                // own loading state, while "you can stop this" had no carrier at all. A spinner
                // you cannot stop was the whole complaint.
                //
                // Every one of the five things that differ between the two states comes from one
                // resolved `ScanRungMode`, where a test can hold them together — a rung whose
                // glyph says Stop while its badge still offers ⌘R is the failure this shape rules
                // out by construction.
                let mode = ScanRungMode.resolve(isRefreshing: isRefreshing, canCancel: onCancelScan != nil)
                Button(action: { mode == .stop ? onCancelScan?() : onRefresh() }) {
                    Image(systemName: mode.symbol)
                        .symbolEffect(.rotate, options: .repeating, isActive: mode.spins)
                        .paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
                }
                .buttonStyle(navButtonStyle)
                .shortcutKeycap(mode.keycap)
                .disabled(!mode.isEnabled)
                .help(mode.help)
                .accessibilityLabel(mode.label)
            }

        case .newFolder:
            // New Folder. In Columns its target is unambiguous — the deepest open column — which
            // is why it graduates from the right-click menu to the chrome here.
            if let onNewFolder {
                Button(action: onNewFolder) {
                    Image(systemName: "folder.badge.plus")
                        .paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
                }
                .buttonStyle(navButtonStyle)
                .shortcutKeycap(AppChord.newFolder.display)
                .help(ShortcutHint.tooltip("New folder in this pane's current folder", AppChord.newFolder.display))
            }

        case .sort:
            // Sort moved out of the titlebar (its file-action neighbors are now the pane's
            // contextual action bar); it lives per-pane, driving the shared sort order.
            Menu {
                Picker("Sort By", selection: $sortOption) {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
            }
            .menuIndicator(.hidden)
            // The one combination that leaves the label alone. `.button` makes the menu render as
            // a button; `.plain` inside `navButtonStyle` stops that button drawing chrome of its
            // own over the capsule the label already carries. Measured at 21x20 painted —
            // pixel-identical to a plain Button, which nothing else here managed.
            //
            // A `Menu` also does NOT inherit a `buttonStyle` from an ancestor, so this has to be
            // restated on the menu itself rather than left to the cluster.
            .menuStyle(.button)
            .buttonStyle(navButtonStyle)
            .fixedSize()
            .help("Choose how items are sorted")

        case .hiddenFiles:
            // Hidden-files toggle, icon-only. The eye mirrors the state: open when hidden files are
            // shown, slashed when filtered.
            Button {
                showHiddenFiles.toggle()
            } label: {
                Image(systemName: showHiddenFiles ? "eye" : "eye.slash").paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
            }
            .buttonStyle(navButtonStyle)
            .shortcutKeycap(AppChord.hiddenFiles.display)
            .help(ShortcutHint.tooltip(showHiddenFiles
                                       ? "Hidden files are visible — click to hide them"
                                       : "Hidden files are hidden — click to show them",
                                       AppChord.hiddenFiles.display))

        case .preview:
            if showsPreviewToggle {
                previewTogglePill(controlSize: controlSize)
            }

        case .delete:
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        // The one glyph on this bar that wears a colour of its own rather than the
                        // app accent. Every other rung here either changes something reversible or
                        // changes nothing at all; this one moves files. Disabled it greys out with
                        // the rest, so the red appears only when there is something to act on.
                        .paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize,
                                       ink: ChromeInk.semantic(colorScheme, SemanticColor.error))
                }
                .buttonStyle(navButtonStyle)
                .disabled(selectionCount == 0)
                // Deliberately NOT `AppChord.deleteSelection`: ⌘⌫ is Compare-only and acts on the
                // ACTIVE pane, so badging this button with it would promise the chord does what
                // the button does — which is false on the inactive side, and false everywhere in
                // Browse and Organize.
                .help(deleteHelp)
                .accessibilityLabel(deleteHelp)
            }

        case .search:
            // A plain nav pill, not Design's `ExpandingSearchToggle`. The toggle is the right
            // affordance on a lens header, where it is the last item of a row of bare glyphs; here
            // its neighbours are `paneNavChrome` pills, and a differently-sized magnifier among
            // them would be the one control that does not line up. The behaviour it carries is one
            // Bool, restated below; the FIELD — where the real mechanism is (deferred focus on an
            // animated reveal, Escape, clear) — is `ExpandingSearchField` verbatim.
            if let searchText, let searchIsExpanded {
                Button {
                    withAnimation(ExpandingSearch.animation) {
                        searchIsExpanded.wrappedValue.toggle()
                        if !searchIsExpanded.wrappedValue { searchText.wrappedValue = "" }
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        // **No live-query tint, and its absence is the decision.** This rung
                        // carried one — "tinted whenever a query is live, so a search narrowing
                        // what you are looking at can never be silently on behind a quiet glyph" —
                        // written as a `.foregroundStyle` on the Button, outside the label, where
                        // `paneNavChrome`'s own glyph colour outranked it. It painted nothing:
                        // 0 accent pixels in both states, measured.
                        //
                        // Wiring it up was the wrong repair, and finding out why is the useful
                        // part: **the state it guards cannot happen.** This magnifier is drawn
                        // only in the `else` of `isExpanded`, and every path that collapses the
                        // field clears the query with it — `ExpandingSearch.collapse` does it in
                        // one transaction, for the reason stated there ("a query left live behind
                        // a hidden field is a filter you can't see or undo"), and this button's
                        // own toggle does it too. A live query is therefore always accompanied by
                        // a visible field holding it. There is no silent filter to signal, so
                        // there is nothing here to tint.
                        //
                        // `PaneBarSearchTintTests` pins that invariant, so a future change that
                        // lets a query outlive its field fails there rather than silently
                        // re-creating the hidden state this tint was written for.
                        .paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
                }
                .buttonStyle(navButtonStyle)
                // Centred, not trailing: a ⌘F keycap is nearly as wide as this button, and
                // anything overhanging would foul the nav glyphs either side of it. Covering the
                // magnifier for the length of an ⌥ hold is fine — the badge IS the answer to the
                // question the hold asked.
                .shortcutKeycap(AppChord.findInPane.display)
                .help(ShortcutHint.tooltip("Find a file or folder in this pane", AppChord.findInPane.display))
            }
        }
    }

    /// The revealed field: Design's shared `ExpandingSearchField`, with Compare's own “N of M” in
    /// its trailing slot.
    ///
    /// Nothing about focus is restated here, deliberately. The field claims focus itself, one Task
    /// hop after it appears — inline that back into whatever reveals it and the field opens dead, so
    /// you have to click it before typing. That mechanism is the reason this is the shared field and
    /// not a `TextField`.
    ///
    /// **↩ and ⇧↩ both arrive as `onSubmit`.** A single-line `TextField` submits on Return with or
    /// without Shift, and its own handling of the key comes first — an `.onKeyPress(.return)` on an
    /// ancestor of the focused field does not see it. So the direction is read from the modifiers at
    /// the moment of submission, through the same injectable seam the pane's click guards use and
    /// for the same reason: `NSEvent.modifierFlags` is the state of the machine's keyboard, which is
    /// right for a real keystroke and unwinnable for a test. See `paneSearchSubmitModifiers`.
    @ViewBuilder
    private func searchField(text: Binding<String>, isExpanded: Binding<Bool>) -> some View {
        ExpandingSearchField(
            text: text,
            isExpanded: isExpanded,
            placeholder: "Find in this pane — ↩ next, ⇧↩ previous",
            trailing: {
                if let searchSummary {
                    Text(searchSummary)
                        .scaledFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                    // **The counter is not an affordance.** "1 of 101" said where the walk stood
                    // and offered no way to move it: ↩/⇧↩ were written in the placeholder, which is
                    // gone the moment there is a query to count — so by the time the count appears,
                    // the only thing that taught the chords has been replaced by it. Reported as
                    // the search having no next/previous at all, which from the screen is true.
                    //
                    // Up/down rather than the ‹ › this bar uses for Back/Forward: those two live in
                    // this very header (`standardHeaderControls`), and a pair of left/right chevrons
                    // that means "history" in one state and "match" in the other is the ambiguity
                    // worth spending two glyphs to avoid. Up/down is also what ⇧↩/↩ do to a walk
                    // down an ordered list of hits, and what every find bar with a count uses.
                    //
                    // Gated on the walk callback as well as the count: a host that supplies no way
                    // to walk must not be given two buttons that do nothing. It is also what lets
                    // `PaneHeaderSearchTests` render the same field with and without them and count
                    // the difference — an ink threshold with no such control measures the counter
                    // and the ✕ and passes with no arrows at all.
                    if onSearchAdvance != nil {
                        searchStepButton(.previous)
                        searchStepButton(.next)
                    }
                }
                // **Unconditional, and that is the whole point.** The field's own clear button
                // (`ExpandingSearchField`) appears only once there is text to clear, and this row
                // replaces the pane bar while it is open — so an EMPTY search field offered no
                // control of any kind, and once focus moved to the file list even Escape was gone.
                // Reported as "NO way to exit". This closes the search rather than clearing the
                // query, so it is a different verb from the ✕ beside it and never sits alone
                // pretending to be one.
                Button {
                    dismissSearch()
                } label: {
                    Image(systemName: "xmark").hoverInk()
                }
                .buttonStyle(.hoverAffordance(.inline))
                .help("Close search (Esc)")
                .accessibilityLabel("Close search")
            },
            accessories: { _ in
                // **The find is unchanged; this only ever adds a row beneath it.** The substring
                // search runs on this query exactly as before, and ⇧↩ keeps it — so a query that
                // names nobody behaves the way it always has, which is what makes an offer safe to
                // put on a control people already use.
                if let person = personOffer?(text.wrappedValue) {
                    Button {
                        onAcceptPerson?(person)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "person.crop.circle")
                                .scaledFont(.system(size: 11, weight: .semibold))
                            Text("\(person.displayName) — everything that is theirs")
                                .scaledFont(.system(size: 11.5, weight: .medium))
                            Spacer(minLength: 6)
                            // **Bigger than the sentence it sits beside, not smaller.** ⌘ and ↩ are
                            // symbols, not letters: at a given point size they carry far less ink
                            // than a glyph like "e", and a monospaced face thins them further to
                            // fit a letter's advance. Set to 10.5 against the label's 11.5 — the
                            // arithmetic of a quiet trailing hint — they read as a smudge, which is
                            // what was reported. The app's own precedent for a chord shown as text
                            // is `ShortcutsReference`, at `.callout`; this matches that scale.
                            Text("⌘↩")
                                .scaledFont(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .chromeHover()
                    .help("Gather everything filed under \(person.displayName), and everything named for them")
                    .accessibilityLabel("Show everything that is \(person.displayName)'s")
                }
            }
        )
        .onSubmit {
            let modifiers = pinnedSubmitModifiers ?? NSEvent.modifierFlags
            // ↩ and ⇧↩ are the find's own next and previous, always, offer or no offer. Taking the
            // offer is ⌘↩ — a chord the find never used — so the offer costs the find nothing and
            // no key stops doing what it did before.
            // The routing is a pure table — see ``PaneSearchSubmit``, which is where it is
            // tested, because `onSubmit` cannot be fired from a test.
            let person = personOffer?(text.wrappedValue)
            switch PaneSearchSubmit.action(modifiers: modifiers, hasOffer: person != nil) {
            case .acceptPerson:
                if let person { onAcceptPerson?(person) }
            case .advance(let reverse):
                onSearchAdvance?(reverse)
            }
        }
    }

    /// One of the two walk buttons beside the counter.
    ///
    /// Disabled on zero hits rather than hidden: "No matches" beside a live pair of arrows would
    /// read as "there is somewhere to go, this just is not it". Deliberately still enabled at
    /// exactly one hit — the walk wraps (`PaneSearchWalk.advance`), so pressing it re-reveals that
    /// hit, which is what someone who has scrolled away from it is asking for.
    ///
    /// Everything that differs between the two buttons is in `PaneSearchStep`, not here. The two
    /// otherwise differ only by a Bool, and a copy-paste that walked the same direction twice would
    /// look entirely right on screen — the enum is what a test can hold instead.
    @ViewBuilder
    func searchStepButton(_ step: PaneSearchStep) -> some View {
        Button {
            onSearchAdvance?(step.reverse)
        } label: {
            Image(systemName: step.systemImage)
                .scaledFont(.system(size: 10, weight: .semibold))
                .hoverInk()
        }
        .buttonStyle(.hoverAffordance(.inline))
        .disabled(searchMatchCount == 0)
        // **`.disabled` alone is invisible here, and that was measured.** `HoverAffordanceStyle`
        // reads `isEnabled` only to suppress the hover wash (see its `resolve`); the glyph keeps
        // its resting colour, so a disabled arrow rendered pixel-for-pixel identical to a live one
        // — 630 ink either way. "No matches" beside two arrows that look pressable is the state
        // this whole pair was added to avoid, so the dimming is drawn rather than inherited.
        .opacity(searchMatchCount == 0 ? 0.35 : 1)
        .help(ShortcutHint.tooltip(step.label, step.chord))
        .accessibilityLabel(step.label)
    }

    /// Closes the search: the field goes away and the query goes with it.
    ///
    /// One definition, reached from both places that offer a way out — the ✕ inside the field and
    /// the stretch of bar beside it. They had a copy each, which is how two controls that mean the
    /// same thing start meaning slightly different things.
    ///
    /// Clearing the query as it closes is `ExpandingSearch.collapse`'s rule, not a choice made here:
    /// a query left live behind a hidden field is a filter you cannot see or undo.
    ///
    /// Internal rather than private so `PaneHeaderSearchTests` can pin what dismissal DOES. What it
    /// cannot pin is that the two controls call it — measured: SwiftUI's `Button` is not an
    /// `NSControl` and `.onTapGesture` installs no `NSGestureRecognizer`, so neither is reachable
    /// from a test. That the ✕ is DRAWN at all is asserted in painted pixels instead, which is the
    /// half that actually regressed.
    func dismissSearch() {
        guard let searchText, let searchIsExpanded else { return }
        ExpandingSearch.collapse(text: searchText, isExpanded: searchIsExpanded)
    }

    /// How wide the revealed search field is allowed to get.
    ///
    /// A cap, not a size, and it exists for two reasons that happen to agree. A search field wider
    /// than this is harder to read a short query in, not easier — Finder and Mail cap theirs for the
    /// same reason. And the points it gives back are the pane bar's dead space, which is what makes
    /// "click somewhere else to stop searching" possible at all: greedy, the field WAS the bar, and
    /// there was nowhere else to click.
    ///
    /// Wide enough for the placeholder, which is the longest string the field ever shows — the
    /// counter only appears once a query has replaced it, so the two never compete for the room.
    static let searchFieldMaxWidth: CGFloat = 460

    /// The narrowest the field may be squeezed to. A floor, because the pane split clamps panes at
    /// 250pt and a field is useless below roughly this — you cannot see the query you are typing.
    /// At that width the dead zone disappears entirely, which is correct: there is no bar to spare,
    /// and the ✕ inside the field is then the only way out it needs.
    static let searchFieldMinWidth: CGFloat = 150

    /// Tree | Columns as a two-segment control, built from the same plain buttons as the window's
    /// tab picker: a `Picker(.segmented)` renders neutral inside macOS 26 glass chrome and ignores
    /// `.tint`, so the selected segment could never carry the app accent.
    private func viewModeSwitch(_ mode: Binding<PaneViewMode>, controlSize: ControlSize) -> some View {
        let pill = PaneNavMetrics.pill(controlSize)
        return HStack(spacing: PaneNavMetrics.segmentSpacing) {
            ForEach(PaneViewMode.allCases) { candidate in
                let isSelected = mode.wrappedValue == candidate
                Button {
                    mode.wrappedValue = candidate
                } label: {
                    Image(systemName: candidate.symbol)
                        .scaledFont(PaneNavMetrics.glyphFont(controlSize))
                        .foregroundStyle(isSelected
                                         ? AnyShapeStyle(glassHue.onAccentLabelColor)
                                         : AnyShapeStyle(Color.primary.opacity(0.75)))
                        .frame(width: pill.width - PaneNavMetrics.segmentInset, height: pill.height)
                        .background(isSelected ? AnyShapeStyle(glassHue.accentFillColor) : AnyShapeStyle(Color.clear),
                                    in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.hoverAffordance(isSelected ? .filled : .segment, tint: glassHue.accentFillColor))
                // These stand in for a Picker, so they restate the selected-state semantics it
                // would have given VoiceOver for free.
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .help(candidate.help)
            }
        }
        // **Horizontal only.** The ground stays — it is what makes two segments read as one
        // control, and Preview borrows its selected-segment fill — but its vertical padding made
        // this the one control on the bar taller than a pill (26pt against 20). Nothing showed it
        // while the 34pt provider capsule set the row height; a title hangs on a baseline below its
        // control, so it put "View" 6pt under every other word and took the row to 40pt against a
        // 34pt budget. Finder's toolbar is the precedent: its segmented controls are not taller
        // than its plain ones. Applied in both modes — see `PaneBarLayout.height(of:)`.
        .padding(.horizontal, PaneNavMetrics.segmentPadding)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pane view")
    }

    /// The ⋯ overflow. Holds **only what this rung folded away** — controls that are on your bar and
    /// that this pane is currently too narrow to draw. Absent entirely when it would be empty, which
    /// is the whole point of it: it is a symptom of the pane's width, and it disappears when the
    /// width stops being a problem.
    ///
    /// It used to also carry every available control the arrangement did not place, so that a
    /// removal "cost a pill and never an ability". That made one glyph stand for two unrelated
    /// things and, worse, handed straight back what the customize sheet had just been used to
    /// remove. `PaneBarLayout.plan` has the full reasoning and the cost.
    ///
    /// It carries only those controls. Customize used to ride along at the bottom, which meant
    /// a ⋯ with one folded item read as a two-entry menu whose second entry had nothing to do with
    /// the first, and the glyph earned its place in the row on the strength of a command that has
    /// its own front door — right-clicking the bar, which is where anyone who has customized
    /// Finder's toolbar aims first. `barContextMenu` is that door and is reachable from every pixel
    /// of the bar, so nothing is lost by leaving this menu to the controls it folded away.
    ///
    /// Dividers separate entries rather than trailing each one; `backForward` alone expands to two
    /// buttons, so the rule is one rule between groups, not one per button.
    private func viewOptionsMenu(controlSize: ControlSize, overflow: [PaneBarItem]) -> some View {
        Menu {
            ForEach(Array(overflow.enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider() }
                overflowEntry(item)
            }
        } label: {
            Image(systemName: "ellipsis")
                .paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
        }
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(navButtonStyle)
        .fixedSize()
        .help("More pane options")
    }

    /// One folded-or-removed control, as a menu item. Deliberately the same verbs as the pill: the
    /// menu is the same control wearing different clothes, not a second, subtly different one.
    @ViewBuilder
    private func overflowEntry(_ item: PaneBarItem) -> some View {
        switch item {
        case .viewMode:
            if let viewMode {
                Picker("View", selection: viewMode) {
                    ForEach(PaneViewMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            }
        case .collapse:
            if let onCollapse {
                Button(action: onCollapse) { Label("Collapse Pane", systemImage: "sidebar.left") }
            }
        case .backForward:
            Button(action: onBack) { Label("Back", systemImage: "chevron.left") }
                .disabled(!canGoBack)
            Button(action: onForward) { Label("Forward", systemImage: "chevron.right") }
                .disabled(!canGoForward)
        case .scan:
            // Unreachable: `PaneBarItem.pinned` is never folded and never absent. Handled rather
            // than defaulted so that adding a case to the enum fails the build here instead of
            // silently dropping the new control out of the menu.
            //
            // Unreachable is not the same as free to diverge, and this is the branch that would
            // diverge: it read `isRefreshing` directly and so still offered a DISABLED "Scan for
            // Changes" mid-scan — the dead control the rung above no longer has. If `pinned` ever
            // moves, that older behaviour would ship silently from here. One `ScanRungMode` for
            // both renderings means they cannot disagree about what this control is.
            if let onRefresh {
                let mode = ScanRungMode.resolve(isRefreshing: isRefreshing, canCancel: onCancelScan != nil)
                Button(action: { mode == .stop ? onCancelScan?() : onRefresh() }) {
                    Label(mode.label, systemImage: mode.symbol)
                }
                .disabled(!mode.isEnabled)
            }
        case .newFolder:
            if let onNewFolder {
                Button(action: onNewFolder) { Label("New Folder", systemImage: "folder.badge.plus") }
            }
        case .sort:
            Picker("Sort By", selection: $sortOption) {
                ForEach(SortOption.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.inline)
        case .hiddenFiles:
            Toggle(isOn: $showHiddenFiles) {
                Label("Show Hidden Files", systemImage: showHiddenFiles ? "eye" : "eye.slash")
            }
        case .preview:
            if showsPreviewToggle {
                Toggle(isOn: previewEnabled) {
                    Label("Show Preview", systemImage: previewSymbol)
                }
            }
        case .search:
            // Reached only when the magnifier is ON the bar and this rung folded it — ⋯ no longer
            // stands in for a bar that never carried it (`PaneBarMigration` puts it there instead).
            // ⌘F is the affordance's real front door and works whether or not the pill is drawn.
            if let searchIsExpanded {
                Button {
                    // Opens it and nothing else: the field claims focus itself, one Task hop after
                    // it appears, and a `FocusState` write made here would land in the transaction
                    // that inserts the field and be dropped.
                    withAnimation(ExpandingSearch.animation) { searchIsExpanded.wrappedValue = true }
                } label: {
                    Label("Find in This Pane…", systemImage: "magnifyingglass")
                }
            }
        case .delete:
            // Only when the rung folded it. A bar arranged before this control existed does not
            // carry it and is not offered it here — deliberately, see `PaneBarItem.delete`: the row
            // menu's Delete and ⌘⌫ reach the same act, so it can wait to be added on purpose.
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("Move Selection to Trash…", systemImage: "trash")
                }
                .disabled(selectionCount == 0)
            }
        case .space, .flexibleSpace:
            EmptyView()
        }
    }

    /// What the Delete rung says it will do.
    ///
    /// It states the confirmation out loud because this control does not honour
    /// "Confirm before deleting" — it always asks. Left unsaid, someone who switched that setting
    /// off would read the prompt as the setting being broken rather than as this button's own rule.
    /// Internal so a test can read the promise the button makes instead of restating it.
    var deleteHelp: String {
        guard selectionCount > 0 else {
            return "Move this pane's selected items to the Trash — select something first"
        }
        let subject = selectionCount == 1 ? "the selected item" : "\(selectionCount) selected items"
        return "Move \(subject) in this pane to the Trash — always asks first, "
            + "even with confirmations turned off"
    }

    /// Whether this header offers the preview toggle at all.
    ///
    /// A header with no view-mode switch (`viewMode == nil`) is on a surface with no Columns mode to
    /// be in, so there is nothing to preview and nothing to offer.
    private var showsPreviewToggle: Bool {
        guard let viewMode else { return false }
        return PaneViewMode.showsPreviewToggle(mode: viewMode.wrappedValue)
    }

    private var previewSymbol: String { "rectangle.righthalf.inset.filled" }

    /// The preview toggle: one pill that wears the accent while the preview is showing.
    ///
    /// Styled as the view switch's SELECTED segment rather than as a plain nav button, because that
    /// is this header's existing vocabulary for "this view option is on" — and unlike the
    /// hidden-files eye there is no honest second glyph for "no preview" to swap to. `HoverAffordanceStyle`
    /// stays the one hover path; only the resting fill differs by state.
    private func previewTogglePill(controlSize: ControlSize) -> some View {
        let pill = PaneNavMetrics.pill(controlSize)
        return Button {
            previewEnabled.wrappedValue.toggle()
        } label: {
            Image(systemName: previewSymbol)
                .scaledFont(PaneNavMetrics.glyphFont(controlSize))
                .foregroundStyle(previewEnabled.wrappedValue
                                 ? AnyShapeStyle(glassHue.onAccentLabelColor)
                                 : AnyShapeStyle(Color.primary.opacity(0.75)))
                .frame(width: pill.width - PaneNavMetrics.segmentInset, height: pill.height)
                .background(previewEnabled.wrappedValue ? AnyShapeStyle(glassHue.accentFillColor) : AnyShapeStyle(Color.clear),
                            in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.hoverAffordance(previewEnabled.wrappedValue ? .filled : .segment, tint: glassHue.accentFillColor))
        .shortcutKeycap(AppChord.previewColumn.display)
        .accessibilityAddTraits(previewEnabled.wrappedValue ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("Preview pane")
        .help(ShortcutHint.tooltip(previewEnabled.wrappedValue
                                   ? "The preview pane is showing — click to hide it"
                                   : "Show a preview of the selected file",
                                   AppChord.previewColumn.display))
    }

    /// Right-clicking the bar itself, which is where anyone who has customized Finder's toolbar will
    /// try first — and, since the ⋯ menu stopped carrying a Customize entry, the **only** way to
    /// open the sheet. That is why `theBarsMenuIsAimableAcrossTheWholeRow` right-clicks its way
    /// along the row rather than trusting the `.contentShape(Rectangle())` above: the controls sit
    /// on top of that shape, and one that swallowed the right-click would leave the sheet
    /// unreachable from a bar too full to have any bare stretch left to aim at.
    @ViewBuilder
    private func barContextMenu() -> some View {
        // Tabs first: they act on the pane, while everything below acts on the bar's own
        // appearance. No key equivalents — the chords are registered once, in the menu bar; a
        // `.keyboardShortcut` here would register a second pair, one per pane.
        if let onNewTab {
            Button("New Tab") { onNewTab() }
            if let onCloseTab {
                Button("Close Tab") { onCloseTab() }
            }
            Divider()
        }
        // Two modes, where Finder has three — see `PaneBarLabelMode` for why Text Only is absent.
        // Menu only, as in Finder: nothing in Settings.
        Picker("Show", selection: $labelModeRaw) {
            ForEach(PaneBarLabelMode.allCases, id: \.rawValue) { mode in
                Text(mode.displayName).tag(mode.rawValue)
            }
        }
        .pickerStyle(.inline)
        Picker("Icon Size", selection: $iconSizeRaw) {
            ForEach(PaneBarIconSize.allCases, id: \.rawValue) { size in
                Text(size.displayName).tag(size.rawValue)
            }
        }
        .pickerStyle(.inline)
        Divider()
        Button {
            isCustomizing = true
        } label: {
            Label("Customize Pane Bar…", systemImage: "gearshape")
        }
    }

    /// Shared by every nav control. `.filled` contributes the press scale and the hover phase
    /// `PaneNavChrome` reads, and paints no wash of its own — the capsule's fill is the wash.
    private var navButtonStyle: HoverAffordanceStyle {
        .hoverAffordance(.filled, tint: glassHue.accentColor, shape: .capsule)
    }
}

/// Sizing for the pane header's nav cluster.
///
/// Liquid Glass takes a button's size straight from its label, so six different SF Symbols gave
/// six different pill heights — 17.5 for the chevrons, 20 for `eye.slash`, 18.5 for the sort
/// arrows — and the sort menu came in at 14, visibly the runt of the row. Pinning one height on
/// every glyph levels all six at 20 (16 at `.mini`) without moving a single width; the menu needs
/// its height set outright, because `ButtonMenuStyle` pins its own and no label padding moves it.
///
/// All figures measured with `NSHostingView.fittingSize` and pinned by `PaneNavMetricsTests`.
enum PaneNavMetrics {
    /// The pill every nav control draws, per control size.
    ///
    /// Fixed, because nothing else worked. Liquid Glass sizes a button from its label, so six SF
    /// Symbols gave six pill heights and `ButtonMenuStyle` pinned the sort menu at 14 regardless.
    /// An outer `.frame(height:)` does NOT stretch a system-drawn pill — it only gives it a taller
    /// box to sit inside, which is why an earlier fix measured 20 and still rendered 14. Drawing
    /// the capsule ourselves is the only way the size is actually ours.
    static func pill(_ controlSize: ControlSize) -> CGSize {
        controlSize == .mini ? CGSize(width: 27, height: 17) : CGSize(width: 33, height: 20)
    }

    /// How far a *segment* — a view-switch half, the preview toggle — is drawn inside the plain
    /// pill's width, so that a two-segment control reads as one control rather than two pills.
    static let segmentInset: CGFloat = 4
    /// The hairline between the view switch's two segments.
    static let segmentSpacing: CGFloat = 3
    /// The capsule ground the view switch's segments sit on, per edge.
    static let segmentPadding: CGFloat = 3
    /// Back and Forward are one item and stay a pair's width apart, as they do in Finder.
    static let pairSpacing: CGFloat = 6
    /// Between two adjacent bar items. Placed by hand rather than by `HStack(spacing:)` — see
    /// `PaneHeader.barContent` for why a flexible space must cost nothing.
    ///
    /// **8 when the bar wears words, 6 when it is glyphs only — a function, because the caller
    /// knows which bar it is pricing and a single constant cannot.**
    ///
    /// Titles changed what this gap separates: an item's box is as wide as the wider of its pill
    /// and its word, so the *pills* still sit further apart than this (New Folder's box is a good
    /// 20pt wider than its pill, and that air is on both sides of it) while the *words* sit exactly
    /// this far apart and nothing else. At 6 the words of two neighbouring controls nearly abutted,
    /// which read as one long caption rather than two labels.
    ///
    /// **It was widened as a plain constant, and that regressed the untitled bar it was never
    /// about.** Every gap is paid at every rung, so an untitled rung grew 2pt per gap — 16pt on the
    /// default browse bar — and the ladder stepped down at a pane that much wider. At the 250pt
    /// split clamp the cost lands on the one element that has to survive there: the provider
    /// capsule, whose name is drawn by an AppKit menu label that **clips rather than ellipsises**.
    /// Looked at rather than computed — `paneHeaderNarrow250WithColumnsControls` went from a
    /// readable "M" at `v4.0` to a glyph sliced down the middle, while claiming "nothing clipped".
    /// `PaneNavMetrics`' own note already said not to buy width out of that pill.
    ///
    /// So Icon Only and the Large-text fallback price gaps exactly as they did at `v4.0`, and only
    /// the titled rung pays 8. `theUntitledLadderIsPricedAsItWasBeforeTitles` holds the untitled
    /// rungs of the default ladder; it does not separately build an Icon Only or a Large-text one,
    /// and does not need to — those differ only in having NO titled rung, so every rung of them
    /// takes the same `titled: false` branch the test already prices.
    ///
    /// **`pairSpacing` stays at 6**, which means that on an untitled bar it equals this gap: Back
    /// and Forward sit exactly as far apart as from everything else, and the pair reads as a pair
    /// only while the bar is titled. That is the same coincidence `v4.0` shipped, left alone here
    /// because narrowing it is a design change and this commit is a regression fix — but the note
    /// that used to sit here claimed the pairing held "in both", which was never true of the
    /// untitled bar and is worth not re-deriving.
    static func itemGap(titled: Bool) -> CGFloat { titled ? 8 : 6 }

    /// An explicit symbol size, so the glyphs stop each having their own intrinsic metrics.
    static func glyphFont(_ controlSize: ControlSize) -> ScaledFont {
        .system(size: controlSize == .mini ? 10 : 12, weight: .medium)
    }

    // `clusterWidth(_:)` used to live here: six pills plus five 6pt gaps, pinned at 226.5 / 188.5 to
    // match what the system chrome took before the bar drew its own. It went with the bar's fixed
    // shape — a bar whose length is now whatever someone arranged has no single width to pin, and a
    // constant that says "six controls" is a false description rather than a loose one.
    //
    // Nothing regressed by removing it. It was never read outside its own two tests, and both of the
    // properties it stood in for are asserted more directly elsewhere: the pill's painted size by
    // `PaneNavMetricsTests.glyphPillsAreIdentical`, and which rung a 250pt pane actually picks by the
    // narrow snapshots in `DashboardSnapshotTests` — which caught two real geometry shifts while this
    // change was being written, so they are known to be sensitive rather than merely present.
    //
    // The tuning note it carried is still worth keeping: do not shrink the pill to buy width. The
    // header's degradation ladder is not monotonic in it. 25pt collapsed the provider capsule to
    // "..." — worse than the 27pt this settles on — and 33 vs 36 at `.small` changed nothing at all,
    // because a 250pt pane is already on the `.mini` rung.
}

/// The chrome for one pane-header nav control: a fixed capsule the app draws itself.
///
/// These used to wear `chromeButtonStyle`, i.e. the system `.glass` style, and three rounds of
/// hover fixes failed against it — an outer `.foregroundStyle` loses to the style's own label
/// colour, an outer `.frame` doesn't resize the pill, and any filter or offscreen pass over glass
/// renders nothing at all. The freshness badge that used to sit beside these gave up on glass for
/// the same family of reason (an accent tint over an accent wash has nothing to shift against).
/// This follows it: the app owns the fill, so the app can guarantee both the size and the hover.
struct PaneNavChrome: ViewModifier {
    let accent: Color
    let controlSize: ControlSize
    /// Overrides the glyph colour while the rung is ENABLED. `nil` — every rung but Delete — keeps
    /// the chrome ink below.
    ///
    /// It has to be a parameter rather than a `.foregroundStyle` on the button, and that is worth
    /// stating because the obvious version is silently inert: this modifier applies its own
    /// `.foregroundStyle(glyph)` directly to the glyph, and the application closest to the leaf is
    /// the one that wins, so a colour set further out never arrives. Measured, not deduced — the
    /// first draft of Delete's red tint painted zero red pixels.
    ///
    /// Deliberately NOT routed through `ChromeInk.label`: that returns full-strength white in dark,
    /// which is right for chrome whose job is legibility and wrong for a colour whose job is to say
    /// "this one is destructive" in both appearances.
    var ink: Color? = nil

    @Environment(\.hoverAffordancePhase) private var phase
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let pill = PaneNavMetrics.pill(controlSize)
        return content
            .scaledFont(PaneNavMetrics.glyphFont(controlSize))
            .foregroundStyle(glyph)
            .frame(width: pill.width, height: pill.height)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
    }

    /// Disabled reads as a flatter, quieter pill and never responds — `canGoBack` is false at the
    /// top of a tree, and a Back arrow that lights up there would promise a click that does nothing.
    private var fill: Color {
        guard isEnabled else { return .primary.opacity(0.035) }
        switch phase {
        case .rest: return .primary.opacity(0.075)
        case .hover: return accent.opacity(0.22)
        case .pressed: return accent.opacity(0.34)
        }
    }

    /// Disabled stays quiet in both appearances — `canGoBack` is false at the top of a tree, and a
    /// Back arrow that reads live there promises a click that does nothing.
    ///
    /// Enabled, dark is full-strength white via `ChromeInk`: on the hue-washed surface this app
    /// actually renders, the 0.75 rest ink measures ~3.4:1 and the engaged accent glyph sits on an
    /// accent wash with nothing to shift against. The pill's `fill` still carries the hover in both
    /// appearances, so dropping the glyph's tint costs the affordance nothing.
    private var glyph: Color {
        guard isEnabled else { return .primary.opacity(0.25) }
        // A supplied ink outranks the engagement tint too: a trash that turned accent-blue under
        // the cursor would drop its one distinguishing cue at the exact moment of the click.
        if let ink { return ink }
        return ChromeInk.label(colorScheme, light: phase.isEngaged ? accent : .primary.opacity(0.75))
    }
}

extension View {
    /// See `PaneNavChrome`. Pair with `.buttonStyle(.hoverAffordance(.filled, …))`, which supplies
    /// the phase this reads plus the press scale, and deliberately no wash of its own — the fill
    /// here is the wash.
    func paneNavChrome(accent: Color, controlSize: ControlSize, ink: Color? = nil) -> some View {
        modifier(PaneNavChrome(accent: accent, controlSize: controlSize, ink: ink))
    }
}


// MARK: - Search submit modifiers

private struct PaneSearchSubmitModifiersKey: EnvironmentKey {
    /// `nil` is "ask the keyboard", which is what the search field's submit handler does
    /// unconditionally in the app. Nothing that does not deliberately pin a value changes at all.
    static let defaultValue: NSEvent.ModifierFlags? = nil
}

extension EnvironmentValues {
    /// The modifiers `PaneHeader`'s search field reads when its query is submitted, or `nil` to read
    /// the live keyboard.
    ///
    /// ↩ walks to the next hit and ⇧↩ to the previous, and BOTH arrive as `onSubmit`: a single-line
    /// `TextField` submits on Return whether or not Shift is held, and it consumes the key before an
    /// ancestor's `.onKeyPress(.return)` can see it. So the direction has to come from the modifier
    /// state at the moment of submission.
    ///
    /// `NSEvent.modifierFlags` is the right answer for a real keystroke — the submit runs inside
    /// AppKit's own key handling, so the flags are the ones the user is holding — and an unwinnable
    /// one for a test, which submits with no event and then reads whatever key the person at the Mac
    /// happens to be leaning on. That is not a hypothetical: `paneClickModifiers` exists because a
    /// full-suite run held that window open for minutes and a stray ⇧ turned a passing test into the
    /// exact signature of the defect it was written to catch.
    ///
    /// Pinning `[]` makes "this is a plain Return" part of the test rather than of the room; pinning
    /// `.shift` is how the reverse walk is asserted at all.
    public var paneSearchSubmitModifiers: NSEvent.ModifierFlags? {
        get { self[PaneSearchSubmitModifiersKey.self] }
        set { self[PaneSearchSubmitModifiersKey.self] = newValue }
    }
}
