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
    let syncManager: FileSyncManager
    let reviewStore = ReviewSessionStore()

    /// The injected `FileManaging` reaches only the manager's own stats — `deleteItems` takes its
    /// own (defaulted) file manager — so a test can hold the keeper stat open without stubbing out
    /// the trash itself.
    init(fileManager: FileManaging = FileManager.default) {
        syncManager = FileSyncManager(fileManager: fileManager)
    }

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

    /// Answer for the trash confirmation, plus what it was asked about.
    var trashConfirmAnswer = true
    var trashConfirmedFor: [String] = []

    var coordinator: DuplicateReviewCoordinator {
        var made = DuplicateReviewCoordinator(
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
        made.confirmTrashRightCopy = { review in
            self.trashConfirmedFor.append(review.deletePath)
            return self.trashConfirmAnswer
        }
        return made
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

/// A `FileManager` that parks `attributesOfItem` for one chosen path until the test releases it.
///
/// `trashRightCopy` stats the keeper OFF the main actor precisely because that call can block for
/// seconds against an unmounted cloud or SMB volume. That is also the whole hazard: seconds of
/// window in which the user can act. Holding the stat open here reproduces the slow volume
/// deterministically, so the window can be DRIVEN rather than raced — a `Task.sleep` long enough
/// to hit it reliably would also be long enough to be a flake on a loaded runner.
private final class GatedKeeperStat: FileManager, @unchecked Sendable {
    private let heldPath: String
    private let lock = NSLock()
    private let released = DispatchSemaphore(value: 0)
    private var _isStatting = false

    init(holding path: String) {
        self.heldPath = path
        super.init()
    }

    /// True once the stat for the held path has actually begun — the proof that the trash task is
    /// parked at its one suspension, so whatever the test does next lands inside that window.
    var isStatting: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isStatting
    }

    /// Lets the parked stat finish, as the volume finally answering would.
    func release() { released.signal() }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        guard path == heldPath else { return try super.attributesOfItem(atPath: path) }
        lock.lock(); _isStatting = true; lock.unlock()
        released.wait()
        return try super.attributesOfItem(atPath: path)
    }
}

