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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    /// Drives both panes to a path: ⌥-click, or any click while the panes are linked. Nil when the
    /// workspace has no second pane (every workspace but Compare): the crumbs then navigate this
    /// pane only, and their tooltips stop offering to bring a pane that isn't there.
    public let onNavigateBoth: ((String) -> Void)?
    /// The enabled providers this pane can switch between, offered as a dropdown. Empty hides the
    /// dropdown affordance.
    public let providers: [CloudProvider]
    /// Switches this pane to the chosen provider id.
    public let onSelectProvider: (String) -> Void
    /// Opens Settings ▸ Sources (the manage-sources menu item).
    public let onManageProviders: () -> Void
    /// Picks a folder and points this pane at it as a source. nil hides "Choose Folder…".
    public let onChooseFolder: (() -> Void)?
    /// The (global) sort order, offered per pane.
    @Binding public var sortOption: SortOption
    /// A new tab on this pane's folder, and closing its active one: the header card's own
    /// right-click route to the tab strip.
    ///
    /// The bar itself doesn't change: no new glyph, no new `PaneBarItem`, nothing in the customize
    /// sheet. Right-clicking the card is where a Mac user reaches for "act on this pane", and it is
    /// the only tab route that works with no folder under the pointer and no strip on screen.
    ///
    /// Optional so other hosts (the tests, any surface with no tabs behind it) get no items rather
    /// than a door onto a no-op.
    public let onNewTab: (() -> Void)?
    /// `nil` at one tab: what is left to close then is the window, and an item reading "Close Tab"
    /// that closes the window is a trap.
    public let onCloseTab: (() -> Void)?
    /// When set, shows a collapse button in the nav cluster, so the single-source rail can collapse
    /// itself back to the spine directly. nil on the comparison panes, which don't collapse
    /// individually.
    public let onCollapse: (() -> Void)?
    /// Triggers a scan/refresh from the pane's nav cluster. nil hides it.
    public let onRefresh: (() -> Void)?
    /// Spins the refresh glyph while a scan is running.
    public let isRefreshing: Bool
    /// Stops the running scan. When present, the scan rung becomes a Stop button while
    /// `isRefreshing` holds, instead of a disabled spinner: the control that started the scan is
    /// where a user looks to stop it. `nil`, which every caller outside the app passes, keeps the
    /// rung disabled while running.
    public let onCancelScan: (() -> Void)?
    /// Whether hidden files are shown. A per-pane control for the (global) setting, so it lives
    /// right next to each pane's navigation buttons.
    @Binding public var showHiddenFiles: Bool
    /// This pane's presentation. `nil` hides the switch entirely: the single-source rail has no
    /// Columns mode, so it gets no control for one.
    public var viewMode: Binding<PaneViewMode>?
    /// Creates a folder in the pane's current folder; in Columns, the deepest open column. `nil`
    /// hides it.
    public let onNewFolder: (() -> Void)?
    /// Trashes this pane's selection. `nil`, which every caller outside the app passes, hides the
    /// control and leaves the bar, the ladder and the snapshots unchanged.
    ///
    /// This pane's, not the active pane's: Compare's floating action bar can follow the active side
    /// because it shows on one side at a time, but a header control is visible on both sides at
    /// once, so following `activePane` would give two identical buttons two meanings.
    public let onDelete: (() -> Void)?
    /// How many items THIS pane has selected, so the button can be disabled with none and say how
    /// many it would take with some.
    ///
    /// A count rather than a Bool because the tooltip needs the number.
    public let selectionCount: Int

    // MARK: Search inside this pane's tree
    //
    // All four arrive together or not at all. `nil` is a header with no search, which every caller
    // outside the app passes; `availableItems` (and so the bar, the ladder and the snapshots) then
    // stay unchanged.

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
    /// The Filter button's state and counts. `nil` is a header with no Filter button (every caller
    /// outside the app), so `availableItems`, the ladder and the snapshots stay unchanged.
    public var typeFilter: PaneTypeFilterControl?
    @State private var typeFilterShown = false
    /// The breadcrumb falls back to its compact form when the whole trail doesn't fit, as in Edit's
    /// one-column pane. See `PaneBreadcrumb.compactsWhenNarrow`.
    public var compactsBreadcrumbWhenNarrow: Bool
    // No surface style here: the header's shape comes from its container, its material from the
    // glass level. This view only paints the tint and never reads the level: the source chip
    // carries a flat brand wash, not a glass pill, so nothing here needs a ground floored at Clear.
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    /// The bar's arrangement and icon size. App-wide keys, not per pane: both Compare panes and the
    /// single-source rail share one arrangement, so the two panes stay the same instrument pointed
    /// at two providers. Customizing from either pane moves both, live while the sheet is open.
    @AppStorage(PaneBar.arrangementKey) private var arrangementRaw: String =
        PaneBarArrangement.default.encoded
    @AppStorage(PaneBar.iconSizeKey) private var iconSizeRaw: String = PaneBarIconSize.regular.rawValue
    /// Defaults to `iconAndText`: the words are the feature, and a preference that ships off is one
    /// nobody finds. A pane too narrow for the titled rung sheds the words on its own, and so do the
    /// largest text sizes; see `PaneBarTitleMetrics.rowFits` and `rowBudget` beside it.
    @AppStorage(PaneBar.labelModeKey) private var labelModeRaw: String =
        PaneBarLabelMode.iconAndText.rawValue
    /// Whether this header is showing the customize sheet. Per-header on purpose: the sheet edits
    /// shared state, but only the pane you invoked it from should sprout a sheet.
    @State private var isCustomizing = false
    /// The modifiers a search submission is read as carrying, or `nil` (the shipped default) to ask
    /// the keyboard. See `paneSearchSubmitModifiers`.
    @Environment(\.paneSearchSubmitModifiers) private var pinnedSubmitModifiers
    /// Only the dark appearance drops the provider name's brand tint; see `ChromeInk`.
    @Environment(\.colorScheme) private var colorScheme
    private var glassHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: glassHueRaw) ?? .blue
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
        onNavigateBoth: ((String) -> Void)?,
        providers: [CloudProvider] = [],
        onSelectProvider: @escaping (String) -> Void = { _ in },
        onManageProviders: @escaping () -> Void = {},
        onChooseFolder: (() -> Void)? = nil,
        sortOption: Binding<SortOption>,
        onNewTab: (() -> Void)? = nil,
        onCloseTab: (() -> Void)? = nil,
        compactsBreadcrumbWhenNarrow: Bool = false,
        onCollapse: (() -> Void)? = nil,
        onRefresh: (() -> Void)? = nil,
        isRefreshing: Bool = false,
        onCancelScan: (() -> Void)? = nil,
        showHiddenFiles: Binding<Bool>,
        viewMode: Binding<PaneViewMode>? = nil,
        onNewFolder: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        selectionCount: Int = 0,
        searchText: Binding<String>? = nil,
        searchIsExpanded: Binding<Bool>? = nil,
        searchSummary: String? = nil,
        searchMatchCount: Int = 0,
        onSearchAdvance: ((Bool) -> Void)? = nil,
        personOffer: ((String) -> Person?)? = nil,
        onAcceptPerson: ((Person) -> Void)? = nil,
        typeFilter: PaneTypeFilterControl? = nil
    ) {
        self.typeFilter = typeFilter
        self.compactsBreadcrumbWhenNarrow = compactsBreadcrumbWhenNarrow
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
        self._showHiddenFiles = showHiddenFiles
        self.viewMode = viewMode
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
        // 10, not 8, between the bar and the breadcrumb: at 8 the callout-sized breadcrumb and the
        // bar read as one crowded block. Paid for out of the measured slack `PaneBreadcrumb.body`
        // documents.
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                if provider != nil {
                    // Nothing: the breadcrumb's first crumb already names the source and carries
                    // its picker (`PaneBreadcrumb.SourcePicker`), so the whole row is the bar's.
                    //
                    // The `else` below is not the same thing: a pane whose provider was disabled or
                    // has not loaded has no crumb worth reading, so it keeps its own title and the
                    // degradation ladder that makes it fit.
                    EmptyView()
                } else {
                    // The sparse state (a pane whose provider was disabled or has not loaded) gets
                    // a degradation ladder: the glyph yields first, and the name is the identity
                    // anchor and only truncates. Truncation alone can't fit a narrow pane (icon,
                    // spacings and the bar's minimum exceed it), so the icon must be sheddable too.
                    // `PaneBarLadderTests.theHeaderWithNoProviderStillFitsItsPane` pins it.
                    //
                    // `.layoutPriority(2)` is load-bearing. Without it this content takes its ideal
                    // width in the same pass as the greedy bar, and the bar, offered less than its
                    // minimum, overflows silently. The priority makes the row offer this side
                    // `available - the bar's minimum`, which the ladder then steps down through.
                    ViewThatFits(in: .horizontal) {
                        sparseTitle(showsIcon: true)
                        sparseTitle(showsIcon: false)
                    }
                    .layoutPriority(2)
                }
                // No `Spacer` here: the trailing push lives in the arrangement as
                // `PaneBarItem.flexibleSpace`, which the default carries at its head, so a
                // customized bar can pack left. `.leading`, so a bar with no flexible space hugs
                // the pane's leading edge; with one, its greedy `Spacer` fills the width.
                //
                // The search field takes the bar's track while it is open, and the bar comes back
                // when it closes. This row, not a new one: the header is pinned to
                // `LiquidGlass.headerHeight` and holds two rows inside it, the bar (up to 34pt) and
                // the breadcrumb (~20pt). The ~33pt field fits this row and would burst the
                // breadcrumb's, pushing the header off the height `PaneHeaderHeightTests` pins. It
                // also gets the pane's full width.
                //
                // The breadcrumb stays: while searching, where you are is still worth reading,
                // since the hit is about to move you away from it.
                if let searchText, let searchIsExpanded, searchIsExpanded.wrappedValue {
                    HStack(spacing: 0) {
                        searchField(text: searchText, isExpanded: searchIsExpanded)
                            // The floor is load-bearing: `Color.clear` below is greedy too, so the
                            // row splits between them, and with only the cap the field would be a
                            // few points wide in a 250pt pane, the narrowest the split allows.
                            .frame(minWidth: Self.searchFieldMinWidth,
                                   maxWidth: Self.searchFieldMaxWidth)
                        // The way out that isn't a control: the field is capped rather than greedy
                        // so there is a stretch of bar to click when you are done. With an empty
                        // query the field has no clear button, so without this a pane whose focus
                        // moved to the file list would offer nothing to click. Like clicking
                        // outside a popover.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { dismissSearch() }
                            .accessibilityHidden(true)
                    }
                    .padding(.leading, barLeadingInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                } else {
                    navCluster
                        .padding(.leading, barLeadingInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // An `HStack` claims no hit area of its own, so without this right-clicking the bar
            // would work only on a pill, not on the empty stretch that is most of the bar.
            .contentShape(Rectangle())
            .contextMenu { barContextMenu() }
            .sheet(isPresented: $isCustomizing) {
                PaneBarCustomizeSheet(availableHere: Set(availableItems))
                    .presentedNativeControlAccent()
            }
            PaneBreadcrumb(
                rootPath: rootPath,
                providerName: provider?.displayName,
                providerIsLocalFolder: provider?.isLocalFolder ?? false,
                sourcePicker: provider.map {
                    PaneBreadcrumb.SourcePicker(
                        imageName: $0.imageName,
                        currentId: $0.id,
                        providers: providers,
                        onSelect: onSelectProvider,
                        onManage: onManageProviders,
                        onChooseFolder: onChooseFolder
                    )
                },
                relativePath: relativePath,
                showHidden: showHiddenFiles,
                onNavigate: onNavigate,
                onNavigateBoth: onNavigateBoth,
                compactsWhenNarrow: compactsBreadcrumbWhenNarrow
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        // Pinned, not intrinsic: this header and the lens workspaces' `LensHeaderCard` both read
        // `headerHeight`, so the pane's header/list boundary and the card's bottom edge land on the
        // same line (83.5 = cardInset + headerHeight). The intrinsic height varies with the rung
        // and with the provider, worst when panes are narrow.
        .frame(height: LiquidGlass.headerHeight)
        .contentSurface(hue: glassHue, tint: surfaceTint)
    }

    /// The gap between whatever sits at the row's leading edge and the bar.
    ///
    /// Nothing sits left of the bar in the ordinary case, and the bar shares a leading edge with
    /// the breadcrumb below. The sparse header has a title on that side, so it keeps a 12pt gap.
    private var barLeadingInset: CGFloat { provider == nil ? 12 : 0 }

    /// The no-provider header's leading content: a folder glyph and the pane's title.
    ///
    /// Two rungs: `showsIcon` false is what a 250pt pane gets, where the icon and its 12pt gap
    /// decide between fitting and running the bar off the trailing edge. The title has a line limit
    /// so it truncates: a wrapping `Text` reports its longest word as its minimum width and can't
    /// compress.
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

    /// The ladder this header actually builds, from its own preferences and its own item list.
    ///
    /// Internal, and the single source: `PaneBarLadderTests` measures the drawn bar against this
    /// rather than re-assembling one from `.default` and the ceiling, which could stay green
    /// against a ladder the header no longer builds (a different label mode, say).
    var barLadder: PaneBarLadder {
        PaneBarLadder(arrangement: PaneBarArrangement(encoded: arrangementRaw),
                      available: availableItems,
                      ceiling: iconSize.ceiling,
                      labelMode: labelMode,
                      scale: appFontScale)
    }

    /// The height of the tallest rung this ladder can draw — the row's reservation.
    ///
    /// Taken across every rung rather than assumed to be rung 0: the ladder is deliberately not
    /// monotonic (see `PaneBarLadder`), so "the widest is the tallest" can break with a label mode
    /// or an icon size.
    private func tallestRungHeight(_ ladder: PaneBarLadder) -> CGFloat {
        (0...ladder.terminal).map { ladder.height(forRung: $0) }.max() ?? ladder.height(forRung: 0)
    }

    /// This pane's bar, the track running the full width of the pane, at the widest rung the
    /// offered width fits. One path, for the header with a source and the header without.
    ///
    /// Laddered so that at the narrowest widths (the split clamps panes at 250pt, where small
    /// controls at full count exceed the row) the bar steps down to `.mini` controls and then sheds
    /// pills into ⋯ instead of overflowing the trailing edge: every control stays reachable.
    ///
    /// The rung is computed, not searched: a `ViewThatFits` over every rung builds each full bar to
    /// measure it, for both panes on every `ContentView` body evaluation, and that dominated the
    /// main thread. `PaneBarLadder` does it with arithmetic; see it for why the ladder is not
    /// monotonic and must be walked in order. The `GeometryReader` reads the width the bar is
    /// actually offered, after the higher-`layoutPriority` sparse title takes its share.
    private var navCluster: some View {
        let ladder = barLadder
        return GeometryReader { proxy in
            let rung = ladder.rung(fitting: proxy.size.width)
            // `.topLeading`, stated: a bar carrying a flexible space fills the width either way,
            // but one packed hard left doesn't, and would drift to the middle.
            hedged(rung, ladder)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        // A `GeometryReader` is greedy in both axes and reports nothing about its content, so two
        // things are restated: the narrowest rung's width, which the row reserves for the bar, and
        // a pinned height, or the row would stretch.
        //
        // The height is the tallest rung's, not the narrowest's: the bar is alone on this row, and
        // a taller rung in a shorter box would escape upward and unbalance the card. A `.mini` bar
        // then sits at the top of a taller reservation (`.topLeading`, above), using air the card
        // has spare. `theHeaderIsBalancedTopToBottom` measures the result.
        .frame(minWidth: ladder.width(forRung: ladder.terminal),
               minHeight: tallestRungHeight(ladder),
               maxHeight: tallestRungHeight(ladder))
    }

    /// The computed rung, with the narrowest rung behind it as the layout engine's veto.
    ///
    /// The fallback is the narrowest rung, not the next one down: if the arithmetic ever
    /// overestimates what fits, the bar drops all the way to compact. A bar that over-compacts is
    /// visibly wrong with every control still in ⋯, while one that overflows the pane has no
    /// symptom at all. `{rung, rung + 1, terminal}` would build a third bar on every layout pass;
    /// `PaneBarLadderTests` checks the arithmetic against the drawn bar instead.
    ///
    /// Branched rather than always emitting both: at the narrowest widths the computed rung is the
    /// terminal one, and two identical children would build the bar twice. The branch sits outside
    /// the `ViewThatFits` on purpose: an `if` inside its `ViewBuilder` is one `_ConditionalContent`
    /// child, not two, and the ladder would collapse.
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
    /// The icon-size preference is a ceiling: choosing Small starts at rung 1's size, but the
    /// shedding rungs still apply, because a bar that overflows the pane is worse than small glyphs.
    /// The terminal rung sheds everything sheddable, so an arrangement of any length still has a
    /// variant that fits rather than falling off the end.
    ///
    /// Internal rather than private, like `availableItems`: `PaneBarLadderTests` lays this out at
    /// each rung and compares it with the arithmetic, which is only honest against the view's own
    /// variant, not a restatement of it.
    func barVariant(_ rung: Int, _ ladder: PaneBarLadder) -> some View {
        barContent(ladder.controlSize(forRung: rung),
                   depth: ladder.depth(forRung: rung),
                   arrangement: ladder.arrangement,
                   available: ladder.available,
                   titled: ladder.isTitled(forRung: rung))
    }

    /// Which items this particular header can offer at all. A header with no view-mode binding has
    /// no View control to place.
    ///
    /// Internal rather than private so `PaneBarLadderTests` can build its ladder from the same list
    /// the view does; a hand-restated list could keep passing after this one changes.
    var availableItems: [PaneBarItem] {
        var available: [PaneBarItem] = [.backForward, .sort, .hiddenFiles]
        if viewMode != nil { available.append(.viewMode) }
        if onCollapse != nil { available.append(.collapse) }
        if onRefresh != nil { available.append(.scan) }
        if onNewFolder != nil { available.append(.newFolder) }
        // A header with no delete handler has nothing to trash, so it offers no trash, which keeps
        // `PaneHeaderHeightTests` and the 250pt snapshots measuring the bar they were written for.
        if onDelete != nil { available.append(.delete) }
        // No search bindings, no field to reveal, so no magnifier; the same reasoning for the
        // header tests, snapshots and ladder measurements.
        if searchText != nil, searchIsExpanded != nil { available.append(.search) }
        // Same gate, same reason: no control value, no Filter button.
        if typeFilter != nil { available.append(.typeFilter) }
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
        // cost nothing: as a stack child it would earn a 6pt gap of its own, widening the minimum of
        // every bar that carries one, which is every default bar.
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
                    // Hidden from VoiceOver: the pill carries the control's own label and hint, and
                    // this word repeats it, so both would read every item twice ("Scan, button.
                    // Scan."). `children: .contain` below keeps children as separate elements, so
                    // it doesn't prevent that; only hiding the duplicate does.
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
    /// The order comes from the arrangement, not from this function's shape.
    @ViewBuilder
    private func barItem(_ item: PaneBarItem, controlSize: ControlSize, compactViewMode: Bool) -> some View {
        switch item {
        case .flexibleSpace:
            // The push toward the trailing edge, as an item so it can sit anywhere, or nowhere,
            // which is how a bar packs left.
            Spacer(minLength: 0)

        case .space:
            Color.clear.frame(width: PaneNavMetrics.pill(controlSize).width, height: 1)

        case .viewMode:
            if let viewMode {
                if compactViewMode {
                    // One pill showing the current mode, the alternatives in its menu: the deepest
                    // rung's economy, two pills' worth in one pill's width.
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
                    .paneNavGlass()
                    .fixedSize()
                // `.help` is the accessibility help on macOS, never the name: an icon-only button
                // with only a tooltip has no accessible name at all.
                    .help("Choose how this pane shows its files")
                    .accessibilityLabel("View mode")
                } else {
                    viewModeSwitch(viewMode, controlSize: controlSize)
                }
            }

        case .collapse:
            if let onCollapse {
                Button(action: onCollapse) {
                    Image(systemName: PaneBarItem.collapseSymbol).paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
                }
                .buttonStyle(navButtonStyle)
                .paneNavGlass()
                .help("Collapse the source pane")
                .accessibilityLabel("Collapse the source pane")
            }

        case .backForward:
            // One arrangement item, two pills: they move and fold together, as in Finder. The
            // stack restates the 6pt the bar's outer spacing doesn't supply.
            //
            // Known trade, as with the ⌘F badge below: both panes' rungs wear the chord during the
            // ⌥ reveal, but the chord acts on the focused pane. Focus-gating would need pane
            // identity in this shared header and would flicker keycaps mid-reveal; the button
            // itself always acts on its own pane, so the click the badge decorates is never wrong.
            HStack(spacing: PaneNavMetrics.pairSpacing) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
                }
                .buttonStyle(navButtonStyle)
                .paneNavGlass()
                .shortcutKeycap(AppChord.paneBack.display)
                .disabled(!canGoBack)
                .help(ShortcutHint.tooltip("Go back to this pane’s previous folder", AppChord.paneBack.display))
                .accessibilityLabel("Back")

                Button(action: onForward) {
                    Image(systemName: "chevron.right").paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
                }
                .buttonStyle(navButtonStyle)
                .paneNavGlass()
                .shortcutKeycap(AppChord.paneForward.display)
                .disabled(!canGoForward)
                .help(ShortcutHint.tooltip("Go forward to this pane’s next folder", AppChord.paneForward.display))
                .accessibilityLabel("Forward")
            }
            // Frosted and Clear: Back and Forward share one glass capsule, as Finder's do.
            .chromeGlassGroup()

        case .scan:
            // The pane's one scan control at every point in its lifecycle (freshness lives on the
            // differences count pill, which is a toggle). That is why `PaneBarItem.pinned` refuses
            // to remove or fold it: a gate here would mean a pane that can never be scanned.
            if let onRefresh {
                // Mid-scan this rung becomes Stop, when the host supplied one: the scan it would
                // start is already running, so Stop takes chrome that would be disabled anyway. The
                // rung keeps its position and size, so nothing after it moves on the swap.
                //
                // The spinning arrow goes with it: the count pill's "scanning…" and both panes'
                // loading state still say something is happening, and only this says you can stop.
                //
                // Everything that differs between the two states comes from one resolved
                // `ScanRungMode`, so a glyph saying Stop beside a badge offering ⌘R can't happen.
                let mode = ScanRungMode.resolve(isRefreshing: isRefreshing, canCancel: onCancelScan != nil)
                Button(action: { mode == .stop ? onCancelScan?() : onRefresh() }) {
                    Image(systemName: mode.symbol)
                        .symbolEffect(.rotate, options: .repeating, isActive: mode.spins)
                        .paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
                }
                .buttonStyle(navButtonStyle)
                .paneNavGlass()
                .shortcutKeycap(mode.keycap)
                .disabled(!mode.isEnabled)
                .help(mode.help)
                .accessibilityLabel(mode.label)
            }

        case .newFolder:
            // New Folder. In Columns its target is unambiguous (the deepest open column), which is
            // why it earns a place in the chrome and not only the right-click menu.
            if let onNewFolder {
                Button(action: onNewFolder) {
                    Image(systemName: "folder.badge.plus")
                        .paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
                }
                .buttonStyle(navButtonStyle)
                .paneNavGlass()
                .shortcutKeycap(AppChord.newFolder.display)
                .lockedDuringRun()
                .help(ShortcutHint.tooltip("New folder in this pane’s current folder", AppChord.newFolder.display))
                .accessibilityLabel("New folder")
            }

        case .sort:
            // Sort, per pane, driving the shared sort order.
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
            // The one combination that leaves the label alone: `.button` makes the menu render as a
            // button, and `.plain` inside `navButtonStyle` stops that button drawing chrome over
            // the label's own capsule, so it paints like a plain Button.
            //
            // A `Menu` doesn't inherit a `buttonStyle` from an ancestor, so it is restated here.
            .menuStyle(.button)
            .buttonStyle(navButtonStyle)
            .paneNavGlass()
            .fixedSize()
            .help("Choose how items are sorted")
            .accessibilityLabel("Sort")

        case .hiddenFiles:
            // Hidden-files toggle, icon-only. The eye mirrors the state: open when hidden files are
            // shown, slashed when filtered.
            Button {
                showHiddenFiles.toggle()
            } label: {
                Image(systemName: showHiddenFiles ? "eye" : "eye.slash").paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
            }
            .buttonStyle(navButtonStyle)
            .paneNavGlass()
            .shortcutKeycap(AppChord.hiddenFiles.display)
            .help(ShortcutHint.tooltip(showHiddenFiles
                                       ? "Hidden files are visible — click to hide them"
                                       : "Hidden files are hidden — click to show them",
                                       AppChord.hiddenFiles.display))
            // Its state rides in a glyph swap (eye against eye.slash), so VoiceOver needs a value
            // as well as a label, the shape `ContentView+SplitLayout`'s link toggle uses.
            .accessibilityLabel("Hidden files")
            .accessibilityValue(showHiddenFiles ? "Shown" : "Hidden")

        case .delete:
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        // The one glyph on this bar with a colour of its own: every other rung is
                        // reversible or changes nothing, and this one moves files. Disabled, it
                        // greys out with the rest, so the red appears only with something to act
                        // on.
                        .paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize,
                                       ink: ChromeInk.semantic(colorScheme, SemanticColor.error))
                }
                .buttonStyle(navButtonStyle)
                .paneNavGlass()
                .disabled(selectionCount == 0)
                .lockedDuringRun()
                // Deliberately not `AppChord.deleteSelection`: ⌘⌫ is Compare-only and acts on the
                // active pane, so the badge would promise something false on the inactive side and
                // everywhere in Browse and Organize.
                .help(deleteHelp)
                .accessibilityLabel(deleteHelp)
            }

        case .search:
            // A plain nav pill, not Design's `ExpandingSearchToggle`, which suits a lens header's
            // row of bare glyphs; among `paneNavChrome` pills it would be the one control that
            // doesn't line up. The toggle is one Bool, restated below; the field, where the real
            // mechanism lives (deferred focus on an animated reveal, Escape, clear), is
            // `ExpandingSearchField`.
            if let searchText, let searchIsExpanded {
                Button {
                    withDesignAnimation(ExpandingSearch.animation, reduceMotion: reduceMotion) {
                        searchIsExpanded.wrappedValue.toggle()
                        if !searchIsExpanded.wrappedValue { searchText.wrappedValue = "" }
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        // No live-query tint, on purpose: the state it would signal can't happen.
                        // This magnifier is drawn only while the field is collapsed, and every
                        // path that collapses the field clears the query with it
                        // (`ExpandingSearch.collapse`, and this button's toggle), so a live query
                        // always has a visible field holding it. `PaneBarSearchTintTests` pins that
                        // invariant, so a query that outlives its field fails there.
                        .paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize)
                }
                .buttonStyle(navButtonStyle)
                .paneNavGlass()
                // Centred, not trailing: a ⌘F keycap is nearly as wide as this button, and an
                // overhang would foul the glyphs either side. Covering the magnifier during an ⌥
                // hold is fine: the badge is the answer the hold asked for.
                .shortcutKeycap(AppChord.findInPane.display)
                .help(ShortcutHint.tooltip("Find a file or folder in this pane", AppChord.findInPane.display))
                .accessibilityLabel("Search this pane")
            }

        case .typeFilter:
            if let typeFilter {
                typeFilterPill(typeFilter, controlSize: controlSize)
            }
        }
    }

    /// The Filter button: a pill that opens the type list. The glyph fills and takes the accent
    /// while a filter is on, so the state rides in the glyph the way Hidden's eye does, and the
    /// tooltip and VoiceOver value say what it shows.
    @ViewBuilder
    private func typeFilterPill(_ control: PaneTypeFilterControl, controlSize: ControlSize) -> some View {
        Button {
            typeFilterShown.toggle()
        } label: {
            Image(systemName: control.isOn ? PaneBarItem.typeFilterSymbol + ".fill" : PaneBarItem.typeFilterSymbol)
                .paneNavChrome(accent: glassHue.accentColor, controlSize: controlSize,
                               ink: control.isOn ? glassHue.accentColor : nil)
        }
        .buttonStyle(navButtonStyle)
        .paneNavGlass()
        .popover(isPresented: $typeFilterShown, arrowEdge: .bottom) {
            PaneTypeFilterPopover(control: control)
                .presentedNativeControlAccent()
        }
        .help(control.help)
        .accessibilityLabel("Filter by type")
        .accessibilityValue(control.accessibilityValue)
    }

    /// The revealed field: Design's shared `ExpandingSearchField`, with Compare's own “N of M” in
    /// its trailing slot.
    ///
    /// Nothing about focus is restated here, deliberately: the field claims focus itself, one Task
    /// hop after it appears. Inline that into whatever reveals it and the field opens dead, needing
    /// a click before typing. That mechanism is why this is the shared field, not a `TextField`.
    ///
    /// ↩ and ⇧↩ both arrive as `onSubmit`: a single-line `TextField` submits on Return with or
    /// without Shift, before an ancestor's `.onKeyPress(.return)` sees it. So the direction is read
    /// from the modifiers at submission, through an injectable seam, since `NSEvent.modifierFlags`
    /// is the real keyboard's state and a test can't set it. See `paneSearchSubmitModifiers`.
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
                    // Arrows beside the counter, because the counter alone is not an affordance:
                    // the placeholder that teaches ↩/⇧↩ is gone once there is a query to count.
                    //
                    // Up/down rather than ‹ ›, which this header uses for Back/Forward: chevrons
                    // meaning "history" in one state and "match" in the other would be ambiguous.
                    // Up/down is also what ⇧↩/↩ do to an ordered list of hits.
                    //
                    // Gated on the walk callback as well as the count: a host with no way to walk
                    // gets no buttons that do nothing. It also lets `PaneHeaderSearchTests` render
                    // the field with and without them and count the difference.
                    if onSearchAdvance != nil {
                        searchStepButton(.previous)
                        searchStepButton(.next)
                    }
                }
                // Unconditional, on purpose: the field's own clear button appears only once there
                // is text to clear, and this row replaces the pane bar, so an empty field would
                // offer no way out once focus moved to the file list. This closes the search rather
                // than clearing the query, a different verb from the ✕ beside it.
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
                // The find is unchanged; this only adds a row beneath it. The substring search runs
                // on the query as always, and ↩/⇧↩ keep walking it, so a query that names nobody
                // behaves as a plain find, which makes the offer safe on a control people already
                // use.
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
                            // Bigger than the sentence beside it, not smaller: ⌘ and ↩ carry far
                            // less ink than letters at a given size, and a monospaced face thins
                            // them further, so smaller reads as a smudge. Matches the `.callout`
                            // scale of `ShortcutsReference`, the app's precedent for a chord shown
                            // as text.
                            Text("⌘↩")
                                .scaledFont(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .chromeHover()
                    .help("Gather everything filed under \(person.displayName), and everything named for them")
                    .accessibilityLabel("Show everything that is \(person.displayName)’s")
                }
            }
        )
        .onSubmit {
            let modifiers = pinnedSubmitModifiers ?? NSEvent.modifierFlags
            // ↩ and ⇧↩ are the find's own next and previous, offer or no offer. Taking the offer is
            // ⌘↩, a chord the find doesn't use, so the offer costs the find nothing.
            // The routing is a pure table, ``PaneSearchSubmit``, tested there because `onSubmit`
            // can't be fired from a test.
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
    /// Disabled on zero hits rather than hidden: "No matches" beside live arrows would suggest
    /// somewhere to go. Still enabled at exactly one hit: the walk wraps
    /// (`PaneSearchWalk.advance`), so pressing it re-reveals that hit for someone who has scrolled
    /// away from it.
    ///
    /// Everything that differs between the two buttons is in `PaneSearchStep`, which a test can
    /// hold: two buttons walking the same direction would look right on screen.
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
        // `.disabled` alone is invisible here: `HoverAffordanceStyle` reads `isEnabled` only to
        // suppress the hover wash (see its `resolve`), and the glyph keeps its resting colour. So
        // the dimming is drawn, or "No matches" would sit beside arrows that look pressable.
        .opacity(searchMatchCount == 0 ? 0.35 : 1)
        .help(ShortcutHint.tooltip(step.label, step.chord))
        .accessibilityLabel(step.label)
    }

    /// Closes the search: the field goes away and the query goes with it.
    ///
    /// One definition, reached from both ways out (the close button in the field's trailing slot
    /// and the stretch of bar beside the field), so the two can't drift apart.
    ///
    /// Clearing the query as it closes is `ExpandingSearch.collapse`'s rule: a query left live
    /// behind a hidden field is a filter you can't see or undo.
    ///
    /// Internal so `PaneHeaderSearchTests` can pin what dismissal does. It can't pin that the two
    /// controls call it (a SwiftUI `Button` is not an `NSControl`, and `.onTapGesture` installs no
    /// `NSGestureRecognizer`), so the close button's presence is asserted in painted pixels
    /// instead.
    func dismissSearch() {
        guard let searchText, let searchIsExpanded else { return }
        ExpandingSearch.collapse(text: searchText, isExpanded: searchIsExpanded,
                                 reduceMotion: reduceMotion)
    }

    /// How wide the revealed search field is allowed to get.
    ///
    /// A cap, not a size, for two reasons: a wider field is harder to read a short query in (Finder
    /// and Mail cap theirs too), and the points it gives back are the dead space you click to stop
    /// searching.
    ///
    /// Wide enough for the placeholder, the longest string the field shows; the counter appears
    /// only once a query has replaced it, so the two never compete for room.
    static let searchFieldMaxWidth: CGFloat = 460

    /// The narrowest the field may be squeezed to: the split clamps panes at 250pt, and below
    /// roughly this you can't see the query you are typing. At that width the dead zone disappears,
    /// which is correct: there is no bar to spare, and the close button is the way out.
    static let searchFieldMinWidth: CGFloat = 150

    /// Tree | Columns' selection lens in Frosted and Clear; see `SelectionLens`.
    static let viewModeLensChannel = SelectionLensChannel("pane.viewMode")

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
                        // The on-accent ink on Solid's fill and on dark glass; `.primary`, black, on light glass.
                        .selectionLensLabelInk(isSelected: isSelected, onFill: glassHue.onAccentLabelColor,
                                               unselected: Color.primary.opacity(0.75))
                        .frame(width: pill.width - PaneNavMetrics.segmentInset, height: pill.height)
                        .background {
                            if isSelected {
                                SelectionLensTodayMarker { Capsule().fill(glassHue.accentFillColor) }
                            }
                        }
                        .selectionLensStop(Self.viewModeLensChannel, id: candidate)
                        .contentShape(Capsule())
                }
                // `.filled` for the chosen mode at Solid; under the lens, `.segment` (`SelectionLens`).
                .selectionLensChoiceButtonStyle(isSelected: isSelected, tint: glassHue.accentFillColor)
                // These stand in for a Picker, so they restate the selected-state semantics it
                // would have given VoiceOver for free.
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .help(candidate.help)
            }
        }
        // Horizontal padding only. The ground stays, since it makes two segments read as one
        // control, but vertical padding would make this taller than a pill, hang its title below
        // every other word and overflow the row's budget. Finder's segmented controls are no
        // taller than its plain ones either. Both modes; see `PaneBarLayout.height(of:)`.
        //
        // Frosted and Clear: one glass lens that glides between the two. Inside the padding, so
        // it sits on the ground rather than under it.
        .selectionLensHost(Self.viewModeLensChannel, selected: mode.wrappedValue,
                           style: .fill(.capsule, color: glassHue.accentFillColor))
        .padding(.horizontal, PaneNavMetrics.segmentPadding)
        // Frosted and Clear: the switch's track is a glass capsule like the buttons beside it.
        .chromeGlassTrack()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pane view")
    }

    /// The ⋯ overflow. Holds only what this rung folded away: controls on your bar that this pane
    /// is too narrow to draw. Absent when it would be empty, since it is a symptom of the pane's
    /// width.
    ///
    /// Not the controls the arrangement didn't place: that would hand back what the customize sheet
    /// removed (`PaneBarLayout.plan` has the reasoning). Not Customize either: it has its own door
    /// in `barContextMenu`, right-clicking anywhere on the bar, where anyone who has customized
    /// Finder's toolbar aims first.
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
        .paneNavGlass()
        .fixedSize()
        .help("More pane options")
        .accessibilityLabel("More pane options")
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
                Button(action: onCollapse) { Label("Collapse Pane", systemImage: PaneBarItem.collapseSymbol) }
            }
        case .backForward:
            Button(action: onBack) { Label("Back", systemImage: "chevron.left") }
                .disabled(!canGoBack)
            Button(action: onForward) { Label("Forward", systemImage: "chevron.right") }
                .disabled(!canGoForward)
        case .scan:
            // Unreachable: `PaneBarItem.pinned` is never folded and never absent. Handled rather
            // than defaulted so a new enum case fails the build here instead of silently dropping
            // out of the menu. It still resolves the same `ScanRungMode` as the rung, so if
            // `pinned` ever moves the two renderings can't disagree.
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
                    .lockedDuringRun()
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
        case .search:
            // Reached only when the magnifier is on the bar and this rung folded it; ⋯ doesn't
            // stand in for a bar that never carried it (`PaneBarMigration` puts it there). ⌘F is
            // the real front door and works whether or not the pill is drawn.
            if let searchIsExpanded {
                Button {
                    // Opens it and nothing else: the field claims focus itself, one Task hop after
                    // it appears, and a `FocusState` write made here would land in the transaction
                    // that inserts the field and be dropped.
                    withDesignAnimation(ExpandingSearch.animation, reduceMotion: reduceMotion) {
                        searchIsExpanded.wrappedValue = true
                    }
                } label: {
                    Label("Find in This Pane…", systemImage: "magnifyingglass")
                }
            }
        case .delete:
            // Only when the rung folded it. A bar arranged without it isn't offered it here, on
            // purpose (see `PaneBarItem.delete`): the row menu's Delete and ⌘⌫ reach the same act,
            // so it can wait to be added deliberately.
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("Move Selection to Trash…", systemImage: "trash")
                }
                .disabled(selectionCount == 0)
                .lockedDuringRun()
            }
        case .typeFilter:
            // Folded, the list becomes a submenu: one checkmark per kind present, then Show All. A
            // popover can't hang off a pill that isn't drawn.
            if let typeFilter {
                Menu {
                    PaneTypeFilterMenuItems(control: typeFilter)
                } label: {
                    Label("Filter by Type", systemImage: PaneBarItem.typeFilterSymbol)
                }
            }
        case .space, .flexibleSpace:
            EmptyView()
        }
    }

    /// What the Delete rung says it will do.
    ///
    /// It states the confirmation because this control ignores "Confirm before deleting" and
    /// always asks; unsaid, someone who switched that setting off would read the prompt as the
    /// setting being broken. Internal so a test can read the promise instead of restating it.
    var deleteHelp: String {
        guard selectionCount > 0 else {
            return "Move this pane’s selected items to the Trash — select something first"
        }
        let subject = selectionCount == 1 ? "the selected item" : "\(selectionCount) selected items"
        return "Move \(subject) in this pane to the Trash — always asks first, "
            + "even with confirmations turned off"
    }

    /// Right-clicking the bar itself, where anyone who has customized Finder's toolbar tries first,
    /// and the only way to open the customize sheet. So `theBarsMenuIsAimableAcrossTheWholeRow`
    /// right-clicks along the row rather than trusting the `.contentShape(Rectangle())` above: a
    /// control that swallowed the right-click could leave the sheet unreachable on a full bar.
    @ViewBuilder
    private func barContextMenu() -> some View {
        // Tabs first: they act on the pane, while everything below acts on the bar's appearance.
        // No key equivalents: the chords are registered once, in the menu bar, and a
        // `.keyboardShortcut` here would register a second pair, one per pane.
        if let onNewTab {
            Button("New Tab") { onNewTab() }
            if let onCloseTab {
                Button("Close Tab") { onCloseTab() }
            }
            Divider()
        }
        // Two modes, where Finder has three; see `PaneBarLabelMode` for why Text Only is absent.
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
    /// `PaneNavChrome` reads, and paints no wash of its own: the capsule's fill is the wash.
    private var navButtonStyle: HoverAffordanceStyle {
        .hoverAffordance(.filled, tint: glassHue.accentColor, shape: .capsule)
    }
}

