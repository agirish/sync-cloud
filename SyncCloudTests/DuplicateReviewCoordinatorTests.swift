import SwiftUI
import Testing
import Sync
import FileExplorer
@testable import SyncCloud

/// Exercises ``DuplicateReviewCoordinator`` — the effect-EXECUTION half of the duplicate-review
/// flow (``CompareReviewReducer`` owns the decisions and has its own suite). These paths used to
/// live inline in `ContentView`'s `@State` glue, unreachable by tests; the coordinator receives
/// bindings and closures, so a test can stand in for the view and pin the execution contracts:
///
/// - the suppression counter is seeded BEFORE any provider-id write is applied (an id onChange
///   that fires against an unseeded counter wipes the Tidy results the retarget is protecting),
/// - `compareCopies` keeps the ORIGINAL restore snapshot when a second pair is compared without
///   ending the first review (the panes are already pinned — capturing again would "restore" to
///   the pinned provider and leak it),
/// - teardown-with-restore vs drop-without-restore reach the right execution effects.
@MainActor
private final class Harness {
    let syncManager = FileSyncManager()
    let reviewStore = ReviewSessionStore()

    var duplicateReview: DuplicateCompareContext?
    var leftId = "icloud"
    var rightId = "dropbox"
    var pendingSwapProviderChanges = 0
    var tab: ContentView.BottomTab = .tidy
    var lens: TidyLens = .duplicates

    // Live-context stand-ins (ContentView resolves these from providers + pane state).
    var currentLeftPath = ""
    var currentRightPath = ""
    var tidyTargetIsRight = false
    var tidyProviderRoot = "/scan/root"

    // Recorded effects.
    var refreshCount = 0
    var appliedPlans: [ProviderPinPlan] = []
    /// The counter's value at the moment each plan was applied — proves seeding came first.
    var pendingCounterAtApply: [Int] = []

    var coordinator: DuplicateReviewCoordinator {
        DuplicateReviewCoordinator(
            syncManager: syncManager,
            reviewStore: reviewStore,
            duplicateReview: Binding(get: { self.duplicateReview }, set: { self.duplicateReview = $0 }),
            leftProviderId: Binding(get: { self.leftId }, set: { self.leftId = $0 }),
            rightProviderId: Binding(get: { self.rightId }, set: { self.rightId = $0 }),
            pendingSwapProviderChanges: Binding(get: { self.pendingSwapProviderChanges },
                                                set: { self.pendingSwapProviderChanges = $0 }),
            selectedBottomTab: Binding(get: { self.tab }, set: { self.tab = $0 }),
            selectedTidyLens: Binding(get: { self.lens }, set: { self.lens = $0 }),
            accentColor: .blue,
            glassLevel: .frosted,
            currentLeftPath: { self.currentLeftPath },
            currentRightPath: { self.currentRightPath },
            tidyTargetIsRight: { self.tidyTargetIsRight },
            tidyProviderRootExpanded: { self.tidyProviderRoot },
            refreshAction: { self.refreshCount += 1 },
            applyProviderPinAssignments: { plan in
                self.pendingCounterAtApply.append(self.pendingSwapProviderChanges)
                self.appliedPlans.append(plan)
                // Mirror ContentView's implementation: id writes, left before right.
                for assignment in plan.assignments {
                    switch assignment.side {
                    case .left: self.leftId = assignment.providerId
                    case .right: self.rightId = assignment.providerId
                    }
                }
            }
        )
    }

    /// A review as `compareCopies` would set it up, with panes "pinned" to the Tidy provider.
    func installReview(
        keepRel: String = "Docs", deleteRel: String = "Backup/Docs",
        restore: SavedCompareState? = nil
    ) -> DuplicateCompareContext {
        let review = DuplicateCompareContext(
            groupName: "Docs",
            keepPath: "\(tidyProviderRoot)/\(keepRel)",
            deletePath: "\(tidyProviderRoot)/\(deleteRel)",
            keepIsDirectory: true,
            keepScannedSize: 1234,
            keeperRelativePath: keepRel,
            redundantRelativePath: deleteRel,
            restore: restore ?? SavedCompareState(
                leftProviderId: "icloud", rightProviderId: "dropbox",
                leftRelativePath: "Was/Left", rightRelativePath: "Was/Right"))
        duplicateReview = review
        // compareCopies pins both panes to the Tidy provider (left pane's, here).
        rightId = leftId
        return review
    }
}

