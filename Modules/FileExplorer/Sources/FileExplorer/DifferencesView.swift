import Events
import SwiftUI
import Sync
import AppKit
import Design

/// List of all differences between the two panes with actions to copy or move each item left or right.
public struct DifferencesView: View {
    @ObservedObject public var syncManager: FileSyncManager
    /// Host-owned review state: this view is conditionally mounted (bottom tab; empty live
    /// list), so a session kept in `@State` here would die on any unmount. The host's store
    /// keeps it alive — and keeps the view mounted — for the whole review.
    @ObservedObject private var reviewStore: ReviewSessionStore
    @StateObject private var modifierTracker = ModifierTracker()
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    /// The resolved glass material; `.frosted` (standard Liquid Glass) if unrecognized.
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue
    @State private var selectedFilter: DifferenceFilter = .all
    /// Whether the table breaks its rows into top-level folder sections. Persisted, and ON by
    /// default: a flat list of five hundred differences has no landmarks, and the single-section
    /// fall-back (`DifferenceGrouping.isWorthGrouping`) means a small comparison is never given a
    /// lone header it gains nothing from. Turning it off restores the flat table — which is what
    /// you want when sorting by Size across the whole comparison, since grouping means the largest
    /// file is no longer the top row.
    @AppStorage("differencesGroupByFolder") private var groupByFolder: Bool = true
    /// Folder names whose section is collapsed. Deliberately NOT persisted and cleared on every
    /// rescan: the folders themselves change between scans, so a remembered "Claude was collapsed"
    /// is a preference about a list that no longer exists — and restoring it would hide
    /// differences the user has never seen.
    @State private var collapsedSections: Set<String> = []
    /// Toggles the per-side item totals beside the count pill — clicking the pill reveals them,
    /// clicking again collapses. Off by default so the header stays uncluttered until asked.
    @State private var showItemCounts = false
    /// Hover state for the count pill: a slight grow signals the pill is clickable (post-scan only).
    @State private var isCountPillHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Read here rather than inside `LabelMetrics` because a `ScaledFont` cannot see the
    /// environment — the same reason `Text.scaledFont(_:scale:)` takes the scale as an argument.
    /// The header ladder measures its rungs at this scale.
    @Environment(\.appFontScale) private var appFontScale
    /// Drives the count pill's freshness palette. Read from the environment rather than from the
    /// Theme setting, so it follows System just as well as an explicit Light/Dark.
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""
    @State private var selection = Set<FileDifference.ID>()
    @State private var sortOrder: [KeyPathComparator<FileDifference>] = [KeyPathComparator(\.fileName, comparator: .localizedStandard, order: .forward)]
    /// The filtered+sorted table rows, cached in state and rebuilt by `.task(id:)` off the main
    /// actor (the DiffStatusIndex pattern): running the O(n) filter and the O(n log n)
    /// localized-comparator sort inline in `body` re-ran both on EVERY re-render, and during a
    /// bulk sync the view re-renders per published file. `DisplayInputs` keys the task, so a
    /// re-render with unchanged inputs costs an (identity-fast-pathed) equality check instead.
    @State private var displayRows = DisplayRows()
    /// False until the first row computation lands: gates the "No differences" empty overlay so
    /// the async first pass shows a briefly blank table, never a wrong "nothing here" flash.
    @State private var hasComputedRows = false
    @State private var isSearchExpanded = false
    /// The review table's selection — doubles as the review cursor: advancing the session moves
    /// it, and clicking a pending row jumps the session. Separate from `selection` so entering
    /// and leaving review mode can't corrupt the normal table's selection.
    @State private var reviewSelection = Set<FileDifference.ID>()
    /// Bumped on every review-table click so the card re-claims key focus (see `focusNudge`).
    @State private var reviewFocusNudge = 0
    private let paneNames: PaneProviderNames
    /// Both panes' name rulesets — see `PaneProviderRules` for why a differences row asks BOTH.
    private let paneRules: PaneProviderRules
    /// Names the user has kept, read live off the manager's store so a keep made from a pane row
    /// silences this table's badges in the same beat.
    private var keptNames: Set<String> { syncManager.keptNamesStore?.names ?? [] }
    private let onQuickLook: ((URL) -> Void)?
    /// Shows the in-app Info inspector for a path (the "Get Info" row action). Default no-op.
    private let onGetInfo: (String) -> Void
    /// Host-owned collapse state for the whole pane. When bound, the header shows a chevron that
    /// hides the differences list, leaving only this header strip (the host shrinks the pane to it
    /// and hands the freed height to the panes above). `nil` — the default — means the pane can't
    /// collapse and the chevron is withheld.
    private let isCollapsed: Binding<Bool>?
    /// A guided review overrides the collapse: the review card carries a cursor and progress that
    /// exist nowhere else, so starting one re-opens the pane rather than leaving the session hidden
    /// behind a chevron. The stored preference is untouched, so the pane re-collapses when the
    /// review ends. `ContentView.bottomPaneIsCollapsed` gates the pane's HEIGHT on the identical
    /// condition (`isReviewing` is defined as `session != nil`), so the two cannot disagree about
    /// whether this pane is currently a header strip or a full list.
    private var collapsed: Bool {
        Self.isCollapsedToHeaderStrip(storedCollapse: isCollapsed?.wrappedValue ?? false,
                                      isReviewing: reviewStore.isReviewing)
    }

    /// Whether a collapsible differences pane is a header strip right now. THE rule, in one place:
    /// the host gates the pane's HEIGHT on it and this view gates what it RENDERS on it, so if the
    /// two ever disagreed the list would be clipped to the header's height. Both used to restate
    /// the condition and rely on comments to keep them honest — the same hand-maintained-mirror
    /// shape the compaction ladder and the model picker were both bitten by.
    public static func isCollapsedToHeaderStrip(storedCollapse: Bool, isReviewing: Bool) -> Bool {
        // A guided review overrides the stored preference: the review card carries a cursor and
        // progress that exist nowhere else, so starting one re-opens the pane. The preference is
        // left untouched, so the pane re-collapses when the review ends.
        storedCollapse && !isReviewing
    }
    /// - Parameters:
    ///   - reviewStore: The host-owned guided-review state (`@StateObject` at the host, NOT
    ///     created inline here — a per-render store would reset the session every render).
    ///   - onQuickLook: Presents a Quick Look preview for the given file. The app routes this
    ///     to the same `quickLookPreview` binding the spacebar shortcut uses, so there is a
    ///     single presenter; `nil` hides the Quick Look menu items.
    ///   - onGetInfo: Shows the Info inspector for a file path (the "Get Info" row action).
    public init(syncManager: FileSyncManager, reviewStore: ReviewSessionStore, paneNames: PaneProviderNames = .leftRight, paneRules: PaneProviderRules = .strictest, onQuickLook: ((URL) -> Void)? = nil, onGetInfo: @escaping (String) -> Void = { _ in }, isCollapsed: Binding<Bool>? = nil) {
        self.syncManager = syncManager
        self.reviewStore = reviewStore
        self.paneNames = paneNames
        self.paneRules = paneRules
        self.onQuickLook = onQuickLook
        self.onGetInfo = onGetInfo
        self.isCollapsed = isCollapsed
    }