/// Sizing for the pane header's nav cluster.
///
/// Liquid Glass takes a button's size from its label, so different SF Symbols give different pill
/// heights, and `ButtonMenuStyle` pins the sort menu's own. One fixed pill levels them all.
///
/// All figures measured with `NSHostingView.fittingSize` and pinned by `PaneNavMetricsTests`.
enum PaneNavMetrics {
    /// The pill every nav control draws, per control size.
    ///
    /// Fixed, and drawn by the app. An outer `.frame(height:)` does not stretch a system-drawn
    /// pill, only gives it a taller box to sit in, so it measures right and still renders small.
    /// Drawing the capsule ourselves is the only way the size is actually ours.
    static func pill(_ controlSize: ControlSize) -> CGSize {
        controlSize == .mini ? CGSize(width: 27, height: 17) : CGSize(width: 33, height: 20)
    }

    /// How far a segment (a view-switch half) is drawn inside the plain pill's width, so a
    /// two-segment control reads as one control rather than two pills.
    static let segmentInset: CGFloat = 4
    /// The hairline between the view switch's two segments.
    static let segmentSpacing: CGFloat = 3
    /// The capsule ground the view switch's segments sit on, per edge.
    static let segmentPadding: CGFloat = 3
    /// Back and Forward are one item and stay a pair's width apart, as they do in Finder.
    static let pairSpacing: CGFloat = 6
    /// Between two adjacent bar items. Placed by hand rather than by `HStack(spacing:)`; see
    /// `PaneHeader.barContent` for why a flexible space must cost nothing.
    ///
    /// 8 when the bar wears words, 6 when it is glyphs only: a function, because the caller knows
    /// which bar it is pricing. On a titled bar an item's box is the wider of its pill and its
    /// word, so this is the gap between words, and at 6 neighbouring words read as one caption.
    ///
    /// Untitled bars keep 6 because every gap is paid at every rung: a wider gap makes the ladder
    /// step down at a wider pane, costing the narrowest panes their room.
    /// `theUntitledLadderIsPricedAsItWasBeforeTitles` holds the untitled rungs of the default
    /// ladder, which take the same `titled: false` branch as Icon Only and the Large-text fallback.
    ///
    /// `pairSpacing` is also 6, so on an untitled bar Back and Forward sit as far apart as from
    /// everything else; the pair reads as a pair only while the bar is titled.
    static func itemGap(titled: Bool) -> CGFloat { titled ? 8 : 6 }

