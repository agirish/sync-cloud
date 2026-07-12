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
    @AppStorage(LiquidGlass.intensityKey) private var glassIntensity: Double = 0.65
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    @State private var selectedFilter: DifferenceFilter = .all
    /// Toggles the per-side item totals beside the count pill — clicking the pill reveals them,
    /// clicking again collapses. Off by default so the header stays uncluttered until asked.
    @State private var showItemCounts = false
    /// Hover state for the count pill: a slight grow signals the pill is clickable (post-scan only).
    @State private var isCountPillHovered = false
    @State private var searchText = ""
    @State private var selection = Set<FileDifference.ID>()
    @State private var sortOrder: [KeyPathComparator<FileDifference>] = [KeyPathComparator(\.fileName, comparator: .localizedStandard, order: .forward)]
    @State private var isSearchExpanded = false
    @FocusState private var searchFocused: Bool
    /// The review table's selection — doubles as the review cursor: advancing the session moves
    /// it, and clicking a pending row jumps the session. Separate from `selection` so entering
    /// and leaving review mode can't corrupt the normal table's selection.
    @State private var reviewSelection = Set<FileDifference.ID>()
    /// Bumped on every review-table click so the card re-claims key focus (see `focusNudge`).
    @State private var reviewFocusNudge = 0
    private let paneNames: PaneProviderNames
    private let onQuickLook: ((URL) -> Void)?
    /// Leading accessory rendered at the start of the header row — the host passes the
    /// Differences/Details tab picker here so the tabs merge into this single toolbar.
    private let leadingHeader: AnyView?
    /// - Parameters:
    ///   - reviewStore: The host-owned guided-review state (`@StateObject` at the host, NOT
    ///     created inline here — a per-render store would reset the session every render).
    ///   - onQuickLook: Presents a Quick Look preview for the given file. The app routes this
    ///     to the same `quickLookPreview` binding the spacebar shortcut uses, so there is a
    ///     single presenter; `nil` hides the Quick Look menu items.
    public init(syncManager: FileSyncManager, reviewStore: ReviewSessionStore, paneNames: PaneProviderNames = .leftRight, onQuickLook: ((URL) -> Void)? = nil, leadingHeader: AnyView? = nil) {
        self.syncManager = syncManager
        self.reviewStore = reviewStore
        self.paneNames = paneNames
        self.onQuickLook = onQuickLook
        self.leadingHeader = leadingHeader
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
        syncManager.verifiedIdenticalForCopy?.count ?? 0
    }
    private var glassHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: glassHueRaw) ?? .blue
    }
    private var surfaceStyle: SurfaceStyle {
        SurfaceStyle(rawValue: surfaceStyleRaw) ?? .unified
    }

    public var body: some View {
        // Derive everything once per render: the header reads the target counts several times and
        // this view re-renders per file during bulk sync. One O(n) filter+search pass, then an
        // O(n log n) sort over the (much smaller, filtered) result to match the Table's sortOrder.
        // Skipped outright in review mode: nothing renders from them there, and every review
        // decision triggers a rescan whose republished list would re-run the pass per render.
        let isReviewing = reviewStore.session != nil
        let filtered = isReviewing ? [] : DifferencesQuery.filtered(syncManager.differences, filter: selectedFilter, searchText: searchText)
        let sorted = isReviewing ? [] : filtered.sorted(using: sortOrder)
        let targets = DifferenceActionTargets(filtered: filtered, selection: selection)
        // Per-filter counts for the filter menu rows, tallied in one pass (not once per filter).
        // Skipped in review mode — the standard header (its only reader) isn't shown there.
        let filterCounts = isReviewing ? [:] : DifferencesQuery.counts(syncManager.differences)

        return VStack(spacing: 8) {
            // Toolbar card: tabs · count · filter · actions · search.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if let leadingHeader {
                        leadingHeader
                    }
                    if let session = reviewStore.session {
                        reviewHeaderControls(session)
                    } else {
                        standardHeaderControls(targets: targets, sorted: sorted, filterCounts: filterCounts)
                    }
                }
                if reviewStore.session == nil, isSearchExpanded || !searchText.isEmpty {
                    searchField(filteredCount: filtered.count)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tint(glassHue.accentColor)
            // Match the top action bar's glass pills: capsule shape, the taller `.large` control
            // height, but the label font pinned to the top bar's ~13pt `.body` (otherwise `.large`
            // would scale the text up too). Result: same pill height AND same text size.
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .font(.body)
            .bottomSectionCard(surfaceStyle, intensity: glassIntensity, hue: glassHue, tint: surfaceTint)

            // Table card: review card / progress (during ops) sits above the differences table.
            VStack(spacing: 0) {
                if let session = reviewStore.session {
                    reviewSection(session)
                } else {
                    standardTableSection(sorted: sorted)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .bottomSectionCard(surfaceStyle, intensity: glassIntensity, hue: glassHue, tint: surfaceTint)
        }
        // Match the pane cards' gutter so the bottom cards line up with the panes above.
        .padding(LiquidGlass.cardGutter)
        // Review-cursor plumbing, both directions: a row click jumps the session (pending rows
        // only — decided rows snap the highlight back), and a session advance re-highlights.
        .onChange(of: reviewSelection) { _, newSelection in
            guard let session = reviewStore.session else { return }
            // Any click hands key focus to the Table; send it back to the card.
            reviewFocusNudge += 1
            // Deselection (⌘-click on the selected row) must snap back too — the highlight IS
            // the cursor and may not go dark until the next advance.
            guard let id = newSelection.first else {
                reviewSelection = session.current.map { [$0.id] } ?? []
                return
            }
            guard id != session.current?.id else { return }
            var updated = session
            if updated.jump(to: id) {
                reviewStore.session = updated
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

    // MARK: Header

    /// The header's normal (non-review) trailing controls: count pill, filter, selection chip,
    /// Review…, the bulk Copy/Move buttons, Verify, and the search toggle.
    @ViewBuilder
    private func standardHeaderControls(targets: DifferenceActionTargets, sorted: [FileDifference], filterCounts: [DifferenceFilter: Int]) -> some View {
        // The count pill is a toggle for the per-side item totals: click to reveal them inline,
        // click again to collapse. No-op until a scan has run (nothing meaningful to show) —
        // so the chevron affordance is also withheld pre-scan: no invitation on a dead control.
        Button {
            guard syncManager.hasScanned else { return }
            withAnimation(.easeInOut(duration: 0.15)) { showItemCounts.toggle() }
        } label: {
            StatPill(
                count: syncManager.differences.count,
                label: "Differences",
                color: .orange,
                systemImage: "exclamationmark.triangle",
                // Totals expand to the pill's right and collapse back left; the chevron
                // points the way the next click will send them, and is withheld pre-scan
                // (CountPillChevron owns both rules).
                trailingSystemImage: CountPillChevron.symbol(hasScanned: syncManager.hasScanned, expanded: showItemCounts)
            )
            .scaleEffect(isCountPillHovered ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            // Grow only post-scan, but always honor hover-exit: if hasScanned flips false
            // mid-hover (it resets on navigation) a gated reset would strand the pill at 1.03.
            withAnimation(.easeInOut(duration: 0.12)) {
                isCountPillHovered = hovering && syncManager.hasScanned
            }
        }
        // A fresh scan starts collapsed: expansion is opt-in per result set, not a sticky
        // preference that silently reapplies to counts the user never asked to see.
        .onChange(of: syncManager.hasScanned) { _, hasScanned in
            if !hasScanned {
                showItemCounts = false
                isCountPillHovered = false
            }
        }
        .help(syncManager.hasScanned
              ? "\(syncManager.leftItemCount.formatted()) \(paneNames.left) · \(syncManager.rightItemCount.formatted()) \(paneNames.right)"
              : "Scan to see per-side item totals")
        // StatPill collapses itself to one element labeled "N Differences"; the value/hint
        // ride on the button so VoiceOver conveys the toggle state and what a click does.
        .accessibilityValue(syncManager.hasScanned ? (showItemCounts ? "expanded" : "collapsed") : "")
        .accessibilityHint(syncManager.hasScanned ? "Shows or hides the per-side item totals" : "")
        // Revealed on demand; `hasScanned` keeps it from ever reading "0 · 0" pre-scan, and the
        // pill's `.help` still spells out the full text on hover when this truncates.
        if syncManager.hasScanned, showItemCounts {
            Text("\(syncManager.leftItemCount.formatted()) \(paneNames.left) · \(syncManager.rightItemCount.formatted()) \(paneNames.right)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .transition(.opacity)
        }
        Spacer()
        Menu {
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
        } label: {
            // Uncapped provider names can be long; truncate instead of forcing the
            // full width (fixedSize) and clipping the header on narrow windows.
            Label(
                selectedFilter.displayName(leftName: paneNames.left, rightName: paneNames.right),
                systemImage: "line.3.horizontal.decrease.circle"
            )
            .lineLimit(1)
            .truncationMode(.middle)
        }
        if targets.isSelectionScoped {
            Button {
                selection.removeAll()
            } label: {
                HStack(spacing: 4) {
                    Text("\(targets.targets.count) selected")
                    Image(systemName: "xmark.circle.fill")
                }
                .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Clear selection")
        }
        if !targets.targets.isEmpty {
            Button {
                startReview(targets: targets, sorted: sorted)
            } label: {
                Label(targets.isSelectionScoped ? "Review \(targets.targets.count)…" : "Review…", systemImage: "checklist")
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .disabled(isSyncActionBlocked)
            .help("Step through each difference one at a time — hold ⇧ or ⌘ to move instead of copy")
        }
        if targets.copyToRightCount > 0 {
            Button {
                copy(direction: .copyToRight, targets: targets)
            } label: {
                Label(
                    actionLabel(count: targets.copyToRightCount, to: paneNames.right),
                    // Shares the toolbar/menu copy/move vocabulary (TransferGlyph). The button
                    // doubles as Move when the modifier is held, so its icon follows suit:
                    // the directional move box (pointing at the target pane) vs. the copy glyph.
                    systemImage: modifierTracker.isMoveModifierPressed ? TransferGlyph.move(toRight: true) : TransferGlyph.copy
                )
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSyncActionBlocked)
        }
        if targets.copyToLeftCount > 0 {
            Button {
                copy(direction: .copyToLeft, targets: targets)
            } label: {
                Label(
                    actionLabel(count: targets.copyToLeftCount, to: paneNames.left),
                    systemImage: modifierTracker.isMoveModifierPressed ? TransferGlyph.move(toRight: false) : TransferGlyph.copy
                )
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSyncActionBlocked)
        }
        if targets.verifiableCount > 0 {
            Button {
                verify(targets: targets)
            } label: {
                Label("Verify \(targets.verifiableCount)", systemImage: "checkmark.shield")
            }
            .buttonStyle(.bordered)
            .disabled(isSyncActionBlocked)
            // Same explanation as the review card's Verify, scoped to what the bulk run
            // actually covers: only date-only differences whose sizes match are checksummed.
            .help("Checksum both sides of each same-size, date-only difference to confirm whether the contents actually differ")
        }
        // Search collapses to an icon; clicking it reveals the field on a second
        // line, which takes focus itself on appear (a FocusState write here, in
        // the same transaction that inserts the field, can be silently dropped).
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                isSearchExpanded.toggle()
                if !isSearchExpanded { searchText = "" }
            }
        } label: {
            Image(systemName: "magnifyingglass")
        }
        .buttonStyle(.borderless)
        .foregroundStyle((isSearchExpanded || !searchText.isEmpty) ? glassHue.accentColor : Color.secondary)
        .help("Search by name or path")
        .accessibilityLabel("Search by name or path")
    }

    /// The header's review-mode trailing controls: position pill, running tally, and the
    /// session-level actions (finish the rest in bulk, or exit).
    @ViewBuilder
    private func reviewHeaderControls(_ session: ReviewSession) -> some View {
        // Mockup-style position pill: dot + "Reviewing N of M" (reads as a sentence, unlike
        // StatPill's count-first layout).
        HStack(spacing: 6) {
            Circle()
                .fill(glassHue.accentColor)
                .frame(width: 7, height: 7)
            Text("Reviewing \(session.position) of \(session.total)")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(glassHue.accentColor)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(glassHue.accentColor.opacity(0.10)))
        .overlay(Capsule(style: .continuous).strokeBorder(glassHue.accentColor.opacity(0.45), lineWidth: 0.5))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reviewing \(session.position) of \(session.total)")
        Spacer()
        if session.copiedCount + session.skippedCount > 0 {
            Text("\(session.copiedCount) \(session.isMove ? "moved" : "copied") · \(session.skippedCount) skipped")
                .font(.caption)
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
            .buttonStyle(.bordered)
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
        .buttonStyle(.bordered)
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
            onVerdict: { reviewVerdict($1, for: $0) },
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
        Table(session.queue, selection: $reviewSelection) {
            TableColumn("Name") { DifferenceNameCell(difference: $0) }
            TableColumn("Change") { DifferenceChangeCell(difference: $0) }
            TableColumn("Size") { DifferenceSizeCell(difference: $0) }
                .width(min: 70, ideal: 90)
            TableColumn("Status") { ReviewStatusCell(difference: $0, session: session) }
                .width(min: 96, ideal: 140)
        }
        .scrollContentBackground(.hidden)
        .tableStyle(.inset(alternatesRowBackgrounds: false))
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
    private func standardTableSection(sorted: [FileDifference]) -> some View {
        if let progress = syncManager.verifyAllProgress {
            syncProgressRow(verb: "Verifying", completed: progress.completed, total: progress.total)
        }
        if let progress = syncManager.bulkSyncProgress {
            syncProgressRow(verb: "Syncing", completed: progress.completed, total: progress.total)
        }
        Table(sorted, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.fileName, comparator: .localizedStandard) { DifferenceNameCell(difference: $0) }
            TableColumn("Change", value: \.changeSortRank) { DifferenceChangeCell(difference: $0) }
            TableColumn("Size", value: \.displaySizeSort) { DifferenceSizeCell(difference: $0) }
                .width(min: 70, ideal: 90)
            TableColumn("Copy to", value: \.copyToSortRank) { DifferenceDirectionCell(difference: $0, paneNames: paneNames) }
                .width(min: 96, ideal: 140)
        }
        // Let the surface fill below show through: hide the scroll background AND the
        // alternating row fills, or the Table paints opaque (white) rows over the surface.
        .scrollContentBackground(.hidden)
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: FileDifference.ID.self) { ids in
            differenceContextMenu(for: ids, in: sorted)
        }
        .overlay {
            if sorted.isEmpty {
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
        // Quick Look the topmost selected row's source side — matches the pane/review Space loop.
        .onKeyPress(.space) {
            guard let onQuickLook, let primary = sorted.first(where: { selection.contains($0.id) }) else {
                return .ignored
            }
            onQuickLook(URL(fileURLWithPath: primary.reviewSourcePath))
            return .handled
        }
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
        reviewStore.isActing = true
        let isMove = session.isMove
        Logger.shared.debug("Review \(isMove ? "move" : "copy"): \(item.relativePath)")
        Task { @MainActor in
            // confirmed: the review card IS the per-item confirmation UI — re-running the
            // transferConfirmer here doubled every accept, and an Escape on that redundant
            // prompt was recorded as a deliberate Skip in the session tally.
            let succeeded = await syncManager.syncFile(item, isMove: isMove, confirmed: true)
            reviewStore.isActing = false
            // Not copied = failure or Skip at the collision prompt; both already told the user.
            applyReviewOutcome(succeeded ? .copied : .skipped, for: item.id)
        }
    }

    private func reviewSkip(_ item: FileDifference) {
        guard !reviewStore.isActing else { return }
        applyReviewOutcome(.skipped, for: item.id)
    }

    /// The one place session outcomes land. Id-addressed (the user may have jumped rows while
    /// the copy ran) and guarded on the session still existing — a decision arriving after Exit
    /// tore the session down is dropped instead of resurrecting it.
    private func applyReviewOutcome(_ outcome: ReviewSession.Outcome, for id: UUID) {
        guard var session = reviewStore.session else { return }
        session.record(outcome, for: id)
        reviewStore.session = session
        if session.isComplete { finishReview() }
    }

    /// Records a per-item Verify verdict; same teardown guard as outcomes.
    private func reviewVerdict(_ verdict: ReviewSession.VerifyVerdict, for id: UUID) {
        guard var session = reviewStore.session else { return }
        session.recordVerdict(verdict, for: id)
        reviewStore.session = session
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
        if session.copiedCount > 0 {
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
        } else {
            Task {
                // syncAll takes one direction and filters the subset by it; a mixed-direction
                // remainder needs both runs — sequential, since syncAll refuses to overlap.
                await syncManager.syncAll(direction: .copyToRight, isMove: isMove, subset: remaining, confirmed: true)
                await syncManager.syncAll(direction: .copyToLeft, isMove: isMove, subset: remaining, confirmed: true)
            }
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let activeProgress = syncManager.activeProgress, activeProgress.isCancellable {
                    Button("Cancel") {
                        activeProgress.cancel()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            ProgressView(value: Double(completed), total: Double(total))
                .progressViewStyle(.linear)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    /// Inline search field (second header row): a magnifier, the query, a clear button, and a
    /// live "N of M" match count when a filter or search narrows the list.
    private func searchField(filteredCount: Int) -> some View {
        HStack(spacing: 6) {
            TextField("Search by name or path", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                // Focus is claimed here, once the field exists — not by the reveal button,
                // whose FocusState write lands in the transaction that inserts the field
                // and can fail silently. The one-turn defer outlives that transaction.
                .onAppear { Task { @MainActor in searchFocused = true } }
                .onExitCommand { collapseSearch() }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
            if selectedFilter != .all || !searchText.isEmpty {
                Text("\(filteredCount) of \(syncManager.differences.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
    }

    /// The Copy/Move button label, reflecting the target count and the held move modifier.
    private func actionLabel(count: Int, to name: String) -> String {
        "\(modifierTracker.isMoveModifierPressed ? "Move" : "Copy") \(count) to \(name)"
    }

    /// Escape in the search field: clear the query and collapse back to the icon.
    private func collapseSearch() {
        withAnimation(.easeOut(duration: 0.15)) {
            searchText = ""
            isSearchExpanded = false
        }
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

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: searchText.isEmpty ? "line.3.horizontal.decrease.circle" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(emptyStateMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var emptyStateMessage: String {
        if !searchText.isEmpty {
            return "No differences match “\(searchText)”."
        }
        if selectedFilter != .all {
            return "No items match the current filter."
        }
        return "No differences."
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

/// Name column: type glyph, dimmed parent path, then the filename — single line, middle-truncated.
private struct DifferenceNameCell: View {
    let difference: FileDifference

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: DifferenceGlyph.symbol(for: difference.type, filled: true))
                .foregroundStyle(DifferenceGlyph.color(for: difference.type))
                .symbolRenderingMode(.hierarchical)
            // Affix whitespace made visible (NameDisplay): a row can exist precisely because
            // its name differs invisibly from the other side's ("Swimming␣" vs "Swimming").
            if !difference.parentPath.isEmpty {
                Text(NameDisplay.visiblePath(difference.parentPath) + "/")
                    .foregroundStyle(.secondary)
            }
            Text(NameDisplay.visibleName(difference.fileName))
                .fontWeight(.medium)
                .layoutPriority(1)
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .help(NameDisplay.visiblePath(difference.relativePath))
    }
}

/// Change column: the description with the folder roll-up ("… — includes N items").
private struct DifferenceChangeCell: View {
    let difference: FileDifference

    var body: some View {
        Text(difference.rolledUpDescription)
            .foregroundStyle(DifferenceGlyph.color(for: difference.type))
            .lineLimit(1)
            .truncationMode(.tail)
            .help(difference.rolledUpDescription)
    }
}

/// Size column: the source side's byte size (right-aligned, monospaced), or "—" for folders/unknown.
private struct DifferenceSizeCell: View {
    let difference: FileDifference

    var body: some View {
        Text(difference.displaySize.map { FileSizeFormat.byteCount.string(fromByteCount: Int64($0)) } ?? "—")
            .monospacedDigit()
            .foregroundStyle(.secondary)
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
                        .foregroundStyle(.green)
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
        .font(.caption.weight(.medium))
    }
}

/// Copy-to column: a small tinted direction chip (blue → right, purple → left) naming the destination pane.
private struct DifferenceDirectionCell: View {
    let difference: FileDifference
    let paneNames: PaneProviderNames

    var body: some View {
        let toRight = difference.action == .copyToRight
        let tint = DifferenceGlyph.color(toRight: toRight)
        HStack(spacing: 4) {
            Image(systemName: toRight ? "arrow.right" : "arrow.left")
                .font(.caption2.weight(.bold))
            Text(toRight ? paneNames.right : paneNames.left)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule(style: .continuous).fill(tint.opacity(0.15)))
    }
}