    private var isBulkSyncing: Bool {
        syncManager.bulkSyncProgress != nil
    }
    private var isVerifyAllInProgress: Bool {
        syncManager.verifyAllProgress != nil
    }
    /// One gate for every Copy/Move/Verify entry point — the header buttons AND the bulk
    /// context menu must share it: `syncAll` silently drops re-entrant runs, so an entry
    /// point left enabled during a bulk sync is a silent no-op.
    private var isSyncActionBlocked: Bool {
        syncManager.differences.contains { $0.isSyncing } || isBulkSyncing || isVerifyAllInProgress
    }
    private var verifiedIdenticalCount: Int {
        syncManager.verifiedIdenticalForCopy?.differences.count ?? 0
    }
    private var glassHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: glassHueRaw) ?? .blue
    }
    private var surfaceStyle: SurfaceStyle {
        SurfaceStyle(rawValue: surfaceStyleRaw) ?? .unified
    }
    /// The appearance density (H7): comfortable leaves the table untouched; compact
    /// tightens the rows via `.listDensity(_:)` (small controls + subheadline cells +
    /// lowered row minimum — the floor alone can't shrink regular-size cells).
    private var listDensity: ListDensity {
        ListDensity(rawValue: listDensityRaw) ?? .comfortable
    }

    /// One filtered + one sorted snapshot of the visible rows (see `displayRows`).
    /// @unchecked Sendable for the same reason as DisplayInputs below: every stored property is
    /// an immutable value snapshot (`DifferenceFilter` is a plain value type that merely lacks
    /// the public conformance), built on the detached rebuild and handed back whole.
    private struct DisplayRows: @unchecked Sendable {
        var filtered: [FileDifference] = []
        var sorted: [FileDifference] = []
        /// Per-filter badge counts over ALL differences (not the filtered rows), riding the same
        /// detached rebuild as the rows. Menu content builders are NOT lazy — the closure is
        /// non-escaping and runs on every render of the header — so computing counts inside the
        /// Menu paid an O(differences) pass per published file during bulk sync.
        var filterCounts: [DifferenceFilter: Int] = [:]
    }

    /// Everything that decides the visible rows, bundled as the `.task(id:)` key so the pass
    /// recomputes exactly when one of them changes — including per-row mutations mid-bulk
    /// (`isSyncing` flips republish `differences`, and array equality catches element changes;
    /// an untouched array fast-paths on buffer identity). Review mode is an input too: entering
    /// it empties the rows without running the pass (nothing renders from them there).
    ///
    /// @unchecked Sendable: every stored property is an immutable value snapshot that's safe to
    /// hop to the detached compute (`FileDifference` is Sendable; `DifferenceFilter` and
    /// `KeyPathComparator` are plain value types that merely lack the public conformance).
    private struct DisplayInputs: Equatable, @unchecked Sendable {
        var differences: [FileDifference]
        var filter: DifferenceFilter
        var searchText: String
        var sortOrder: [KeyPathComparator<FileDifference>]
        var isReviewing: Bool
    }

    private var displayInputs: DisplayInputs {
        DisplayInputs(
            differences: syncManager.differences,
            filter: selectedFilter,
            searchText: searchText,
            sortOrder: sortOrder,
            isReviewing: reviewStore.session != nil
        )
    }

    public var body: some View {
        // The rows come from the state cache (rebuilt by the .task(id:) below), so a re-render
        // whose inputs didn't change — and during bulk sync the view re-renders per published
        // file — does no filtering or sorting work in body.
        let filtered = displayRows.filtered
        let sorted = displayRows.sorted
        let targets = DifferenceActionTargets(filtered: filtered, selection: selection)
        // Derived ONCE per render and threaded down, not recomputed by each consumer. Two callers
        // need it — the table draws it, the filter menu reads it for the Expand/Collapse All
        // enabled states — and a Menu's content builder is NOT lazy (see `filterMenu`), so a
        // computed property read from both would run this O(n) grouping pass twice on every
        // render, which during a bulk sync means twice per copied file.
        let sections = groupedSections(sorted)

        // spacing 0: each bottomSectionCard insets itself by half a gutter, so the gap between
        // them is already `cardGutter`. A spacing here would add to it.
        return VStack(spacing: 0) {
            // Toolbar card: tabs · count · filter · actions · search.
            VStack(alignment: .leading, spacing: 10) {
                if collapsed {
                    // Collapsed to a thin bar: only the differences count (left) and the
                    // expand chevron (right). Filter, Review, the Copy buttons and search are
                    // all withheld until the pane is opened again.
                    HStack(spacing: 10) {
                        collapsedHeader
                        collapseToggle
                    }
                } else if let session = reviewStore.session {
                    // No collapse toggle: `collapseToggle` withholds itself during a review, and
                    // this branch is the only one that runs then.
                    HStack(spacing: 10) { reviewHeaderControls(session) }
                } else {
                    // Owns its own row — it is a ViewThatFits over the whole zoned bar, so the
                    // trailing view controls have to be inside it to be shed against.
                    standardHeader(targets: targets, sorted: sorted, sections: sections)
                }
                if reviewStore.session == nil, !collapsed, isSearchExpanded || !searchText.isEmpty {
                    searchField(filteredCount: filtered.count)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(HeaderCardChrome(tint: glassHue.accentColor))
            .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)

            // Table card: review card / progress (during ops) sits above the differences table.
            // Dropped entirely when collapsed so the pane shrinks to just the header strip above.
            if !collapsed {
                VStack(spacing: 0) {
                    if let session = reviewStore.session {
                        reviewSection(session)
                    } else {
                        standardTableSection(sorted: sorted, sections: sections)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
            }
        }
        // Review-cursor plumbing, both directions: a row click jumps the session (pending rows
        // only — decided rows snap the highlight back), and a session advance re-highlights.
        .onChange(of: reviewSelection) { oldSelection, newSelection in
            guard let session = reviewStore.session else { return }
            // Any click hands key focus to the Table; send it back to the card.
            reviewFocusNudge += 1
            // The Table binds a Set selection, so ⌘/⇧-click can leave more than one row selected
            // and `.first` would be non-deterministic. Drive the cursor from the row the user just
            // ADDED (falling back to whatever remains), and collapse any stray multi-selection back
            // to one row — otherwise a second highlight can disagree with what Return/Skip acts on.
            let target = newSelection.subtracting(oldSelection).first ?? newSelection.first
            // Deselection (⌘-click on the selected row) must snap back too — the highlight IS
            // the cursor and may not go dark until the next advance.
            guard let id = target else {
                reviewSelection = session.current.map { [$0.id] } ?? []
                return
            }
            guard id != session.current?.id else {
                if newSelection != [id] { reviewSelection = [id] }   // collapse a stray extra row
                return
            }
            var updated = session
            if updated.jump(to: id) {
                reviewStore.session = updated   // the currentIndex onChange re-seeds selection to [id]
            } else {
                reviewSelection = session.current.map { [$0.id] } ?? []
            }
        }
        .onChange(of: reviewStore.session?.currentIndex) { _, _ in
            guard let session = reviewStore.session else { return }
            reviewSelection = session.current.map { [$0.id] } ?? []
        }
        // Remount mid-review (Details tab peek and back): the session lives in the store, but
        // the cursor highlight is view `@State` — re-seed it from the surviving session.
        .onAppear {
            if let current = reviewStore.session?.current {
                reviewSelection = [current.id]
            }
        }
        // A new scan is a new list: folders appear, disappear and change size, so a collapse
        // carried across it would hide differences the user has never laid eyes on. Keyed on the
        // scan date rather than on `differences`, which also republishes mid-bulk-sync per file —
        // collapsing a folder and watching it spring open on every copied file would be worse
        // than not collapsing at all.
        .onChange(of: syncManager.lastScanDate) { _, _ in
            collapsedSections.removeAll()
        }
        // Rebuild the visible rows off the main actor whenever an input changes (and once on
        // appear). task(id:) cancels a stale rebuild when the inputs change again mid-flight,
        // and the isCancelled check keeps its result from landing over a newer one — the same
        // shape as ContentView's DiffStatusIndex rebuild.
        .task(id: displayInputs) {
            let inputs = displayInputs
            if inputs.isReviewing {
                // Drop the cached rows (the review UI owns the screen; holding thousands of
                // stale rows costs memory) but do NOT mark them computed: the table isn't
                // rendered during a review, and on exit the first body beat would otherwise
                // pair the emptied rows with a set flag — flashing "No differences" until the
                // detached rebuild below lands. Leaving the flag false makes the exit hold the
                // same blank-table placeholder as the first load. Filter counts are kept: they
                // cost six Ints, and clearing them would zero the menu badges for the rebuild
                // window right after exiting the review.
                displayRows = DisplayRows(filterCounts: displayRows.filterCounts)
                hasComputedRows = false
                return
            }
            let rows = await Task.detached(priority: .userInitiated) { () -> DisplayRows in
                let filtered = DifferencesQuery.filtered(inputs.differences, filter: inputs.filter, searchText: inputs.searchText)
                return DisplayRows(
                    filtered: filtered,
                    sorted: filtered.sorted(using: inputs.sortOrder),
                    filterCounts: DifferencesQuery.counts(inputs.differences)
                )
            }.value
            guard !Task.isCancelled else { return }
            displayRows = rows
            hasComputedRows = true
        }
        .confirmationDialog("Copy to Match Dates", isPresented: Binding(
            get: { syncManager.verifiedIdenticalForCopy != nil },
            // Deferred cleanup: SwiftUI writes false here on ANY dismissal, including confirm,
            // and may run this setter before the button action. A synchronous cleanup here would
            // destroy the list before the confirm button can claim it (making Copy a no-op).
            set: { if !$0 { syncManager.verifiedCopyDialogDismissed() } }
        )) {
            Button("Copy \(paneNames.left) to \(paneNames.right)") {
                syncManager.confirmVerifiedCopy()
            }
            Button("Cancel", role: .cancel) {
                syncManager.dismissVerifiedCopyDialogWithoutCopy()
            }
        } message: {
            Text("\(verifiedIdenticalCount) files verified identical. One permission — copies all from \(paneNames.left) to \(paneNames.right) to match dates. No per-file confirmation.")
        }
    }

    // MARK: Header — scan freshness

    /// What scan freshness contributes to the differences count pill at one moment in time.
    ///
    /// Freshness used to be a standalone badge in each pane header — two capsules reporting one
    /// fact, because a single Scan drives both panes, so they could only ever differ mid-scan.
    /// It lives here now: the count and its age are one statement ("576 differences, as of 29
    /// minutes ago"), and staleness lands on the very number it undermines.
    /// Internal rather than private because `standardHeaderRow` takes one, and that row is internal
    /// so `HeaderLadderTests` can render the row the ladder prices.
    struct CountPillDressing {
        let semantic: SemanticCapsuleStyle
        /// The family the AGE RUN wears, or nil when there is nothing to report. The capsule around
        /// it is the accent in every state — this is the only thing freshness changes.
        let detailStyle: SemanticCapsuleStyle?
        /// The secondary run inside the pill — "29m ago", or nil before the first scan.
        let detail: String?
        /// What VoiceOver says in `detail`'s place. Carried separately because the two states that
        /// fill `detail` mean different things: an age is something the scan already did, and
        /// "scanning…" is something it is still doing. `StatPill` used to glue "scanned " onto
        /// whatever it was handed, which turned the in-flight state into "scanned scanning…".
        let spokenDetail: String?
        /// The exact timestamp sentence, appended to the pill's tooltip. The age buckets are
        /// deliberately coarse and cannot answer "when precisely?", so hover does.
        let help: String?
    }

    /// The dressing for `now`. The CAPSULE is the accent in all four states; only the age run
    /// changes:
    ///
    /// - **fresh** — bare age run. Reassurance does not deserve a colour.
    /// - **stale** — the run wears `.attention`. Hue-independent, so it survives the `.green` and
    ///   `.amber` accents that would otherwise collide with the colour carrying the status.
    /// - **scanning** — the run wears `.neutral`, and deliberately not green: a scan in flight has
    ///   not yet earned "fresh", and colouring it as success flashes a verdict before the result
    ///   exists.
    /// - **pre-scan** — no run at all. "0 Differences" with no age is honest; an age run would have
    ///   nothing to report and the pill is already a no-op toggle here.
    ///
    /// Why the capsule stopped moving: stale used to take the WHOLE capsule to flat `.attention`
    /// and scanning to flat `.neutral`. Two things were wrong with that. The threshold was ten
    /// minutes, tuned when freshness was a small badge in a pane header, so on a machine that keeps
    /// this app open for hours the warning was on almost all the time — and a warning that is
    /// always on is furniture. Worse, beside a saturated accent the pale terracotta read as
    /// *disabled* rather than as *warning*, on a control whose whole job is being clickable. The
    /// status is worth keeping; the volume was not. Scoping it to the run keeps the capsule saying
    /// "this is a toggle" while the run says "and it is old". `staleAfter` moved to an hour in the
    /// same change.
    ///
    /// Nothing coloured can carry this on the accent fill, which is why the run is a filled capsule
    /// with a ring rather than a tinted word: on a saturated accent nothing coloured clears 3:1
    /// (see `SemanticCapsuleStyle.dotRing`). An earlier cut recoloured the leading dot green while
    /// fresh and, under the green accent, painted a green dot on a green fill inside a white ring —
    /// a hollow circle that read as an empty checkbox. That dot is gone now; see `StatPill`.
    ///
    /// The `at:` seam is deliberately time-only, and that is the one thing here worth revisiting:
    /// staleness is inferred from the CLOCK, not from the trees having actually changed. A future
    /// change-detector would feed this same `detailStyle` decision rather than replace it — and
    /// should be additive, since a detector that MISSES a change under-warns, which is a worse
    /// failure than the over-warning this change fixes.
    private func countPillDressing(at now: Date) -> CountPillDressing {
        let accent = SemanticCapsuleStyle.onAccent(fill: glassHue.accentFillColor,
                                                   label: glassHue.onAccentLabelColor)
        guard let scanDate = syncManager.lastScanDate else {
            return CountPillDressing(semantic: accent, detailStyle: nil, detail: nil,
                                     spokenDetail: nil, help: nil)
        }
        let stamp = Calendar.current.isDateInToday(scanDate)
            ? scanDate.formatted(date: .omitted, time: .standard)
            : scanDate.formatted(date: .abbreviated, time: .standard)
        if syncManager.isScanning {
            return CountPillDressing(semantic: accent,
                                     detailStyle: .of(.neutral, colorScheme),
                                     detail: "scanning…",
                                     // Present tense, and no "scanned": the count beside it is the
                                     // PREVIOUS scan's, and announcing it as freshly scanned would
                                     // vouch for a number the running scan is about to replace.
                                     spokenDetail: "scanning for changes",
                                     help: "Scanning for changes…")
        }
        let freshness = ScanFreshness.describe(scanDate: scanDate, now: now)
        // `freshness.spoken` on BOTH branches, and it is the only thing that says "stale" in
        // words: the run's terracotta capsule is colour, the age itself reads the same either
        // way, `.help` is not announced, and the button's own value/hint describe the toggle.
        // `ScanFreshness.Result` owns the phrasing so the two branches cannot drift apart.
        guard freshness.isStale else {
            return CountPillDressing(semantic: accent, detailStyle: nil, detail: freshness.age,
                                     spokenDetail: freshness.spoken,
                                     help: "Last scanned \(stamp)")
        }
        return CountPillDressing(semantic: accent,
                                 detailStyle: .of(.attention, colorScheme),
                                 detail: freshness.age,
                                 spokenDetail: freshness.spoken,
                                 help: "This comparison may be out of date — last scanned \(stamp)")
    }

    /// Runs `content` on a 30s tick so the age stays honest without the view polling.
    ///
    /// Anchored to `lastScanDate`, NOT to `Date()`: anchored to view creation the ticks sat on an
    /// arbitrary phase relative to the scan, so a "30s ago" label could land anywhere within 30s
    /// of the truth — and, because `ScanFreshness.staleAfter` is a whole number of 30s ticks,
    /// anchoring also puts the fresh→stale flip exactly on the threshold instead of up to 30s
    /// late. Stated as a property of the constant rather than as its value, which is what let this
    /// go on naming ten minutes for an hour after the threshold moved. Pre-scan there is nothing
    /// to tick, so the content renders once.
    @ViewBuilder
    private func withScanFreshness(@ViewBuilder _ content: @escaping (CountPillDressing) -> some View) -> some View {
        if let scanDate = syncManager.lastScanDate {
            TimelineView(.periodic(from: scanDate, by: 30)) { context in
                content(countPillDressing(at: context.date))
            }
        } else {
            content(countPillDressing(at: Date()))
        }
    }

    // MARK: Header

    /// The header's normal (non-review) trailing controls: count pill, filter, selection chip,
    /// Review…, the bulk Copy/Move buttons, Verify, and the search toggle.
    /// The collapsed bar's only content: the differences count on the left, a spacer pushing the
    /// expand chevron to the right. A plain (non-toggle) pill — the per-side totals it can reveal
    /// belong to the expanded header.
    @ViewBuilder
    private var collapsedHeader: some View {
        // Freshness matters MORE here than in the expanded header, not less: collapsed, this pill
        // is the only thing left on screen that says anything about the scan at all.
        withScanFreshness { dressing in
            let pill = StatPill(
                count: syncManager.differences.count,
                label: "Differences",
                // Unused on the capsule path — see `countPillToggle`, whose note this mirrors.
                color: glassHue.accentColor,
                systemImage: "exclamationmark.triangle",
                // The same capsule the expanded header's pill wears, freshness and all. Collapsing
                // the pane changes how much of the header survives, never what its colour language
                // means: wearing the old `.warning` wash here made one count read as two
                // conventions depending on a state the user toggles freely.
                semantic: dressing.semantic,
                detail: dressing.detail,
                spokenDetail: dressing.spokenDetail,
                detailStyle: dressing.detailStyle
            )
            // Branch rather than `?? ""`: pre-scan there is no timestamp to report, and the honest
            // expression of "nothing to say" is no `.help` at all, not a `.help` carrying an empty
            // string. (Exactly what AppKit does with an empty tooltip was not pinned down — the
            // point is that this pill should not be asking the question.) The expanded header's
            // pill builds its own non-optional first line, so only this one can end up empty.
            if let help = dressing.help {
                pill.help(help)
            } else {
                pill
            }
        }
        Spacer()
    }

    /// The show/hide chevron pinned to the header's trailing edge. Points down while the list is
    /// shown (a click hides it) and up while collapsed (a click brings it back) — the same "points
    /// the way the next click sends it" rule the count pill's chevron follows. Withheld entirely
    /// when the host doesn't bind collapse state.
    ///
    /// Also withheld during a guided review: collapsing then hid the review card and left a bare
    /// differences count in its place, which reads as "the review is gone" rather than "the pane is
    /// closed" — and the review, unlike the list, has a cursor and progress you can't see any other
    /// way. Finish or exit the review to collapse.
    @ViewBuilder
    private var collapseToggle: some View {
        if let isCollapsed, reviewStore.session == nil {
            Button {
                // Instant: the chevron should feel like a hard toggle, not an easing panel.
                isCollapsed.wrappedValue.toggle()
            } label: {
                Image(systemName: isCollapsed.wrappedValue ? "chevron.up" : "chevron.down")
                    .scaledFont(.system(size: 12, weight: .semibold))
                    .hoverInk()
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverAffordance(.glyph, tint: glassHue.accentColor))
            .help(isCollapsed.wrappedValue ? "Show the differences list" : "Hide the differences list")
            .accessibilityLabel(isCollapsed.wrappedValue ? "Show differences" : "Hide differences")
        }
    }

    /// The standard (non-review) header, in four zones separated by hairlines:
    ///
    ///     [ state ] │ [ scope ] ————— [ actions ] │ [ view ]
    ///
    /// A control's zone is decided by the question it answers — what did the scan find, what am I
    /// acting on, do what, show me what — not by when it was added. Two consequences worth naming:
    /// the selection chip lives in *scope* beside the filter rather than in the action run where it
    /// read as a fourth button, and the search and collapse controls sit behind a hairline because
    /// they change nothing on disk.
    ///
    /// The rung is **computed**, not searched; see `HeaderLadder` for why, and for the arithmetic.
    /// The gap between the scope and action zones states a `minLength` so the seam stays visible on a
    /// full row — not to make the ladder work, which it does with a bare `Spacer()` too: a Spacer's
    /// ideal width is its minLength, so a candidate row reports a finite width to compare against
    /// despite being infinitely flexible afterwards. `ActionBarLadderTests` pins that behaviour,
    /// since the intuition runs the other way and a regression there would clip instead of shed.
    ///
    /// The whole row sits inside `withScanFreshness` rather than just the count pill, and that hoist
    /// is load-bearing rather than tidying. The pill's age run ("29m ago", and the inset capsule it
    /// grows when the scan goes stale) is worth up to 12pt of the row's width, and it changes on a
    /// 30s `TimelineView` tick that does NOT re-run this `body`. With the ladder measured out here
    /// the rung would have been computed against an age the pill had since stopped drawing; measured
    /// inside, the arithmetic and the pill always see the same `dressing`.
    private func standardHeader(targets: DifferenceActionTargets, sorted: [FileDifference],
                                sections: [DifferenceGrouping.Section]) -> some View {
        withScanFreshness { dressing in
            let ladder = HeaderLadder(
                facts: headerFacts(dressing: dressing, targets: targets, sections: sections),
                scale: appFontScale)
            GeometryReader { proxy in
                // `.leading` is (leading, centre): a `GeometryReader` parks its content in its
                // top-left corner, where the row used to take the card's own leading alignment and
                // the vertical centring of the height it is pinned to below.
                hedged(ladder.rung(fitting: proxy.size.width), ladder,
                       dressing: dressing, targets: targets, sorted: sorted, sections: sections)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            }
            // A `GeometryReader` reports nothing about its content and is greedy in BOTH axes, so the
            // two things the `ViewThatFits` it replaced *did* report have to be restated: the
            // narrowest rung's width, which is what the card reserves before anything may squeeze the
            // row, and a height — without which this row would stretch to fill the card and the card
            // would grow with it. The height is `ActionBarMetrics.height` because the filter menu is
            // an action-bar capsule and is on the row at every rung, so it is the row's height
            // authority at every width; `HeaderLadderTests.theRowIsAlwaysTheActionBarHeight` pins
            // that against the drawn row at every rung and every font scale.
            .frame(minWidth: ladder.width(of: ladder.terminal),
                   minHeight: ActionBarMetrics.height,
                   maxHeight: ActionBarMetrics.height)
        }
        // OUTSIDE `withScanFreshness`, and that placement is the whole point. It rode on
        // `countPillToggle` until the row moved inside the TimelineView; the reasoning is unchanged
        // and it has to stay out here to keep holding.
        //
        // Belt-and-braces against a `hasScanned` reset that keeps this view mounted: in practice
        // invalidateComparisonState() also empties `differences` and unmounts us, and the remount
        // resets this @State. Deliberately NOT wired to plain re-Compares on the same roots
        // (hasScanned stays true): expansion persisting there is a remembered preference, not a leak.
        //
        // Inside the closure it was quietly disarmed for the one caller it was written for.
        // `invalidateDifferencesForPaneRetarget()` clears `lastScanDate` and `hasScanned` in a single
        // transaction, so `withScanFreshness` swaps its TimelineView branch for the else branch on the
        // very change this watches — a handler torn down by its own trigger cannot be relied on to
        // fire. Out here it hangs off the branch SWITCH rather than off either branch, and observes
        // unconditionally.
        .onChange(of: syncManager.hasScanned) { _, hasScanned in
            if !hasScanned {
                showItemCounts = false
                isCountPillHovered = false
            }
        }
    }

    /// The computed rung, with the narrowest rung behind it as the layout engine's veto.
    ///
    /// The fallback is the NARROWEST rung, not the next one down: if the arithmetic ever
    /// overestimates what fits, the bar does not step down one rung, it drops all the way to
    /// `.shortPrimary`. That is the deliberate trade — an over-compacted row is visibly wrong and
    /// every action stays reachable, whereas a row that overflows the card clips its trailing
    /// controls with no symptom at all. Widening this to three children would soften the landing at
    /// the cost of building a third toolbar on every layout pass, which is the cost this change
    /// exists to remove.
    ///
    /// Branched rather than always emitting both, because at the narrowest widths the computed rung
    /// *is* the terminal one and a `ViewThatFits` of two identical children would build the row
    /// twice for nothing. The branch is outside the `ViewThatFits` on purpose: an `if` inside its
    /// `ViewBuilder` is one `_ConditionalContent` child, not two, and the ladder would collapse.
    @ViewBuilder
    private func hedged(_ compaction: HeaderCompaction, _ ladder: HeaderLadder,
                        dressing: CountPillDressing,
                        targets: DifferenceActionTargets,
                        sorted: [FileDifference],
                        sections: [DifferenceGrouping.Section]) -> some View {
        if compaction >= ladder.terminal {
            standardHeaderRow(ladder.terminal, facts: ladder.facts, dressing: dressing,
                              targets: targets, sorted: sorted, sections: sections)
        } else {
            ViewThatFits(in: .horizontal) {
                standardHeaderRow(compaction, facts: ladder.facts, dressing: dressing,
                                  targets: targets, sorted: sorted, sections: sections)
                standardHeaderRow(ladder.terminal, facts: ladder.facts, dressing: dressing,
                                  targets: targets, sorted: sorted, sections: sections)
            }
        }
    }

    /// Snapshots everything `HeaderLadder` needs to price the row, from the same values the row is
    /// about to draw with. One place, so the measured row and the drawn row cannot describe
    /// different headers.
    private func headerFacts(dressing: CountPillDressing,
                             targets: DifferenceActionTargets,
                             sections: [DifferenceGrouping.Section]) -> HeaderLadder.Facts {
        HeaderLadder.Facts(
            differencesCount: syncManager.differences.count,
            detail: dressing.detail,
            detailIsCapsuled: dressing.detailStyle != nil,
            chevronSymbol: CountPillChevron.symbol(hasScanned: syncManager.hasScanned,
                                                   expanded: showItemCounts),
            itemCountsText: (syncManager.hasScanned && showItemCounts) ? itemCountsText : nil,
            sectionCount: sections.count,
            filterName: selectedFilter.displayName(leftName: paneNames.left, rightName: paneNames.right),
            isSelectionScoped: targets.isSelectionScoped,
            targetCount: targets.targets.count,
            verifiableCount: targets.verifiableCount,
            copyToLeftCount: targets.copyToLeftCount,
            copyToRightCount: targets.copyToRightCount,
            reverseIsMajority: targets.dominantCopyDirection == .copyToLeft,
            leftName: paneNames.left,
            rightName: paneNames.right,
            isMove: modifierTracker.isMoveModifierPressed,
            showsCollapseToggle: isCollapsed != nil && reviewStore.session == nil)
    }

    /// The compaction rungs the ladder walks, in order. Read by `HeaderLadder.rung(fitting:)` to
    /// choose one and by `HeaderCompactionTests` to catch a rung added to the enum but not here.
    ///
    /// `nonisolated` because it is an immutable array of a `Sendable` enum — a constant, with no
    /// main-actor state in it. It picked up this view's isolation only by living here, which made
    /// `HeaderLadder` (a plain struct, deliberately isolation-free so its arithmetic can be tested
    /// off the main actor) reach across an actor boundary to read six enum cases.
    nonisolated static let renderedCompactionLadder: [HeaderCompaction] =
        [.full, .foldVerify, .foldReview, .shortReverse, .glyphFilter, .shortPrimary]

    /// Internal, not private, so `HeaderLadderTests` can render the very row `HeaderLadder` prices.
    /// The arithmetic is only worth anything while it is checked against this view.
    ///
    /// It takes `facts` — the same snapshot the ladder was priced from — rather than reading
    /// `showItemCounts` again for the totals readout. The readout is the one run on this row whose
    /// presence AND text both come from view state, so having the drawn string and the measured
    /// string be literally the same value is what stops the two drifting.
    func standardHeaderRow(_ compaction: HeaderCompaction,
                           facts: HeaderLadder.Facts,
                           dressing: CountPillDressing,
                           targets: DifferenceActionTargets,
                           sorted: [FileDifference],
                           sections: [DifferenceGrouping.Section]) -> some View {
        HStack(spacing: 10) {
            countPillToggle(dressing)                           // STATE
            itemCountsReadout(facts.itemCountsText)
            ActionBarDivider()
            foldAllToggle(compaction, sections: sections)       // SCOPE
            filterMenu(compaction, sections: sections)
            selectionChip(targets)
            Spacer(minLength: 16)
            overflowMenu(compaction, targets: targets, sorted: sorted)   // ACTIONS
            if compaction < .foldVerify { verifyButton(targets) }
            if compaction < .foldReview { reviewButton(targets, sorted: sorted) }
            // `facts.isMove`, not `modifierTracker` read afresh: the ladder priced these two labels
            // from that snapshot, and "Move" is materially wider than "Copy" — at the narrow rungs it
            // is 37pt wider, because Copy sheds its verb along with its destination and Move never
            // does. Reading the tracker again here would agree in practice (same `body` pass) but
            // nothing would enforce it, and it left the whole Move vocabulary untestable: a test can
            // set a fact, and cannot reach into a private `@StateObject`.
            reverseTransferButton(compaction, isMove: facts.isMove, targets: targets)
            primaryTransferButton(compaction, isMove: facts.isMove, targets: targets)
            ActionBarDivider()
            ExpandingSearchToggle(                              // VIEW
                text: $searchText,
                isExpanded: $isSearchExpanded,
                accent: glassHue.accentColor,
                help: "Search by name or path"
            )
            collapseToggle
        }
    }

    // MARK: Header — state zone

    /// The count pill is a toggle for the per-side item totals: click to reveal them inline,
    /// click again to collapse. No-op until a scan has run (nothing meaningful to show) —
    /// so the chevron affordance is also withheld pre-scan: no invitation on a dead control.
    ///
    /// Takes its `dressing` as an argument rather than reaching for `withScanFreshness` itself: the
    /// header's whole row now sits inside that `TimelineView` so the ladder can price the age run it
    /// is about to draw (see `standardHeader`), and a second, nested subscription here would tick the
    /// pill on its own schedule.
    private func countPillToggle(_ dressing: CountPillDressing) -> some View {
        Button {
            guard syncManager.hasScanned else { return }
            withAnimation(.easeInOut(duration: 0.15)) { showItemCounts.toggle() }
        } label: {
            StatPill(
                count: syncManager.differences.count,
                label: "Differences",
                // `color` is unused on the capsule path — the fill, text and dot all come from the
                // style below. Kept as the accent so a future non-semantic use of this pill (which
                // would read it as a tint wash) doesn't inherit a stale value.
                color: glassHue.accentColor,
                systemImage: "exclamationmark.triangle",
                // Totals expand to the pill's right and collapse back left; the chevron
                // points the way the next click will send them, and is withheld pre-scan
                // (CountPillChevron owns both rules).
                trailingSystemImage: CountPillChevron.symbol(hasScanned: syncManager.hasScanned, expanded: showItemCounts),
                // The accent capsule in every state — this pill is a toggle, and a solid accent
                // capsule reads as a control the way a pale semantic wash does not. Freshness lands
                // on the age run instead. See `countPillDressing`, which owns the whole rule.
                semantic: dressing.semantic,
                detail: dressing.detail,
                spokenDetail: dressing.spokenDetail,
                detailStyle: dressing.detailStyle
            )
            // Reduce Motion suppresses the grow, matching `HoverAffordanceMetrics.resolve` — the
            // choke point this control is deliberately exempt from still sets the house rule, and
            // an edge moving out from under a settled pointer is exactly what that setting is for.
            .scaleEffect(isCountPillHovered && !reduceMotion ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            // Grow only post-scan, but always honor hover-exit: if hasScanned flips false
            // mid-hover (it resets on navigation) a gated reset would strand the pill at 1.03.
            withAnimation(.easeInOut(duration: 0.12)) {
                isCountPillHovered = hovering && syncManager.hasScanned
            }
        }
        // Two facts, two lines: what a click does, then when this was last scanned. The exact
        // timestamp only exists here — the pill's age run is bucketed and cannot answer "when?".
        .help([syncManager.hasScanned ? itemCountsText : "Scan to see per-side item totals",
               dressing.help].compactMap { $0 }.joined(separator: "\n"))
        // StatPill collapses itself to one element labeled "N Differences"; the value/hint
        // ride on the button so VoiceOver conveys the toggle state and what a click does.
        .accessibilityValue(syncManager.hasScanned ? (showItemCounts ? "expanded" : "collapsed") : "")
        .accessibilityHint(syncManager.hasScanned ? "Shows or hides the per-side item totals" : "")
    }

    /// The per-side totals, in the one place both the readout and the pill's tooltip read them —
    /// and the ladder measures them.
    private var itemCountsText: String {
        "\(syncManager.leftItemCount.formatted()) \(paneNames.left) · "
            + "\(syncManager.rightItemCount.formatted()) \(paneNames.right)"
    }

    /// The per-side totals the count pill reveals, or nothing when it is collapsed. `headerFacts`
    /// owns the "is there anything to show" rule — `hasScanned` keeps it from ever reading "0 · 0"
    /// pre-scan — and the pill's `.help` still spells out the full text on hover when this truncates.
    @ViewBuilder
    private func itemCountsReadout(_ text: String?) -> some View {
        if let text {
            Text(text)
                .scaledFont(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .transition(.opacity)
        }
    }

    // MARK: Header — scope zone

    /// The master disclosure for the table's folder sections: one click collapses every folder,
    /// one more brings them all back. `FoldAllAction` owns every rule it follows.
    ///
    /// It opens the SCOPE zone, immediately before the filter, because the sections it folds are
    /// created by "Group by folder" — which lives one click inside that filter button. The two read
    /// as one cluster: what am I looking at, and how much of it at a time.
    ///
    /// That is also why it is NOT at the trailing edge beside `collapseToggle`, which was the first
    /// placement tried. That chevron already means "collapse" in this row and it hides the entire
    /// pane; sitting next to it, the only thing distinguishing two collapse controls would be their
    /// glyphs. Here the whole bar separates them.
    ///
    /// Nothing here is a new capability — the filter menu's Expand All / Collapse All and ⌥-click
    /// on a section triangle both predate it and both still work. This is the visible door to them,
    /// and it calls the same two paths they do rather than owning a third copy of the behavior.
    @ViewBuilder
    private func foldAllToggle(_ compaction: HeaderCompaction,
                               sections: [DifferenceGrouping.Section]) -> some View {
        if FoldAllAction.isOffered(sectionCount: sections.count, compaction: compaction) {
            let action = FoldAllAction.next(collapsedOnScreen: collapsedOnScreen(sections),
                                            sectionCount: sections.count)
            Button {
                switch action {
                case .collapse: collapseAll(sections)
                case .expand: collapsedSections.removeAll()
                }
            } label: {
                Image(systemName: action.systemImage)
                    .scaledFont(.system(size: 12, weight: .semibold))
                    .hoverInk()
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverAffordance(.glyph, tint: glassHue.accentColor))
            // Both from `action`, so the tooltip and the announced name can never describe
            // different clicks.
            .help(action.title)
            .accessibilityLabel(action.title)
        }
    }

    /// How many of the sections the table is drawing are collapsed.
    ///
    /// The ONE count, read by the master toggle and by the filter menu's two items. Judged against
    /// the visible sections rather than `collapsedSections`, which can hold names for folders the
    /// active filter has since hidden — that is how "Expand All" ends up lit with nothing to expand,
    /// and how the toggle would end up offering Expand over a table of expanded rows.
    private func collapsedOnScreen(_ sections: [DifferenceGrouping.Section]) -> Int {
        sections.filter { collapsedSections.contains($0.folder) }.count
    }

    /// The filter. Drops to its glyph at `.glyphFilter`: the active filter stays checked in the
    /// menu's own column, so the name is one click away rather than gone.
    private func filterMenu(_ compaction: HeaderCompaction,
                            sections: [DifferenceGrouping.Section]) -> some View {
        let name = selectedFilter.displayName(leftName: paneNames.left, rightName: paneNames.right)
        return Menu {
            // Per-filter counts come from the DisplayRows cache: they're tallied in the same
            // detached rebuild as the rows, so the header renders that recur per file during a
            // bulk sync read six cached Ints instead of re-tallying O(differences). (A Menu's
            // content builder is NOT lazy — it's a non-escaping closure that runs on every
            // render — so computing the counts here was an every-render cost, not on-open.)
            let filterCounts = displayRows.filterCounts
            // A Picker inside a Menu gets the native menu check column; a per-row
            // checkmark-in-icon-slot Label only fakes it (and leaves the slot empty
            // on unselected rows). Same pattern as the main toolbar's Sort menu.
            Picker("Filter", selection: $selectedFilter) {
                ForEach(DifferenceFilter.allCases, id: \.self) { filter in
                    // Count appended to each dropdown row (Tidy's `Identical (312)` pattern);
                    // the collapsed menu button below stays just the active filter's name.
                    Text("\(filter.displayName(leftName: paneNames.left, rightName: paneNames.right)) (\(filterCounts[filter, default: 0]))")
                        .tag(filter)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Divider()
            // Grouping lives in the filter menu rather than earning chrome of its own: it is a
            // scope decision like the filter above it, and the header has no width to spare.
            Toggle("Group by folder", isOn: $groupByFolder)
            if !sections.isEmpty {
                // Enabled states are judged against the sections actually on screen (see
                // `collapsedOnScreen`, which the header's master toggle reads too — one count, so
                // the menu and the button cannot disagree about what is folded).
                let collapsedCount = collapsedOnScreen(sections)
                Button("Expand All") { collapsedSections.removeAll() }
                    .disabled(collapsedCount == 0)
                Button("Collapse All") { collapseAll(sections) }
                    .disabled(collapsedCount == sections.count)
            }
        } label: {
            if compaction < .glyphFilter {
                // Uncapped provider names can be long; truncate instead of forcing the
                // full width (fixedSize) and clipping the header on narrow windows.
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(name).lineLimit(1).truncationMode(.middle)
                    // The system indicator is hidden below so the glyph-only form stays a circle;
                    // the full form draws its own, matching the count pill's trailing chevron.
                    Image(systemName: "chevron.down").scaledFont(.system(size: 9, weight: .semibold))
                }
            } else {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
        }
        .menuStyle(.button)
        .buttonStyle(.actionBar(.outline, tint: glassHue.accentColor,
                                onTint: glassHue.onAccentLabelColor,
                                iconOnly: compaction >= .glyphFilter))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter the list — showing \(name)")
    }

    /// The selection chip lives beside the filter, not in the action run: both answer "acting on
    /// what?", and in the action run it read as a fourth button.
    @ViewBuilder
    private func selectionChip(_ targets: DifferenceActionTargets) -> some View {
        if targets.isSelectionScoped {
            Button {
                selection.removeAll()
            } label: {
                HStack(spacing: 5) {
                    Text("\(targets.targets.count) selected")
                    Image(systemName: "xmark.circle.fill")
                }
            }
            .buttonStyle(.actionBar(.quiet, tint: glassHue.accentColor,
                                    onTint: glassHue.onAccentLabelColor))
            .help("Clear selection")
        }
    }

    // MARK: Header — action zone

    /// The overflow, present only once the row has actually folded something into it.
    ///
    /// A permanently visible ⋯ is a control that does nothing at full width; one that appears as
    /// the window narrows appears exactly when it has contents. It holds only what the row shed —
    /// it is an overflow, not a second home for actions that already have a button.
    @ViewBuilder
    private func overflowMenu(_ compaction: HeaderCompaction,
                              targets: DifferenceActionTargets,
                              sorted: [FileDifference]) -> some View {
        let foldedReview = compaction >= .foldReview && !targets.targets.isEmpty
        let foldedVerify = compaction >= .foldVerify && targets.verifiableCount > 0
        if foldedReview || foldedVerify {
            Menu {
                if foldedReview {
                    Button { startReview(targets: targets, sorted: sorted) } label: {
                        Label(reviewTitle(targets), systemImage: "checklist")
                    }
                    .disabled(isSyncActionBlocked)
                }
                if foldedVerify {
                    Button { verify(targets: targets) } label: {
                        Label("Verify \(targets.verifiableCount)", systemImage: "checkmark.shield")
                    }
                    .disabled(isSyncActionBlocked)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.actionBar(.outline, tint: glassHue.accentColor,
                                    onTint: glassHue.onAccentLabelColor, iconOnly: true))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
    }

    /// Always carries the count, scoped or not.
    ///
    /// A bare "Review" said nothing about how much it was about to queue, and the count only
    /// appeared once a selection scoped it — so the number showed up exactly when it was SMALL and
    /// was absent when it was large. That is backwards: `Review started: 1 item(s) (selection)`
    /// against a scan of 123 is the failure this fixes, and a user who has seen "Review 123" once
    /// reads a later "Review 1" as a change rather than as a plain fact.
    private func reviewTitle(_ targets: DifferenceActionTargets) -> String {
        "Review \(targets.targets.count)"
    }

    @ViewBuilder
    private func reviewButton(_ targets: DifferenceActionTargets, sorted: [FileDifference]) -> some View {
        if !targets.targets.isEmpty {
            Button {
                startReview(targets: targets, sorted: sorted)
            } label: {
                // No ellipsis: it is macOS shorthand for "opens a dialog", and this starts an
                // inline review in the pane below.
                Label(reviewTitle(targets), systemImage: "checklist")
            }
            .buttonStyle(.actionBar(.outline, tint: glassHue.accentColor,
                                    onTint: glassHue.onAccentLabelColor))
            .disabled(isSyncActionBlocked)
            .help("Step through each difference one at a time — hold ⇧ or ⌘ to move instead of copy")
        }
    }

    @ViewBuilder
    private func verifyButton(_ targets: DifferenceActionTargets) -> some View {
        if targets.verifiableCount > 0 {
            Button {
                verify(targets: targets)
            } label: {
                Label("Verify \(targets.verifiableCount)", systemImage: "checkmark.shield")
            }
            .buttonStyle(.actionBar(.outline, tint: glassHue.accentColor,
                                    onTint: glassHue.onAccentLabelColor))
            .disabled(isSyncActionBlocked)
            // Same explanation as the review card's Verify, scoped to what the bulk run
            // actually covers: only date-only differences whose sizes match are checksummed.
            .help("Checksum both sides of each same-size, date-only difference to confirm whether the contents actually differ")
        }
    }

    /// The reverse transfer, drawn BEFORE the primary so the two buttons sit in the same order as
    /// the panes they target — the header used to render right-then-left, putting "to Dropbox"
    /// (the right pane) to the left of "to iCloud" (the left pane).
    @ViewBuilder
    private func reverseTransferButton(_ compaction: HeaderCompaction,
                                       isMove: Bool,
                                       targets: DifferenceActionTargets) -> some View {
        if targets.copyToLeftCount > 0 {
            transferButton(
                direction: .copyToLeft,
                count: targets.copyToLeftCount,
                destination: paneNames.left,
                // `dominantCopyDirection` no longer decides which button is prominent — the layout
                // does. It answers a smaller question now: is the quiet direction actually the bulk
                // of the work, and therefore the thing this row must not swallow?
                namesDestination: BulkActionLabel.reverseNamesDestination(
                    reverseIsMajority: targets.dominantCopyDirection == .copyToLeft,
                    compaction: compaction),
                // A lone action takes the fill whichever way it points: the fixed direction decides
                // which of TWO buttons is primary, not whether a bar gets a primary at all.
                weight: targets.copyToRightCount > 0 ? .quiet : .primary,
                isMove: isMove,
                targets: targets)
        }
    }

    /// The primary. Always left-to-right, whatever the counts say — see `TransferGlyph`'s type doc
    /// and the header doc above. A copy overwrites files at its destination; which way the biggest
    /// button on the bar sends them should not change between two scans you didn't act on.
    @ViewBuilder
    private func primaryTransferButton(_ compaction: HeaderCompaction,
                                       isMove: Bool,
                                       targets: DifferenceActionTargets) -> some View {
        if targets.copyToRightCount > 0 {
            transferButton(
                direction: .copyToRight,
                count: targets.copyToRightCount,
                destination: paneNames.right,
                namesDestination: BulkActionLabel.primaryNamesDestination(compaction: compaction),
                weight: .primary,
                isMove: isMove,
                targets: targets)
        }
    }

    private func transferButton(direction: FileDifference.SyncAction,
                                count: Int,
                                destination: String,
                                namesDestination: Bool,
                                weight: ActionBarWeight,
                                isMove: Bool,
                                targets: DifferenceActionTargets) -> some View {
        let toRight = direction == .copyToRight
        return Button {
            copy(direction: direction, targets: targets)
        } label: {
            Label(
                BulkActionLabel.text(count: count,
                                     destination: namesDestination ? destination : nil,
                                     isMove: isMove),
                // Direction is fixed for this button, so it belongs in the icon: a bare arrow for
                // copy, the boxed arrow for move, both pointing at the target pane.
                systemImage: isMove ? TransferGlyph.move(toRight: toRight) : TransferGlyph.copy(toRight: toRight)
            )
        }
        .buttonStyle(.actionBar(weight, tint: glassHue.accentColor,
                                onTint: glassHue.onAccentLabelColor))
        .disabled(isSyncActionBlocked)
        // The label may shed the destination; the tooltip never does, and it always names the verb.
        .help(BulkActionLabel.help(count: count, destination: destination, isMove: isMove))
        // …and neither does the accessible name. The visible label names both verbs while it has
        // room, but Copy sheds its verb along with the destination as the row tightens, so at the
        // narrow rungs it reads just "12" — which would leave a VoiceOver user unable to tell Copy
        // from Move, the one pair where the difference is whether the source survives. An icon and
        // a tooltip are not announced; the name is.
        .accessibilityLabel(BulkActionLabel.help(count: count, destination: destination, isMove: isMove))
    }

    /// The header's review-mode trailing controls: position pill, running tally, and the
    /// session-level actions (finish the rest in bulk, or exit).
    @ViewBuilder
    private func reviewHeaderControls(_ session: ReviewSession) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(glassHue.accentColor)
                .frame(width: 7, height: 7)
            Text("Reviewing \(session.position) of \(session.total)")
                .scaledFont(PillVariant.standard.numberFont)
                .monospacedDigit()
                .foregroundStyle(glassHue.accentColor)
        }
        .pillSurface(.standard, tint: glassHue.accentColor)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reviewing \(session.position) of \(session.total)")
        Spacer()
        if session.copiedCount + session.skippedCount > 0 {
            Text("\(session.copiedCount) \(session.isMove ? "moved" : "copied") · \(session.skippedCount) skipped")
                .scaledFont(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        let pendingCount = session.pending.count
        if pendingCount > 1 {
            Button {
                copyRemaining(session)
            } label: {
                // Share the copy/move action vocabulary (TransferGlyph) like the other bulk
                // buttons; "Remaining" resolves each item in its own direction, so it's the
                // non-directional copy/move glyph rather than a single-direction arrow.
                Label("\(session.isMove ? "Move" : "Copy") Remaining \(pendingCount)…",
                      systemImage: session.isMove ? TransferGlyph.move : TransferGlyph.copy)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.actionBar(.outline, tint: glassHue.accentColor,
                                    onTint: glassHue.onAccentLabelColor))
            // Gated while the current item's copy runs: that item is still undecided (in
            // `pending`), so handing the remainder to syncAll now would target it twice.
            .disabled(reviewStore.isActing || isSyncActionBlocked)
            .help("\(session.isMove ? "Move" : "Copy") every remaining item without further review")
        }
        Button {
            exitReview()
        } label: {
            Label("Exit Review", systemImage: "xmark.circle")
        }
        .buttonStyle(.actionBar(.outline, tint: glassHue.accentColor,
                                onTint: glassHue.onAccentLabelColor))
        .help("Stop reviewing (esc)")
    }

    // MARK: Table sections

    /// The review-mode table card content: the docked review card above the frozen-queue table.
    @ViewBuilder
    private func reviewSection(_ session: ReviewSession) -> some View {
        ReviewCardView(
            session: session,
            paneNames: paneNames,
            accent: glassHue.accentColor,
            fileManager: syncManager.fileManager,
            onQuickLook: onQuickLook,
            isActing: reviewStore.isActing,
            focusNudge: reviewFocusNudge,
            onPrimary: { reviewPrimary($0) },
            onSkip: { reviewSkip($0) },
            onVerdict: { reviewVerdict($1, for: $0, token: $2) },
            onExit: { exitReview() }
        )
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
        reviewTable(session: session)
    }

    /// The frozen review queue: same cells as the live table, but unsorted (review order is the
    /// order captured at entry), with the direction column swapped for per-item status. Native
    /// selection doubles as the "current item" highlight (see the `reviewSelection` onChange).
    private func reviewTable(session: ReviewSession) -> some View {
        let compact = listDensity == .compact
        return Table(session.queue, selection: $reviewSelection) {
            TableColumn("Name") { DifferenceNameCell(difference: $0, compact: compact, paneRules: paneRules, keptNames: keptNames) }
            TableColumn("Change") { DifferenceChangeCell(difference: $0, compact: compact) }
            TableColumn("Size") { DifferenceSizeCell(difference: $0, compact: compact) }
                .width(min: 70, ideal: 90)
            TableColumn("Status") { ReviewStatusCell(difference: $0, session: session) }
                .width(min: 96, ideal: 140)
        }
        .scrollContentBackground(.hidden)
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .listDensity(listDensity)
        // The status cell's "Reviewing" marker and the selection highlight follow the app hue.
        .tint(glassHue.accentColor)
        .contextMenu(forSelectionType: FileDifference.ID.self) { ids in
            // Inspection only mid-review: no ignore toggle (it edits the live list, not the
            // frozen queue) and no bulk copy/move (that's what the review itself is for).
            if ids.count == 1, let id = ids.first,
               let difference = session.queue.first(where: { $0.id == id }) {
                inspectionMenuItems(for: difference)
            }
        }
    }

    /// The normal table card content: bulk-op progress rows above the live differences table.
    @ViewBuilder
    private func standardTableSection(sorted: [FileDifference],
                                      sections: [DifferenceGrouping.Section]) -> some View {
        if let progress = syncManager.verifyAllProgress {
            syncProgressRow(verb: "Verifying", completed: progress.completed, total: progress.total)
        }
        if let progress = syncManager.bulkSyncProgress {
            syncProgressRow(verb: "Syncing", completed: progress.completed, total: progress.total)
        }
        // Rows going the same way as the bulk of the list quiet their direction chip; the
        // majority is read over the whole visible list, not the selection.
        let bulkDirection = DifferencesQuery.bulkCopyDirection(sorted)
        let compact = listDensity == .compact
        // `sections` is empty when grouping is off OR when it would not be worth it — both gates
        // live in `groupedSections`, so this asks one question. Read here, once, by both the Name
        // column and the rows builder, so the column cannot disagree with the shape it is drawing.
        let grouped = !sections.isEmpty
        // ONE Table, whichever shape the rows take.
        //
        // This used to be two Tables behind an `if` — `Table(of:selection:sortOrder:columns:rows:)`
        // for the sectioned form and `Table(_:selection:sortOrder:)` for the flat one. Two
        // initializers are two view identities, so every toggle of "Group by folder" tore one down
        // and built the other, discarding dragged column widths and scroll position. That was not
        // a rare event: `isWorthGrouping` requires sections to average >= 3 rows, and a bulk sync
        // consumes rows as it runs, so a long copy can cross the threshold and reshuffle the table
        // mid-operation.
        //
        // The fix is to never use the collection initializer: `Table(of:)` takes an explicit rows
        // builder, and @TableRowBuilder supports if/else, so ONE Table can emit either sectioned or
        // unsectioned rows. Nothing is lost by dropping `Table(sorted, ...)` — its implicit sorting
        // was already unused, because `sorted` arrives pre-sorted from the `.task(id:)` in `body`
        // and `sortOrder` is bound here only to drive the header chevrons.
        //
        // The columns being defined once is the point, not a bonus: they were duplicated verbatim
        // across both branches with nothing pinning them identical, and they had ALREADY drifted —
        // the Name column passed `grouped: true` in the sectioned branch and defaulted in the flat
        // one. Sharing them makes that class of drift unrepresentable.
        Table(of: FileDifference.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.fileName, comparator: .localizedStandard) { DifferenceNameCell(difference: $0, compact: compact, grouped: grouped, paneRules: paneRules, keptNames: keptNames) }
            TableColumn("Change", value: \.changeSortRank) { DifferenceChangeCell(difference: $0, compact: compact) }
            TableColumn("Size", value: \.displaySizeSort) { DifferenceSizeCell(difference: $0, compact: compact) }
                .width(min: 70, ideal: 90)
            TableColumn("Copy to", value: \.copyToSortRank) { DifferenceDirectionCell(difference: $0, paneNames: paneNames, bulkDirection: bulkDirection) }
                .width(min: 96, ideal: 140)
        } rows: {
            if grouped {
                ForEach(sections) { section in
                    let isCollapsed = collapsedSections.contains(section.folder)
                    SwiftUI.Section {
                        // Collapsing is "emit no rows". The header is a separate slot, so it
                        // survives an empty section — verified by `collapsedSectionKeepsItsHeader`
                        // rather than assumed, because a collapsed folder VANISHING instead of
                        // collapsing would be the obvious way for this to fail.
                        ForEach(isCollapsed ? [] : section.rows) { TableRow($0) }
                    } header: {
                        DifferenceSectionHeader(
                            // `title`, not `folder`: the latter is the bucket identity (the root
                            // bucket is spelled "/"), and only `title` turns it into words.
                            folder: section.title,
                            count: section.count,
                            accent: glassHue.accentColor,
                            isFullySelected: DifferenceGrouping.isFullySelected(section, in: selection),
                            isCollapsed: isCollapsed,
                            // Only the collapsed form shows this, and it is an O(rows) tally —
                            // computing it for expanded sections would walk the entire diff on
                            // every render, which during a bulk sync means per copied file.
                            directionSummary: isCollapsed
                                ? section.directionSummary(leftName: paneNames.left,
                                                           rightName: paneNames.right)
                                : "",
                            onToggleCollapse: { toggleCollapse(section, allSections: sections) },
                            onSelect: { selectSection(section) })
                    }
                }
            } else {
                ForEach(sorted) { TableRow($0) }
            }
        }
        // Let the surface fill below show through: hide the scroll background AND the
        // alternating row fills, or the Table paints opaque (white) rows over the surface.
        .scrollContentBackground(.hidden)
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .listDensity(listDensity)
        .contextMenu(forSelectionType: FileDifference.ID.self) { ids in
            differenceContextMenu(for: ids, in: sorted)
        }
        .overlay {
            // hasComputedRows: the rows land asynchronously (see the .task(id:) in body), so the
            // first beat after mounting must show a blank table, not a wrong "No differences".
            if sorted.isEmpty, hasComputedRows {
                emptyState
            }
        }
        // Directional Copy/Move on the selection: ⌘→/⌘← copy, ⇧ makes it a move. Scoped to the
        // Table subtree via .onKeyPress (NOT a window-level .keyboardShortcut, which is consulted
        // before the first responder and would hijack ⌘→ typed into the search field). Fires
        // only while key focus is inside the table, so the search field keeps ⌘→ for its cursor.
        // A bare arrow (no ⌘) returns .ignored so the Table's own row navigation is untouched.
        .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .down) { press in
            guard let intent = KeyboardCopyIntent.from(key: press.key, modifiers: press.modifiers) else {
                return .ignored
            }
            keyboardCopy(direction: intent.direction, isMove: intent.isMove, in: sorted)
            return .handled
        }
        // Marks this table as the surface the user means, so Space can tell a Differences
        // selection from a pane one. Only a non-empty selection claims it: a clear (the ✕ chip,
        // a rescan dropping the row) says "not this any more", and letting it claim the token
        // would point Space at a table holding nothing.
        .onChange(of: selection) { _, newSelection in
            guard !newSelection.isEmpty else { return }
            if syncManager.lastSelectionSurface != .differences {
                syncManager.lastSelectionSurface = .differences
            }
        }
        // Quick Look on plain Space — and the one handler that has to arbitrate.
        //
        // `.onKeyPress` is strictly focus-scoped (measured): only the handler in the subtree
        // holding the first responder runs, siblings never both see the event, and `.ignored`
        // does not fall through to a sibling. This table keeps key focus while it is on screen —
        // a pane row click does not take it away — so with the bottom pane open, Space arrives
        // HERE even when the user is working in a pane and the panes' own handler is never
        // consulted. That is why "Space previewed the Differences row while the Info inspector
        // showed the pane file": the panes' handler was correct and simply starved.
        //
        // So this asks `CurrentSelection` rather than assuming the answer is its own row.
        // `singleSource: false` unconditionally: `compareBottomListActive` gates this whole view
        // to Compare, and Tidy shows `TidyView` instead, so the rail's hidden-right-pane case
        // cannot reach here.
        .onKeyPress(.space) {
            guard let onQuickLook, let targetPath = DifferencesQuery.spaceQuickLookTarget(
                lastInteracted: syncManager.lastSelectionSurface,
                leftSelection: syncManager.selectedLeftPaths,
                rightSelection: syncManager.selectedRightPaths,
                rows: sorted,
                selection: selection
            ) else { return .ignored }
            onQuickLook(URL(fileURLWithPath: targetPath))
            return .handled
        }
    }

    // MARK: Section headers

    /// Applies a header click to the selection. ⌘ is read at click time from `NSEvent` rather than
    /// tracked, the same one-shot read the drop handler and the transfer buttons use — a published
    /// modifier stream can be a frame stale, and this decides between "replace everything" and
    /// "add to what you have".
    private func selectSection(_ section: DifferenceGrouping.Section) {
        let intent = SectionClickIntent.resolve(
            commandHeld: NSEvent.modifierFlags.contains(.command),
            isFullySelected: DifferenceGrouping.isFullySelected(section, in: selection))
        selection = DifferenceGrouping.selection(after: intent, section: section, current: selection)
    }

    /// Toggles one section — or, with ⌥ held, every section at once. ⌥-click on a disclosure
    /// triangle is the Finder gesture for "do this to all of them"; it costs nothing and the menu
    /// items carry the same actions for anyone who doesn't know it.
    private func toggleCollapse(_ section: DifferenceGrouping.Section,
                                allSections: [DifferenceGrouping.Section]) {
        guard !NSEvent.modifierFlags.contains(.option) else {
            // Match the clicked section's NEW state, so ⌥-collapsing an expanded folder collapses
            // everything and ⌥-expanding a collapsed one expands everything.
            if collapsedSections.contains(section.folder) {
                collapsedSections.removeAll()
            } else {
                collapsedSections = Set(allSections.map(\.folder))
            }
            return
        }
        if collapsedSections.contains(section.folder) {
            collapsedSections.remove(section.folder)
        } else {
            collapsedSections.insert(section.folder)
        }
    }

    /// The sections the table will draw for `sorted`, or empty when it will draw a flat list.
    ///
    /// The ONE derivation. The rows builder and the Expand/Collapse All menu items were computing
    /// it separately, which is how a menu ends up collapsing a different set of folders than the
    /// table is showing, the moment their inputs drift apart. Returning empty for "not worth
    /// grouping" folds that gate in here too, so no caller can forget it.
    private func groupedSections(_ sorted: [FileDifference]) -> [DifferenceGrouping.Section] {
        guard groupByFolder else { return [] }
        let sections = DifferenceGrouping.sections(sorted)
        return DifferenceGrouping.isWorthGrouping(sections) ? sections : []
    }

    /// Collapses every section on screen.
    private func collapseAll(_ sections: [DifferenceGrouping.Section]) {
        collapsedSections = Set(sections.map(\.folder))
    }

    // MARK: Review lifecycle

    /// Enters review mode over the current action targets, in visible table order. The move
    /// modifier is read here, at entry, and fixed for the whole session (the card and header
    /// relabel to Move) — unlike the bulk buttons there's no long-lived press to track.
    private func startReview(targets: DifferenceActionTargets, sorted: [FileDifference]) {
        let targetIds = Set(targets.targets.map(\.id))
        let queue = sorted.filter { targetIds.contains($0.id) }
        guard let session = ReviewSession(queue: queue, isMove: ModifierTracker.moveModifierHeld) else { return }
        Logger.shared.debug(
            "Review started: \(queue.count) item(s)"
            + "\(session.isMove ? " (move)" : "")"
            + " (\(targets.isSelectionScoped ? "selection" : "filtered set"))")
        reviewStore.session = session
        selection.removeAll()
        reviewSelection = queue.first.map { [$0.id] } ?? []
    }

    /// Copy/Move the given review item through the same per-item path as a table row action —
    /// collision prompts and the retryable failure alert work unchanged. The outcome comes from
    /// `syncFile`'s return value, NOT from inspecting the differences list: the post-operation
    /// rescan regenerates row UUIDs mid-session, which would make any list-based check lie.
    private func reviewPrimary(_ item: FileDifference) {
        guard let session = reviewStore.session, !reviewStore.isActing else { return }
        reviewStore.isActing = true; let token = session.sessionToken
        let isMove = session.isMove
        Logger.shared.debug("Review \(isMove ? "move" : "copy"): \(item.relativePath)")
        Task { @MainActor in
            // The token is captured above, synchronously with the click — NOT inside this Task.
            // Exiting review and starting a new session over the same un-rescanned set keeps the
            // difference ids, so only the token can tell the store this outcome belongs to the
            // torn-down session; re-reading it after this hop would read the replacement's token
            // and stamp the old session's item into the new queue. `decide` also clears
            // `isActing` on every exit.
            let applied = await reviewStore.decide(for: item.id, token: token) {
                // confirmed: the review card IS the per-item confirmation UI — re-running the
                // transferConfirmer here doubled every accept, and an Escape on that redundant
                // prompt was recorded as a deliberate Skip in the session tally.
                let succeeded = await syncManager.syncFile(item, isMove: isMove, confirmed: true)
                // Not copied = failure or Skip at the collision prompt; both already told the user.
                return succeeded ? .copied : .skipped
            }
            if applied, reviewStore.session?.isComplete == true { finishReview() }
        }
    }

    private func reviewSkip(_ item: FileDifference) {
        guard let session = reviewStore.session, !reviewStore.isActing else { return }
        applyReviewOutcome(.skipped, for: item.id, token: session.sessionToken)
    }

    /// The one place session outcomes land. Id-addressed and token-guarded in the store (see
    /// `ReviewSessionStore.apply`) — a decision arriving after Exit tore the session down is
    /// dropped instead of resurrecting it, or worse, advancing a REPLACEMENT session whose
    /// queue happens to carry the same ids.
    private func applyReviewOutcome(_ outcome: ReviewSession.Outcome, for id: UUID, token: UUID) {
        guard reviewStore.apply(outcome, for: id, token: token) else { return }
        if reviewStore.session?.isComplete == true { finishReview() }
    }

    /// Records a per-item Verify verdict; same token guard as outcomes.
    private func reviewVerdict(_ verdict: ReviewSession.VerifyVerdict, for id: UUID, token: UUID) {
        reviewStore.recordVerdict(verdict, for: id, token: token)
    }

    /// Tears the session down after the last item was decided, summarizing into a banner.
    private func finishReview() {
        guard let session = reviewStore.session else { return }
        let verb = session.isMove ? "moved" : "copied"
        Logger.shared.info("Review complete: \(session.copiedCount) \(verb), \(session.skippedCount) skipped of \(session.total)")
        syncManager.banner = .success("Review complete — \(session.copiedCount) \(verb), \(session.skippedCount) skipped")
        reviewStore.session = nil
        reviewSelection = []
    }

    /// Exits mid-review (Esc / the header button), summarizing what already happened when
    /// anything did.
    private func exitReview() {
        guard let session = reviewStore.session else { return }
        Logger.shared.debug("Review exited at \(session.position) of \(session.total)")
        // Summarize whenever the user made ANY decision — a skip-only pass (nothing copied) still
        // resolved rows, so it shouldn't exit silently the way a copy-containing pass summarizes.
        if session.copiedCount > 0 || session.skippedCount > 0 {
            let verb = session.isMove ? "moved" : "copied"
            syncManager.banner = .success("Review ended — \(session.copiedCount) \(verb), \(session.skippedCount) skipped, \(session.pending.count) not reviewed")
        }
        reviewStore.session = nil
        reviewSelection = []
    }

    /// "Copy Remaining N…": leaves review mode and resolves every still-pending item through
    /// the existing bulk path (or the single-item path, whose failure alert carries Retry).
    private func copyRemaining(_ session: ReviewSession) {
        let remaining = session.pending
        let isMove = session.isMove
        Logger.shared.debug("Review: \(isMove ? "move" : "copy") remaining \(remaining.count) item(s)")
        reviewStore.session = nil
        reviewSelection = []
        // confirmed: the "Copy Remaining N…" button names the exact count and lives inside
        // review mode — it IS the confirmation. Prompting per syncAll call asked twice for a
        // mixed-direction remainder (with partial counts that never matched the button), and
        // declining the second prompt silently dropped items after the session was torn down.
        if remaining.count == 1, let single = remaining.first {
            Task { await syncManager.syncFile(single, isMove: isMove, confirmed: true) }
            return
        }
        let hasRight = remaining.contains { $0.action == .copyToRight }
        let hasLeft = remaining.contains { $0.action == .copyToLeft }
        if hasRight && hasLeft {
            // A mixed-direction remainder needs two sequential syncAll runs (each takes one
            // direction) — two separate undo groups, so no single Undo reverses both. Suppress
            // their per-run completion banners: the second would overwrite the first with an
            // undercount, and its Undo would silently reverse only its own half. This path had no
            // completion banner before the Undo feature anyway; the resolved rows disappearing is
            // the feedback.
            Task {
                await syncManager.syncAll(direction: .copyToRight, isMove: isMove, subset: remaining, confirmed: true, postBanner: false)
                await syncManager.syncAll(direction: .copyToLeft, isMove: isMove, subset: remaining, confirmed: true, postBanner: false)
            }
        } else {
            // Single direction: one run, which posts its own (undoable) completion banner.
            let direction: FileDifference.SyncAction = hasRight ? .copyToRight : .copyToLeft
            Task { await syncManager.syncAll(direction: direction, isMove: isMove, subset: remaining, confirmed: true) }
        }
    }

    /// The "<verb> N of M…" progress row shown above the table during a bulk op, with a Cancel
    /// button while the active operation is cancellable. Shared by the Verify and Sync passes —
    /// the only difference is the leading verb — so the two stay identical by construction.
    @ViewBuilder
    private func syncProgressRow(verb: String, completed: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(verb) \(completed) of \(total)...")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let activeProgress = syncManager.activeProgress, activeProgress.isCancellable {
                    Button {
                        activeProgress.cancel()
                    } label: {
                        Text("Cancel")
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.hoverAffordance(.segment, tint: glassHue.accentColor))
                    .scaledFont(.caption)
                }
            }
            ProgressView(value: Double(completed), total: Double(total))
                .progressViewStyle(.linear)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    /// Inline search field (second header row): the query, a clear button, and a live "N of M"
    /// match count — plus, below, the parsed filter tokens (removable) and, while focused,
    /// one-tap suggestions. Typing `kind:pdf`, `>10mb`, or `only:left` narrows the list; anything
    /// else is a plain path substring, exactly as before.
    ///
    /// The field, its clear button, its Escape handling and its focus-on-appear are Design's
    /// `ExpandingSearchField` — this view is where that mechanism came from, and it adopts the
    /// extraction rather than keeping the original alongside five copies of it. What stays here
    /// is what's genuinely Compare's: the "N of M" against the unfiltered total, and the chips /
    /// suggestions, whose labels name the live panes ("only on iCloud").
    private func searchField(filteredCount: Int) -> some View {
        let tokens = DifferenceSearch.parse(searchText).tokens
        let chips = DifferenceSearch.chips(searchText)
        return ExpandingSearchField(
            text: $searchText,
            isExpanded: $isSearchExpanded,
            placeholder: "Search — try kind:pdf, >10mb, only:left",
            trailing: {
                if selectedFilter != .all || !searchText.isEmpty {
                    Text("\(filteredCount) of \(syncManager.differences.count)")
                        .scaledFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            },
            accessories: { isFocused in
                if !chips.isEmpty {
                    tokenChips(chips)
                }
                if isFocused {
                    suggestionRow(active: tokens)
                }
            }
        )
    }

    /// The recognized filter words as removable chips (Design's shared `TokenChipsRow`): a human
    /// reading of the query, each with an ✕ that edits its exact word back out of the raw text —
    /// mirroring the Tidy search's chips. The labels stay this view's `tokenLabel` because the
    /// `only:` chips name the live panes.
    private func tokenChips(_ chips: [DifferenceSearch.Chip]) -> some View {
        HStack(spacing: 6) {
            TokenChipsRow(
                items: chips.map { TokenChipsRow.Item(label: tokenLabel($0.token), word: $0.raw, isActive: $0.isActive) },
                tint: glassHue.accentColor,
                onRemove: { word in searchText = DifferenceSearch.removing(searchText, word: word) }
            )
            Spacer(minLength: 0)
        }
    }

    private func tokenLabel(_ token: DifferenceSearch.Token) -> String {
        switch token {
        case .kind(let ext): return "kind: \(ext)"
        case .sizeAtLeast(let bytes): return "> \(FileSyncManager.formatBytes(bytes))"
        case .sizeAtMost(let bytes): return "< \(FileSyncManager.formatBytes(bytes))"
        case .onlyLeft: return "only on \(paneNames.left)"
        case .onlyRight: return "only on \(paneNames.right)"
        }
    }

    /// One-tap filter suggestions shown while the field is focused, omitting any already active.
    @ViewBuilder
    private func suggestionRow(active: [DifferenceSearch.Token]) -> some View {
        let suggestions = searchSuggestions(active: active)
        if !suggestions.isEmpty {
            HStack(spacing: 6) {
                Text("Add filter")
                    .scaledFont(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                ForEach(suggestions, id: \.raw) { suggestion in
                    Button {
                        // Trim first so appending never leaves a double space when the field already
                        // ends in whitespace (leading/trailing spaces are meaningless to the query).
                        let base = searchText.trimmingCharacters(in: .whitespaces)
                        searchText = base.isEmpty ? suggestion.raw : base + " " + suggestion.raw
                    } label: {
                        Text(suggestion.label)
                            .scaledFont(.caption2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary.opacity(0.6)))
                            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
                    }
                    .buttonStyle(.hoverAffordance(.segment, tint: glassHue.accentColor))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func searchSuggestions(active: [DifferenceSearch.Token]) -> [(label: String, raw: String)] {
        let candidates: [(label: String, raw: String, token: DifferenceSearch.Token)] = [
            ("only on \(paneNames.left)", "only:left", .onlyLeft),
            ("only on \(paneNames.right)", "only:right", .onlyRight),
            ("PDFs", "kind:pdf", .kind("pdf")),
            ("larger than 10 MB", ">10mb", .sizeAtLeast(10_000_000)),
        ]
        return candidates
            .filter { !active.contains($0.token) }
            .map { (label: $0.label, raw: $0.raw) }
    }

    // MARK: Header actions

    /// Fires a header Copy/Move on the current action targets (selection when any, else the
    /// filtered set).
    private func copy(direction: FileDifference.SyncAction, targets: DifferenceActionTargets) {
        runCopyOrMove(
            direction: direction,
            items: targets.targets.filter { $0.action == direction },
            scope: targets.isSelectionScoped ? "selection" : "filtered set"
        )
    }

    /// The keyboard shortcut's Copy/Move: the same dispatch as the header's `copy`, but strictly
    /// scoped to the current selection (a no-op when nothing is selected — never a surprise copy
    /// of the whole list) and with the move flag taken from ⇧ rather than the global move
    /// modifier (⌘ is always held for this chord, so `ModifierTracker` would read every ⌘→ as a
    /// move). Filters to the rows whose `.action` matches the pressed direction, exactly like the
    /// header. Respects the same in-flight gate the header buttons disable on.
    private func keyboardCopy(direction: FileDifference.SyncAction, isMove: Bool, in sorted: [FileDifference]) {
        guard !selection.isEmpty, !isSyncActionBlocked else { return }
        let items = sorted.filter { selection.contains($0.id) && $0.action == direction }
        guard !items.isEmpty else { return }
        runCopyOrMove(direction: direction, items: items, scope: "selection", isMove: isMove)
    }

    /// One Copy/Move dispatch shared by the header buttons and the bulk context menu, so
    /// their wiring can't drift. Reads the move modifier at invocation, not at view/menu
    /// build — an NSMenu that stays open across a modifier change would otherwise fire the
    /// stale action (drag & drop reads the modifier at drop time for the same reason).
    /// A single item goes through `syncFile`, whose failure alert carries a working Retry
    /// handler; `syncAll` (which offers no Retry) is only for genuine multi-item runs.
    /// `isMove` overrides the live move-modifier read — the keyboard shortcut passes ⇧ explicitly
    /// (⌘ is always held for its chord); the header and context menu omit it to read the modifier.
    private func runCopyOrMove(direction: FileDifference.SyncAction, items: [FileDifference], scope: String, isMove overrideMove: Bool? = nil) {
        let isMove = overrideMove ?? ModifierTracker.moveModifierHeld
        Logger.shared.debug(
            "Bulk \(isMove ? "move" : "copy") \(direction == .copyToRight ? "to right" : "to left"): "
            + "\(items.count) item(s) (\(scope))")
        if items.count == 1, let single = items.first {
            Task { await syncManager.syncFile(single, isMove: isMove) }
        } else {
            Task { await syncManager.syncAll(direction: direction, isMove: isMove, subset: items) }
        }
    }

    /// Fires Verify on the current action targets; `verifyAllWithChecksum` keeps only the
    /// verifiable (date-only, same-size) differences from the subset.
    private func verify(targets: DifferenceActionTargets) {
        Logger.shared.debug(
            "Bulk verify: \(targets.verifiableCount) item(s) "
            + "(\(targets.isSelectionScoped ? "selection" : "filtered set"))")
        Task { await syncManager.verifyAllWithChecksum(subset: targets.targets) }
    }

    // MARK: Empty state

    /// The table's blank overlay, on the app's unified empty-state template (H3). The filtered-to-
    /// empty branches offer one click out (mirroring Tidy's "Clear Filters") instead of a blank
    /// table that reads like there are no differences.
    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No matches",
                message: "No differences match “\(searchText)”.",
                primary: .init("Clear Filters", systemImage: "xmark.circle") {
                    searchText = ""
                    selectedFilter = .all
                }
            )
        } else if selectedFilter != .all {
            EmptyStateView(
                icon: "line.3.horizontal.decrease.circle",
                title: "No matches",
                message: "No items match the current filter.",
                primary: .init("Clear Filters", systemImage: "xmark.circle") {
                    selectedFilter = .all
                }
            )
        } else {
            EmptyStateView(
                icon: "line.3.horizontal.decrease.circle",
                title: "No differences"
            )
        }
    }

    // MARK: Context menu

    /// Right-click menu for the table selection: the full per-row menu (#14) when a single row
    /// is targeted, or bulk Copy/Move/Ignore for a multi-row selection. `visible` is the sorted,
    /// filtered list the ids index into.
    @ViewBuilder
    private func differenceContextMenu(for ids: Set<FileDifference.ID>, in visible: [FileDifference]) -> some View {
        if ids.count == 1, let id = ids.first, let difference = visible.first(where: { $0.id == id }) {
            singleRowMenu(for: difference)
        } else if ids.count > 1 {
            bulkMenu(for: visible.filter { ids.contains($0.id) })
        }
    }

    /// Per-row menu (#14): the inspection items plus the same ignore toggle the tree panes offer.
    @ViewBuilder
    private func singleRowMenu(for difference: FileDifference) -> some View {
        inspectionMenuItems(for: difference)
        Divider()
        let isIgnored = DifferenceRowMenu.isIgnored(difference, ignoredPaths: syncManager.ignoredPaths)
        Button {
            syncManager.ignoredPaths = DifferenceRowMenu.toggledIgnoredPaths(
                for: difference,
                ignoredPaths: syncManager.ignoredPaths
            )
        } label: {
            Label(
                isIgnored ? "Include in comparison" : "Ignore in comparison",
                systemImage: isIgnored ? "eye" : "eye.slash"
            )
        }
    }

    /// Read-only row actions — per-side Reveal/Quick Look/Copy Path for the sides that exist.
    /// Shared by the normal single-row menu and the review table's menu (which offers only these).
    @ViewBuilder
    private func inspectionMenuItems(for difference: FileDifference) -> some View {
        let sides = DifferenceRowMenu.existingSides(for: difference, paneNames: paneNames)
        ForEach(sides, id: \.paneName) { side in
            Button {
                onGetInfo(side.path)
            } label: {
                Label("Get Info (\(side.paneName))", systemImage: "info.circle")
            }
        }
        Divider()
        ForEach(sides, id: \.paneName) { side in
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: side.path)])
            } label: {
                Label("Reveal in Finder (\(side.paneName))", systemImage: RevealGlyph.inFinder)
            }
        }
        if let onQuickLook {
            Divider()
            ForEach(sides, id: \.paneName) { side in
                Button {
                    onQuickLook(URL(fileURLWithPath: side.path))
                } label: {
                    Label("Quick Look (\(side.paneName))", systemImage: "doc.viewfinder")
                }
            }
        }
        Divider()
        ForEach(sides, id: \.paneName) { side in
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(side.path, forType: .string)
            } label: {
                Label("Copy Path (\(side.paneName))", systemImage: "doc.on.clipboard")
            }
        }
    }

    /// Bulk menu for a multi-row selection: Copy/Move the selected rows in each direction
    /// (respecting the move modifier) and ignore them all.
    @ViewBuilder
    private func bulkMenu(for selected: [FileDifference]) -> some View {
        let toRight = selected.filter { $0.action == .copyToRight }
        let toLeft = selected.filter { $0.action == .copyToLeft }
        // Label-only snapshot: NSMenu can't relabel items from @Published while open, so the
        // verb shows the modifier held when the menu was built. The ACTION re-reads the live
        // modifier inside runCopyOrMove.
        let isMove = modifierTracker.isMoveModifierPressed
        if !toRight.isEmpty {
            Button {
                runCopyOrMove(direction: .copyToRight, items: toRight, scope: "selection")
            } label: {
                Label("\(isMove ? "Move" : "Copy") \(toRight.count) to \(paneNames.right)",
                      systemImage: isMove ? TransferGlyph.move(toRight: true) : TransferGlyph.copy)
            }
            .disabled(isSyncActionBlocked)
        }
        if !toLeft.isEmpty {
            Button {
                runCopyOrMove(direction: .copyToLeft, items: toLeft, scope: "selection")
            } label: {
                Label("\(isMove ? "Move" : "Copy") \(toLeft.count) to \(paneNames.left)",
                      systemImage: isMove ? TransferGlyph.move(toRight: false) : TransferGlyph.copy)
            }
            .disabled(isSyncActionBlocked)
        }
        Divider()
        Button {
            syncManager.ignoredPaths = DifferencesQuery.ignoringAll(selected, in: syncManager.ignoredPaths)
        } label: {
            Label("Ignore \(selected.count) in comparison", systemImage: "eye.slash")
        }
        Button {
            selection.removeAll()
        } label: {
            Label("Clear selection", systemImage: "xmark.circle")
        }
    }
}

// MARK: - Table cells
//
// Each column's content is its own small view so the `Table` builder stays simple enough for
// the type-checker (a single big Table literal with inline cell closures times out).

private extension View {
    /// The differences-table cells' density font: subheadline when the table is compact,
    /// and — crucially — the view returned UNMODIFIED when it isn't. `.font(nil)` is NOT a
    /// no-op: it clears any font inherited from an ancestor rather than leaving it in place,
    /// so the shared helper never applies the modifier at all in the comfortable case.
    @ViewBuilder
    func compactCellFont(_ isCompact: Bool) -> some View {
        if isCompact {
            font(.subheadline)
        } else {
            self
        }
    }
}

/// A folder section header in the grouped differences table: disclosure triangle, folder glyph,
/// folder name, row count — and, when collapsed, which way the folder's work points.
///
/// Carries no action buttons, deliberately. The header instead SELECTS its rows, and the bar above
/// already knows how to act on a selection — including a folder pointing both ways, which it splits
/// across its two transfer buttons. A button here could only ever name one direction and hide the
/// other, which is why C3 shipped counts-only; making the header a selection target removes the
/// problem instead of working around it, and composes (⌘-click two folders) where buttons could not.
///
/// Not a `TableRow`: a `Section` header in a SwiftUI `Table` is an ordinary `View`. That is what
/// makes any of this possible — and it is also why the selected highlight is drawn here by hand.
/// The table's selection is a set of ROW ids and a header has no row value, so a header can never
/// BE selected; it performs a selection and then reflects it.
struct DifferenceSectionHeader: View {
    /// Vertical padding inside the tap target, above and below the label row.
    ///
    /// It is the difference between a hit area the height of a line of text and one you can hit
    /// without aiming — and, because a collapsed table is nothing BUT headers, it also sets the
    /// rhythm of the collapsed summary. `sectionHeaderIsAComfortableClickTarget` pins the laid-out
    /// result rather than this constant, since what matters is the height the header reaches.
    ///
    /// **Was 7, which was too airy for the summary it was partly chosen to serve.** The reason it
    /// overshot is that this padding is not the only thing setting the row's height: a SwiftUI
    /// Table adds ~8pt of its own chrome around a hosted section header, so at Comfortable — where
    /// nothing is pinned and the Table measures its rows — 7pt of padding became a 38pt row around
    /// 16pt of text, better than half again a 25pt data row. Collapsed, that is the entire view.
    ///
    /// **2 is the end of the lever, not a preference.** A section header row cannot go below 28pt,
    /// and 2 is the largest padding that reaches it — measured off a mounted table rather than
    /// reasoned about:
    ///
    ///     padding   7    6    5    4    3    2    1    0
    ///     row      38   36   34   32   30   28   28   28
    ///
    /// 7 shipped first and read as a column of gaps once collapsed; 4 was a half-step that landed
    /// at 32pt and was not enough to notice. Below 2 the padding stops mattering entirely, because
    /// the floor is SwiftUI's, not ours.
    ///
    /// That floor is **not** reachable from the density system either, which is worth recording
    /// because it looks like it should be: Compact pins `tableMinRowHeight` at 20 and its section
    /// rows also measure 28, so the two look related. They are not — dropping that pin to 16 takes
    /// Compact's DATA rows to 16pt and leaves its header at 28. Both densities now draw an
    /// identical 28pt section header and differ only in their data rows (25 vs 20).
    ///
    /// Beating 28 would mean shrinking what the header contains — the disclosure triangle's hit box
    /// or the folder name itself — which changes how it reads, not just how it is spaced.
    static let verticalPadding: CGFloat = 2

    let folder: String
    let count: Int
    let accent: Color
    /// True when every row of this section is in the table selection. Tracks the selection rather
    /// than "was I clicked", so ⌘-clicking one row back out of the set unlights the header.
    var isFullySelected: Bool = false
    var isCollapsed: Bool = false
    /// Shown only while collapsed — "11 → Dropbox · 2 → iCloud". Empty hides it.
    var directionSummary: String = ""
    /// Toggles this section's disclosure. ⌥-click is handled by the caller (collapse/expand all).
    var onToggleCollapse: () -> Void = {}
    /// Selects this section. The caller reads ⌘ at click time to decide add vs replace.
    var onSelect: () -> Void = {}

    var body: some View {
        HStack(spacing: 7) {
            // Its own hit target, separate from the header's: the triangle collapses, the rest of
            // the row selects. Two gestures share this row, so the triangle needs real hit area —
            // the padding below is load-bearing, not spacing.
            Button(action: onToggleCollapse) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .scaledFont(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
                    .padding(2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCollapsed ? "Expand \(folder)" : "Collapse \(folder)")

            Image(systemName: "folder.fill")
                .scaledFont(.system(size: 10))
                .foregroundStyle(accent)
            Text(folder)
                .scaledFont(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(count.formatted())
                .scaledFont(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if isCollapsed, !directionSummary.isEmpty {
                Spacer(minLength: 12)
                Text(directionSummary)
                    .scaledFont(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        // The whole row is the selection target — everything except the triangle above, which
        // consumed its own click first.
        .frame(maxWidth: .infinity, alignment: .leading)
        // Padding BEFORE contentShape, and that order is the entire point. Without it the header's
        // hit area was only as tall as its text (~16pt) while the Table drew the section row
        // taller, so the band above the words looked like header and did nothing — the click
        // landed on table chrome outside this view. Owning the vertical space converts it into hit
        // area, and it buys the extra air between collapsed headers at the same time.
        .padding(.vertical, Self.verticalPadding)
        // Expand into whatever height the Table gives the row before the shape is taken, so the
        // hit area is the ROW and not just the padded label. Without it the shape is the 20pt the
        // content asks for, centred in a 28pt row, leaving 4pt of dead band above and below — a
        // smaller version of the bug the padding-before-contentShape ordering was written to fix.
        //
        // Costs nothing where there is no row to fill: `fittingSize` is 20pt either way (measured),
        // so the metrics tests below still see the header's own height. Honest caveat — that the
        // shape then covers the full row is reasoned from the hosting container being row-height,
        // NOT proven: SwiftUI's content shape is not observable from AppKit, and
        // `NSHostingView.hitTest` answers with the hosting view at every point.
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(accent.opacity(isFullySelected ? 0.18 : 0))
                .padding(.vertical, 1)
        )
        .help(isFullySelected
              ? "\(folder) — click to reselect, ⌘-click to deselect"
              : "Select this folder's differences · ⌘-click to add to the selection")
        // One element: VoiceOver reads "Immigration, 6 differences, selected" rather than four
        // fragments, and the tap is announced as what it does.
        //
        // `children: .ignore` collapses the subtree, which SWALLOWS the disclosure Button above —
        // it renders, it works with a mouse, and it is unreachable by VoiceOver. The named action
        // below puts it back as a rotor action on this element, which is also a better fit than a
        // 12pt hit target for anyone driving by keyboard.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(folder), \(count.formatted()) difference\(count == 1 ? "" : "s")")
        .accessibilityValue([isFullySelected ? "selected" : "",
                             isCollapsed ? "collapsed" : ""].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint("Selects this folder's differences")
        .accessibilityAddTraits(isFullySelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: isCollapsed ? "Expand" : "Collapse", onToggleCollapse)
    }
}

/// Name column: type glyph, dimmed parent path, then the filename — single line, middle-truncated.
///
/// `compact` shrinks the cell text to subheadline so it fits the compact row height — the
/// Table doesn't propagate an ambient `.font` into its cells (see `listDensity(_:)` in
/// Design), so each default-font cell opts in itself (via `compactCellFont`).
///
/// Internal rather than file-private so `FileExplorerSnapshotTests.differenceNameCellGroupedVersusFlat`
/// can render both modes: the pure `pathWithinSection` helper is well covered, but nothing pinned
/// that the cell actually SHOWS the shortened prefix — same reason `DifferenceSectionHeader` is
/// internal.
struct DifferenceNameCell: View {
    let difference: FileDifference
    var compact: Bool = false
    /// True when a folder section header is already naming this row's top-level folder, in which
    /// case the prefix drops that component instead of repeating it (`DifferenceGrouping
    /// .pathWithinSection`). The full path is still on the row's hover help either way.
    var grouped: Bool = false
    /// Both panes' rulesets. Defaulted to the strictest so every existing caller — and every test
    /// that builds this cell directly — behaves as it did, rather than needing a provider it has
    /// no opinion about.
    var paneRules: PaneProviderRules = .strictest
    /// Names the user has said they meant, so a keep made from a pane row also silences the badge
    /// here. Empty for callers with no store.
    var keptNames: Set<String> = []

    /// The dimmed prefix ahead of the filename, or "" for none.
    private var prefix: String {
        grouped ? DifferenceGrouping.pathWithinSection(difference) : difference.parentPath
    }

    /// Why this name will not survive this comparison, or nil when it will.
    ///
    /// Asked of every ruleset in play and answered by the FIRST that objects — so a name only
    /// OneDrive rejects is still flagged on a row whose other side is iCloud, which is exactly the
    /// row where flagging it is worth something: this is a difference, so something is about to be
    /// copied. Memoized per (provider, name) like the pane's, and the differences table has far
    /// fewer rows than a pane.
    ///
    /// `isDirectory: false` — a `FileDifference` is always a file. Folders differ only by way of
    /// their contents, so the diff engine never mints a row for one.
    private var riskyReason: String? {
        guard !keptNames.contains(difference.fileName) else { return nil }
        for provider in paneRules.distinct {
            if let reason = RiskyNameBadgeCache.reason(
                name: difference.fileName, isDirectory: false, provider: provider) {
                return reason
            }
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: DifferenceGlyph.symbol(for: difference.type, filled: true))
                .foregroundStyle(DifferenceGlyph.color(for: difference.type))
                .symbolRenderingMode(.hierarchical)
            // Affix whitespace made visible (NameDisplay): a row can exist precisely because
            // its name differs invisibly from the other side's ("Swimming␣" vs "Swimming").
            if !prefix.isEmpty {
                Text(NameDisplay.visiblePath(prefix) + "/")
                    .foregroundStyle(.secondary)
            }
            Text(NameDisplay.visibleName(difference.fileName))
                .fontWeight(.medium)
                .layoutPriority(1)
            // Beside the name, as on a pane row. This is arguably the badge's most valuable
            // surface: a differences row is a copy waiting to happen, and a name the destination
            // will reject is worth knowing BEFORE it goes somewhere, not after the sync fails.
            RiskyNameBadge(reason: riskyReason)
                .layoutPriority(1)
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .compactCellFont(compact)
        .help(NameDisplay.visiblePath(difference.relativePath))
    }
}

/// Change column: the bare description. The folder roll-up count lives in the Size column
/// (`enclosedItemsText`) where it lines up instead of truncating mid-number; the full
/// rolled-up sentence survives as the hover help.
private struct DifferenceChangeCell: View {
    let difference: FileDifference
    var compact: Bool = false

    var body: some View {
        Text(difference.description)
            .foregroundStyle(DifferenceGlyph.color(for: difference.type))
            .lineLimit(1)
            .truncationMode(.tail)
            .compactCellFont(compact)
            .help(difference.rolledUpDescription)
    }
}

/// Size column: the source side's byte size (right-aligned, monospaced), a folder's enclosed
/// item count ("5,301 items"), or "—" when neither is known.
private struct DifferenceSizeCell: View {
    let difference: FileDifference
    var compact: Bool = false

    var body: some View {
        Text(difference.displaySize.map { FileSizeFormat.byteCount.string(fromByteCount: Int64($0)) }
             ?? difference.enclosedItemsText
             ?? "—")
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .compactCellFont(compact)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Status column (review mode): the per-item outcome badge — ✓ copied/moved, – skipped, the
/// cursor marker on the item under review, or a muted "pending".
private struct ReviewStatusCell: View {
    let difference: FileDifference
    let session: ReviewSession

    var body: some View {
        Group {
            if let outcome = session.outcome(for: difference.id) {
                switch outcome {
                case .copied:
                    Label(session.isMove ? "Moved" : "Copied", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(SemanticColor.success)
                case .skipped:
                    Label("Skipped", systemImage: "minus.circle")
                        .foregroundStyle(.secondary)
                }
            } else if difference.id == session.current?.id {
                Label("Reviewing", systemImage: "arrow.left.circle.fill")
                    .foregroundStyle(.tint)
            } else {
                Text("Pending")
                    .foregroundStyle(.tertiary)
            }
        }
        .scaledFont(.caption.weight(.medium))
    }
}

/// Copy-to column: a small tinted direction chip (blue → right, purple → left) naming the
/// destination pane. Rows going the same way as the bulk of the list quiet the chip to dim
/// text — 559 identical capsules repeat what the header already says — and re-ink it on
/// hover; counter-direction rows keep the full chip, so the exceptions pop.
private struct DifferenceDirectionCell: View {
    let difference: FileDifference
    let paneNames: PaneProviderNames
    let bulkDirection: FileDifference.SyncAction?

    @State private var isHovered = false

    var body: some View {
        let toRight = difference.action == .copyToRight
        let tint = DifferenceGlyph.color(toRight: toRight)
        let isQuiet = difference.action == bulkDirection && !isHovered
        HStack(spacing: 4) {
            Image(systemName: toRight ? "arrow.right" : "arrow.left")
                .scaledFont(PillVariant.mini.iconFont)
            Text(toRight ? paneNames.right : paneNames.left)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .scaledFont(PillVariant.mini.labelFont)
        .foregroundStyle(isQuiet ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint))
        .pillSurface(.mini, tint: tint, showsFill: !isQuiet)
        .onHover { isHovered = $0 }
    }
}