    /// An explicit symbol size, so the glyphs stop each having their own intrinsic metrics.
    static func glyphFont(_ controlSize: ControlSize) -> ScaledFont {
        .system(size: controlSize == .mini ? 10 : 12, weight: .medium)
    }

    // No fixed cluster width: the bar's length is whatever someone arranged. The pill's painted
    // size is pinned by `PaneNavMetricsTests.glyphPillsAreIdentical`, and the rung a 250pt pane
    // picks by the narrow snapshots in `DashboardSnapshotTests`.
    //
    // Don't shrink the pill to buy width: the header's degradation ladder is not monotonic in it,
    // and a 250pt pane is already on the `.mini` rung, where `.small` sizes change nothing.
}

/// The chrome for one pane-header nav control: a fixed capsule the app draws itself.
///
/// Not the system `.glass` button style: against it an outer `.foregroundStyle` loses to the
/// style's own label colour, an outer `.frame` doesn't resize the pill, and any filter or offscreen
/// pass over glass renders nothing. The app owns the fill, so it can guarantee size and hover.
struct PaneNavChrome: ViewModifier {
    let accent: Color
    let controlSize: ControlSize
    /// Overrides the glyph colour while the rung is enabled. `nil` (every rung but Delete) keeps
    /// the chrome ink below.
    ///
    /// A parameter, not a `.foregroundStyle` on the button, which would be silently inert: this
    /// modifier applies `.foregroundStyle(glyph)` to the glyph itself, and the application closest
    /// to the leaf wins.
    ///
    /// Not routed through `ChromeInk.label`, which returns full-strength white in dark: right for
    /// legibility, wrong for a colour that must say "destructive" in both appearances.
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
            // Frosted and Clear: the pill is glass, like Finder's toolbar buttons (`ChromeGlass`),
            // and only the hover and press wash is painted on it. Solid draws its own pill.
            //
            // **Never draw the glass here**: `paneNavGlass()` puts it on the button, outside the
            // button style. `navButtonStyle` is `.filled`, which flattens its label into a
            // compositing group for its lift shadow, and Liquid Glass renders nothing through one,
            // so glass drawn here would vanish on screen while offscreen tests still passed.
            .background {
                ChromeGlassTodayGround { Capsule().fill(fill) }
                ChromeGlassOnly { Capsule().fill(engagedWash) }
            }
            .contentShape(Capsule())
    }

    /// What hover and press paint on a glass pill: the same washes `fill` uses, minus its resting
    /// grey, which the glass replaces.
    private var engagedWash: Color {
        guard isEnabled else { return .clear }
        switch phase {
        case .rest: return .clear
        case .hover: return accent.opacity(0.22)
        case .pressed: return accent.opacity(0.34)
        }
    }

    /// Disabled reads as a flatter, quieter pill and never responds: `canGoBack` is false at the
    /// top of a tree, and a Back arrow that lit up there would promise a click that does nothing.
    private var fill: Color {
        guard isEnabled else { return .primary.opacity(0.035) }
        switch phase {
        case .rest: return .primary.opacity(0.075)
        case .hover: return accent.opacity(0.22)
        case .pressed: return accent.opacity(0.34)
        }
    }

    /// Disabled stays quiet in both appearances, for the same reason as `fill`.
    ///
    /// Enabled, dark is full-strength white via `ChromeInk`: on the hue-washed surface the 0.75
    /// rest ink measures ~3.4:1, and an accent glyph on an accent wash has nothing to shift
    /// against. The pill's `fill` still carries the hover in both appearances.
    private var glyph: Color {
        guard isEnabled else { return .primary.opacity(0.25) }
        // A supplied ink outranks the engagement tint too: a trash that turned accent-blue under
        // the cursor would lose its one distinguishing cue at the moment of the click.
        if let ink { return ink }
        return ChromeInk.label(colorScheme, light: phase.isEngaged ? accent : .primary.opacity(0.75))
    }
}

