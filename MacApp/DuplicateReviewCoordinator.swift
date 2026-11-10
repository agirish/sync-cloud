import SwiftUI
import Sync
import Events
import FileExplorer
import Design

/// The duplicate-review flow handed off from the Duplicates lens to Compare: opening two copies
/// side by side (`compareCopies`), the keep-left / trash-right banner and its actions, and the
/// teardown and restore driven by `CompareReviewReducer`. The reducer makes the decisions; this
/// runs the effects: provider pinning, suppression seeding, focus, invalidation and rescans.
///
/// Stateless: the review state is App-owned (`duplicateReview`, `reviewStore`) so it outlives the
/// window, and this holds only bindings, references and closures over it. The closures read live
/// state on every call, so a read after an await (`trashRightCopy`'s post-trash dispatch) sees
/// the review and panes as they are then.
@MainActor
struct DuplicateReviewCoordinator {
    let syncManager: FileSyncManager
    let reviewStore: ReviewSessionStore

    /// Active "compare two duplicate copies" handoff — App-owned; see `ContentView.duplicateReview`.
    @Binding var duplicateReview: DuplicateCompareContext?
    @Binding var leftProviderId: String
    @Binding var rightProviderId: String
    /// `ContentView`'s suppression counter for in-flight programmatic provider-id writes. Bump it
    /// before `applyProviderPinAssignments` writes any id, so each suppressed onChange finds a
    /// positive counter to decrement.
    @Binding var pendingSwapProviderChanges: Int
    @Binding var selectedWorkspace: Workspace
    /// The rail item to select when returning to a lens inside Organize. Naming the workspace alone
    /// would land on Organize's overview, not back on the duplicates list.
    @Binding var organizeLens: OrganizeLens?

    /// The banner icon's tint (the host's glass accent).
    let accentColor: Color
    /// The host's glass material — the banner's Done button frosts at Clear like every other
    /// control on a see-through card.
    let glassLevel: GlassLevel

    /// The two panes' absolute focused paths, resolved live by the host (provider root + relative
    /// path) — `duplicateReviewActive` compares them against the reviewed copies.
    let currentLeftPath: @MainActor () -> String
    let currentRightPath: @MainActor () -> String
    /// Whether a lens scan/inspect targets the right pane (see `PaneLogic.lensTargetsRightPane`).
    let lensTargetIsRight: @MainActor () -> Bool
    /// The provider root of the pane a lens action targets, tilde-expanded.
    let lensProviderRootExpanded: @MainActor () -> String

    /// Reloads both pane trees and runs a diff scan (the host's `refreshAction`).
    let refreshAction: @MainActor () -> Void
    /// Applies a `ProviderPinPlan`'s id writes, left before right. Lives in `ContentView`, which
    /// the pane swap shares; callers seed `pendingSwapProviderChanges` with `plan.suppressCount`
    /// first.
    let applyProviderPinAssignments: @MainActor (ProviderPinPlan) -> Void

    /// Confirms trashing the reviewed right copy. A seam, like Sync's `transferConfirmer`, because
    /// `NativeAlerts.confirmDestructive` is a blocking modal a test can't answer. Defaults to the
    /// real alert.
    var confirmTrashRightCopy: @MainActor (DuplicateCompareContext) -> Bool = { review in
        NativeAlerts.confirmDestructive(
            messageText: "Move the right copy of “\(review.groupName)” to the Trash?",
            // ⌘Z is not always available: on a volume with no Trash (exFAT, most SMB shares)
            // `deleteItems` escalates to a permanent delete, which registers no undo. The text
            // names that second alert (`SyncOperationAlerts.confirmPermanentDelete`) rather than
            // promising undo unconditionally.
            informativeText: "Trashes \((review.deletePath as NSString).abbreviatingWithTildeInPath). The left copy is kept. Undo with ⌘Z. On a volume with no Trash you’ll be asked first, and a permanent delete can’t be undone.",
            confirmTitle: "Move to Trash")
    }

