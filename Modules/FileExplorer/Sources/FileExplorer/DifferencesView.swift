import Events
import SwiftUI
import Sync
import AppKit
import Design

/// List of all differences between the two panes with actions to copy or move each item left or right.
public struct DifferencesView: View {
    @ObservedObject public var syncManager: FileSyncManager
    /// Host-owned review state: this view is conditionally mounted, so a session in `@State` would
    /// die on unmount. The host's store keeps it, and the view, alive for the whole review.
    @ObservedObject private var reviewStore: ReviewSessionStore
    @StateObject private var modifierTracker = ModifierTracker()
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    /// The resolved glass material; `.frosted` (standard Liquid Glass) if unrecognized.
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue
    /// The narrowings the reader set, kept where they outlive the workspace (see
    /// ``DifferencesSession``); the members below forward onto it.
    ///
    /// `@StateObject` seeded with the host's object, as `LensWorkspaceView` takes its session:
    /// `ContentView` hands one down, and a caller that hands none gets a fresh one per mount.
    @StateObject private var session: DifferencesSession

    private var selectedFilter: DifferenceFilter {
        get { session.selectedFilter }
        nonmutating set { session.selectedFilter = newValue }
    }
    /// Whether the table breaks its rows into top-level folder sections. Persisted, on by default:
    /// a long flat list has no landmarks, and `DifferenceGrouping.isWorthGrouping` spares a small
    /// comparison a lone header. Off gives the flat table, so a Size sort spans the whole list.
    @AppStorage("differencesGroupByFolder") private var groupByFolder: Bool = true
    /// Folder names whose section is collapsed. Not persisted, and cleared on every rescan: the
    /// folders change between scans, and restoring a fold would hide differences never seen.
    private var collapsedSections: Set<String> {
        get { session.collapsedSections }
        nonmutating set { session.collapsedSections = newValue }
    }
    /// The per-side item totals beside the count pill, toggled by clicking the pill. Off by
    /// default, so the header stays uncluttered.
    private var showItemCounts: Bool {
        get { session.showItemCounts }
        nonmutating set { session.showItemCounts = newValue }
    }
    /// Hover state for the count pill: a slight grow signals the pill is clickable (post-scan only).
    @State private var isCountPillHovered = false
    /// Bumped on wake, clock and time-zone changes, so the sparse freshness timeline restarts.
    @State private var clockEpoch = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Read here, not in `LabelMetrics`, because a `ScaledFont` can't see the environment (why
    /// `Text.scaledFont(_:scale:)` takes the scale). The header ladder measures at this scale.
    @Environment(\.appFontScale) private var appFontScale
    /// Drives the count pill's freshness palette. From the environment, not the Theme setting, so
    /// it follows System too.
    @Environment(\.colorScheme) private var colorScheme
    private var searchText: String {
        get { session.searchText }
        nonmutating set { session.searchText = newValue }
    }
    @State private var selection = Set<FileDifference.ID>()
    private var sortOrder: [KeyPathComparator<FileDifference>] {
        get { session.sortOrder }
        nonmutating set { session.sortOrder = newValue }
    }
    /// The filtered and sorted rows, cached in state and rebuilt by `.task(id:)` off the main actor
    /// (the `DiffStatusIndex` pattern). Inline in `body` the filter and sort would re-run on every
    /// render, which a bulk sync triggers per file; keyed by `DisplayInputs`, an unchanged render
    /// costs an equality check.
    @State private var displayRows = DisplayRows()
    /// False until the first rows land, so the async first pass shows a briefly blank table, never
    /// a false "No differences" flash.
    @State private var hasComputedRows = false
    /// Rows Ask Claude selected that the table still has to scroll to. Set only by
    /// `session.requestedSelection`, so no user click starts a scroll, and taken once the rows for
    /// the request's filter land (see `revealIsDue`).
    @State private var pendingReveal: Set<FileDifference.ID>?
    private var isSearchExpanded: Bool {
        get { session.isSearchExpanded }
        nonmutating set { session.isSearchExpanded = newValue }
    }
    /// The review table's selection, which is also the review cursor: advancing moves it, clicking
    /// a pending row jumps the session. Separate from `selection`, so review can't corrupt it.
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
    /// Hands one side's file to the Edit workspace (the "Open in Edit" row action). `nil`, the
    /// default, withholds the items, as a `nil` `onQuickLook` withholds Quick Look.
    private let onOpenInEditor: ((String) -> Void)?
    /// Host-owned collapse state for the whole pane. When bound, a header chevron hides the list,
    /// leaving the header strip, and the host gives the freed height to the panes above. `nil`, the
    /// default, withholds the chevron.
    private let isCollapsed: Binding<Bool>?
    /// A status pill after the count (one-way sync's), in both the collapsed bar and the header,
    /// and the widest it may draw, which the header's ladder prices.
    private let accessory: AnyView?
    private let accessoryWidth: CGFloat
    /// True while the host has a destination pick in flight: its overlay blocks the mouse from
    /// this header, so the menu chords published below go quiet too. Same rule as
    /// `ShortcutValuePublisher.suspended`.
    private let shortcutsSuspended: Bool
    /// Whether the pane is a header strip now: a guided review re-opens it. See
    /// ``isCollapsedToHeaderStrip(storedCollapse:isReviewing:)``.
    private var collapsed: Bool {
        Self.isCollapsedToHeaderStrip(storedCollapse: isCollapsed?.wrappedValue ?? false,
                                      isReviewing: reviewStore.isReviewing)
    }

    /// Whether a collapsible differences pane is a header strip right now. The one rule: the host
    /// gates the pane's height on it and this view gates what it renders, so they can't disagree
    /// and clip the list to the header's height.
    public static func isCollapsedToHeaderStrip(storedCollapse: Bool, isReviewing: Bool) -> Bool {
        // A guided review overrides the stored preference, since its card holds a cursor and
        // progress found nowhere else. The preference stays, so the pane re-collapses after.
        storedCollapse && !isReviewing
    }
    /// Opens the shared file-pair viewer on a changed row.
    ///
    /// A closure to the window, not an overlay of its own: an `.overlay` is clamped to its anchor,
    /// and this bottom pane leaves a few hundred points at the window's minimum size. Like the
    /// Duplicates host (`CompareOverlayMetrics`), it hands the pair up to `ContentView`.
    private let onCompareFilePair: (DifferencePair) -> Void
    /// Ask Claude About This on rows; nil withholds the items.
    private let askClaude: DifferencesAskClaude?

    /// - Parameters:
    ///   - reviewStore: The host-owned guided-review state (a `@StateObject` at the host; one
    ///     made inline would reset the session every render).
    ///   - onQuickLook: Presents a Quick Look preview, through the same `quickLookPreview`
    ///     binding the spacebar uses; `nil` hides the Quick Look menu items.
    ///   - onGetInfo: Shows the Info inspector for a file path (the "Get Info" row action).
    ///   - onOpenInEditor: Hands a file path to the Edit workspace (one "Open in Edit" per side
    ///     holding a text file), via `handOffToEditor`, leaving the left pane where it is;
    ///     `nil` hides the items.
    public init(syncManager: FileSyncManager, reviewStore: ReviewSessionStore, paneNames: PaneProviderNames = .leftRight, paneRules: PaneProviderRules = .strictest, onQuickLook: ((URL) -> Void)? = nil, onGetInfo: @escaping (String) -> Void = { _ in }, onOpenInEditor: ((String) -> Void)? = nil, isCollapsed: Binding<Bool>? = nil, shortcutsSuspended: Bool = false, onCompareFilePair: @escaping (DifferencePair) -> Void = { _ in }, session: DifferencesSession? = nil, accessory: AnyView? = nil, accessoryWidth: CGFloat = 0, askClaude: DifferencesAskClaude? = nil) {
        self.askClaude = askClaude
        self.accessory = accessory
        self.accessoryWidth = accessory == nil ? 0 : accessoryWidth
        self.syncManager = syncManager
        self.reviewStore = reviewStore
        self.paneNames = paneNames
        self.paneRules = paneRules
        self.onQuickLook = onQuickLook
        self.onGetInfo = onGetInfo
        self.onOpenInEditor = onOpenInEditor
        self.isCollapsed = isCollapsed
        self.shortcutsSuspended = shortcutsSuspended
        self.onCompareFilePair = onCompareFilePair
        _session = StateObject(wrappedValue: session ?? DifferencesSession())
    }

