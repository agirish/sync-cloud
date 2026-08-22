import SwiftUI
import Sync
import Events
import FileExplorer
import Design

/// The duplicate-review flow handed off from the Duplicates lens to Compare, extracted from `ContentView`:
/// opening two copies side by side (`compareCopies`), the keep-left / trash-right banner and its
/// actions, and the teardown/restore plumbing driven by `CompareReviewReducer`. The reducer stays
/// the single place the review DECISIONS live; this coordinator owns the effect EXECUTION — the
/// provider pinning, suppression seeding, focus, invalidation, and rescan glue `ContentView` used
/// to inline around them.
///
/// Deliberately stateless: the review state itself stays App-owned (`duplicateReview` is the App
/// scene's binding, `reviewStore` its store) — a window close + Dock reopen recreates ContentView
/// and any value it holds, and the review context must survive that cycle (see the
/// `duplicateReview` note in `ContentView`). The coordinator only receives bindings, references,
/// and closures over that state, so constructing a fresh one per use changes nothing.
///
/// The closures read LIVE state on every call (they capture the host view, whose property
/// wrappers read the backing storage), which matters for the paths that re-read state after an
/// await — `trashRightCopy`'s post-trash `dispatchReview(.rightCopyTrashed)` must see the
/// review/panes as they are then, not as they were when the coordinator was built.
@MainActor
struct DuplicateReviewCoordinator {
    let syncManager: FileSyncManager
    let reviewStore: ReviewSessionStore

    /// Active "compare two duplicate copies" handoff — App-owned; see `ContentView.duplicateReview`.
    @Binding var duplicateReview: DuplicateCompareContext?
    @Binding var leftProviderId: String
    @Binding var rightProviderId: String
    /// `ContentView`'s suppression counter for in-flight programmatic provider-id writes. The
    /// seeding order is load-bearing: it must be bumped BEFORE `applyProviderPinAssignments`
    /// writes any id, so each suppressed onChange finds a positive counter to decrement.
    @Binding var pendingSwapProviderChanges: Int
    @Binding var selectedWorkspace: Workspace
    /// The rail item to select when returning to a lens inside Organize. Duplicates stopped being
    /// a workspace of its own, so naming the workspace alone would land on Organize's overview and
    /// quietly lose the "back to the duplicates list" half of the request.
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
    /// Applies a `ProviderPinPlan`'s id writes, left before right — stays implemented in
    /// `ContentView` (the pane-swap path shares it). The coordinator seeds
    /// `pendingSwapProviderChanges` with `plan.suppressCount` FIRST, exactly as before.
    let applyProviderPinAssignments: @MainActor (ProviderPinPlan) -> Void

    /// Confirms trashing the reviewed right copy. A seam for the same reason Sync has
    /// `transferConfirmer`: `NativeAlerts.confirmDestructive` is a blocking modal, so with the call
    /// inlined the ONE destructive path on this coordinator could not be driven by a test at all —
    /// not the declined answer, not the keeper-drift refusal, not the success sequence. Defaults to
    /// the real alert, so production behaviour is unchanged.
    var confirmTrashRightCopy: @MainActor (DuplicateCompareContext) -> Bool = { review in
        NativeAlerts.confirmDestructive(
            messageText: "Move the right copy of “\(review.groupName)” to the Trash?",
            // **"Reversible with ⌘Z" was unconditional, and it is not.** On a volume with no Trash
            // — exFAT, most SMB shares — `deleteItems` cannot trash the copy and escalates to the
            // permanent-delete confirmation, which destroys it outright: nothing is registered
            // with the undo manager, because there is no backup to restore from. The same
            // distinction this file already draws thirty lines down, where the log line branches
            // "Trashed" against "Permanently deleted" rather than calling both the former.
            //
            // The second alert is named rather than the promise merely dropped: it is real
            // (`SyncOperationAlerts.confirmPermanentDelete`, critical style, with Return
            // deliberately left unbound), so saying so is both true and the reassurance the ⌘Z
            // sentence was there to give.
            informativeText: "Trashes \((review.deletePath as NSString).abbreviatingWithTildeInPath). The left copy is kept. Undo with ⌘Z. On a volume with no Trash you'll be asked first, and a permanent delete can't be undone.",
            confirmTitle: "Move to Trash")
    }