    /// Opens two copies of a duplicate *folder* group side by side in Compare: the keeper on the
    /// left, the delete candidate on the right. A group never spans providers, so this pins both
    /// panes to the lens's provider, focuses each on its copy and runs the diff. The lens results
    /// survive, so the user can go back to the list for the next pair.
    ///
    /// A provider-id change normally clears the lens results and resets navigation, which would
    /// wipe the list and the focus set here, so each id change is suppressed through
    /// `pendingSwapProviderChanges`, as a pane swap does.
    func compareCopies(keep: DuplicateCopy, delete: DuplicateCopy) {
        let providerId = lensTargetIsRight() ? rightProviderId : leftProviderId
        let providerRoot = lensProviderRootExpanded()
        let keepPath = (keep.path as NSString).expandingTildeInPath
        let deletePath = (delete.path as NSString).expandingTildeInPath
        // `PathBoundary` is boundary-safe on "/" ("/a/Docs" never claims "/a/DocsBackup"). A copy
        // outside the root refuses the compare, with no fallback: a wrong relative path would
        // focus a pane on the wrong folder.
        guard !providerRoot.isEmpty,
              let keepRel = PathBoundary.relativize(keepPath, under: providerRoot),
              let deleteRel = PathBoundary.relativize(deletePath, under: providerRoot) else {
            Logger.shared.warning("Compare copies: a copy path sits outside the scanned provider root — skipping")
            return
        }
        // Snapshot the Compare setup so ending the review restores it. A review already in
        // progress has pinned the panes, so keep its original snapshot, not the pinned one.
        let restore = duplicateReview?.restore ?? SavedCompareState(
            leftProviderId: leftProviderId, rightProviderId: rightProviderId,
            leftRelativePath: syncManager.leftRelativePath, rightRelativePath: syncManager.rightRelativePath)

        // The comparison is changing, so end any guided review framed on the old panes; the id
        // onChange would do this, but it is about to be suppressed. `duplicateReview` is set
        // below, after the panes are pinned.
        dispatchReview(.compareCopiesStarted)

        // Suppress the id onChange for each id that actually changes, so neither clears the lens
        // duplicate results nor resets the focus applied just below.
        let plan = ProviderPinPlan.make(
            currentLeft: leftProviderId, currentRight: rightProviderId,
            targetLeft: providerId, targetRight: providerId)
        pendingSwapProviderChanges += plan.suppressCount
        applyProviderPinAssignments(plan)
        // The suppression also skips the onChange's ignore-store re-key, so re-key here, or the
        // diff is filtered through the old pair's ignores and hides real differences from the
        // review that decides whether a copy is safe to trash.
        syncManager.ignoredItemsStore?.activate(
            pairKey: IgnoredItemsStore.pairKey(providerId, providerId))
        // It also skips `retargetPane`'s invalidation, so drop the old differences here: their
        // paths point at roots the panes are leaving, and would stay actionable until the
        // re-diff lands. Targeted, so the duplicate results survive.
        syncManager.invalidateDifferencesForPaneRetarget()
        syncManager.focusOn(relativePath: keepRel, isLeft: true)
        syncManager.focusOn(relativePath: deleteRel, isLeft: false)
        duplicateReview = DuplicateCompareContext(
            groupName: keep.name, keepPath: keepPath, deletePath: deletePath,
            keepIsDirectory: keep.isDirectory, keepScannedSize: keep.size,
            keepScannedDate: keep.modificationDate,
            deleteIsDirectory: delete.isDirectory, deleteScannedSize: delete.size,
            deleteScannedDate: delete.modificationDate,
            keepContentSnapshot: keep.contentSnapshot,
            deleteContentSnapshot: delete.contentSnapshot,
            keeperRelativePath: keepRel, redundantRelativePath: deleteRel, restore: restore,
            deleteUniqueItemCount: delete.uniqueItemCount,
            // Read off the live group, since the click passes copies, not the group. A pair no
            // group holds keeps the default, which compares dates.
            matchKind: syncManager.liveGroup(holding: delete.path, and: keep.path)?.matchType.kind
                ?? .overlapping)

        Logger.shared.info("Comparing duplicate copies — keep \(keepPath) · delete candidate \(deletePath)")
        selectedWorkspace = .compare
        refreshAction()
    }

    /// Whether the duplicate-review banner should show: a handoff is active AND both panes are still
    /// focused on exactly the two copies it opened. If the user drills either pane elsewhere, the
    /// comparison is no longer that review, so the scoped trash action disappears with the banner.
    func duplicateReviewActive(_ review: DuplicateCompareContext) -> Bool {
        (currentLeftPath() as NSString).expandingTildeInPath == review.keepPath
            && (currentRightPath() as NSString).expandingTildeInPath == review.deletePath
    }