extension View {
    /// See `PaneNavChrome`. Pair with `.buttonStyle(.hoverAffordance(.filled, …))`, which supplies
    /// the phase this reads plus the press scale, and no wash of its own: the fill here is the wash.
    func paneNavChrome(accent: Color, controlSize: ControlSize, ink: Color? = nil) -> some View {
        modifier(PaneNavChrome(accent: accent, controlSize: controlSize, ink: ink))
    }

    /// A pane-bar button's glass capsule in Frosted and Clear. Apply it to the button, after its
    /// style, never inside the label (see `PaneNavChrome`). Back and Forward's group capsule stands
    /// in for theirs.
    func paneNavGlass() -> some View {
        chromeGlassGround(.capsule)
    }
}


// MARK: - Search submit modifiers

private struct PaneSearchSubmitModifiersKey: EnvironmentKey {
    /// `nil` is "ask the keyboard", which is what the app always does; only a deliberate pin
    /// changes anything.
    static let defaultValue: NSEvent.ModifierFlags? = nil
}

extension EnvironmentValues {
    /// The modifiers `PaneHeader`'s search field reads when its query is submitted, or `nil` to read
    /// the live keyboard.
    ///
    /// ↩ walks to the next hit and ⇧↩ to the previous, and both arrive as `onSubmit`: a single-line
    /// `TextField` submits on Return whether or not Shift is held, and consumes the key before an
    /// ancestor's `.onKeyPress(.return)` sees it. So the direction comes from the modifier state at
    /// the moment of submission.
    ///
    /// `NSEvent.modifierFlags` is right for a real keystroke, which runs inside AppKit's key
    /// handling, and wrong for a test, which submits with no event and would read whatever key the
    /// person at the Mac is holding, so a stray ⇧ could flip a result (as with
    /// `paneClickModifiers`). Pinning `[]` makes a plain Return part of the test; pinning `.shift`
    /// is how the reverse walk is asserted.
    public var paneSearchSubmitModifiers: NSEvent.ModifierFlags? {
        get { self[PaneSearchSubmitModifiersKey.self] }
        set { self[PaneSearchSubmitModifiersKey.self] = newValue }
    }
}