/// Lets an in-flight trash task run as far as it is ever going to, for the assertions that must
/// hold when the RIGHT answer is "nothing happened". `waitUntil` can't state that — it waits for
/// an outcome, and the outcome here must never arrive — so this yields the main actor long enough
/// for the alternative to have landed instead. The budget is deliberately generous: measured with
/// the fix mutated out, the whole wrong outcome (trash, teardown, restore, tab switch) lands
/// inside 100ms — a twentieth of the 2s waited here.
private func settleTheTrashTask() async {
    for _ in 0..<100 { try? await Task.sleep(nanoseconds: 20_000_000) }
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
        // `#require`, not a bare subscript: on failure an index trap kills the whole test HOST
        // (Swift array bounds are a fatal error, not an assertion), taking every other test's
        // result with it. This exact line crashed the run when the fix it covers was mutated out.
        #expect(harness.appliedPlans.count == 1)
        #expect(try #require(harness.appliedPlans.first).suppressCount == 1)
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

    @Test func reviewDoneClearsTheReviewAndRestoresTheSavedCompareState() throws {
        let harness = Harness()
        _ = harness.installReview()

        harness.coordinator.dispatchReview(.reviewDone)

        #expect(harness.duplicateReview == nil)
        // The pinned right pane went back to the saved provider, and the counter was seeded
        // BEFORE the write (the restore path shares compareCopies' suppression contract).
        #expect(harness.rightId == "dropbox")
        // `#require`, not a bare subscript: on failure an index trap kills the whole test HOST
        // (Swift array bounds are a fatal error, not an assertion), taking every other test's
        // result with it. This exact line crashed the run when the fix it covers was mutated out.
        #expect(harness.appliedPlans.count == 1)
        #expect(try #require(harness.appliedPlans.first).suppressCount == 1)
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

    @Test func providerSwitchAfterTheReviewWentInactiveReleasesTheOtherPanesPin() throws {
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
        // `#require`, not a bare subscript: on failure an index trap kills the whole test HOST
        // (Swift array bounds are a fatal error, not an assertion), taking every other test's
        // result with it. This exact line crashed the run when the fix it covers was mutated out.
        #expect(harness.appliedPlans.count == 1)
        #expect(try #require(harness.appliedPlans.first).suppressCount == 1)
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

    // MARK: trashRightCopy — the one destructive path

    /// Declining the confirmation must change nothing at all: no delete, no tab switch, and the
    /// review stays up so the user can retry. Before the confirmer became a seam this path — the
    /// only destructive one on the coordinator — could not be exercised by a test in any form.
    @Test func decliningTheTrashConfirmationLeavesEverythingAlone() async {
        let harness = Harness()
        let review = harness.installReview()
        harness.trashConfirmAnswer = false

        harness.coordinator.trashRightCopy(review)
        await Task.yield()

        #expect(harness.trashConfirmedFor == [review.deletePath])
        #expect(harness.duplicateReview == review)   // still up for a retry
        #expect(harness.tab == .tidy)
        #expect(harness.appliedPlans.isEmpty)        // no restore ran
        #expect(harness.refreshCount == 0)
    }

    /// A keeper that no longer matches the scan refuses the trash even after the user confirmed:
    /// an external move/delete during a long side-by-side review would otherwise make the copy
    /// being trashed the LAST one. The review stays up, with a banner saying why.
    @Test func aDriftedKeeperRefusesTheTrashAfterConfirmation() async {
        let harness = Harness()
        // keepPath points at nothing on disk, so the existence half of the gate fails.
        let review = harness.installReview()
        harness.trashConfirmAnswer = true

        harness.coordinator.trashRightCopy(review)
        await waitUntil("the keeper-drift refusal surfaces") {
            harness.syncManager.banner?.severity == .warning
        }

        #expect(harness.syncManager.banner?.message.contains("no longer what the scan saw") == true)
        #expect(harness.duplicateReview == review)   // kept, not torn down
        #expect(harness.appliedPlans.isEmpty)
        #expect(harness.tab == .tidy)
    }

    /// The success path, end to end on a real temp tree: the confirmed trash actually removes the
    /// right copy, the review is torn down with its Compare setup restored, the Duplicates list
    /// drops just that copy, and the user lands back on the Tidy tab. Needs a real fixture because
    /// the keeper-drift gate stats the keeper (existence AND, for files, byte size vs the scan
    /// snapshot) before anything is trashed.
    @Test func confirmingTrashesTheRightCopyAndReturnsToTidy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-review-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let keep = root.appendingPathComponent("Docs")
        let copy = root.appendingPathComponent("Backup/Docs")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: keep.appendingPathComponent("a.txt"))
        try Data("x".utf8).write(to: copy.appendingPathComponent("a.txt"))

        let harness = Harness()
        harness.tidyProviderRoot = root.path
        let review = harness.installReview()   // keepPath = <root>/Docs, deletePath = <root>/Backup/Docs
        // The Duplicates list still holds the group this review came from.
        harness.syncManager.duplicateGroups = [
            DuplicateGroup(
                matchType: .identical,
                name: "Docs",
                isDirectory: true,
                copies: [duplicateCopy(path: keep.path, keeper: true),
                         duplicateCopy(path: copy.path, keeper: false)],
                reclaimableBytes: 1234)
        ]
        harness.tab = .differences
        harness.trashConfirmAnswer = true

        harness.coordinator.trashRightCopy(review)
        await waitUntil("the right copy leaves the disk") {
            !FileManager.default.fileExists(atPath: copy.path)
        }

        // The keeper is untouched — the whole point of the drift gate above it.
        #expect(FileManager.default.fileExists(atPath: keep.path))
        // Back to the Duplicates list, with that copy dropped from its group (the group had two
        // copies, so removing one leaves only the keeper and the group disappears).
        await waitUntil("the review is torn down") { harness.duplicateReview == nil }
        #expect(harness.tab == .tidy)
        #expect(harness.lens == .duplicates)
        #expect(harness.syncManager.duplicateGroups.isEmpty)
        // And the pre-review Compare setup came back (the pinned right pane released).
        #expect(harness.rightId == "dropbox")
    }

    // MARK: trashRightCopy — the user-interaction window the keeper stat opens

    /// Moving the keeper stat off the main actor (so an unmounted cloud volume can't beachball the
    /// window on a button click) put a suspension where the code had none — and that suspension is
    /// seconds long on exactly the volumes it was added for. The Duplicates list is one tab away
    /// the whole time, so the user can compare a DIFFERENT pair while the stat is out. Resuming
    /// blind then trashes a copy they are no longer looking at, and worse, `.rightCopyTrashed`
    /// tears down the review that replaced this one and replays THIS review's saved compare state
    /// over the new pair's panes. The trash must be abandoned instead.
    @Test func aReviewReplacedWhileTheKeeperStatIsInFlightCancelsTheTrash() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-review-race-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Docs", "Backup/Docs", "Photos", "Old/Photos"] {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))
        }

        let stat = GatedKeeperStat(holding: root.appendingPathComponent("Docs").path)
        let harness = Harness(fileManager: stat)
        harness.tidyProviderRoot = root.path
        harness.tab = .differences
        harness.trashConfirmAnswer = true
        let first = harness.installReview()   // Docs (keep) ↔ Backup/Docs (delete candidate)

        harness.coordinator.trashRightCopy(first)
        await waitUntil("the keeper stat is in flight") { stat.isStatting }

        // Inside that window: back to Tidy, compare another pair. The review the trash was
        // authorized for is no longer the one on screen.
        let second = harness.installReview(keepRel: "Photos", deleteRel: "Old/Photos")
        stat.release()
        await settleTheTrashTask()

        // The copy the confirmation named is still on disk — nothing was trashed…
        #expect(FileManager.default.fileExists(atPath: first.deletePath))
        // …the review the user IS looking at survived intact…
        #expect(harness.duplicateReview == second)
        // …and the superseded review's compare state was never replayed over it.
        #expect(harness.appliedPlans.isEmpty)
        #expect(harness.tab == .differences)
    }

    /// The same window, entered through the other control that sits in it: "Done" is rendered
    /// directly beside the destructive button, so it is one stray click away during the whole stat.
    /// A trash that resumes afterwards deletes a copy for a review that no longer exists, and drags
    /// the user back to Tidy from wherever they went.
    @Test func endingTheReviewWhileTheKeeperStatIsInFlightCancelsTheTrash() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-review-done-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Docs", "Backup/Docs"] {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))
        }

        let stat = GatedKeeperStat(holding: root.appendingPathComponent("Docs").path)
        let harness = Harness(fileManager: stat)
        harness.tidyProviderRoot = root.path
        harness.tab = .differences
        harness.trashConfirmAnswer = true
        let review = harness.installReview()

        harness.coordinator.trashRightCopy(review)
        await waitUntil("the keeper stat is in flight") { stat.isStatting }

        // "Done" while the stat is out: the review is torn down and the pre-review Compare setup
        // restored — one pin plan, and it must stay one.
        harness.coordinator.endDuplicateReview()
        #expect(harness.duplicateReview == nil)
        stat.release()
        await settleTheTrashTask()

        #expect(FileManager.default.fileExists(atPath: review.deletePath))
        #expect(harness.duplicateReview == nil)
        #expect(harness.appliedPlans.count == 1, "only Done's own restore ran")
        #expect(harness.tab == .differences, "an abandoned trash must not yank the user back to Tidy")
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