    /// The keep-left / trash-right banner shown over Compare during a duplicate-copy review.
    @ViewBuilder
    func duplicateReviewBanner(_ review: DuplicateCompareContext) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.split.2x1")
                .scaledFont(.system(size: 14, weight: .semibold))
                .foregroundStyle(accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Reviewing duplicate “\(review.groupName)”")
                    .scaledFont(.system(size: 12, weight: .semibold))
                Text("Keeping the left copy — the right is the one you’re deciding on")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Done") { endDuplicateReview() }
                .chromeButtonStyle(glassLevel)
                .controlSize(.small)
                .chromeHover()
            Button(role: .destructive) { trashRightCopy(review) } label: {
                Label("Trash Right Copy", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .accentedProminent()
            .chromeHover()
            .controlSize(.small)
            .lockedDuringRun()
            .help("Move the right copy to the Trash and keep the left one")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        // No fill or divider of its own: the host mounts this as a `bottomSectionCard`, so it
        // lines up with the workspace's card stack.
    }

    /// The review's "Done" button: tears down the review (guided + duplicate) and restores the
    /// Compare setup it overrode. Routed through the shared reducer.
    func endDuplicateReview() {
        dispatchReview(.reviewDone)
    }

    /// Applies the `CompareReviewReducer`'s decision for `event` to the host's state — the single
    /// place the duplicate-review / guided-review teardown decisions live. The reducer decides WHICH
    /// effects run; the implementations stay here. The restore snapshot is captured up front so
    /// `.clearDuplicateReview` may precede `.restoreCompareState` in the effect list.
    func dispatchReview(_ event: CompareReviewEvent) {
        let state = CompareReviewState(
            hasDuplicateReview: duplicateReview != nil,
            duplicateReviewActive: duplicateReview.map(duplicateReviewActive) ?? false,
            isGuidedReviewing: reviewStore.isReviewing
        )
        let restoreSnapshot = duplicateReview?.restore
        for effect in CompareReviewReducer.effects(for: event, state: state) {
            switch effect {
            case .endGuidedReview:
                endReviewForComparisonChange()
            case .clearDuplicateReview:
                // Log the teardown with its cause: the banner going is visible, but why it went
                // is not. Bound rather than defaulted, so an emit with no review writes nothing
                // instead of a made-up name.
                if let discarding = duplicateReview {
                    Logger.shared.info(
                        "Discarded the duplicate review of “\(discarding.groupName)” "
                        + "because \(Self.reviewEventCause(event))")
                }
                duplicateReview = nil
            case .restoreCompareState:
                if let restoreSnapshot { restoreCompareState(restoreSnapshot) }
            case .refocusCopies:
                if let review = duplicateReview {
                    syncManager.focusOn(relativePath: review.keeperRelativePath, isLeft: true)
                    syncManager.focusOn(relativePath: review.redundantRelativePath, isLeft: false)
                    refreshAction()
                }
            case .undoProviderPin(let keepingUserChoiceOnLeft):
                if let restoreSnapshot {
                    undoProviderPin(restoreSnapshot, keepingUserChoiceOnLeft: keepingUserChoiceOnLeft)
                }
            }
        }
    }

    /// A browse tab changed a pane's source: the one entry point for that event. It takes the
    /// side because `CompareReviewEvent.tabChangedSource` carries none, and the warning below is
    /// about the pane the user did not touch.
    ///
    /// `.tabChangedSource` drops the review but leaves its provider pin in place (see that case for
    /// why), so the untouched pane stays on a source the review chose. This logs that, once, and
    /// stays silent when the sibling pane alone was not stranded (`StrandedProviderPin`).
    func noteTabChangedSource(isLeft: Bool) {
        // Read before the dispatch, which clears `duplicateReview` and takes the snapshot with it.
        let saved = duplicateReview?.restore
        dispatchReview(.tabChangedSource)
        // The ids are read after: the effects above write neither, and this describes the panes
        // as the user now sees them.
        guard let saved,
              let stranded = StrandedProviderPin.stranded(
                movedPane: isLeft,
                savedLeft: saved.leftProviderId, savedRight: saved.rightProviderId,
                currentLeft: leftProviderId, currentRight: rightProviderId)
        else { return }
        Logger.shared.warning(
            "A browse tab changed the \(PaneSideChoice.name(isLeft)) pane's source during a "
            + "duplicate review. The review is discarded, and its provider pin on the "
            + "\(stranded.name) pane is deliberately left in place: that pane is on "
            + "\(stranded.current), where before the review it was \(stranded.saved). The panes now "
            + "compare \(leftProviderId) against \(rightProviderId). Nothing will restore that — "
            + "undoing the pin here would leave a pane claiming one source while showing another's "
            + "tree.")
    }

    /// How a review teardown reads in the log. The event names the cause; a line saying only that a
    /// review ended sends a reader looking for a gesture they did not make.
    private nonisolated static func reviewEventCause(_ event: CompareReviewEvent) -> String {
        switch event {
        case .reviewDone: return "the user pressed Done"
        case .rightCopyTrashed: return "the right copy was trashed"
        case .providerSwitched(let isLeft):
            return "the user switched the \(isLeft ? "left" : "right") pane's source"
        case .tabChangedSource: return "a browse tab changed a pane's source"
        case .comparisonRootEdited: return "a source's root folder was edited in Settings"
        case .panesSwapped: return "the panes were swapped"
        case .compareCopiesStarted: return "another pair of copies was opened for review"
        case .tabSwitched: return "the user left Compare with the review already abandoned"
        }
    }

    /// Ends an active guided review when the comparison changes (pane swap, provider switch, root
    /// edit). Its queue still targets the old paths, but the card labels items by the current
    /// panes, so after a swap a user could approve directions in reverse.
    private func endReviewForComparisonChange() {
        guard reviewStore.isReviewing else { return }
        reviewStore.endSession()
        syncManager.banner = .warning("Review ended — the comparison changed", log: .warn)
    }

    /// Releases the review's provider pin from the pane the user did not just repoint, putting its
    /// provider back to the pre-review value and re-homing it, because its root just moved.
    ///
    /// The narrow counterpart to `restoreCompareState`, for a provider switch while a duplicate
    /// review is set but no longer active: a full restore would also undo the pane the user is
    /// repointing. The re-home must happen here, because the caller's `retargetPane` re-homes only
    /// the user's pane; without it the sibling would show the pinned source's tree under the wrong
    /// root. It lands on the saved relative path, where that pane was before the pin.
    private func undoProviderPin(_ saved: SavedCompareState, keepingUserChoiceOnLeft: Bool) {
        // The user's live choice on their side, the saved value on the other, so
        // `ProviderPinPlan` suppresses only the one id this writes.
        let targetLeft = keepingUserChoiceOnLeft ? leftProviderId : saved.leftProviderId
        let targetRight = keepingUserChoiceOnLeft ? saved.rightProviderId : rightProviderId
        let plan = ProviderPinPlan.make(
            currentLeft: leftProviderId, currentRight: rightProviderId,
            targetLeft: targetLeft, targetRight: targetRight)
        guard plan.suppressCount > 0 else { return }
        pendingSwapProviderChanges += plan.suppressCount
        applyProviderPinAssignments(plan)
        // The suppressed onChange skips the ignore-store re-key, as everywhere else that pins an
        // id programmatically; the surviving pair is the user's side plus the restored one.
        syncManager.ignoredItemsStore?.activate(
            pairKey: IgnoredItemsStore.pairKey(targetLeft, targetRight))
        // The sibling is the pane whose id this just wrote. `retargetPane` drops its tree and
        // stack (indexed against the pinned root) and asks for its walk; the caller's retarget of
        // the user's pane follows, and `refreshTreesAndScan` unions the two walks.
        let siblingIsLeft = !keepingUserChoiceOnLeft
        syncManager.retargetPane(isLeft: siblingIsLeft,
                                 landing: siblingIsLeft ? saved.leftRelativePath : saved.rightRelativePath)
    }

    /// Puts both Compare panes back to a saved setup when a duplicate review ends, so the review
    /// never permanently repoints the user's right pane. The id onChanges are suppressed, as in
    /// `compareCopies`, so the lens results survive; each pane then re-focuses and rescans. Ending a
    /// guided review is the reducer's job (it pairs `.endGuidedReview` with this), not this one's.
    private func restoreCompareState(_ saved: SavedCompareState) {
        let plan = ProviderPinPlan.make(
            currentLeft: leftProviderId, currentRight: rightProviderId,
            targetLeft: saved.leftProviderId, targetRight: saved.rightProviderId)
        pendingSwapProviderChanges += plan.suppressCount
        applyProviderPinAssignments(plan)
        // Mirror of compareCopies' re-key, in the restore direction: the suppressed onChange
        // won't re-activate the original pair's ignore store, so do it here.
        syncManager.ignoredItemsStore?.activate(
            pairKey: IgnoredItemsStore.pairKey(saved.leftProviderId, saved.rightProviderId))
        // Same targeted invalidation as `compareCopies`: the review's diff must not stay
        // actionable while the restored trees load, and the full reset would wipe the lens results.
        syncManager.invalidateDifferencesForPaneRetarget()
        syncManager.focusOn(relativePath: saved.leftRelativePath, isLeft: true)
        syncManager.focusOn(relativePath: saved.rightRelativePath, isLeft: false)
        refreshAction()
    }

    /// What a fresh measurement of the reviewed pair says about it, from
    /// ``assessReviewedPair(_:fileManager:)`` — one verdict shared by the pre-trash check and
    /// `deleteItems`' removal gate, so the two can never check different things.
    enum ReviewedPairVerdict: Sendable, Equatable {
        /// Both copies are still what the scan grouped — safe to proceed.
        case matches
        /// The delete candidate is off the disk entirely: nothing to trash, nothing lost.
        case deleteVanished
        /// The KEEP side fails the gate. `missingBaseline` distinguishes "a folder review with no
        /// recorded baseline" (nothing measured, nothing claimable) from a measured change.
        case keepDrifted(missingBaseline: Bool)
        /// The DELETE side fails the gate, same split.
        case deleteDrifted(missingBaseline: Bool)
    }

    /// Measures both copies of `review` afresh and answers whether the pair is still the pair the
    /// scan grouped.
    ///
    /// Both copies: while a review stays open, a move or delete of the left copy makes the right
    /// one the last, and an edit or re-download of the right copy makes it the only instance of its
    /// new content. (`duplicateReviewActive` compares only focused paths.) The gate is the
    /// engine's, through `PaneLogic.duplicateCopyMatchesScan`, so the two can't drift apart.
    ///
    /// The stat runs off the main actor: on an unmounted cloud or SMB volume `attributesOfItem`
    /// blocks until the mount answers, which would beachball the window. One detached task for both
    /// stats, so a slow mount is paid once; only Sendable facts cross back.
    nonisolated static func assessReviewedPair(
        _ review: DuplicateCompareContext, fileManager fm: FileManaging
    ) async -> ReviewedPairVerdict {
        let keepPath = review.keepPath
        let deletePath = review.deletePath
        let measured = await Task.detached(priority: .userInitiated) { () -> (keep: CopyStat, delete: CopyStat) in
            func stat(_ path: String) -> CopyStat {
                let attrs = try? fm.attributesOfItem(atPath: path)
                return CopyStat(
                    exists: fm.fileExists(atPath: path),
                    statSucceeded: attrs != nil,
                    size: (attrs?[.size] as? NSNumber)?.intValue ?? (attrs?[.size] as? Int),
                    date: attrs?[.modificationDate] as? Date)
            }
            return (stat(keepPath), stat(deletePath))
        }.value
        // Directory verdicts, from the engine's `folderContentsMatchScan` re-walk against the
        // scan's baseline, the routine the card's resolve uses, so this gate is never weaker. A
        // folder's stat size is not its content, so files carry nil here. The walk runs off the
        // main actor; a vanished path gets no walk, since the gates below handle it.
        let keepFolderMatches: Bool?
        if review.keepIsDirectory {
            keepFolderMatches = measured.keep.exists
                ? await FileSyncManager.folderContentsMatchScan(
                    path: keepPath, snapshot: review.keepContentSnapshot, fileManager: fm)
                : false
        } else {
            keepFolderMatches = nil
        }
        let deleteFolderMatches: Bool?
        if review.deleteIsDirectory {
            deleteFolderMatches = measured.delete.exists
                ? await FileSyncManager.folderContentsMatchScan(
                    path: deletePath, snapshot: review.deleteContentSnapshot, fileManager: fm)
                : false
        } else {
            deleteFolderMatches = nil
        }
        guard PaneLogic.duplicateCopyMatchesScan(
            exists: measured.keep.exists,
            isDirectory: review.keepIsDirectory,
            statSucceeded: measured.keep.statSucceeded,
            currentSize: measured.keep.size,
            scannedSize: review.keepScannedSize,
            currentDate: measured.keep.date,
            scannedDate: review.keepScannedDate,
            folderContentsMatchScan: keepFolderMatches
        ) else {
            return .keepDrifted(missingBaseline:
                measured.keep.exists && review.keepIsDirectory && review.keepContentSnapshot == nil)
        }
        // A vanished right copy is not drift: nothing is left to trash and nothing was lost, as
        // `dropFullyRemovedGroups` treats it in the engine.
        guard measured.delete.exists else { return .deleteVanished }
        guard PaneLogic.duplicateCopyMatchesScan(
            exists: measured.delete.exists,
            isDirectory: review.deleteIsDirectory,
            statSucceeded: measured.delete.statSucceeded,
            currentSize: measured.delete.size,
            scannedSize: review.deleteScannedSize,
            currentDate: measured.delete.date,
            scannedDate: review.deleteScannedDate,
            folderContentsMatchScan: deleteFolderMatches
        ) else {
            return .deleteDrifted(missingBaseline:
                review.deleteIsDirectory && review.deleteContentSnapshot == nil)
        }
        return .matches
    }

    /// What the right copy holds that the left lacks, by the scan's baselines: each file or link
    /// (relative to the right copy) the left has nowhere at that path, or has as a different kind,
    /// size or modification date. The date catches a same-length edit, since nothing reads the
    /// bytes; dates compare only when both are known. Folders don't count, only what is in them.
    /// Empty when either copy has no baseline; the drift gate refuses that case itself.
    ///
    /// Dates are ignored for an identical group: its content is hash-proven, and `cp -R` or a
    /// download sets new dates, so comparing them would refuse every such pair and point at a
    /// Merge its card doesn't offer.
    nonisolated static func itemsOnlyInRightCopy(_ review: DuplicateCompareContext) -> [String] {
        guard let right = review.deleteContentSnapshot, let left = review.keepContentSnapshot else {
            return []
        }
        let contentProven = review.matchKind == .identical
        func same(_ a: Date?, _ b: Date?) -> Bool { contentProven || a == nil || b == nil || a == b }
        return right.entries.compactMap { path, entry -> String? in
            switch (entry, left.entries[path]) {
            case (.directory, _): return nil
            case (.file(let size, let date), .file(let other, let otherDate)?)
                where size == other && same(date, otherDate): return nil
            case (.symlink(let size, let date), .symlink(let other, let otherDate)?)
                where size == other && same(date, otherDate): return nil
            default: return path
            }
        }.sorted()
    }

    /// "Trash Right Copy" never trashes something only the right copy has: on an overlapping group
    /// it would send those items to the Trash with the folder. It refuses and points at Merge,
    /// which copies them into the keeper first.
    ///
    /// Either of two sources refuses. The scan's `uniqueItemCount` compares content by hash, so it
    /// catches same-path, same-size files whose bytes differ; the baselines compare path, size and
    /// date, so they catch a file the keeper holds only under another name or has edited since. The
    /// count can't go stale under a keeper re-pick: only folder groups reach this review, and only
    /// overlapping ones have a count, and those offer no keeper choice.
    nonisolated static func uniqueItemsRefusal(_ review: DuplicateCompareContext)
        -> (banner: String, log: String)? {
        let onlyRight = itemsOnlyInRightCopy(review)
        let count = max(review.deleteUniqueItemCount, onlyRight.count)
        guard count > 0 else { return nil }
        let items = count == 1 ? "1 item" : "\(count) items"
        let examples = onlyRight.prefix(2).map { "“\(($0 as NSString).lastPathComponent)”" }
        let named = examples.isEmpty ? "" : " (\(examples.joined(separator: ", "))\(onlyRight.count > 2 ? ", …" : ""))"
        return (
            banner: "The right copy holds \(items) the left one doesn’t\(named), so trashing it would lose them. Use Merge into Keeper on the Duplicates card instead — it copies them across first.",
            log: "Refused to trash \(review.deletePath): it holds \(items) the left copy \(review.keepPath) lacks"
                + (onlyRight.isEmpty ? "" : " — \(onlyRight.prefix(5).joined(separator: ", "))\(onlyRight.count > 5 ? ", …" : "")")
                + "; Merge into Keeper keeps them")
    }

    /// Posts the banner and the log line for a refusing verdict, on either side, so a refusal on
    /// screen is always in the log. A missing baseline is worded apart from a change, as the
    /// engine's resolve does: the scan never fully read that folder (unreadable, too deep or a link
    /// cycle), so nothing is known to have changed, and a rescan would record nil again.
    @MainActor
    static func reportReviewRefusal(_ verdict: ReviewedPairVerdict,
                                    review: DuplicateCompareContext,
                                    syncManager: FileSyncManager) {
        switch verdict {
        case .keepDrifted(missingBaseline: true):
            syncManager.banner = .warning("The left copy couldn’t be fully checked against the scan — the scan couldn’t read all of it (unreadable, or nested too deep), so the right copy can’t be proven redundant. Review them manually.", log: .loggedAtSite)
            Logger.shared.warning("Refused to trash \(review.deletePath): the scan recorded no baseline for the left copy \(review.keepPath) (subtree unreadable, too deep, or a link cycle), so the right copy is not provably redundant")
        case .keepDrifted(missingBaseline: false):
            syncManager.banner = .warning("The left copy is no longer what the scan saw — rescan before trashing the right copy.", log: .loggedAtSite)
            Logger.shared.warning("Refused to trash \(review.deletePath): the left copy \(review.keepPath) is no longer what the scan saw, so the right copy may be its last intact instance")
        case .deleteDrifted(missingBaseline: true):
            syncManager.banner = .warning("The right copy couldn’t be fully checked against the scan — the scan couldn’t read all of it (unreadable, or nested too deep), so it can’t be proven still a copy of the left one. Review it manually.", log: .loggedAtSite)
            Logger.shared.warning("Refused to trash \(review.deletePath): the scan recorded no baseline for it (subtree unreadable, too deep, or a link cycle), so it is not provably still a duplicate")
        case .deleteDrifted(missingBaseline: false):
            syncManager.banner = .warning("The right copy has changed since the scan — it is no longer a copy of the left one. Rescan before trashing it.", log: .loggedAtSite)
            Logger.shared.warning("Refused to trash \(review.deletePath): it changed since the scan, so it is no longer provably a duplicate")
        case .matches, .deleteVanished:
            break   // nothing to refuse
        }
    }

    /// Trashes the right copy of the reviewed duplicate (undoable), returns to the Duplicates list,
    /// drops that copy from its group in place without a re-walk, and restores the Compare setup. A
    /// declined or failed trash keeps the review and its banner up for a retry.
    func trashRightCopy(_ review: DuplicateCompareContext) {
        // Before the confirmation: asking "Move to Trash?" and then refusing is worse than not
        // asking, and nothing the user answers changes this.
        if let refusal = Self.uniqueItemsRefusal(review) {
            syncManager.banner = .refusal(refusal.banner, log: .loggedAtSite)
            Logger.shared.warning(refusal.log)
            return
        }
        // Refuse when another group's decision holds the copy: it sits inside a folder a group is
        // keeping, or is or holds a group's keeper, perhaps one picked by hand on the card. Read
        // from the live results here and again in the gate. `keeping:` names this review's left
        // copy, so a right copy re-picked as this group's keeper is refused in those words.
        if syncManager.refuseRemovalIfHeld(copyAt: review.deletePath, keeping: review.keepPath) { return }
        guard confirmTrashRightCopy(review) else {
            Logger.shared.info("User declined trashing the right duplicate copy \(review.deletePath)")
            return
        }
        let sm = syncManager
        Task {
            let fm = sm.fileManager
            let verdict = await Self.assessReviewedPair(review, fileManager: fm)
            // The assessment can take seconds on a slow mount, and meanwhile the user can press
            // Done or open a different pair. Trashing then would delete a copy they've stopped
            // looking at, and the dispatch below would tear down the review that replaced it. So
            // re-read the live binding after the last suspension and abandon if it moved.
            guard duplicateReview == review else {
                Logger.shared.info(
                    "The duplicate review changed while the left copy was being checked — skipping the trash of \(review.deletePath)")
                return
            }
            switch verdict {
            case .keepDrifted, .deleteDrifted:
                Self.reportReviewRefusal(verdict, review: review, syncManager: sm)
                return
            case .deleteVanished:
                // A vanished right copy is not drift: nothing to trash and nothing lost, so log
                // it and clear the review rather than warn about a change the user likely made.
                Logger.shared.info("The right duplicate copy \(review.deletePath) is already gone — nothing to trash")
                sm.removeResolvedDuplicateCopy(atPath: review.deletePath)
                dispatchReview(.rightCopyTrashed)
                return
            case .matches:
                break
            }
            // The verdict above is the first check, not the last: `deleteItems` waits in the
            // serialized op queue, and on a Trash-less volume holds a permanent-delete confirmation
            // open. The removal gate re-runs the assessment when the removal starts and again after
            // a confirmed permanent delete, refusing with the same banner and log line. A copy that
            // merely vanished is not refused; the delete removes nothing and the `guard` below
            // keeps the review up. Pass `fileManager: fm` so the verdict, the gate and the removal
            // all measure the same filesystem; the default would be `FileManager.default`.
            let outcome = await sm.deleteItems(at: [review.deletePath], fileManager: fm,
                                               removalGate: { about in
                if await sm.refuseRemovalIfHeld(copyAt: review.deletePath, keeping: review.keepPath) {
                    return Set(about)
                }
                let gateVerdict = await Self.assessReviewedPair(review, fileManager: fm)
                switch gateVerdict {
                case .matches, .deleteVanished:
                    return []
                case .keepDrifted, .deleteDrifted:
                    await Self.reportReviewRefusal(gateVerdict, review: review, syncManager: sm)
                    // Refuse the set this gate was asked about, not `review.deletePath` again.
                    // `deleteItems` hands the post-confirmation pass URL-round-tripped paths, and a
                    // refusal it can't match back would let the file be destroyed anyway.
                    return Set(about)
                }
            })
            guard outcome.removed > 0 else { return }
            // Log which way it went: on a Trash-less volume (exFAT, most SMB shares) the copy was
            // deleted permanently, and "Trashed" would send a reader to an empty Trash. The
            // permanent count decides, as in `resolveDuplicateCopy`, because a copy trashed without
            // a location is in neither `trashed` nor `permanentlyDeleted`.
            Logger.shared.info(outcome.permanentlyDeleted == 0
                               ? "Trashed the right duplicate copy \(review.deletePath)"
                               : "Permanently deleted the right duplicate copy \(review.deletePath)")
            selectedWorkspace = .filing
            organizeLens = .duplicates
            syncManager.removeResolvedDuplicateCopy(atPath: review.deletePath)
            // End the guided review, drop the duplicate review and restore the pre-review Compare
            // setup, all through the reducer.
            dispatchReview(.rightCopyTrashed)
        }
    }
}

/// One copy as a fresh stat found it: the Sendable facts that cross back from the detached stat,
/// not the attributes dictionary.
private struct CopyStat: Sendable {
    let exists: Bool
    let statSucceeded: Bool
    let size: Int?
    let date: Date?
}

/// A live "compare two duplicate copies" review handed off from the Duplicates lens to the Compare tab. Holds the
/// two absolute (tilde-expanded) copy paths — keeper on the left, delete candidate on the right —
/// plus the Compare setup to put back when the review ends.
struct DuplicateCompareContext: Equatable, Sendable {
    let groupName: String
    let keepPath: String
    let deletePath: String
    /// What the duplicate scan measured about each copy, so "Trash Right Copy" can apply the
    /// engine's drift gate to both through `PaneLogic.duplicateCopyMatchesScan`. The delete
    /// candidate's facts matter most: an edit or re-download while the review is open would make it
    /// the only instance of its new content.
    let keepIsDirectory: Bool
    let keepScannedSize: Int
    let keepScannedDate: Date?
    let deleteIsDirectory: Bool
    let deleteScannedSize: Int
    let deleteScannedDate: Date?
    /// The scan's per-entry baseline for each copy that is a folder (nil for files). A folder's stat
    /// size is not its content, so the gate re-walks against these through
    /// `FileSyncManager.folderContentsMatchScan`. A folder review with nil here refuses, as the
    /// engine does.
    let keepContentSnapshot: FolderContentSnapshot?
    let deleteContentSnapshot: FolderContentSnapshot?
    /// The two copies as provider-root-relative paths — used to re-focus the panes when the user
    /// returns to Compare after a lens detour reset the shared left pane to the rail's root.
    let keeperRelativePath: String
    let redundantRelativePath: String
    /// Where Compare was before this review pinned both panes to the duplicate's provider — restored
    /// on exit so opening two copies never permanently repoints the user's right pane.
    let restore: SavedCompareState
    /// The scan's count of items in the right copy that the group's keeper lacks
    /// (`DuplicateCopy.uniqueItemCount`), "12 unique here" on an overlapping group's card. Read by
    /// `uniqueItemsRefusal`. Defaults to 0, what every non-overlapping copy carries.
    var deleteUniqueItemCount: Int = 0
    /// The group's match kind. An identical group's content is hash-proven, so
    /// `itemsOnlyInRightCopy` ignores dates for it. Defaulted to `.overlapping`, the reading that
    /// compares them: a review that lost its kind refuses more, never less.
    var matchKind: DuplicateMatchType.Kind = .overlapping
}

/// A Compare pane setup — both providers and both focused folders. Captured before a duplicate
/// review overrides them and replayed when it ends.
struct SavedCompareState: Equatable, Sendable {
    let leftProviderId: String
    let rightProviderId: String
    let leftRelativePath: String
    let rightRelativePath: String
}