@MainActor
private func duplicateCopy(path: String, keeper: Bool) -> DuplicateCopy {
    DuplicateCopy(
        id: path, name: (path as NSString).lastPathComponent, isDirectory: true,
        size: 1234, itemCount: 3, modificationDate: nil,
        uniqueItemCount: 0, depth: 1, isRecommendedKeeper: keeper)
}

@MainActor
@Suite struct DuplicateReviewCoordinatorTests {

    // MARK: compareCopies

    @Test func compareCopiesPinsPanesFocusesCopiesAndOpensCompare() throws {
        let harness = Harness()
        harness.coordinator.compareCopies(
            keep: duplicateCopy(path: "/scan/root/Docs", keeper: true),
            delete: duplicateCopy(path: "/scan/root/Backup/Docs", keeper: false))

        // Both panes pinned to the Tidy provider (the left pane's, since tidyTargetIsRight=false):
        // only the right id really changes, so the plan carries exactly that one write.
        #expect(harness.leftId == "icloud")
        #expect(harness.rightId == "icloud")
        #expect(harness.appliedPlans.count == 1)
        #expect(harness.appliedPlans[0].suppressCount == 1)
        // The load-bearing order: the counter was already seeded when the plan was applied.
        #expect(harness.pendingSwapProviderChanges == 1)
        #expect(harness.pendingCounterAtApply == [1])

        // Each pane focused on its copy, review context established, Compare opened, re-diffed.
        #expect(harness.syncManager.leftRelativePath == "Docs")
        #expect(harness.syncManager.rightRelativePath == "Backup/Docs")
        let review = try #require(harness.duplicateReview)
        #expect(review.keepPath == "/scan/root/Docs")
        #expect(review.deletePath == "/scan/root/Backup/Docs")
        #expect(review.keeperRelativePath == "Docs")
        #expect(review.redundantRelativePath == "Backup/Docs")
        // The restore snapshot is the PRE-pin setup.
        #expect(review.restore == SavedCompareState(
            leftProviderId: "icloud", rightProviderId: "dropbox",
            leftRelativePath: "", rightRelativePath: ""))
        #expect(harness.tab == .differences)
        #expect(harness.refreshCount == 1)
    }

    @Test func compareCopiesRekeysIgnoreStoreAndRestoreRekeysItBack() throws {
        // The pin suppresses the provider-id onChange handlers — the ONLY other place the
        // durable ignore store is re-keyed. Without an explicit re-key here, the pinned
        // same-provider review filters its diff through the OLD pair's remembered ignores: a
        // file the user ignored for iCloud↔Dropbox silently vanishes from the iCloud↔iCloud
        // duplicate review they're using to decide "identical — trash the right copy".
        let harness = Harness()
        let suite = "DuplicateReviewCoordinatorTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["CrossPair/report.pdf"], forKey: IgnoredItemsStore.pairKey("icloud", "dropbox"))
        defaults.set(["SamePair/notes.txt"], forKey: IgnoredItemsStore.pairKey("icloud", "icloud"))
        let store = IgnoredItemsStore(userDefaults: defaults)
        store.activate(pairKey: IgnoredItemsStore.pairKey("icloud", "dropbox"))
        harness.syncManager.ignoredItemsStore = store
        #expect(store.rootRelativePaths == ["CrossPair/report.pdf"])

        harness.coordinator.compareCopies(
            keep: duplicateCopy(path: "/scan/root/Docs", keeper: true),
            delete: duplicateCopy(path: "/scan/root/Backup/Docs", keeper: false))

        // Pinned to icloud↔icloud: the review reads THAT pair's ignores, not the old pair's.
        #expect(store.rootRelativePaths == ["SamePair/notes.txt"])

        // Done → restore: the original pair's ignores come back with the original providers.
        harness.coordinator.endDuplicateReview()
        #expect(store.rootRelativePaths == ["CrossPair/report.pdf"])
    }

    @Test func comparingASecondPairKeepsTheOriginalRestoreSnapshot() throws {
        let harness = Harness()
        let original = SavedCompareState(
            leftProviderId: "icloud", rightProviderId: "dropbox",
            leftRelativePath: "Was/Left", rightRelativePath: "Was/Right")
        _ = harness.installReview(restore: original)

        // Compare a second pair without ending the first review: the panes are already pinned,
        // so capturing a fresh snapshot would remember the PINNED provider — the restore must
        // keep pointing at the setup from before the first pair.
        harness.coordinator.compareCopies(
            keep: duplicateCopy(path: "/scan/root/Photos", keeper: true),
            delete: duplicateCopy(path: "/scan/root/Old/Photos", keeper: false))

        let review = try #require(harness.duplicateReview)
        #expect(review.groupName == "Photos")
        #expect(review.restore == original)
    }

    @Test func compareCopiesRefusesACopyOutsideTheProviderRoot() {
        let harness = Harness()
        // Boundary hazard: a sibling whose name merely EXTENDS the root must not be claimed.
        harness.coordinator.compareCopies(
            keep: duplicateCopy(path: "/scan/root/Docs", keeper: true),
            delete: duplicateCopy(path: "/scan/rootBackup/Docs", keeper: false))

        // Refused outright: no review, no pin, no seeding, no tab switch, no rescan.
        #expect(harness.duplicateReview == nil)
        #expect(harness.appliedPlans.isEmpty)
        #expect(harness.pendingSwapProviderChanges == 0)
        #expect(harness.tab == .tidy)
        #expect(harness.refreshCount == 0)
    }

    // MARK: dispatchReview — teardown with restore

    @Test func reviewDoneClearsTheReviewAndRestoresTheSavedCompareState() {
        let harness = Harness()
        _ = harness.installReview()

        harness.coordinator.dispatchReview(.reviewDone)

        #expect(harness.duplicateReview == nil)
        // The pinned right pane went back to the saved provider, and the counter was seeded
        // BEFORE the write (the restore path shares compareCopies' suppression contract).
        #expect(harness.rightId == "dropbox")
        #expect(harness.appliedPlans.count == 1)
        #expect(harness.appliedPlans[0].suppressCount == 1)
        #expect(harness.pendingCounterAtApply == [1])
        // Both panes re-focused on their saved folders, then a rescan.
        #expect(harness.syncManager.leftRelativePath == "Was/Left")
        #expect(harness.syncManager.rightRelativePath == "Was/Right")
        #expect(harness.refreshCount == 1)
    }

    @Test func leavingCompareWithAnInactiveReviewTearsItDownLikeDone() {
        let harness = Harness()
        _ = harness.installReview()
        // The panes are NOT on the two copies (the user navigated away): the review is inactive,
        // so leaving Compare abandons it — teardown with restore, exactly like Done.
        harness.currentLeftPath = "/scan/root/Somewhere/Else"
        harness.currentRightPath = "/scan/root/Backup/Docs"

        harness.coordinator.dispatchReview(.tabSwitched(toCompare: false, fromCompare: true))

        #expect(harness.duplicateReview == nil)
        #expect(harness.rightId == "dropbox")
        #expect(harness.syncManager.leftRelativePath == "Was/Left")
        #expect(harness.syncManager.rightRelativePath == "Was/Right")
        #expect(harness.refreshCount == 1)
    }

    // MARK: dispatchReview — drop without restore

    @Test func providerSwitchDuringAnActiveReviewDropsItWithoutRestoring() {
        let harness = Harness()
        let review = harness.installReview()
        // Both panes are still on the two copies, so the review is ACTIVE: the comparison the
        // user is redefining is the one in front of them.
        harness.currentLeftPath = review.keepPath
        harness.currentRightPath = review.deletePath

        harness.coordinator.dispatchReview(.providerSwitched(isLeft: true))

        // The user chose the new comparison: the review is dropped, but nothing is restored —
        // no pin plan, no suppression seeding, no focus change, no rescan.
        #expect(harness.duplicateReview == nil)
        #expect(harness.appliedPlans.isEmpty)
        #expect(harness.pendingSwapProviderChanges == 0)
        #expect(harness.syncManager.leftRelativePath == "")
        #expect(harness.refreshCount == 0)
    }

    @Test func providerSwitchAfterTheReviewWentInactiveReleasesTheOtherPanesPin() {
        let harness = Harness()
        _ = harness.installReview()   // pins rightId to the left (Tidy) provider
        #expect(harness.rightId == harness.leftId)
        // The panes are NOT on the two copies — entering a Tidy lens re-focused the shared left
        // pane — so the review is inactive and the right pane's pin is stale bookkeeping.
        // The user now repoints the rail (the LEFT pane) to a third provider.
        harness.leftId = "onedrive"

        harness.coordinator.dispatchReview(.providerSwitched(isLeft: true))

        #expect(harness.duplicateReview == nil)
        // The right pane went back to the provider it had before the review…
        #expect(harness.rightId == "dropbox")
        #expect(harness.appliedPlans.count == 1)
        #expect(harness.appliedPlans[0].suppressCount == 1)
        // …seeded before the write, like every other programmatic id change…
        #expect(harness.pendingCounterAtApply == [1])
        // …while the user's own choice on the left is left exactly alone.
        #expect(harness.leftId == "onedrive")
        // No folders restored and no extra scan: the caller's own resetNavigation re-homes the
        // panes a moment later, so doing it here would be undone and would double-scan.
        #expect(harness.syncManager.leftRelativePath == "")
        #expect(harness.syncManager.rightRelativePath == "")
        #expect(harness.refreshCount == 0)
    }

    @Test func aProviderSwitchThatLeavesNoPinToReleaseWritesNothing() {
        let harness = Harness()
        // A review whose saved state already matches the live panes: nothing was ever pinned away
        // from the user's setup, so the release must be a no-op rather than a redundant write.
        _ = harness.installReview(restore: SavedCompareState(
            leftProviderId: harness.leftId, rightProviderId: harness.leftId,
            leftRelativePath: "", rightRelativePath: ""))

        harness.coordinator.dispatchReview(.providerSwitched(isLeft: true))

        #expect(harness.duplicateReview == nil)
        #expect(harness.appliedPlans.isEmpty)
        #expect(harness.pendingSwapProviderChanges == 0)
    }

    // MARK: dispatchReview — returning to Compare mid-review

    @Test func returningToCompareRefocusesBothCopiesAndRescans() {
        let harness = Harness()
        let review = harness.installReview()
        // A Tidy detour reset the shared left pane elsewhere.
        harness.syncManager.focusOn(relativePath: "", isLeft: true)

        harness.coordinator.dispatchReview(.tabSwitched(toCompare: true, fromCompare: false))

        // The review survives and both panes are back on the two copies, re-diffed.
        #expect(harness.duplicateReview == review)
        #expect(harness.syncManager.leftRelativePath == "Docs")
        #expect(harness.syncManager.rightRelativePath == "Backup/Docs")
        #expect(harness.refreshCount == 1)
        // No provider changed hands — refocusing must not touch the pin plumbing.
        #expect(harness.appliedPlans.isEmpty)
        #expect(harness.pendingSwapProviderChanges == 0)
    }

    // MARK: duplicateReviewActive

    @Test func reviewIsActiveOnlyWhileBothPanesShowTheReviewedCopies() {
        let harness = Harness()
        let review = harness.installReview()

        harness.currentLeftPath = "/scan/root/Docs"
        harness.currentRightPath = "/scan/root/Backup/Docs"
        #expect(harness.coordinator.duplicateReviewActive(review))

        // Drilling either pane elsewhere deactivates the review (the scoped trash action's gate).
        harness.currentLeftPath = "/scan/root/Docs/Sub"
        #expect(!harness.coordinator.duplicateReviewActive(review))
    }
}