    /// Opens two copies of a duplicate *folder* group side by side in Compare: the keeper on the
    /// left (kept), the redundant copy on the right (the delete candidate). Duplicate groups never
    /// span providers (the finder walks a single provider tree), so both copies share the lens
    /// provider root — this pins both panes to that provider, focuses each on its copy, and runs the
    /// diff. Switching to Compare doesn't disturb the lens scan results, so the user can tab
    /// back to the duplicate list and compare the next pair.
    ///
    /// Changing a provider id normally clears the lens results and resets navigation (see the id
    /// `onChange` handlers) — both would sabotage this, wiping the duplicate list the user must be
    /// able to return to and the focus set just below. So each id change is suppressed via
    /// `pendingSwapProviderChanges`, exactly as a pane swap does.
    func compareCopies(keep: DuplicateCopy, delete: DuplicateCopy) {
        let providerId = lensTargetIsRight() ? rightProviderId : leftProviderId
        let providerRoot = lensProviderRootExpanded()
        let keepPath = (keep.path as NSString).expandingTildeInPath
        let deletePath = (delete.path as NSString).expandingTildeInPath
        // PathBoundary is boundary-safe on "/" ("/a/Docs" never claims "/a/DocsBackup"); a copy
        // outside the root stays nil and refuses the compare (no fallback — a wrong relative
        // path would focus a pane on the wrong folder).
        guard !providerRoot.isEmpty,
              let keepRel = PathBoundary.relativize(keepPath, under: providerRoot),
              let deleteRel = PathBoundary.relativize(deletePath, under: providerRoot) else {
            Logger.shared.warning("Compare copies: a copy path sits outside the scanned provider root — skipping")
            return
        }
        // Snapshot the Compare setup so exiting the review restores it — but when a review is already
        // in progress (comparing a second pair without ending the first), its panes are already
        // pinned to this provider, so keep the ORIGINAL snapshot rather than capturing the pinned one.
        let restore = duplicateReview?.restore ?? SavedCompareState(
            leftProviderId: leftProviderId, rightProviderId: rightProviderId,
            leftRelativePath: syncManager.leftRelativePath, rightRelativePath: syncManager.rightRelativePath)

        // The comparison itself is changing; end any guided review that was framed on the old panes
        // (the id onChange would normally do this, but we're about to suppress it). The new
        // duplicateReview is set below, after the panes are pinned.
        dispatchReview(.compareCopiesStarted)

        // Suppress the id onChange for each id that actually changes, so neither clears the lens
        // duplicate results nor resets the focus applied just below.
        let plan = ProviderPinPlan.make(
            currentLeft: leftProviderId, currentRight: rightProviderId,
            targetLeft: providerId, targetRight: providerId)
        pendingSwapProviderChanges += plan.suppressCount
        applyProviderPinAssignments(plan)
        // The suppression above also skips the id onChange's ignore-store re-key — the ONLY
        // other place it happens — so re-key here, or the pinned same-provider comparison
        // filters its diff through the OLD pair's remembered ignores (hiding real differences
        // from the very review that decides whether a copy is safe to trash).
        syncManager.ignoredItemsStore?.activate(
            pairKey: IgnoredItemsStore.pairKey(providerId, providerId))
        // The suppression above also skips resetNavigation's comparison invalidation, so drop the
        // OLD comparison's differences here — they carry absolute paths for roots the panes are
        // about to stop showing, and would stay actionable until the re-diff lands. Targeted so
        // the duplicate results survive (the whole reason the onChange is suppressed).
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
            keeperRelativePath: keepRel, redundantRelativePath: deleteRel, restore: restore)

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
                Text("Keeping the left copy — the right is the one you're deciding on")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Done") { endDuplicateReview() }
                .chromeButtonStyle(glassLevel)
                .controlSize(.small)
                .chromeHover()
            Button(role: .destructive) { trashRightCopy(review) } label: {
                Label("Trash right copy", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .chromeHover()
            .controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        // No fill or divider of its own: the host mounts this as a `bottomSectionCard`, so it
        // joins the workspace's card stack (the flush `.regularMaterial` bar it used to be hung
        // 2.5pt wider than the cards below it and closed the gap above them to a half-gutter).
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
                // **A review the user can see disappearing, said out loud, with the cause.** Every
                // branch that emits this effect is already guarded on `hasDuplicateReview`, so this
                // never claims a teardown that did not happen — and the banner going is visible,
                // while WHY it went is not. `.reviewDone` is the one routine cause; the rest are all
                // "something else changed the comparison out from under it", and `.tabChangedSource`
                // is the newest and quietest of them. He audits this log.
                //
                // **Bound rather than defaulted.** This used to read `?? "a group"` — a fallback
                // no test could ever distinguish from the real name, because every branch that
                // emits this effect is guarded on `hasDuplicateReview`. Binding it says the same
                // thing without a literal standing in for a case that cannot happen: a future
                // branch that emitted this without a review would write nothing at all, which is
                // an absence a log reader can notice, rather than a line about "a group".
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

    /// **A browse tab changed a pane's source — the one entry point for that event.**
    ///
    /// It exists because the epilogue below needs to know WHICH pane the tab moved and
    /// `CompareReviewEvent.tabChangedSource` carries no side: strandedness is a question about the
    /// pane the user did NOT touch, and the event alone cannot pick it out. Everything else is
    /// `dispatchReview`'s, unchanged.
    ///
    /// **The half no effect represents, and the only place it is ever said.** `.tabChangedSource`
    /// drops the review and deliberately leaves its programmatic provider pin where it is — see
    /// `CompareReviewEvent.tabChangedSource` for why undoing it would be worse
    /// (`.undoProviderPin` restores no folder, because it expects a `resetNavigation()` that a
    /// tab-driven switch never makes). That is the right call and it is still a loss the user can
    /// see and cannot explain: the banner is gone, and the pane they did not touch is sitting on a
    /// source the *review* chose for them, which nothing will now put back.
    ///
    /// Silent when there is nothing to say — and the test for that is the SIBLING pane alone, not
    /// the pair. See `StrandedProviderPin`, which is where that (previously wrong) gate now lives
    /// and can be driven.
    func noteTabChangedSource(isLeft: Bool) {
        // Read before the dispatch, which clears `duplicateReview` and takes the snapshot with it.
        let saved = duplicateReview?.restore
        dispatchReview(.tabChangedSource)
        // The ids are read AFTER, exactly as before: the effects above write neither, and this has
        // to describe the panes as the user is now looking at them.
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

    /// Ends an active guided review when the comparison itself changes (pane swap, provider
    /// switch, root edit). The frozen queue captured the OLD comparison: its copies would
    /// still run against the captured absolute paths, but the review card relabels each item
    /// against the CURRENT pane names — after a swap, exactly backwards. Ending the session
    /// beats showing directions a user could approve in reverse.
    private func endReviewForComparisonChange() {
        guard reviewStore.isReviewing else { return }
        reviewStore.endSession()
        syncManager.banner = .warning("Review ended — the comparison changed")
    }

    /// Releases the review's provider pin from the pane the user did NOT just repoint, leaving that
    /// pane's provider at its pre-review value and everything else alone.
    ///
    /// The narrow counterpart to `restoreCompareState`, for the case where the user switches a
    /// provider while a duplicate review is set but no longer active. A full restore would fight
    /// the gesture in progress — it would put BOTH providers and both folders back, including the
    /// pane they are actively repointing. Folders are deliberately not restored here at all: the
    /// caller's own `resetNavigation()` re-homes the panes a moment later, so re-focusing saved
    /// paths would be undone anyway, and a `refreshAction()` here would only add a second scan.
    private func undoProviderPin(_ saved: SavedCompareState, keepingUserChoiceOnLeft: Bool) {
        // Target the user's live choice on their side, the saved value on the other — so
        // `ProviderPinPlan` sees no change for the side they are holding and suppresses only the
        // one id this actually writes.
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
    }

    /// Puts both Compare panes back to a saved setup — used when a duplicate review ends, so pinning
    /// both panes to the duplicate's provider never permanently repoints the user's right pane. The
    /// id onChanges are suppressed (as `compareCopies` does) so the restore can't clear the surviving
    /// lens results or reset navigation; then each pane re-focuses its saved folder and rescans.
    /// Ending any active guided review is the reducer's job (it always pairs `.endGuidedReview` with
    /// `.restoreCompareState`), so it is deliberately NOT done here.
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
        // Same targeted invalidation as compareCopies: the review's diff of the two copies must
        // not stay actionable while the restored panes' trees load (the suppression above skips
        // the full reset that would normally clear it — and would also wipe the lens results).
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
    /// **Both copies, because the engine checks both and the right one is the dangerous half.**
    /// The keeper is the file being kept; the right copy is the file being destroyed. A review is
    /// designed to stay open — while it is, an external move or delete of the LEFT copy makes
    /// this the last one, and a provider re-download or an edit of the RIGHT copy makes it the
    /// only instance of its new content. Either way the pair is no longer the pair the scan
    /// grouped. (`duplicateReviewActive` only compares the pane's focused PATH, not existence or
    /// content.) This is the same gate the engine applies to the keeper and to every removal
    /// candidate — `copyDriftedInPlace` for files, the shared `folderContentsMatchScan` re-walk
    /// for folders — reached through `PaneLogic.duplicateCopyMatchesScan` so the two cannot
    /// drift apart.
    ///
    /// The stat runs OFF the main actor: `attributesOfItem` is a synchronous stat, and against a
    /// keeper on an unmounted cloud or SMB volume it blocks for as long as the mount takes to
    /// answer — on the main actor that beachballs the whole window on a button click. Same rule
    /// and same detach as `ContentView.restoreLastPaneFocusIfEnabled` ("cloud roots stat
    /// slowly"). Only the Sendable facts cross back — the attributes dictionary itself never
    /// leaves the task. One detached task for BOTH stats: two would double the worst case on a
    /// slow mount, and the pair is one question.
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
        // Directory verdicts, from the engine's shared re-walk against the scan's recorded
        // baseline — `folderContentsMatchScan` is the same routine `resolveDuplicateGroup`
        // and the batch consult, so the review's directory gate can never be weaker than the
        // card's. Stat facts cannot answer for a folder (its stat size is not its recursive
        // content), which is why files carry nil here and directories carry a real verdict.
        // The walk runs off the main actor (buildTree detaches itself); a vanished path gets
        // no walk — the keep gate refuses on existence, and a vanished delete candidate is a
        // verdict of its own.
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
        // **A vanished right copy is not drift.** There is nothing left to trash and nothing was
        // lost — the same distinction `dropFullyRemovedGroups` draws in the engine.
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

    /// Posts the banner AND the log line for a refusing verdict — both sides, both wordings.
    /// The delete side always logged its refusals; the keep side used to set a banner and write
    /// NOTHING, so a refusal he could see on screen was absent from the log he audits. The two
    /// refusals stay worded apart (the engine's resolve draws the same line): a folder review
    /// carrying NO baseline was never fully read by the scan — nothing is known to have changed,
    /// and a rescan of the same tree records nil again — so it must not be described as "no
    /// longer what the scan saw". And "couldn't read all of it (unreadable, or nested too deep)"
    /// rather than the old "part of it wasn't readable": the walk's depth cap and its
    /// symlink-cycle guard record a nil baseline exactly like an unreadable descendant does, and
    /// naming only the readable half over-claimed.
    @MainActor
    static func reportReviewRefusal(_ verdict: ReviewedPairVerdict,
                                    review: DuplicateCompareContext,
                                    syncManager: FileSyncManager) {
        switch verdict {
        case .keepDrifted(missingBaseline: true):
            syncManager.banner = .warning("The left copy couldn't be fully checked against the scan — the scan couldn't read all of it (unreadable, or nested too deep), so the right copy can't be proven redundant. Review them manually.")
            Logger.shared.warning("Refused to trash \(review.deletePath): the scan recorded no baseline for the left copy \(review.keepPath) (subtree unreadable, too deep, or a link cycle), so the right copy is not provably redundant")
        case .keepDrifted(missingBaseline: false):
            syncManager.banner = .warning("The left copy is no longer what the scan saw — rescan before trashing the right copy.")
            Logger.shared.warning("Refused to trash \(review.deletePath): the left copy \(review.keepPath) is no longer what the scan saw, so the right copy may be its last intact instance")
        case .deleteDrifted(missingBaseline: true):
            syncManager.banner = .warning("The right copy couldn't be fully checked against the scan — the scan couldn't read all of it (unreadable, or nested too deep), so it can't be proven still a copy of the left one. Review it manually.")
            Logger.shared.warning("Refused to trash \(review.deletePath): the scan recorded no baseline for it (subtree unreadable, too deep, or a link cycle), so it is not provably still a duplicate")
        case .deleteDrifted(missingBaseline: false):
            syncManager.banner = .warning("The right copy has changed since the scan — it is no longer a copy of the left one. Rescan before trashing it.")
            Logger.shared.warning("Refused to trash \(review.deletePath): it changed since the scan, so it is no longer provably a duplicate")
        case .matches, .deleteVanished:
            break   // nothing to refuse
        }
    }

    /// Trashes the right copy of the reviewed duplicate (undoable), then returns to the Duplicates
    /// list, drops just that copy from its group in place — the group's figures update, or the group
    /// disappears when only the keeper is left, without re-walking the whole tree — and restores the
    /// Compare setup. A declined or failed trash keeps the review (and its banner) up for a retry.
    func trashRightCopy(_ review: DuplicateCompareContext) {
        guard confirmTrashRightCopy(review) else {
            Logger.shared.info("User declined trashing the right duplicate copy \(review.deletePath)")
            return
        }
        let sm = syncManager
        Task {
            let fm = sm.fileManager
            let verdict = await Self.assessReviewedPair(review, fileManager: fm)
            // The assessment's stat — and, for a folder review, its two re-walks — are the only
            // suspensions between the user's click and the trash, and they exist precisely for
            // the case where they are slow: an unmounted cloud or SMB keeper can take seconds to
            // answer. Seconds in which the window is live — "Done" sits right beside the
            // destructive button, and the Duplicates list is one tab away, so the user can end
            // this review or open a DIFFERENT pair through `compareCopies` before the answer
            // lands. Either way the review this task was started for is no longer the one on
            // screen: trashing would delete a copy the user has stopped looking at, and the
            // `.rightCopyTrashed` dispatch below would tear down the review that replaced it and
            // replay THIS review's saved compare state over it. Re-read the live binding (the
            // coordinator's closures always read current state) AFTER the last suspension, and
            // abandon the trash if it moved.
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
                // **A vanished right copy is not drift.** There is nothing left to trash and
                // nothing was lost, so this says so and clears the review rather than warning
                // about a change the user probably made deliberately.
                Logger.shared.info("The right duplicate copy \(review.deletePath) is already gone — nothing to trash")
                sm.removeResolvedDuplicateCopy(atPath: review.deletePath)
                dispatchReview(.rightCopyTrashed)
                return
            case .matches:
                break
            }
            // The verdict above is the FIRST check, not the last: `deleteItems` routes through
            // the serialized op queue (a long queued operation inserts its whole duration here),
            // and on a Trash-less volume it holds a permanent-delete confirmation open for as
            // long as the user leaves it. The removal gate re-runs the same assessment at the
            // moment the removal starts and again after a confirmed permanent delete, refusing —
            // with the same banner and log line — if the pair drifted in either window. A copy
            // that merely vanished meanwhile is not refused; the delete then removes nothing and
            // the `guard` below keeps the review up, as it always has for a no-op delete.
            let outcome = await sm.deleteItems(at: [review.deletePath], removalGate: { about in
                let gateVerdict = await Self.assessReviewedPair(review, fileManager: fm)
                switch gateVerdict {
                case .matches, .deleteVanished:
                    return []
                case .keepDrifted, .deleteDrifted:
                    await Self.reportReviewRefusal(gateVerdict, review: review, syncManager: sm)
                    // Refuse what this gate was ASKED about, not `review.deletePath` again. This
                    // gate ignores its input — the pair it re-assesses is the review's, which is
                    // the only path the delete carries — so echoing the argument is the same set
                    // by construction and cannot become a different one. Naming the review's own
                    // spelling could: `deleteItems` feeds the post-confirmation pass URL
                    // round-tripped paths, and a refusal it cannot match back is a refusal banner
                    // posted over a file that was destroyed anyway. (`deleteItems` now matches on
                    // `canonicalRemovalPath`, which closes that too; this closes it here, where the
                    // set is produced, so neither side rests on the other.)
                    return Set(about)
                }
            })
            guard outcome.removed > 0 else { return }
            // **Say which way it went.** `removed` folds together the two outcomes `DeleteOutcome`
            // exists to separate, and this line is in the log he audits: on a Trash-less volume —
            // exFAT, most SMB shares — the copy was destroyed permanently, and calling that
            // "Trashed" sends anyone reading the log to a Trash that never received it.
            Logger.shared.info(outcome.trashed > 0
                               ? "Trashed the right duplicate copy \(review.deletePath)"
                               : "Permanently deleted the right duplicate copy \(review.deletePath)")
            selectedWorkspace = .filing
            organizeLens = .duplicates
            syncManager.removeResolvedDuplicateCopy(atPath: review.deletePath)
            // End the guided review, drop the duplicate review, and restore the pre-review Compare
            // setup — all via the reducer (it reads review.restore before clearing duplicateReview).
            dispatchReview(.rightCopyTrashed)
        }
    }
}

/// One copy as a fresh stat found it — the Sendable facts that cross back from the detached stat,
/// deliberately not the attributes dictionary itself.
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
    /// What the duplicate scan measured about EACH copy, so "Trash right copy" can apply the
    /// engine's full drift gate to both ends via `PaneLogic.duplicateCopyMatchesScan`.
    ///
    /// **The delete candidate's facts are the ones this used to be missing**, and they are the
    /// dangerous half: the keeper is the file being kept, the candidate is the file being
    /// destroyed. Without them the check was structurally impossible — a review is designed to
    /// stay open, and a provider re-download or an edit of the right copy in that window made it
    /// the only instance of its new content, which the button then trashed.
    let keepIsDirectory: Bool
    let keepScannedSize: Int
    let keepScannedDate: Date?
    let deleteIsDirectory: Bool
    let deleteScannedSize: Int
    let deleteScannedDate: Date?
    /// The scan's per-entry baseline for each copy that is a FOLDER (nil for files). The Compare
    /// review is the folder-ONLY flow — the card offers it for every directory group — and stat
    /// facts cannot answer for a directory (its stat size is not its recursive content), so the
    /// directory half of the gate re-walks against these through the engine's shared
    /// `FileSyncManager.folderContentsMatchScan`. A folder review carrying nil here refuses,
    /// same as the engine refuses a copy with no recorded baseline.
    let keepContentSnapshot: FolderContentSnapshot?
    let deleteContentSnapshot: FolderContentSnapshot?
    /// The two copies as provider-root-relative paths — used to re-focus the panes when the user
    /// returns to Compare after a lens detour reset the shared left pane to the rail's root.
    let keeperRelativePath: String
    let redundantRelativePath: String
    /// Where Compare was before this review pinned both panes to the duplicate's provider — restored
    /// on exit so opening two copies never permanently repoints the user's right pane.
    let restore: SavedCompareState
}

/// A Compare pane setup — both providers and both focused folders. Captured before a duplicate
/// review overrides them and replayed when it ends.
struct SavedCompareState: Equatable, Sendable {
    let leftProviderId: String
    let rightProviderId: String
    let leftRelativePath: String
    let rightRelativePath: String
}