    private var isBulkSyncing: Bool {
        syncManager.bulkSyncProgress != nil
    }
    private var isVerifyAllInProgress: Bool {
        syncManager.verifyAllProgress != nil
    }
    /// One gate for every Copy/Move/Verify entry point, header and bulk menu alike: `syncAll`
    /// silently drops re-entrant runs, so an entry point left enabled mid-run does nothing.
    ///
    /// Any long run on `activeProgress` (a merge, a pane copy, a trash) blocks them too: the
    /// window's run lock reaching Compare's buttons and chords.
    private var isSyncActionBlocked: Bool {
        syncManager.differences.contains { $0.isSyncing } || isBulkSyncing || isVerifyAllInProgress
            || syncManager.activeProgress != nil
    }
    private var verifiedIdenticalCount: Int {
        syncManager.verifiedIdenticalForCopy?.differences.count ?? 0
    }
    private var glassHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: glassHueRaw) ?? .blue
    }
    /// The compared folder's name the Path column anchors its paths to, such as "Home" when both
    /// roots are called Home (the usual case). Nil when the roots' names differ, since either would
    /// misname the other side, or before any scan; the cells then show the bare parent path
    /// (`DifferencesQuery.pathColumnText`). Internal, not private, so a test can check the gate.
    var pathRootName: String? {
        guard let roots = syncManager.lastScanRootNames, roots.left == roots.right else { return nil }
        return roots.left
    }
    private var surfaceStyle: SurfaceStyle {
        SurfaceStyle(rawValue: surfaceStyleRaw) ?? .unified
    }
    /// The appearance density: comfortable leaves the table untouched; compact tightens rows via
    /// `.listDensity(_:)` (small controls, subheadline cells and a lower row minimum).
    private var listDensity: ListDensity {
        ListDensity(rawValue: listDensityRaw) ?? .comfortable
    }

    /// One filtered and one sorted snapshot of the visible rows (see `displayRows`).
    /// `@unchecked Sendable`, as `DisplayInputs` is: every property is an immutable value snapshot.
    private struct DisplayRows: @unchecked Sendable {
        var filtered: [FileDifference] = []
        var sorted: [FileDifference] = []
        /// Per-filter badge counts over all differences, built with the rows. A Menu's content
        /// builder runs on every header render, so counting there would cost a pass per file in a
        /// bulk sync.
        var filterCounts: [DifferenceFilter: Int] = [:]
        /// The inputs these rows were built from (`nil` for a placeholder), so a reveal can tell
        /// its filter's rows from the ones still on screen.
        var builtFrom: DisplayInputs?
    }

    /// Everything that decides the visible rows, as the `.task(id:)` key, so the pass reruns
    /// exactly when one changes, per-row `isSyncing` flips included. Review mode is an input:
    /// entering it empties the rows without running the pass.
    ///
    /// `@unchecked Sendable`: every property is an immutable value snapshot; `DifferenceFilter`
    /// and `KeyPathComparator` are value types that just lack the conformance.
    private struct DisplayInputs: Equatable, @unchecked Sendable {
        var differences: [FileDifference]
        var filter: DifferenceFilter
        var searchText: String
        var sortOrder: [KeyPathComparator<FileDifference>]
        var isReviewing: Bool
        /// The Path column's anchor, snapshotted with its rows: search matches the anchored path
        /// text the user sees.
        var pathRootName: String?
        /// The last bulk transfer's failed rows. An input, not read inside the pass, so a run that
        /// fails reruns it; otherwise the Failed filter and its count would show the previous run.
        var failedIDs: Set<UUID>
    }

    private var displayInputs: DisplayInputs {
        DisplayInputs(
            differences: syncManager.differences,
            filter: selectedFilter,
            searchText: searchText,
            sortOrder: sortOrder,
            isReviewing: reviewStore.session != nil,
            pathRootName: pathRootName,
            failedIDs: syncManager.lastTransferFailures?.ids ?? []
        )
    }

    public var body: some View {
        // From the state cache (rebuilt by the `.task(id:)` below), so a render with unchanged
        // inputs does no filtering or sorting.
        let filtered = displayRows.filtered
        let sorted = displayRows.sorted
        let targets = DifferenceActionTargets(filtered: filtered, selection: selection)
        // Derived once per render and passed down: the table draws it and the filter menu's
        // eager builder (`filterMenu`) reads it, so a computed property would group twice.
        let sections = groupedSections(sorted)

        // Spacing 0: in Cards each card insets itself by half a gutter, so the gap is already
        // `cardGutter`. In Unified the two are one area (`columnRegionFrame`), table flush under.
        return VStack(spacing: 0) {
            // Toolbar card: tabs · count · filter · actions · search.
            VStack(alignment: .leading, spacing: 10) {
                if collapsed {
                    // Collapsed to a thin bar: the count and the expand chevron only.
                    HStack(spacing: 10) {
                        collapsedHeader
                        collapseToggle
                    }
                } else if let session = reviewStore.session {
                    // No collapse toggle: `collapseToggle` withholds itself during a review.
                    HStack(spacing: 10) { reviewHeaderControls(session) }
                } else {
                    // Its own row: a ViewThatFits over the whole bar, so the trailing controls
                    // must be inside it to be shed.
                    standardHeader(targets: targets, sorted: sorted, sections: sections)
                }
                if reviewStore.session == nil, !collapsed, isSearchExpanded || !searchText.isEmpty {
                    searchField(filteredCount: filtered.count)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(HeaderCardChrome())
            // The hairline marks the toolbar's edge against the table, so it goes with the table:
            // collapsed, the toolbar is the whole region and the frame's own outline is its edge.
            .columnHeaderRule(surfaceStyle, overContent: !collapsed)
            .columnSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)

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
                .columnSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
            }
        }
        // One area in Unified, two cards in Cards, like every workspace column
        // (`columnSectionCard`).
        .columnRegionFrame(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
        // The menu bar's three differences items (⇧⌘R Review, ⇧⌘V Verify, ⇧⌘F fold), published
        // from body so they use this render's targets and sections, as the header's buttons do.
        // The rules live in `DifferencesShortcutRules`. One deliberate difference from the header:
        // Review stays available while collapsed, since starting one re-opens the pane.
        // `focusedSceneValue`, not `focusedValue`, so they fire wherever focus sits in the window;
        // `nil` disables the item.
        .focusedSceneValue(\.startDifferencesReview,
                           DifferencesShortcutRules.reviewAvailable(
                               sessionActive: reviewStore.session != nil,
                               targetCount: targets.targets.count,
                               blocked: isSyncActionBlocked,
                               suspended: shortcutsSuspended)
                               ? { startReview(targets: targets, sorted: sorted) } : nil)
        .focusedSceneValue(\.verifyDifferences,
                           DifferencesShortcutRules.verifyAvailable(
                               sessionActive: reviewStore.session != nil,
                               verifiableCount: targets.verifiableCount,
                               blocked: isSyncActionBlocked,
                               collapsed: collapsed,
                               suspended: shortcutsSuspended)
                               ? { verify(targets: targets) } : nil)
        .focusedSceneValue(\.foldAllDifferences, foldAllShortcut(sections: sections))
        // Review cursor, both ways: a row click jumps the session (pending rows only; a decided
        // row snaps the highlight back), and a session advance re-highlights.
        .onChange(of: reviewSelection) { oldSelection, newSelection in
            guard let session = reviewStore.session else { return }
            // Any click hands key focus to the Table; send it back to the card.
            reviewFocusNudge += 1
            // A Set selection can hold several rows after ⌘/⇧-click, and `.first` is arbitrary.
            // Follow the row just added (else what remains) and collapse to one row, so no second
            // highlight disagrees with what Return/Skip acts on.
            let target = newSelection.subtracting(oldSelection).first ?? newSelection.first
            // A deselection (⌘-click) snaps back too: the highlight is the cursor and must not go
            // dark.
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
        // A remount mid-review keeps the session (it lives in the store) but loses the cursor
        // highlight (view `@State`), so re-seed it.
        .onAppear {
            if let current = reviewStore.session?.current {
                reviewSelection = [current.id]
            }
        }
        // The folds belong to one comparison, and this is the one handler that retires them. A new
        // scan is a new list, so a carried fold would hide differences never seen. Keyed on the
        // scan date, not `differences`, which republishes per file mid-sync and would spring
        // every fold open.
        //
        // The folds outlive this view, so it records which scan they describe, and
        // `initial: true` checks on arrival too: back after any rescan, the date is new and the
        // folds go; back with nothing rescanned, they stay. Keep it one handler: a second
        // `.onChange` on this value would be missed by the next edit.
        .onChange(of: syncManager.lastScanDate, initial: true) { _, date in
            guard session.collapsedSectionsScanDate != date else { return }
            collapsedSections.removeAll()
            session.collapsedSectionsScanDate = date
        }
        // Rows Ask Claude asked to select, taken once: on arrival if the table mounts after the
        // request, or as it comes. The scroll waits for the rows (see `reveal`). A pane collapsed
        // to its bar opens, since Claude was asked to show them.
        //
        // Not during a review (the host refuses `show` then): the rows would be selected unasked
        // when it ends, and opening the bar would overwrite the preference the review overrides
        // (`isCollapsedToHeaderStrip`).
        .onChange(of: session.requestedSelection, initial: true) { _, requested in
            guard let requested else { return }
            session.requestedSelection = nil
            guard !reviewStore.isReviewing else { return }
            selection = requested
            pendingReveal = requested
            if isCollapsed?.wrappedValue == true { isCollapsed?.wrappedValue = false }
        }
        // The same for the filter: `.failed` is set and cleared by `.onChange`, so failures that
        // cleared while Compare was off screen would leave it standing, an empty table whose
        // Picker selection matches no tag and no way back.
        .onAppear {
            if selectedFilter == .failed, syncManager.lastTransferFailures == nil {
                selectedFilter = .all
            }
        }
        // A partial run leaves its failures in the list, unmarked and hard to find, so land on them.
        //
        // Keyed on the publish identity, not the id set: two runs failing on the same rows give an
        // equal set and would not fire the second time. It can't replay: `TransferFailures.id`
        // changes once per bulk run (`recordTransferFailures`), and `onChange` never fires on a
        // remount.
        .onChange(of: syncManager.lastTransferFailures?.id) { _, id in
            guard id != nil else {
                // The failures went (a clean run or a rescan). A filter no longer in the menu
                // would show an empty table whose Picker selection matches no tag.
                if selectedFilter == .failed { selectedFilter = .all }
                return
            }
            selectedFilter = .failed
        }
        // Rebuild the visible rows off the main actor on any input change and on appear.
        // `task(id:)` cancels a stale rebuild, and the `isCancelled` check keeps it from landing
        // over a newer one, as in `ContentView`'s `DiffStatusIndex` rebuild.
        .task(id: displayInputs) {
            let inputs = displayInputs
            if inputs.isReviewing {
                // Drop the cached rows (the review owns the screen) but clear the computed flag,
                // or leaving the review would flash "No differences" until the rebuild lands.
                // Filter counts are kept, so the menu badges don't read zero meanwhile.
                displayRows = DisplayRows(filterCounts: displayRows.filterCounts)
                hasComputedRows = false
                return
            }
            let rows = await Task.detached(priority: .userInitiated) { () -> DisplayRows in
                let filtered = DifferencesQuery.filtered(inputs.differences, filter: inputs.filter, searchText: inputs.searchText, pathRootName: inputs.pathRootName, failedIDs: inputs.failedIDs)
                return DisplayRows(
                    filtered: filtered,
                    sorted: filtered.sorted(using: inputs.sortOrder),
                    filterCounts: DifferencesQuery.counts(inputs.differences, failedIDs: inputs.failedIDs),
                    builtFrom: inputs
                )
            }.value
            guard !Task.isCancelled else { return }
            displayRows = rows
            hasComputedRows = true
        }
        // "Match Dates", title and button alike: nothing is copied, only the dates are set.
        .confirmationDialog("Match Dates", isPresented: Binding(
            get: { syncManager.verifiedIdenticalForCopy != nil },
            // Deferred cleanup: SwiftUI writes false on any dismissal, confirm included, and may
            // run this before the button's action. Cleaning up synchronously would destroy the
            // list before confirm can claim it.
            set: { if !$0 { syncManager.verifiedCopyDialogDismissed() } }
        )) {
            Button("Match Dates on \(paneNames.right)") {
                syncManager.confirmVerifiedCopy()
            }
            Button("Cancel", role: .cancel) {
                syncManager.dismissVerifiedCopyDialogWithoutCopy()
            }
        } message: {
            // The run sets dates; it never copies a byte-identical file over its twin.
            Text(verifiedIdenticalCount == 1
                 ? "1 file verified identical. The file on \(paneNames.right) takes the date of its twin on \(paneNames.left). Nothing is copied: the contents already match."
                 : "\(verifiedIdenticalCount.formatted()) files verified identical. One permission — each file on \(paneNames.right) takes the date of its twin on \(paneNames.left). Nothing is copied: the contents already match. No per-file confirmation.")
        }
    }

    // MARK: Header — scan freshness

    /// What scan freshness contributes to the differences count pill at one moment. The count
    /// and its age are one statement ("576 differences, as of 29 minutes ago"), so staleness
    /// lands on the number it undermines. Internal because `standardHeaderRow` takes one, and that
    /// row is internal so `HeaderLadderTests` can render it.
    struct CountPillDressing {
        let semantic: SemanticCapsuleStyle
        /// The family the age run wears, or nil when there is nothing to report. The capsule is
        /// the accent in every state; this is all freshness changes.
        let detailStyle: SemanticCapsuleStyle?
        /// The secondary run inside the pill — "29m ago", or nil before the first scan.
        let detail: String?
        /// What VoiceOver says in `detail`'s place. Separate because an age is done and
        /// "scanning…" is still going, so no one prefix fits both.
        let spokenDetail: String?
        /// The exact timestamp, appended to the pill's tooltip, since the age buckets are coarse.
        let help: String?
    }

    /// The dressing for `now`. The capsule is the accent in all four states; only the age run
    /// changes:
    ///
    /// - fresh: a bare age run. Reassurance needs no colour.
    /// - stale: the run wears `.attention`, which is hue-independent, so it can't collide with the
    ///   `.green` and `.amber` accents.
    /// - scanning: the run wears `.neutral`, not green, which would call it fresh before the
    ///   result exists.
    /// - pre-scan: no run. "0 Differences" with no age is honest.
    ///
    /// The whole capsule stays the accent, because a pale warning capsule reads as disabled on a
    /// control that must look clickable. The run is a filled capsule with a ring, not a tinted
    /// word: on a saturated accent nothing coloured clears 3:1 (`SemanticCapsuleStyle.dotRing`).
    ///
    /// Staleness comes from the clock plus the folder watcher's changed-on-disk flags. Any further
    /// change signal should add to these, never replace them: missing a change under-warns, which
    /// is worse than over-warning.
    func countPillDressing(at now: Date) -> CountPillDressing {
        let accent = SemanticCapsuleStyle.onAccent(fill: glassHue.accentFillColor,
                                                   label: glassHue.onAccentLabelColor)
        // The comparison's age, not the scan's (`lastScanReadAt`): a scan from cached trees
        // compares earlier walks, perhaps hours old, and dated by when it ran would read "just now".
        guard let completed = syncManager.lastScanDate else {
            return CountPillDressing(semantic: accent, detailStyle: nil, detail: nil,
                                     spokenDetail: nil, help: nil)
        }
        let scanDate = syncManager.lastScanReadAt ?? completed
        let stamp = ScanFreshness.stamp(scanDate: scanDate, now: now)
        // `isScanShown`, not `isScanning`: most rescans take a few hundred milliseconds, and each
        // would flash "scanning…".
        if syncManager.isScanShown {
            return CountPillDressing(semantic: accent,
                                     detailStyle: .of(.neutral, colorScheme),
                                     detail: "scanning…",
                                     // Present tense, no "scanned": the count beside it is the
                                     // previous scan's, about to be replaced.
                                     spokenDetail: "scanning for changes",
                                     help: "Scanning for changes…")
        }
        // A change the folder watcher saw under either pane since its walk began dates this
        // comparison too. Additive, as the note above asks.
        let freshness = ScanFreshness.describe(scanDate: scanDate, now: now,
                                               changedOnDisk: syncManager.leftChangedOnDisk
                                                   || syncManager.rightChangedOnDisk)
        // `freshness.spoken` on both branches: it is the only thing that says "stale" in words,
        // since the run's colour, the age and `.help` don't. `ScanFreshness.Result` owns the
        // phrasing, so the branches can't drift.
        guard freshness.isStale else {
            return CountPillDressing(semantic: accent, detailStyle: nil, detail: freshness.age,
                                     spokenDetail: freshness.spoken,
                                     help: "Last scanned \(stamp)")
        }
        return CountPillDressing(semantic: accent,
                                 detailStyle: .of(.attention, colorScheme),
                                 detail: freshness.age,
                                 spokenDetail: freshness.spoken,
                                 help: freshness.changedOnDisk
                                     ? "Files have changed since this comparison — last scanned \(stamp)"
                                     : "This comparison may be out of date — last scanned \(stamp)")
    }

    /// Runs `content` again only when the dressing can change, without polling:
    /// `ScanFreshnessSchedule` ticks at the ladder's seams, the stale threshold and the stamp's
    /// midnight, hourly after the first hour. A fixed short period would rebuild the whole header
    /// constantly.
    ///
    /// Anchored to `lastScanReadAt`, the date the age is measured from, not `Date()`, so labels
    /// and the stale flip land on time. Before any scan there is nothing to tick; it renders once.
    @ViewBuilder
    private func withScanFreshness(@ViewBuilder _ content: @escaping (CountPillDressing) -> some View) -> some View {
        if let completed = syncManager.lastScanDate {
            TimelineView(ScanFreshnessSchedule(anchor: syncManager.lastScanReadAt ?? completed,
                                               epoch: clockEpoch)) { context in
                content(countPillDressing(at: context.date))
            }
            // Ticks can be a day apart; after a sleep or a clock or zone change, start over.
            .onReceive(ScanFreshnessSchedule.clockChanges) {
                // `Calendar.current` is read on the restart; make sure it has the new zone.
                NSTimeZone.resetSystemTimeZone()
                clockEpoch &+= 1
            }
        } else {
            content(countPillDressing(at: Date()))
        }
    }

    // MARK: Header

    /// The collapsed bar's content: the differences count, then a spacer pushing the expand
    /// chevron right. A plain pill, not a toggle: the per-side totals belong to the full header.
    @ViewBuilder
    private var collapsedHeader: some View {
        // Freshness matters more here: collapsed, this pill is all that is left about the scan.
        withScanFreshness { dressing in
            let pill = StatPill(
                count: syncManager.differences.count,
                label: "Differences",
                // Unused on the capsule path; see `countPillToggle`.
                color: glassHue.accentColor,
                systemImage: "exclamationmark.triangle",
                // The same capsule as the expanded header's pill, freshness and all: collapsing
                // changes how much of the header shows, never what its colours mean.
                semantic: dressing.semantic,
                detail: dressing.detail,
                spokenDetail: dressing.spokenDetail,
                detailStyle: dressing.detailStyle
            )
            // Branch rather than `?? ""`: pre-scan there is no timestamp, so no `.help` at all
            // rather than an empty one. The expanded pill always has a first line.
            if let help = dressing.help {
                pill.help(help)
            } else {
                pill
            }
        }
        accessoryView
        Spacer()
    }

    /// The host's status pill, no wider than the ladder priced it.
    @ViewBuilder
    private var accessoryView: some View {
        if let accessory {
            accessory.frame(maxWidth: accessoryWidth, alignment: .leading)
        }
    }

    /// The show/hide chevron at the header's trailing edge. It points the way the next click sends
    /// the list, like the count pill's chevron. Withheld when the host binds no collapse state.
    ///
    /// Also withheld during a guided review: collapsing would hide the review card, which reads as
    /// the review being gone, and its cursor and progress show nowhere else.
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
            // Frosted and Clear: a glass circle with a round hover, like every bar button
            // (`ChromeGlass`) — grown 2pt to 28pt, level with the header's pills.
            .chromeGlassGlyphButton(tint: glassHue.accentColor, outset: 2)
            .shortcutKeycap(AppChord.differencesList.display)
            .help(ShortcutHint.tooltip(
                isCollapsed.wrappedValue ? "Show the differences list" : "Hide the differences list",
                AppChord.differencesList.display))
            .accessibilityLabel(isCollapsed.wrappedValue ? "Show differences" : "Hide differences")
        }
    }

    /// The standard (non-review) header, in four zones separated by hairlines:
    ///
    ///     [ state ] │ [ scope ] ————— [ actions ] │ [ view ]
    ///
    /// A control's zone is the question it answers: what did the scan find, what am I acting on,
    /// do what, show me what. So the selection chip sits in scope beside the filter, not among the
    /// buttons, and search and collapse sit behind a hairline because they change nothing on disk.
    ///
    /// The rung is computed, not searched (see `HeaderLadder`). The scope–action gap's `minLength`
    /// keeps the seam visible on a full row; the ladder works with a bare `Spacer()` too, since its
    /// ideal width is its minLength (`ActionBarLadderTests`).
    ///
    /// The whole row sits inside `withScanFreshness`, not just the pill: the age run changes width
    /// (up to 12pt) on a `TimelineView` tick that doesn't re-run `body`, so the ladder must price
    /// the same `dressing` the pill draws.
    private func standardHeader(targets: DifferenceActionTargets, sorted: [FileDifference],
                                sections: [DifferenceGrouping.Section]) -> some View {
        withScanFreshness { dressing in
            let ladder = HeaderLadder(
                facts: headerFacts(dressing: dressing, targets: targets, sections: sections),
                scale: appFontScale)
            GeometryReader { proxy in
                // `.leading` is (leading, centre): a `GeometryReader` would park the row top-left.
                hedged(ladder.rung(fitting: proxy.size.width), ladder,
                       dressing: dressing, targets: targets, sorted: sorted, sections: sections)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            }
            // A `GeometryReader` is greedy in both axes and reports nothing, so state the narrowest
            // rung's width (what the card reserves) and a height, or the row and card would grow.
            // `ActionBarMetrics.height`, because the filter menu is an action-bar capsule on every
            // rung (`HeaderLadderTests.theRowIsAlwaysTheActionBarHeight`).
            .frame(minWidth: ladder.width(of: ladder.terminal),
                   minHeight: ActionBarMetrics.height,
                   maxHeight: ActionBarMetrics.height)
        }
        // Must stay outside `withScanFreshness`: `invalidateDifferencesForPaneRetarget()` clears
        // `lastScanDate` and `hasScanned` together, which swaps that closure's branch, and a
        // handler torn down by its own trigger may not fire.
        //
        // Covers a `hasScanned` reset that keeps this view mounted (usually the view unmounts and
        // its state resets). Not wired to a re-Compare of the same roots: expansion persisting
        // there is a remembered preference.
        .onChange(of: syncManager.hasScanned) { _, hasScanned in
            if !hasScanned {
                showItemCounts = false
                isCountPillHovered = false
            }
        }
    }

    /// The computed rung, with the narrowest rung behind it as the layout engine's veto.
    ///
    /// The fallback is the narrowest rung, not the next one down: if the arithmetic overestimates,
    /// an over-compacted row keeps every action reachable, where an overflowing one clips its
    /// trailing controls silently. A third child would cost another toolbar build per layout pass.
    ///
    /// Branched, so a computed rung that is already terminal isn't built twice. The branch sits
    /// outside the `ViewThatFits`: an `if` inside is one `_ConditionalContent` child, not two.
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

    /// Snapshots everything `HeaderLadder` needs to price the row, from the values the row draws
    /// with, so the measured and drawn rows can't differ.
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
            heldText: targets.heldText,
            reverseIsMajority: targets.dominantCopyDirection == .copyToLeft,
            leftName: paneNames.left,
            rightName: paneNames.right,
            isMove: modifierTracker.isMoveModifierPressed,
            showsCollapseToggle: isCollapsed != nil && reviewStore.session == nil,
            accessoryWidth: accessoryWidth)
    }

    /// The compaction rungs the ladder walks, in order. Read by `HeaderLadder.rung(fitting:)` to
    /// choose one and by `HeaderCompactionTests` to catch a rung added to the enum but not here.
    ///
    /// `nonisolated`: an immutable array of a `Sendable` enum, so `HeaderLadder`, kept
    /// isolation-free for tests off the main actor, can read it without crossing an actor boundary.
    nonisolated static let renderedCompactionLadder: [HeaderCompaction] =
        [.full, .foldVerify, .foldReview, .shortReverse, .glyphFilter, .shortPrimary]

    /// Internal, not private, so `HeaderLadderTests` can render the row `HeaderLadder` prices.
    ///
    /// Takes `facts`, the snapshot the ladder priced, rather than reading `showItemCounts` again,
    /// so the totals readout drawn is the very string measured.
    func standardHeaderRow(_ compaction: HeaderCompaction,
                           facts: HeaderLadder.Facts,
                           dressing: CountPillDressing,
                           targets: DifferenceActionTargets,
                           sorted: [FileDifference],
                           sections: [DifferenceGrouping.Section]) -> some View {
        HStack(spacing: 10) {
            countPillToggle(dressing)                           // STATE
            itemCountsReadout(facts.itemCountsText)
            accessoryView
            ActionBarDivider()
            foldAllToggle(compaction, sections: sections)       // SCOPE
            filterMenu(compaction, sections: sections)
            selectionChip(targets)
            Spacer(minLength: 16)
            overflowMenu(compaction, targets: targets, sorted: sorted)   // ACTIONS
            if compaction < .foldVerify { verifyButton(targets) }
            if compaction < .foldReview { reviewButton(targets, sorted: sorted) }
            heldReadout(facts.heldText)
            // `facts.isMove`, not the tracker read afresh: the ladder priced these labels from it,
            // "Move" is much wider than "Copy" at narrow rungs, and a test can set a fact but not
            // reach a private `@StateObject`.
            reverseTransferButton(compaction, isMove: facts.isMove, targets: targets)
            primaryTransferButton(compaction, isMove: facts.isMove, targets: targets)
            ActionBarDivider()
            ExpandingSearchToggle(                              // VIEW
                text: $session.searchText,
                isExpanded: $session.isSearchExpanded,
                accent: glassHue.accentColor,
                help: "Search by name or path"
            )
            collapseToggle
        }
    }

    // MARK: Header — state zone

    /// The count pill toggles the per-side item totals inline. A no-op until a scan has run, so
    /// the chevron is withheld until then too.
    ///
    /// Takes `dressing` rather than calling `withScanFreshness`: the whole row already sits in that
    /// `TimelineView` (see `standardHeader`), and a nested one would tick the pill separately.
    private func countPillToggle(_ dressing: CountPillDressing) -> some View {
        Button {
            guard syncManager.hasScanned else { return }
            withDesignAnimation(.easeInOut(duration: 0.15), reduceMotion: reduceMotion) {
                showItemCounts.toggle()
            }
        } label: {
            StatPill(
                count: syncManager.differences.count,
                label: "Differences",
                // Unused on the capsule path, where the style below supplies everything. Kept as
                // the accent for any non-semantic use, which reads it as a tint wash.
                color: glassHue.accentColor,
                systemImage: "exclamationmark.triangle",
                // The chevron points the way the next click sends the totals, and is withheld
                // pre-scan (`CountPillChevron` owns both rules).
                trailingSystemImage: CountPillChevron.symbol(hasScanned: syncManager.hasScanned, expanded: showItemCounts),
                // The accent capsule in every state, so the toggle reads as a control; freshness
                // lands on the age run (see `countPillDressing`).
                semantic: dressing.semantic,
                detail: dressing.detail,
                spokenDetail: dressing.spokenDetail,
                detailStyle: dressing.detailStyle
            )
            // Reduce Motion suppresses the grow, matching `HoverAffordanceMetrics.resolve`, whose
            // rule still applies though this control doesn't go through it.
            .scaleEffect(isCountPillHovered && !reduceMotion ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            // Grow only post-scan, but always honour hover-exit: if `hasScanned` flips false
            // mid-hover, a gated reset would strand the pill at 1.03.
            withAnimation(.easeInOut(duration: 0.12)) {
                isCountPillHovered = hovering && syncManager.hasScanned
            }
        }
        // Two lines: what a click does, then the exact last-scan time, which the bucketed age
        // run can't give.
        .help([syncManager.hasScanned ? itemCountsText : "Scan to see per-side item totals",
               dressing.help].compactMap { $0 }.joined(separator: "\n"))
        // `StatPill` is one element, "N Differences"; the value and hint on the button give
        // VoiceOver the toggle state and what a click does.
        .accessibilityValue(syncManager.hasScanned ? (showItemCounts ? "expanded" : "collapsed") : "")
        .accessibilityHint(syncManager.hasScanned ? "Shows or hides the per-side item totals" : "")
    }

    /// The per-side totals, the one string the readout and the pill's tooltip show and the ladder
    /// measures.
    private var itemCountsText: String {
        "\(syncManager.leftItemCount.formatted()) \(paneNames.left) · "
            + "\(syncManager.rightItemCount.formatted()) \(paneNames.right)"
    }

    /// The per-side totals the count pill reveals, or nothing when collapsed. `headerFacts` decides
    /// whether there is anything to show (never "0 · 0" pre-scan); the pill's `.help` has the full
    /// text when this truncates.
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

    /// "2 need your decision", beside the transfer buttons that leave those rows out, or nothing
    /// when none are held. Priced from the same string (`HeaderLadder.Facts.heldText`). On every
    /// rung, because when every target is held it is all that says why there is no Copy.
    @ViewBuilder
    private func heldReadout(_ text: String?) -> some View {
        if let text {
            Text(text)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help("Left out of Copy and Move — each row’s note says why")
        }
    }

    // MARK: Header — scope zone

    /// The master disclosure for the table's folder sections: one click collapses every folder,
    /// one more brings them back. `FoldAllAction` owns its rules.
    ///
    /// It opens the scope zone, just before the filter, whose menu holds "Group by folder", which
    /// makes the sections. Not beside `collapseToggle`, which collapses the whole pane: two collapse
    /// controls side by side would differ only by glyph.
    ///
    /// The visible door to the filter menu's Expand All / Collapse All and ⌥-click on a section
    /// triangle, calling the same paths they do.
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
            // Frosted and Clear: a glass circle with a round hover, like every bar button
            // (`ChromeGlass`) — grown 2pt to 28pt, level with the header's pills.
            .chromeGlassGlyphButton(tint: glassHue.accentColor, outset: 2)
            .shortcutKeycap(AppChord.foldAllDifferences.display)
            // Both from `action`, so the tooltip and spoken name describe the same click.
            .help(ShortcutHint.tooltip(action.title, AppChord.foldAllDifferences.display))
            .accessibilityLabel(action.title)
        }
    }

    /// The ⇧⌘F menu item's payload, or `nil` when folding is unavailable: mid-review, collapsed to
    /// the header strip, or with no sections, as for the header's toggle.
    ///
    /// The action is resolved here and carried with the closure, so the item's title and effect
    /// come from one `FoldAllAction.next` call.
    private func foldAllShortcut(sections: [DifferenceGrouping.Section]) -> FoldAllShortcut? {
        guard DifferencesShortcutRules.foldAvailable(sessionActive: reviewStore.session != nil,
                                                     collapsed: collapsed,
                                                     sectionCount: sections.count,
                                                     suspended: shortcutsSuspended) else { return nil }
        let action = FoldAllAction.next(collapsedOnScreen: collapsedOnScreen(sections),
                                        sectionCount: sections.count)
        return FoldAllShortcut(action: action) {
            switch action {
            case .collapse: collapseAll(sections)
            case .expand: collapsedSections.removeAll()
            }
        }
    }

    /// How many of the sections the table is drawing are collapsed.
    ///
    /// The one count, read by the master toggle and the filter menu's two items. Judged against the
    /// visible sections, not `collapsedSections`, which can name folders the filter hides; otherwise
    /// "Expand All" could be lit with nothing to expand.
    private func collapsedOnScreen(_ sections: [DifferenceGrouping.Section]) -> Int {
        sections.filter { collapsedSections.contains($0.folder) }.count
    }

    /// The filter. Drops to its glyph at `.glyphFilter`: the active filter stays checked in the
    /// menu's own column, so the name is one click away rather than gone.
    private func filterMenu(_ compaction: HeaderCompaction,
                            sections: [DifferenceGrouping.Section]) -> some View {
        let name = selectedFilter.displayName(leftName: paneNames.left, rightName: paneNames.right)
        return Menu {
            // Per-filter counts from the `DisplayRows` cache, tallied with the rows. A Menu's
            // content builder runs on every render, not on open, so counting here would re-tally
            // per file during a bulk sync.
            let filterCounts = displayRows.filterCounts
            // A Picker inside a Menu gets the native check column, as the toolbar's Sort menu does.
            Picker("Filter", selection: $session.selectedFilter) {
                // `.failed` is withheld at zero (`DifferenceFilter.isOffered`); everything else is
                // listed at zero, so the menu keeps its shape.
                ForEach(DifferenceFilter.allCases.filter { $0.isOffered(failedCount: filterCounts[.failed, default: 0]) },
                        id: \.self) { filter in
                    // A count on each row, like the Duplicates lens's `Identical (312)`; the button
                    // shows only the active filter's name.
                    Text("\(filter.displayName(leftName: paneNames.left, rightName: paneNames.right)) (\(filterCounts[filter, default: 0]))")
                        .tag(filter)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Divider()
            // Grouping lives here, not in chrome of its own: it is a scope decision like the
            // filter, and the header has no width to spare.
            Toggle("Group by Folder", isOn: $groupByFolder)
            if !sections.isEmpty {
                // Judged against the sections on screen (`collapsedOnScreen`, also read by the
                // master toggle), so the menu and the button agree on what is folded.
                let collapsedCount = collapsedOnScreen(sections)
                Button("Expand All") { collapsedSections.removeAll() }
                    .disabled(collapsedCount == 0)
                Button("Collapse All") { collapseAll(sections) }
                    .disabled(collapsedCount == sections.count)
            }
        } label: {
            if compaction < .glyphFilter {
                // Provider names can be long; truncate rather than clip the header when narrow.
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(name).lineLimit(1).truncationMode(.middle)
                    // The system indicator is hidden so the glyph-only form stays a circle; the
                    // full form draws its own, like the count pill's chevron.
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
        .compareBarGlass()
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter the list — showing \(name)")
    }

    /// The selection chip lives beside the filter, not among the buttons: both answer "acting on
    /// what?", and among the buttons it would read as one.
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

    /// The overflow, present only once the row has folded something into it. It holds only what
    /// the row shed, never a second copy of an action that has a button.
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
            .compareBarGlass()
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
    }

    /// Always carries the count, scoped or not, so the label always says how much it will queue
    /// and a scoped "Review 1" reads against an earlier "Review 123".
    private func reviewTitle(_ targets: DifferenceActionTargets) -> String {
        "Review \(targets.targets.count)"
    }

    @ViewBuilder
    private func reviewButton(_ targets: DifferenceActionTargets, sorted: [FileDifference]) -> some View {
        if !targets.targets.isEmpty {
            Button {
                startReview(targets: targets, sorted: sorted)
            } label: {
                // No ellipsis, which means "opens a dialog": this starts an inline review.
                Label(reviewTitle(targets), systemImage: "checklist")
            }
            .buttonStyle(.actionBar(.outline, tint: glassHue.accentColor,
                                    onTint: glassHue.onAccentLabelColor))
            .compareBarGlass()
            .shortcutKeycap(AppChord.reviewDifferences.display)
            .disabled(isSyncActionBlocked)
            .lockedDuringRun()
            .help(ShortcutHint.tooltip(
                "Step through each difference one at a time — hold ⇧ or ⌘ to move instead of copy",
                AppChord.reviewDifferences.display))
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
            .compareBarGlass()
            .shortcutKeycap(AppChord.verifyDifferences.display)
            .disabled(isSyncActionBlocked)
            .lockedDuringRun()
            // As the review card's Verify, scoped to what the bulk run covers: same-size,
            // date-only differences.
            .help(ShortcutHint.tooltip(
                "Checksum both sides of each same-size, date-only difference to confirm whether the contents actually differ",
                AppChord.verifyDifferences.display))
        }
    }

    /// The reverse transfer, drawn before the primary so the two buttons sit in the order of the
    /// panes they target.
    @ViewBuilder
    private func reverseTransferButton(_ compaction: HeaderCompaction,
                                       isMove: Bool,
                                       targets: DifferenceActionTargets) -> some View {
        if targets.copyToLeftCount > 0 {
            transferButton(
                direction: .copyToLeft,
                count: targets.copyToLeftCount,
                destination: paneNames.left,
                // The layout decides which button is prominent; `dominantCopyDirection` only says
                // whether the quiet direction is the bulk of the work and must keep its name.
                namesDestination: BulkActionLabel.reverseNamesDestination(
                    reverseIsMajority: targets.dominantCopyDirection == .copyToLeft,
                    compaction: compaction),
                // A lone action takes the fill whichever way it points; the fixed direction only
                // picks which of two buttons is primary.
                weight: targets.copyToRightCount > 0 ? .quiet : .primary,
                isMove: isMove,
                targets: targets)
        }
    }

    /// The primary. Always left to right, whatever the counts say (see `TransferGlyph`): a copy
    /// overwrites at its destination, so the biggest button's direction must not change between
    /// scans.
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
        // From the `AppChord` registration, so the badge and the menu item read one value. It
        // includes ⇧ when the button has retitled to Move, so badge and label match.
        let chord = AppChord.transfer(toRight: toRight, isMove: isMove).display
        return Button {
            copy(direction: direction, targets: targets)
        } label: {
            Label(
                BulkActionLabel.text(count: count,
                                     destination: namesDestination ? destination : nil,
                                     isMove: isMove),
                // The direction is fixed, so it is in the icon: a bare arrow for copy, a boxed
                // arrow for move, pointing at the target pane.
                systemImage: isMove ? TransferGlyph.move(toRight: toRight) : TransferGlyph.copy(toRight: toRight)
            )
        }
        .buttonStyle(.actionBar(weight, tint: glassHue.accentColor,
                                onTint: glassHue.onAccentLabelColor))
        // The quiet direction wears the bar's glass like Review and Verify; the opaque primary
        // wears none. `when:`, not a branch, so the button keeps its identity when its weight
        // changes.
        .compareBarGlass(when: weight == .quiet)
        // Above `.disabled`, so the badge stays off a blocked button.
        //
        // The badge only ever shows the ⌘ form: the reveal needs ⌥ held alone, and `isMove` means
        // ⇧ or ⌘ is down. The ungated tooltip is where the ⇧⌘ form shows.
        .shortcutKeycap(chord)
        .disabled(isSyncActionBlocked)
        .lockedDuringRun()
        // The label may shed the destination; the tooltip never does, and it names the verb and
        // the chord.
        .help(ShortcutHint.tooltip(
            BulkActionLabel.help(count: count, destination: destination, isMove: isMove), chord))
        // Nor does the accessible name: at narrow rungs Copy's label reads just "12", and
        // VoiceOver must still tell Copy from Move, whether the source survives.
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
                .foregroundStyle(.primary)
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
        if session.pending.count > 1 {
            // Counts the rows it will copy, not the held ones it leaves: the count is the
            // confirmation. At zero it stays, disabled, and its help says why.
            let copyable = CopyRemainingRoute.copyableCount(session.pending)
            Button {
                copyRemaining(session)
            } label: {
                // The non-directional `TransferGlyph`: each item goes its own way. No ellipsis: it
                // acts at once, and the count it names is the confirmation (see `copyRemaining`).
                Label("\(session.isMove ? "Move" : "Copy") Remaining \(copyable)",
                      systemImage: session.isMove ? TransferGlyph.move : TransferGlyph.copy)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.actionBar(.outline, tint: glassHue.accentColor,
                                    onTint: glassHue.onAccentLabelColor))
            .compareBarGlass()
            // Gated while the current item's copy runs: it is still in `pending`, so `syncAll`
            // would target it twice.
            .disabled(reviewStore.isActing || isSyncActionBlocked || copyable == 0)
            .lockedDuringRun()
            .help(copyable == 0
                  ? "Every remaining item needs your decision — right-click its row to choose which to keep"
                  : "\(session.isMove ? "Move" : "Copy") every remaining item without further review")
        }
        Button {
            exitReview()
        } label: {
            Label("Exit Review", systemImage: "xmark.circle")
        }
        .buttonStyle(.actionBar(.outline, tint: glassHue.accentColor,
                                onTint: glassHue.onAccentLabelColor))
        .compareBarGlass()
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
            TableColumn("Path") { DifferencePathCell(difference: $0, compact: compact, rootName: session.pathRootName) }
                .width(min: 80, ideal: 150)
            TableColumn("Size") { DifferenceSizeCell(difference: $0, compact: compact) }
                .width(min: 70, ideal: 90)
            TableColumn("Status") { ReviewStatusCell(difference: $0, session: session, accent: glassHue.accentColor) }
                .width(min: 96, ideal: 140)
        }
        .scrollContentBackground(.hidden)
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .listDensity(listDensity)
        // The selection highlight follows the app hue (the status cell is handed it).
        .tint(glassHue.accentColor)
        .contextMenu(forSelectionType: FileDifference.ID.self) { ids in
            // Mid-review: no ignore toggle (it edits the live list, not the frozen queue) and no
            // bulk copy/move (that's what the review itself is for). An undecided row keeps its
            // Copy to … items, which are where a held row's "choose which to keep" is made.
            if ids.count == 1, let id = ids.first,
               let difference = session.queue.first(where: { $0.id == id }) {
                inspectionMenuItems(for: difference)
                let copyDirections = session.outcome(for: id) == nil
                    ? DifferenceRowMenu.copyDirections(for: difference) : []
                if !copyDirections.isEmpty { Divider() }
                if copyDirections.contains(.copyToRight) { rowCopyButton(id: id, direction: .copyToRight, inReview: true) }
                if copyDirections.contains(.copyToLeft) { rowCopyButton(id: id, direction: .copyToLeft, inReview: true) }
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
        ScrollViewReader { proxy in
            differencesTable(sorted: sorted, sections: sections)
                // `initial: true` for a table that mounts with the reveal already due, as when
                // Compare was collapsed to its bar when Claude asked.
                .onChange(of: revealIsDue, initial: true) { _, due in
                    if due { reveal(sorted: sorted, sections: sections, proxy: proxy) }
                }
        }
    }

    /// Whether `pendingReveal` can be answered now: the rows on screen were built from the inputs
    /// in force, so the filter `show` set has applied. Until then the rows are the previous
    /// filter's, and the row to scroll to may not be in them, or not where it will be.
    private var revealIsDue: Bool {
        pendingReveal != nil && displayRows.builtFrom == displayInputs
    }

    /// Scrolls the first selected row in display order to the middle of the table; `show` opened
    /// every section. The request is spent either way, so a rescan that brings back a filtered-out
    /// row never scrolls to it later.
    ///
    /// Deferred twice, as `FileTreeView.scrollTreeRow` is: this runs in the update that delivered
    /// the rows, and the table may not hold the row yet (`DifferencesRevealTests`).
    private func reveal(sorted: [FileDifference], sections: [DifferenceGrouping.Section],
                        proxy: ScrollViewProxy) {
        guard let requested = pendingReveal else { return }
        pendingReveal = nil
        guard let id = DifferenceGrouping.firstShown(of: requested, sorted: sorted,
                                                     sections: sections)?.id
        else { return }
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
        DispatchQueue.main.asyncAfter(deadline: .now() + FileTreeView.searchRevealRetryDelay) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    /// The live differences table, with everything that hangs off it.
    @ViewBuilder
    private func differencesTable(sorted: [FileDifference],
                                  sections: [DifferenceGrouping.Section]) -> some View {
        let compact = listDensity == .compact
        // `sections` is empty when grouping is off or not worth it; `groupedSections` holds both
        // gates.
        let grouped = !sections.isEmpty
        // One Table, whichever shape the rows take. Two Tables behind an `if` are two view
        // identities, so toggling grouping (which a bulk sync can do as it consumes rows) would
        // drop column widths and scroll position. `Table(of:)` with a rows builder emits sectioned
        // or flat rows, and the columns are defined once. `sorted` arrives pre-sorted, so
        // `sortOrder` only drives the header chevrons.
        Table(of: FileDifference.self, selection: $selection, sortOrder: $session.sortOrder) {
            TableColumn("Name", value: \.fileName, comparator: .localizedStandard) { DifferenceNameCell(difference: $0, compact: compact, paneRules: paneRules, keptNames: keptNames) }
            TableColumn("Change", value: \.changeSortRank) { DifferenceChangeCell(difference: $0, compact: compact) }
            // Sorted on the bare parent (root rows first, siblings adjacent); the cell anchors it at
            // the compared folder's name, so a root-level row reads "Home", not "".
            TableColumn("Path", value: \.parentPath, comparator: .localizedStandard) { DifferencePathCell(difference: $0, compact: compact, rootName: pathRootName) }
                .width(min: 80, ideal: 150)
            TableColumn("Size", value: \.displaySizeSort) { DifferenceSizeCell(difference: $0, compact: compact) }
                .width(min: 70, ideal: 90)
        } rows: {
            if grouped {
                ForEach(sections) { section in
                    let isCollapsed = collapsedSections.contains(section.folder)
                    SwiftUI.Section {
                        // Collapsing emits no rows; the header is a separate slot and survives
                        // (`collapsedSectionKeepsItsHeader`).
                        ForEach(isCollapsed ? [] : section.rows) { TableRow($0) }
                    } header: {
                        DifferenceSectionHeader(
                            // `title`, not `folder`, the bucket identity (the root is "/").
                            folder: section.title,
                            count: section.count,
                            accent: glassHue.accentColor,
                            isFullySelected: DifferenceGrouping.isFullySelected(section, in: selection),
                            isCollapsed: isCollapsed,
                            // Only the collapsed form shows this O(rows) tally; for expanded
                            // sections it would walk the whole diff on every render.
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
        // Hide the scroll background and the alternating row fills, or the Table paints opaque
        // rows over the surface.
        .scrollContentBackground(.hidden)
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .listDensity(listDensity)
        // Sort chevrons and other table chrome follow the app hue, as in the review table.
        .tint(glassHue.accentColor)
        // The selection: the panes' accent wash in place of the OS highlight, at full strength,
        // since this table has no active/inactive pairing.
        .background(DifferencesTableSelectionStyler(
            washColor: NSColor(glassHue.accentColor)
                .withAlphaComponent(PaneSelectionWash.active)))
        .contextMenu(forSelectionType: FileDifference.ID.self) { ids in
            differenceContextMenu(for: ids, in: sorted)
        }
        .overlay {
            // `hasComputedRows`: the rows land asynchronously, so the first beat shows a blank
            // table, not a false "No differences".
            if sorted.isEmpty, hasComputedRows {
                emptyState
            }
        }
        // Directional Copy/Move is a menu item (`TransferCommands`), with no key handler here: a
        // disabled menu item doesn't consume its equivalent, so a second route would make ⌘→
        // work only sometimes. `chordBelongsToTextEditor` keeps ⌘→ for the search field, and
        // `lastSelectionSurface`, Space's arbiter, says which selection ⌘→ means.
        .focusedSceneValue(\.transferSelection,
                           DifferencesShortcutRules.transferAvailable(
                               selectionCount: selection.count,
                               surface: syncManager.lastSelectionSurface,
                               sessionActive: reviewStore.session != nil,
                               blocked: isSyncActionBlocked,
                               suspended: shortcutsSuspended)
                               // No rows captured here: `keyboardCopy` reads the visible rows
                               // when it fires, because a focused value isn't re-armed while a
                               // menu is open. See `TransferShortcut`.
                               ? TransferShortcut(leftName: paneNames.left, rightName: paneNames.right,
                                                  run: { direction, isMove in
                                                      keyboardCopy(direction: direction, isMove: isMove)
                                                  })
                               : nil)
        // Marks this table as the surface the user means, so Space can tell a Differences
        // selection from a pane one. Only a non-empty selection claims it; a cleared one would
        // point Space at nothing.
        .onChange(of: selection) { _, newSelection in
            guard !newSelection.isEmpty else { return }
            if syncManager.lastSelectionSurface != .differences {
                syncManager.lastSelectionSurface = .differences
            }
        }
        // Quick Look on plain Space, and the one handler that has to arbitrate.
        //
        // `.onKeyPress` is strictly focus-scoped: only the handler in the first responder's subtree
        // runs, and `.ignored` doesn't fall through to a sibling. A click moves first responder to
        // the list it landed in (`PaneListKeyFocus`), but focus and "what the user last picked"
        // still differ, as in a window not yet clicked in. So this asks `CurrentSelection` (via
        // `DifferencesQuery.spaceQuickLookTarget`) rather than assuming its own row.
        //
        // The single-key overload also takes modified presses and key-repeats (see
        // `KeyPress.isPlainKeystroke`); harmless here, since Quick Look moves nothing on disk.
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

    /// Applies a header click to the selection. ⌘ is read from `NSEvent` at click time, not
    /// tracked: a published modifier stream can be a frame stale, and it decides replace or add.
    private func selectSection(_ section: DifferenceGrouping.Section) {
        let intent = SectionClickIntent.resolve(
            commandHeld: NSEvent.modifierFlags.contains(.command),
            isFullySelected: DifferenceGrouping.isFullySelected(section, in: selection))
        selection = DifferenceGrouping.selection(after: intent, section: section, current: selection)
    }

    /// Toggles one section, or with ⌥ held every section, the Finder gesture. The menu items
    /// carry the same actions.
    private func toggleCollapse(_ section: DifferenceGrouping.Section,
                                allSections: [DifferenceGrouping.Section]) {
        guard !NSEvent.modifierFlags.contains(.option) else {
            // Every section takes the clicked section's new state.
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
    /// The one derivation, so the rows builder and the Expand/Collapse All items fold the same
    /// folders. "Not worth grouping" returns empty here, so no caller can forget that gate.
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
    /// modifier is read once, at entry, and fixed for the session (card and header say Move).
    private func startReview(targets: DifferenceActionTargets, sorted: [FileDifference]) {
        let targetIds = Set(targets.targets.map(\.id))
        let queue = sorted.filter { targetIds.contains($0.id) }
        // The anchor freezes with the queue it labels (`ReviewSession.pathRootName`).
        guard let session = ReviewSession(queue: queue, isMove: ModifierTracker.moveModifierHeld,
                                          pathRootName: pathRootName) else { return }
        Logger.shared.debug(
            "Review started: \(queue.count) item(s)"
            + "\(session.isMove ? " (move)" : "")"
            + " (\(targets.isSelectionScoped ? "selection" : "filtered set"))")
        reviewStore.session = session
        selection.removeAll()
        reviewSelection = queue.first.map { [$0.id] } ?? []
    }

    /// Copies or moves the review item through the table row's per-item path, collision prompts
    /// and retryable failure alert included. The outcome is `syncFile`'s return value, not the
    /// list: the rescan after the operation gives rows new UUIDs.
    private func reviewPrimary(_ item: FileDifference) {
        guard let session = reviewStore.session, !reviewStore.isActing else { return }
        reviewStore.isActing = true; let token = session.sessionToken
        let isMove = session.isMove
        Logger.shared.debug("Review \(isMove ? "move" : "copy"): \(item.relativePath)")
        Task { @MainActor in
            // The token is captured above, with the click, not in this Task: a new session over
            // the same set keeps the ids, so only the token can mark this outcome as the old
            // session's. Read after the hop, it would stamp the item into the new queue. `decide`
            // clears `isActing` on every exit.
            let applied = await reviewStore.decide(for: item.id, token: token) {
                // `confirmed`: the review card is the per-item confirmation; a second prompt
                // would double every accept and record its Escape as a Skip.
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

    /// The one place session outcomes land, id-addressed and token-guarded
    /// (`ReviewSessionStore.apply`): a decision arriving after Exit is dropped rather than
    /// resurrecting the session or advancing a replacement with the same ids.
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
        // Summarize after any decision: a skip-only pass still resolved rows.
        if session.copiedCount > 0 || session.skippedCount > 0 {
            let verb = session.isMove ? "moved" : "copied"
            syncManager.banner = .success("Review ended — \(session.copiedCount) \(verb), \(session.skippedCount) skipped, \(session.pending.count) not reviewed")
        }
        reviewStore.session = nil
        reviewSelection = []
    }

    /// "Copy Remaining N": leaves review mode and resolves every pending item through the bulk
    /// path (or the single-item path, whose failure alert carries Retry).
    ///
    /// Held rows keep the session open: every bulk run leaves them out, so the rest is copied
    /// (`FileSyncManager.copyRemaining`, whose banner names the held rows), each row is marked,
    /// and the card stays on the held rows for the user to decide.
    private func copyRemaining(_ session: ReviewSession) {
        let remaining = session.pending
        let isMove = session.isMove
        Logger.shared.debug("Review: \(isMove ? "move" : "copy") remaining \(remaining.count) item(s)")
        if remaining.contains(where: { $0.heldBack != nil }) {
            guard !reviewStore.isActing else { return }
            reviewStore.isActing = true; let token = session.sessionToken
            Task { @MainActor in
                defer { reviewStore.isActing = false }
                guard let resolved = await syncManager.copyRemaining(remaining, isMove: isMove) else { return }
                // Not resolved means a failure or a collision-prompt Skip, as in `reviewPrimary`;
                // both already told the user. Token-guarded like every outcome.
                for item in remaining where item.heldBack == nil {
                    reviewStore.apply(resolved.contains(item.id) ? .copied : .skipped, for: item.id, token: token)
                }
            }
            return
        }
        reviewStore.session = nil
        reviewSelection = []
        // `confirmed`: the button names the exact count and is the confirmation. A prompt per
        // `syncAll` would ask twice for a mixed remainder, and declining the second would drop
        // items silently after the session is gone.
        if case .single(let single) = CopyRemainingRoute.route(remaining) {
            Task { await syncManager.syncFile(single, isMove: isMove, confirmed: true) }
            return
        }
        let hasRight = remaining.contains { $0.action == .copyToRight }
        let hasLeft = remaining.contains { $0.action == .copyToLeft }
        if hasRight && hasLeft {
            // A mixed remainder needs two `syncAll` runs, one per direction, so two undo groups.
            // Their banners are suppressed: the second would overwrite the first with an
            // undercount, and its Undo would reverse only its own half. The rows disappearing is
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

    /// The "<verb> N of M…" progress row above the table during a bulk op, with Cancel while the
    /// operation is cancellable. Shared by Verify and Sync, so the two stay identical.
    @ViewBuilder
    private func syncProgressRow(verb: String, completed: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(verb) \(completed) of \(total)…")
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

    /// Inline search field (second header row): the query, a clear button and a live "N of M"
    /// count, with the parsed filter tokens below and, while focused, one-tap suggestions.
    /// `kind:pdf`, `>10mb` or `only:left` narrow the list; anything else is a path substring.
    ///
    /// The field itself is Design's `ExpandingSearchField`. What is Compare's own: the "N of M"
    /// against the unfiltered total, and chips and suggestions that name the live panes.
    private func searchField(filteredCount: Int) -> some View {
        let tokens = DifferenceSearch.parse(searchText).tokens
        let chips = DifferenceSearch.chips(searchText)
        return ExpandingSearchField(
            text: $session.searchText,
            isExpanded: $session.isSearchExpanded,
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

    /// The recognised filter words as removable chips (Design's `TokenChipsRow`), like the lens
    /// search's: each ✕ edits its word out of the raw text. Labels come from `tokenLabel`, because
    /// the `only:` chips name the live panes.
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
                        // Trim first, so appending never leaves a double space.
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
                    .help("Add “\(suggestion.raw)” to the search")
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
            items: targets.transferItems(direction),
            held: targets.heldItems(direction),
            scope: targets.isSelectionScoped ? "selection" : "filtered set"
        )
    }

    /// The bulk context menu's Copy/Move, resolved when it fires.
    ///
    /// A menu item must not carry the rows it was built from: an NSMenu stays open while scans land
    /// and rows change, so captured values describe the table as it was. Same rule as the ⌘→ path
    /// ("No rows captured here") and `runCopyOrMove`'s move-modifier read.
    ///
    /// Ids, not values, since an id survives a row's contents changing. A full rescan gives rows
    /// new ids, so nothing matches and this does nothing, as `keyboardCopy` does: those rows are
    /// no longer on screen.
    private func bulkTransfer(ids: Set<FileDifference.ID>, direction: FileDifference.SyncAction) {
        guard !isSyncActionBlocked else { return }
        let items = DifferencesShortcutRules.transferItems(rows: displayRows.sorted,
                                                           selection: ids,
                                                           direction: direction)
        let held = DifferencesShortcutRules.heldItems(rows: displayRows.sorted, selection: ids, direction: direction)
        guard !items.isEmpty || !held.isEmpty else { return }
        runCopyOrMove(direction: direction, items: items, held: held, scope: "selection")
    }

    /// What ⌘← / ⌘→ / ⇧⌘← / ⇧⌘→ do, resolved entirely at fire time: a focused value isn't re-armed
    /// while a menu is open (the rule `DeleteSelectionCommand` records), so rows captured earlier
    /// could carry a stale `action` into `syncFile`/`syncAll`.
    ///
    /// The header's dispatch, but scoped strictly to the selection (nothing selected does
    /// nothing) and with `isMove` from ⇧, since ⌘ is always held for this chord. It reads
    /// `displayRows.sorted`, the rows on screen, so a chord never acts on a row the filter hides.
    /// The selection filter is ``DifferencesShortcutRules/transferItems(rows:selection:direction:)``,
    /// which keeps this away from ``DifferenceActionTargets``' whole-set fallback.
    private func keyboardCopy(direction: FileDifference.SyncAction, isMove: Bool) {
        guard !isSyncActionBlocked else { return }
        let items = DifferencesShortcutRules.transferItems(rows: displayRows.sorted,
                                                           selection: selection,
                                                           direction: direction)
        let held = DifferencesShortcutRules.heldItems(rows: displayRows.sorted, selection: selection,
                                                      direction: direction)
        guard !items.isEmpty || !held.isEmpty else { return }
        runCopyOrMove(direction: direction, items: items, held: held, scope: "selection", isMove: isMove)
    }

    /// One Copy/Move dispatch for the header, the bulk menu and the chord, so their wiring can't
    /// drift. The move modifier is read here, at invocation, since an open NSMenu would otherwise
    /// fire a stale action; `isMove` overrides it for the chord, which passes ⇧. A single item goes
    /// through `syncFile`, whose failure alert has Retry; `syncAll` is for multi-item runs.
    ///
    /// `held` is the held rows the caller's rule left out of `items`. They ride into `syncAll`'s
    /// subset, which leaves them out and says how many and why. With any held row in hand the run
    /// is `syncAll` even for one item, because `syncFile` would not mention them.
    private func runCopyOrMove(direction: FileDifference.SyncAction, items: [FileDifference],
                               held: [FileDifference], scope: String, isMove overrideMove: Bool? = nil) {
        let isMove = overrideMove ?? ModifierTracker.moveModifierHeld
        Logger.shared.debug(
            "Bulk \(isMove ? "move" : "copy") \(direction == .copyToRight ? "to right" : "to left"): "
            + "\(items.count) item(s), \(held.count) held (\(scope))")
        if items.count == 1, held.isEmpty, let single = items.first {
            Task { await syncManager.syncFile(single, isMove: isMove) }
        } else if !items.isEmpty || !held.isEmpty {
            Task { await syncManager.syncAll(direction: direction, isMove: isMove, subset: items + held) }
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

    /// The table's blank overlay, on the app's empty-state template. When filtered to nothing it
    /// offers one click out ("Clear Filters", as in the lens workspace), so a filtered table never
    /// reads as having no differences.
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

    /// Right-click menu for the table selection: the per-row menu for one row, bulk
    /// Copy/Move/Ignore for several. `visible` is the sorted, filtered list the ids index into.
    @ViewBuilder
    private func differenceContextMenu(for ids: Set<FileDifference.ID>, in visible: [FileDifference]) -> some View {
        if ids.count == 1, let id = ids.first, let difference = visible.first(where: { $0.id == id }) {
            // The row for the labels and inspection items, the id for the actions that write
            // (see `singleRowMenu`).
            singleRowMenu(for: difference, id: id)
        } else if ids.count > 1 {
            // The ids decide what the actions act on, resolved against the live rows when they
            // fire; the snapshot only feeds the labels' counts.
            bulkMenu(for: ids, snapshot: visible.filter { ids.contains($0.id) })
        }
    }

    /// Per-row menu: the inspection items plus the tree panes' ignore toggle. The read-only items
    /// take the clicked row; the items that write take the id.
    ///
    /// Get Info, Reveal and Copy Path may inspect the row the user pointed at. The ignore toggle
    /// writes `syncManager.ignoredPaths`, keyed on the row's paths, and an NSMenu outlives the
    /// table state it was built from, so it resolves the id against the live rows when it fires,
    /// as the bulk items do. A row gone from the list resolves to nothing, and the toggle does
    /// nothing.
    ///
    /// Each row also gets a Copy to … item per direction its sides allow
    /// (`DifferenceRowMenu.copyDirections`), where a held row's "choose which to keep" is made.
    /// They write, so they take the id too.
    @ViewBuilder
    private func singleRowMenu(for difference: FileDifference, id: FileDifference.ID) -> some View {
        inspectionMenuItems(for: difference)
        if let askClaude {
            askClaudeItem(askClaude, rows: [difference])
        }
        Divider()
        let copyDirections = DifferenceRowMenu.copyDirections(for: difference)
        if copyDirections.contains(.copyToRight) { rowCopyButton(id: id, direction: .copyToRight) }
        if copyDirections.contains(.copyToLeft) { rowCopyButton(id: id, direction: .copyToLeft) }
        if !copyDirections.isEmpty { Divider() }
        let isIgnored = DifferenceRowMenu.isIgnored(difference, ignoredPaths: syncManager.ignoredPaths)
        Button {
            guard let live = DifferencesShortcutRules.rows(displayRows.sorted, matching: [id]).first
            else { return }
            syncManager.ignoredPaths = DifferenceRowMenu.toggledIgnoredPaths(
                for: live,
                ignoredPaths: syncManager.ignoredPaths
            )
        } label: {
            Label(
                isIgnored ? "Include in Comparison" : "Ignore in Comparison",
                systemImage: isIgnored ? "eye" : "eye.slash"
            )
        }
    }

    /// One of a row's Copy to … items: copies the row the way the user chose, against the
    /// engine's suggestion as readily as with it.
    private func rowCopyButton(id: FileDifference.ID, direction: FileDifference.SyncAction,
                               inReview: Bool = false) -> some View {
        let toRight = direction == .copyToRight
        return Button {
            if inReview {
                copyReviewRowFromMenu(id: id, direction: direction)
            } else {
                copyRowFromMenu(id: id, direction: direction)
            }
        } label: {
            Label("Copy to \(toRight ? paneNames.right : paneNames.left)",
                  systemImage: TransferGlyph.copy(toRight: toRight))
        }
        .disabled(isSyncActionBlocked)
    }

    /// Resolved when it fires, like every writing item here: the live row must still be on screen
    /// and still offer this direction. One deliberate copy, through `syncFile` and its prompt,
    /// redirected the way picked and refused when the side it now copies from is a link
    /// (`DifferenceRowMenu.row(_:copiedTo:isSymbolicLink:)`).
    ///
    /// A copy against the suggestion overwrites the newer file, and its prompt says so
    /// (`DifferenceRowMenu.newerDestinationNote`).
    private func copyRowFromMenu(id: FileDifference.ID, direction: FileDifference.SyncAction) {
        guard !isSyncActionBlocked else { return }
        let found = DifferencesShortcutRules.rows(displayRows.sorted, matching: [id]).first
        if let refusal = DifferenceRowMenu.copyRefusal(for: found, direction: direction) {
            Logger.shared.info("Row copy from its menu did nothing: \(refusal)")
            syncManager.banner = .warning(refusal)
            return
        }
        guard let live = found else { return }
        sendRowCopy(live, direction: direction)
    }

    /// The copy both tables' Copy to … items send once their row is resolved: redirected the way
    /// picked and link-checked on the side it now copies from, through `syncFile` and its prompt.
    @discardableResult
    private func sendRowCopy(_ live: FileDifference, direction: FileDifference.SyncAction) -> Task<Bool, Never> {
        Logger.shared.debug("Row copied \(direction == .copyToRight ? "to right" : "to left") from its menu: \(live.relativePath)")
        let fm = syncManager.fileManager
        let row = DifferenceRowMenu.row(live, copiedTo: direction) { path in
            (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink
        }
        let note = DifferenceRowMenu.newerDestinationNote(for: live, copiedTo: direction, paneNames: paneNames)
        return Task { await syncManager.syncFile(row, newerDestinationNote: note) }
    }

    /// The Review table's Copy to … items, where Review's banner sends the user to choose which
    /// side of a held row to keep. Same rule and prompt as the Compare row's (`sendRowCopy`),
    /// resolved when it fires against Review's frozen queue, and only for an undecided row. A copy
    /// that lands marks the row copied; a declined or failed one leaves it for the card.
    private func copyReviewRowFromMenu(id: FileDifference.ID, direction: FileDifference.SyncAction) {
        guard !isSyncActionBlocked, let session = reviewStore.session, !reviewStore.isActing else { return }
        let found = session.pending.first { $0.id == id }
        if let refusal = DifferenceRowMenu.copyRefusal(for: found, direction: direction) {
            Logger.shared.info("Review row copy from its menu did nothing: \(refusal)")
            syncManager.banner = .warning(refusal)
            return
        }
        guard let item = found else { return }
        reviewStore.isActing = true; let token = session.sessionToken
        let copy = sendRowCopy(item, direction: direction)
        Task { @MainActor in
            defer { reviewStore.isActing = false }
            guard await copy.value else { return }
            if reviewStore.apply(.copied, for: id, token: token), reviewStore.session?.isComplete == true {
                finishReview()
            }
        }
    }

    private func askClaudeItem(_ askClaude: DifferencesAskClaude, rows: [FileDifference]) -> some View {
        DifferencesAskClaudeItem(askClaude: askClaude, rows: rows, paneNames: paneNames)
    }

    /// Read-only row actions: Compare…, Open in Edit, and per-side Get Info, Reveal, Quick Look
    /// and Copy Path. Shared by the single-row and review menus; the items are
    /// `DifferenceInspectionMenu`, a view a test can host.
    private func inspectionMenuItems(for difference: FileDifference) -> some View {
        DifferenceInspectionMenu(difference: difference, paneNames: paneNames,
                                 onCompareFilePair: onCompareFilePair,
                                 onOpenInEditor: onOpenInEditor,
                                 onGetInfo: onGetInfo, onQuickLook: onQuickLook)
    }

    /// Bulk menu for a multi-row selection: Copy/Move the selected rows in each direction
    /// (respecting the move modifier) and ignore them all.
    @ViewBuilder
    private func bulkMenu(for ids: Set<FileDifference.ID>, snapshot selected: [FileDifference]) -> some View {
        // Counted by the rule the actions send through, so a held row is in neither.
        let toRight = DifferencesShortcutRules.transferItems(rows: selected, selection: ids, direction: .copyToRight)
        let toLeft = DifferencesShortcutRules.transferItems(rows: selected, selection: ids, direction: .copyToLeft)
        // Label-only snapshot: an open NSMenu can't relabel from `@Published`, so the verb shows
        // the modifier held at build. The action re-reads it in `runCopyOrMove`.
        let isMove = modifierTracker.isMoveModifierPressed
        if !toRight.isEmpty {
            Button {
                bulkTransfer(ids: ids, direction: .copyToRight)
            } label: {
                Label("\(isMove ? "Move" : "Copy") \(toRight.count) to \(paneNames.right)",
                      systemImage: isMove ? TransferGlyph.move(toRight: true) : TransferGlyph.copy)
            }
            .disabled(isSyncActionBlocked)
        }
        if !toLeft.isEmpty {
            Button {
                bulkTransfer(ids: ids, direction: .copyToLeft)
            } label: {
                Label("\(isMove ? "Move" : "Copy") \(toLeft.count) to \(paneNames.left)",
                      systemImage: isMove ? TransferGlyph.move(toRight: false) : TransferGlyph.copy)
            }
            .disabled(isSyncActionBlocked)
        }
        Divider()
        if let askClaude {
            askClaudeItem(askClaude, rows: selected)
            Divider()
        }
        Button {
            // Ids, not the snapshot: `ignoringAll` reads each row's paths, which may have moved.
            syncManager.ignoredPaths = DifferencesQuery.ignoringAll(
                DifferencesShortcutRules.rows(displayRows.sorted, matching: ids),
                in: syncManager.ignoredPaths)
        } label: {
            Label("Ignore \(selected.count) in Comparison", systemImage: "eye.slash")
        }
        Button {
            selection.removeAll()
        } label: {
            Label("Clear Selection", systemImage: "xmark.circle")
        }
    }
}

// MARK: - Row menu

/// The read-only items of a differences row's menu, in order: Compare…, Open in Edit per side,
/// then Get Info, Reveal in Finder, Quick Look and Copy Path per side.
///
/// A view of its own, not a builder method, so a test can host it and read the order it is drawn
/// in (`DifferenceRowMenuDrawnTests`). It holds no state; everything is passed in.
struct DifferenceInspectionMenu: View {
    let difference: FileDifference
    let paneNames: PaneProviderNames
    let onCompareFilePair: (DifferencePair) -> Void
    /// `nil` withholds Open in Edit, as `nil` `onQuickLook` withholds Quick Look.
    let onOpenInEditor: ((String) -> Void)?
    let onGetInfo: (String) -> Void
    let onQuickLook: ((URL) -> Void)?

    var body: some View {
        let sides = DifferenceRowMenu.existingSides(for: difference, paneNames: paneNames)
        // Only where there are two files to compare: `pair(for:paneNames:)` is nil for a one-sided
        // row or a folder, so the item is absent, not inert. Read-only, so the review menu has it.
        if let pair = DifferencesPairCompare.pair(for: difference, paneNames: paneNames) {
            Button {
                onCompareFilePair(pair)
            } label: {
                Label("Compare…", systemImage: "rectangle.split.2x1")
            }
            Divider()
        }
        // Under Compare…, ahead of Get Info, as in the pane row menu. One item per side holding a
        // file the editor opens (text, or a PDF read-only; `editableSides`). A folder or a `.docx`
        // gets none, and no divider either.
        let editable = DifferenceRowMenu.editableSides(for: difference, paneNames: paneNames)
        if let onOpenInEditor, !editable.isEmpty {
            ForEach(editable, id: \.paneName) { side in
                Button {
                    onOpenInEditor(side.path)
                } label: {
                    Label("Open in Edit (\(side.paneName))", systemImage: "square.and.pencil")
                }
            }
            Divider()
        }
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
}

// MARK: - Table cells
//
// Each column's content is its own small view so the `Table` builder stays simple enough for
// the type-checker (a single big Table literal with inline cell closures times out).

private extension View {
    /// The differences-table cells' density font: subheadline when compact, and the view
    /// unmodified otherwise. `.font(nil)` is not a no-op: it clears an inherited font.
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
/// No action buttons, deliberately: a click selects the folder's rows, and the bar acts on a
/// selection, splitting a folder that points both ways across its two transfer buttons. A button
/// here could name only one direction, and selection composes (⌘-click two folders).
///
/// A `Section` header in a SwiftUI `Table` is an ordinary `View`, not a `TableRow`. The selection
/// is a set of row ids, so a header is never selected itself: it selects, then draws the
/// highlight by hand.
struct DifferenceSectionHeader: View {
    /// Vertical padding inside the tap target, above and below the label row.
    ///
    /// It makes the header easy to hit and, since a collapsed table is all headers, sets the
    /// collapsed summary's rhythm. `sectionHeaderIsAComfortableClickTarget` pins the laid-out
    /// height, not this constant.
    ///
    /// 2 is the largest padding that reaches SwiftUI's 28pt floor for a section header row; the
    /// Table adds about 8pt of chrome, so more padding only makes the row taller (measured):
    ///
    ///     padding   7    6    5    4    3    2    1    0
    ///     row      38   36   34   32   30   28   28   28
    ///
    /// The density system can't lower that floor either: Compact's `tableMinRowHeight` moves only
    /// the data rows. Going below 28 would mean shrinking the triangle's hit box or the name.
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
            // Its own hit target: the triangle collapses, the rest of the row selects, so the
            // triangle needs real hit area and the padding below is load-bearing.
            Button(action: onToggleCollapse) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .scaledFont(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
                    .padding(2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Expand this folder · ⌥-click to expand every folder"
                              : "Collapse this folder · ⌥-click to collapse every folder")
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
        // The whole row is the selection target, except the triangle, which takes its own click.
        .frame(maxWidth: .infinity, alignment: .leading)
        // Padding before `contentShape`: otherwise the hit area is only the text's height and a
        // click in the band above it lands on table chrome.
        .padding(.vertical, Self.verticalPadding)
        // Fill the row's height before the shape is taken, so the hit area is the whole 28pt row,
        // not the 20pt label with dead bands. `fittingSize` stays 20pt, so the metrics tests still
        // see the header's own height. That the shape covers the row is reasoned, not proven:
        // SwiftUI's content shape can't be observed from AppKit.
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .background(
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .fill(accent.opacity(isFullySelected ? 0.18 : 0))
                .padding(.vertical, 1)
        )
        .help(isFullySelected
              ? "\(folder) — click to reselect, ⌘-click to deselect"
              : "Select this folder’s differences · ⌘-click to add to the selection")
        // One element: VoiceOver reads "Immigration, 6 differences, selected", not four fragments.
        //
        // `children: .ignore` hides the disclosure Button from VoiceOver, so the named action below
        // puts it back as a rotor action.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(folder), \(count.formatted()) difference\(count == 1 ? "" : "s")")
        .accessibilityValue([isFullySelected ? "selected" : "",
                             isCollapsed ? "collapsed" : ""].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint("Selects this folder’s differences")
        .accessibilityAddTraits(isFullySelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: isCollapsed ? "Expand" : "Collapse", onToggleCollapse)
    }
}

/// Name column: type glyph then the filename, one line, middle-truncated. The location is in the
/// Path column; the full relative path is on the hover help.
///
/// `compact` sets subheadline via `compactCellFont`, since the Table doesn't pass an ambient
/// `.font` into its cells (see Design's `listDensity(_:)`). Internal, not file-private, so
/// `FileExplorerSnapshotTests` can render it, as for `DifferenceSectionHeader`.
struct DifferenceNameCell: View {
    let difference: FileDifference
    var compact: Bool = false
    /// Both panes' rulesets. Defaults to the strictest, so a caller or test with no provider in
    /// mind needn't pick one.
    var paneRules: PaneProviderRules = .strictest
    /// Names the user has said they meant, so a keep made from a pane row also silences the badge
    /// here. Empty for callers with no store.
    var keptNames: Set<String> = []

    /// Why this name will not survive this comparison, or nil when it will.
    ///
    /// Asked of every ruleset in play, answered by the first that objects, so a name only OneDrive
    /// rejects is flagged on a row whose other side is iCloud, just before it is copied. Memoized
    /// per (provider, name), like the pane's.
    ///
    /// `isDirectory: false`: a `FileDifference` is always a file, since folders differ only by
    /// their contents.
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
            // Affix whitespace made visible (`NameDisplay`): a row may exist only because its
            // name differs invisibly from the other side's ("Swimming␣" vs "Swimming").
            Text(NameDisplay.visibleName(difference.fileName))
                .fontWeight(.medium)
                .layoutPriority(1)
            // Beside the name, as on a pane row: a differences row is a copy waiting to happen,
            // so a name the destination will reject is worth knowing before the sync fails.
            RiskyNameBadge(reason: riskyReason)
                .layoutPriority(1)
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .compactCellFont(compact)
        .help(NameDisplay.visiblePath(difference.relativePath))
    }
}

/// Change column: the bare description. A folder's roll-up count is in the Size column
/// (`enclosedItemsText`), where it lines up; the full rolled-up sentence is the hover help.
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
    /// The window's accent, for the "Reviewing" marker — passed rather than read from `.tint`, so it
    /// does not depend on the table's row host passing that down (`AccentFillScanTests`, rule 5).
    let accent: Color

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
                    .foregroundStyle(accent)
            } else {
                Text("Pending")
                    .foregroundStyle(.tertiary)
            }
        }
        .scaledFont(.caption.weight(.medium))
    }
}

/// Path column: where the row's file lives, anchored at the compared folder's name: "Home" for a
/// root-level row, "Home/Legal" for a nested one (`DifferencesQuery.pathColumnText`), so even a
/// root-level file shows its location. Middle-truncated, so the anchor and nearest parent
/// survive a squeeze.
///
/// Internal rather than file-private so `FileExplorerSnapshotTests` can render it directly.
struct DifferencePathCell: View {
    let difference: FileDifference
    var compact: Bool = false
    /// The compared folder's name, or nil when the two roots disagree
    /// (`DifferencesView.pathRootName`); the cell then shows the bare parent path.
    var rootName: String? = nil

    var body: some View {
        Text(NameDisplay.visiblePath(
            DifferencesQuery.pathColumnText(parentPath: difference.parentPath, rootName: rootName)))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .compactCellFont(compact)
            .help(NameDisplay.visiblePath(difference.relativePath))
    }
}

private extension View {
    /// Compare's header pills in Frosted and Clear: a glass capsule (a circle once the pill has
    /// shed its words), like every bar button (`ChromeGlass`). Apply it on the button, after its
    /// style: `.actionBar` flattens its label into a compositing group, where Liquid Glass renders
    /// nothing. The pill's own hairline is its only edge, so no Clear rim (`rim: false`).
    func compareBarGlass(when enabled: Bool = true) -> some View {
        chromeGlassGround(.capsule, rim: false, when: enabled)
    }
}

/// Ask Claude About This on Compare's differences rows: why it can't take these paths now (one is
/// hidden from Claude), or nil; and the hand-off that opens the panel with them attached.
public struct DifferencesAskClaude {
    public let refusal: ([String]) -> String?
    public let ask: ([String]) -> Void

    public init(refusal: @escaping ([String]) -> String?, ask: @escaping ([String]) -> Void) {
        self.refusal = refusal
        self.ask = ask
    }
}

/// Ask Claude About This on differences rows: each row's existing sides, attached for the
/// question. A view of its own so a test can host and draw it.
struct DifferencesAskClaudeItem: View {
    let askClaude: DifferencesAskClaude
    let rows: [FileDifference]
    let paneNames: PaneProviderNames

    var paths: [String] {
        rows.flatMap { DifferenceRowMenu.existingSides(for: $0, paneNames: paneNames).map(\.path) }
    }

    var body: some View {
        let paths = paths
        let refusal = askClaude.refusal(paths)
        Button {
            guard askClaude.refusal(paths) == nil else { return }
            askClaude.ask(paths)
        } label: {
            Label(AskClaudeMenuItems.askTitle(rows.count), systemImage: "bubble.left.and.text.bubble.right")
        }
        .disabled(refusal != nil || paths.isEmpty)
        .help(refusal ?? "Opens Ask Claude with \(rows.count == 1 ? "this difference" : "these differences") attached, for your question.")
    }
}
