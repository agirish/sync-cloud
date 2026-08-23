import SwiftUI
import Testing
import Events
import Sync
import FileExplorer
@testable import SyncCloud

/// Exercises ``DuplicateReviewCoordinator`` — the effect-EXECUTION half of the duplicate-review
/// flow (``CompareReviewReducer`` owns the decisions and has its own suite). These paths used to
/// live inline in `ContentView`'s `@State` glue, unreachable by tests; the coordinator receives
/// bindings and closures, so a test can stand in for the view and pin the execution contracts:
///
/// - the suppression counter is seeded BEFORE any provider-id write is applied (an id onChange
///   that fires against an unseeded counter wipes the lens results the retarget is protecting),
/// - `compareCopies` keeps the ORIGINAL restore snapshot when a second pair is compared without
///   ending the first review (the panes are already pinned — capturing again would "restore" to
///   the pinned provider and leak it),
/// - teardown-with-restore vs drop-without-restore reach the right execution effects.
@MainActor
private final class Harness {
    let syncManager: FileSyncManager
    let reviewStore = ReviewSessionStore()

    /// The injected `FileManaging` reaches the manager's stats AND, since `trashRightCopy` began
    /// passing `fileManager:` explicitly, the removal itself — so a double that fails `trashItem`
    /// drives the permanent-delete branch for real (see `DuplicateReviewLogHonestyTests`). This
    /// used to say the removal took its own defaulted manager and was therefore undrivable; that
    /// was true, and is the very seam that let the gate and the delete measure different disks.
    init(fileManager: FileManaging = FileManager.default) {
        syncManager = FileSyncManager(fileManager: fileManager)
    }

    var duplicateReview: DuplicateCompareContext?
    var leftId = "icloud"
    var rightId = "dropbox"
    var pendingSwapProviderChanges = 0
    var workspace: Workspace = .filing
    /// The rail item inside Organize. Starts on a DIFFERENT lens than the one the coordinator has
    /// to select, so a coordinator that sets only the workspace fails here rather than passing on
    /// a value that happened to be right already.
    var organizeLens: OrganizeLens? = .toFile

    // Live-context stand-ins (ContentView resolves these from providers + pane state).
    var currentLeftPath = ""
    var currentRightPath = ""
    var lensTargetIsRight = false
    var lensProviderRoot = "/scan/root"

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
            selectedWorkspace: Binding(get: { self.workspace }, set: { self.workspace = $0 }),
            organizeLens: Binding(get: { self.organizeLens }, set: { self.organizeLens = $0 }),
            accentColor: .blue,
            glassLevel: .frosted,
            currentLeftPath: { self.currentLeftPath },
            currentRightPath: { self.currentRightPath },
            lensTargetIsRight: { self.lensTargetIsRight },
            lensProviderRootExpanded: { self.lensProviderRoot },
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

    /// A review as `compareCopies` would set it up, with panes "pinned" to the lens provider.
    /// Snapshots default to nil, which the fixed gate REFUSES for a folder review — tests that
    /// drive the trash to completion capture real baselines and pass them in.
    func installReview(
        keepRel: String = "Docs", deleteRel: String = "Backup/Docs",
        keepSnapshot: FolderContentSnapshot? = nil,
        deleteSnapshot: FolderContentSnapshot? = nil,
        restore: SavedCompareState? = nil
    ) -> DuplicateCompareContext {
        let review = DuplicateCompareContext(
            groupName: "Docs",
            keepPath: "\(lensProviderRoot)/\(keepRel)",
            deletePath: "\(lensProviderRoot)/\(deleteRel)",
            keepIsDirectory: true,
            keepScannedSize: 1234,
            keepScannedDate: nil,
            deleteIsDirectory: true, deleteScannedSize: 1234, deleteScannedDate: nil,
            keepContentSnapshot: keepSnapshot,
            deleteContentSnapshot: deleteSnapshot,
            keeperRelativePath: keepRel,
            redundantRelativePath: deleteRel,
            restore: restore ?? SavedCompareState(
                leftProviderId: "icloud", rightProviderId: "dropbox",
                leftRelativePath: "Was/Left", rightRelativePath: "Was/Right"))
        duplicateReview = review
        // compareCopies pins both panes to the lens provider (left pane's, here).
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
/// A real `FileManager` whose Trash always refuses — a Trash-less volume (exFAT, most SMB shares)
/// without needing one. Same shape as `Sync`'s `MergeUndoPromiseTests.TrashlessVolume`.
private final class TrashlessVolume: FileManager, @unchecked Sendable {
    override func trashItem(at url: URL,
                            resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
    }
}

/// A reference box for what the permanent-delete confirmer was asked about; the closure escapes.
private final class PermanentDeleteBox: @unchecked Sendable {
    var paths: [String] = []
}

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

/// A continuation-backed latch for parking an enqueued file operation WITHOUT blocking a
/// cooperative-pool thread (the Sync package's flake notes document why a semaphore park on the
/// pool is the wrong tool here).
private actor ReviewTestLatch {
    private var opened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func open() {
        opened = true
        for c in continuations { c.resume() }
        continuations.removeAll()
    }
}

/// A lock-guarded boolean for signalling out of a `@Sendable` closure.
private final class ReviewTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
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

        // Both panes pinned to the lens provider (the left pane's, since lensTargetIsRight=false):
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
        #expect(harness.workspace == .compare)
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
        defer { wipeDefaultsSuite(suite) }
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

        // Refused outright: no review, no pin, no seeding, no workspace switch, no rescan.
        #expect(harness.duplicateReview == nil)
        #expect(harness.appliedPlans.isEmpty)
        #expect(harness.pendingSwapProviderChanges == 0)
        #expect(harness.workspace == .filing)
        // Unchanged from where the harness started: this path refuses, so it must not
        // navigate. (Asserted against `.toFile` rather than the destination, so a
        // coordinator that DID navigate here fails instead of passing by coincidence.)
        #expect(harness.organizeLens == .toFile)
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

    /// **A browse tab changing a pane's source destroys an in-progress duplicate review, and both
    /// halves of that loss are now said out loud.**
    ///
    /// `.tabChangedSource` clears the review and *deliberately* strands the review's programmatic
    /// provider pin on the sibling pane — undoing it would repoint a pane and restore no folder,
    /// because `.undoProviderPin` expects a `resetNavigation()` that a tab-driven switch never
    /// makes (see `CompareReviewEvent.tabChangedSource`). That is the right call, and it is still a
    /// loss the user can see and cannot explain: the banner is gone and the pane they did not touch
    /// sits on a source the *review* chose. Neither half wrote anything to `~/sync-cloud.log` — the
    /// clear case is a bare `duplicateReview = nil`, and the strand is represented by no effect at
    /// all — so this delta added a NEW route into a silent state loss.
    ///
    /// **Read between this test's own markers, with the review's group name and both provider ids
    /// carrying a token.** `Logger.shared` is process-wide and `entries` is a rolled 1000-line
    /// window: the opener is `#require`d as the eviction guard, and the tokens are what make both
    /// the presence and the absence readings exclusive to this run in a parallel suite.
    @Test func aTabDrivenSourceChangeSaysWhatItDiscardedAndWhatItStranded() async throws {
        /// Everything logged between two fresh markers, with the call under test run between them.
        func window(_ act: () -> Void) async throws -> ArraySlice<String> {
            let marker = UUID().uuidString.prefix(8)
            await Logger.shared.debug("review window open \(marker)").value
            act()
            await Logger.shared.debug("review window close \(marker)").value
            let messages = Logger.shared.entries.map(\.message)
            let opened = try #require(messages.firstIndex(where: { $0.contains("open \(marker)") }),
                                      "the log window rolled past this test's own marker, so this reading is vacuous")
            let tail = messages[opened...]
            let closed = try #require(tail.lastIndex(where: { $0.contains("close \(marker)") }),
                                      "the closing marker never landed — this reading is vacuous")
            return tail[...closed]
        }

        /// A review whose group name and pre-review sources are unique to this run, with both panes
        /// pinned to one provider exactly as `compareCopies` leaves them.
        func pinnedReview(_ token: String, on harness: Harness) -> DuplicateCompareContext {
            harness.leftId = "pinned-\(token)"
            harness.rightId = "pinned-\(token)"
            let review = DuplicateCompareContext(
                groupName: "Docs-\(token)",
                keepPath: "\(harness.lensProviderRoot)/Docs",
                deletePath: "\(harness.lensProviderRoot)/Backup/Docs",
                keepIsDirectory: true, keepScannedSize: 1234,
                keepScannedDate: nil,
                deleteIsDirectory: true, deleteScannedSize: 1234, deleteScannedDate: nil,
                keepContentSnapshot: nil, deleteContentSnapshot: nil,
                keeperRelativePath: "Docs", redundantRelativePath: "Backup/Docs",
                restore: SavedCompareState(leftProviderId: "was-left-\(token)",
                                           rightProviderId: "was-right-\(token)",
                                           leftRelativePath: "Was/Left",
                                           rightRelativePath: "Was/Right"))
            harness.duplicateReview = review
            return review
        }

        // 1. The tab-driven change itself: both halves land. The tab moved the LEFT pane, so the
        //    pin that can be stranded is the RIGHT one — `was-right-…` below is the sibling's.
        let tabToken = String(UUID().uuidString.prefix(8))
        let harness = Harness()
        _ = pinnedReview(tabToken, on: harness)
        let changed = try await window { harness.coordinator.noteTabChangedSource(isLeft: true) }

        #expect(harness.duplicateReview == nil, "the review survived a tab-driven source change")
        let discarded = changed.filter { $0.contains("Docs-\(tabToken)") }
        #expect(discarded.count == 1,
                "\(discarded.count) lines name the review a tab-driven source change threw away — the banner vanishes with nothing in the log to say what took it")
        #expect(discarded.first?.contains("a browse tab changed a pane's source") == true,
                "the line does not name the CAUSE, so it sends a reader looking for a gesture they did not make")

        let stranded = changed.filter { $0.contains("was-right-\(tabToken)") }
        #expect(stranded.count == 1,
                "\(stranded.count) lines about the provider pin this event deliberately leaves behind — the user's other pane keeps a source the review chose and nothing says so")
        #expect(stranded.first?.contains("pinned-\(tabToken)") == true,
                "the line names the pre-review sources but not the ones the panes are actually left on, which is the half a reader is looking at")

        // 2. …and the strand line is specific to this event. A swap clears the review the same way
        //    but exchanges the two ids, so the pin travels with the pane rather than being left —
        //    a warning there would be a sentence about something that did not happen.
        let swapToken = String(UUID().uuidString.prefix(8))
        let swapped = Harness()
        _ = pinnedReview(swapToken, on: swapped)
        let afterSwap = try await window { swapped.coordinator.dispatchReview(.panesSwapped) }
        #expect(afterSwap.contains(where: { $0.contains("Docs-\(swapToken)") }),
                "a swap drops the review and says nothing about it either")
        #expect(!afterSwap.contains(where: { $0.contains("was-right-\(swapToken)") }),
                "a pane swap claims it stranded the review's provider pin — it exchanges the ids, so the pin travels with the pane")

        // 3. …and an event that clears NOTHING says nothing. `.compareCopiesStarted` with no guided
        //    review running produces no effects at all, so a discard line there would be a claim
        //    about a review that is still sitting right where it was.
        let quietToken = String(UUID().uuidString.prefix(8))
        let quiet = Harness()
        let kept = pinnedReview(quietToken, on: quiet)
        let afterQuiet = try await window { quiet.coordinator.dispatchReview(.compareCopiesStarted) }
        #expect(quiet.duplicateReview == kept, "the review was cleared by an event that clears nothing")
        #expect(!afterQuiet.contains(where: { $0.contains("Docs-\(quietToken)") }),
                "a review that was not discarded is logged as discarded")

        // 4. **The case this warning was firing on with nothing stranded.** `compareCopies` pins
        //    both panes and `ProviderPinPlan` writes nothing for a side already on the target — so
        //    a user whose pre-review pair was ALREADY that provider on both sides has no pin left
        //    anywhere. A tab then moves one pane, the PAIR differs from the saved pair, and the old
        //    gate warned that the review's pin was stranded and "Nothing will restore that". The
        //    sibling here is where the user left it, so the review must say what it discarded and
        //    nothing more. This is the half the commit body claimed and no window covered: window 2
        //    tests a different EVENT (`.panesSwapped`), not this event with nothing to strand.
        let calmToken = String(UUID().uuidString.prefix(8))
        let calm = Harness()
        let unchanged = "userchoice-\(calmToken)"
        calm.leftId = unchanged
        calm.rightId = unchanged
        calm.duplicateReview = DuplicateCompareContext(
            groupName: "Calm-\(calmToken)",
            keepPath: "\(calm.lensProviderRoot)/Docs",
            deletePath: "\(calm.lensProviderRoot)/Backup/Docs",
            keepIsDirectory: true, keepScannedSize: 1234,
            keepScannedDate: nil,
            deleteIsDirectory: true, deleteScannedSize: 1234, deleteScannedDate: nil,
            keepContentSnapshot: nil, deleteContentSnapshot: nil,
            keeperRelativePath: "Docs", redundantRelativePath: "Backup/Docs",
            // Both panes were already on this source before the review, so the review pinned
            // nothing: there is no leftover on either side.
            restore: SavedCompareState(leftProviderId: unchanged, rightProviderId: unchanged,
                                       leftRelativePath: "Was/Left", rightRelativePath: "Was/Right"))
        // The tab moves the RIGHT pane onto a new source — the user's own choice, on the pane they
        // clicked in. The sibling (left) is untouched, so nothing is stranded.
        calm.rightId = "tabchoice-\(calmToken)"
        let afterCalm = try await window { calm.coordinator.noteTabChangedSource(isLeft: false) }

        #expect(calm.duplicateReview == nil, "the review survived a tab-driven source change")
        #expect(afterCalm.contains(where: { $0.contains("Calm-\(calmToken)") }),
                "the discard line went missing — this window would then be asserting the absence of a warning in a run where nothing happened at all")
        #expect(!afterCalm.contains(where: { $0.contains("deliberately left in place") }),
                "a WARNING claims the review stranded a provider pin on a pane that is exactly where the user left it — a warning about a loss that did not happen, in the log he audits")
        #expect(!afterCalm.contains(where: { $0.contains(unchanged) }),
                "the stranded-pin line named a pane whose source never moved")
    }

    /// **Which pane can be holding the review's leftover pin, on the rule itself.**
    ///
    /// The gate asked "has the PAIR moved from the pre-review pair", and strandedness is not that:
    /// the user chose the source on the pane they clicked in, so the only pin that can be left
    /// behind is on the SIBLING. Driven here rather than scanned, because the polarity is the whole
    /// content — a `stranded(movedPane:)` that reads its own side instead of the sibling's warns
    /// about the pane the user is looking at and stays silent about the one they are not.
    @Test func theStrandedPinIsTheSiblingsAndOnlyTheSiblings() {
        // The tab moved the LEFT pane onto something new; the RIGHT one still carries the pin.
        let afterLeftMoved = StrandedProviderPin.stranded(
            movedPane: true,
            savedLeft: "was-left", savedRight: "was-right",
            currentLeft: "tab-choice", currentRight: "pinned")
        #expect(afterLeftMoved == StrandedProviderPin.Sibling(isLeft: false, saved: "was-right",
                                                             current: "pinned"),
                "a tab moving the left pane reports the wrong pane's pin — the ids named in the warning are the ones the user did not touch")
        #expect(afterLeftMoved?.name == "right", "the warning names the wrong pane")

        // …and the mirror, from the other side, because a rule that simply always answers “right”
        // passes the pair above.
        let afterRightMoved = StrandedProviderPin.stranded(
            movedPane: false,
            savedLeft: "was-left", savedRight: "was-right",
            currentLeft: "pinned", currentRight: "tab-choice")
        #expect(afterRightMoved == StrandedProviderPin.Sibling(isLeft: true, saved: "was-left",
                                                              current: "pinned"),
                "a tab moving the right pane reports the wrong pane's pin")
        #expect(afterRightMoved?.name == "left", "the warning names the wrong pane")

        // **Nothing stranded: the sibling is where the user left it.** This is the shape the old
        // gate warned about — the pane the tab moved differs from the saved pair, so "has the pair
        // moved" said yes while there was no pin to strand anywhere.
        #expect(StrandedProviderPin.stranded(movedPane: false,
                                             savedLeft: "mine", savedRight: "mine",
                                             currentLeft: "mine", currentRight: "tab-choice") == nil,
                "a pane the review never repointed is reported as stranded — a WARNING naming a loss that did not happen")
        // …and the converse, which is what stops the fix over-correcting into silence: the sibling
        // holds a pin even though the pane the tab moved is back where it started.
        #expect(StrandedProviderPin.stranded(movedPane: true,
                                             savedLeft: "mine", savedRight: "was-right",
                                             currentLeft: "mine", currentRight: "pinned")
                != nil,
                "a genuinely stranded sibling pin goes unreported when the pane the tab moved happens to match its saved value")
    }

    @Test func providerSwitchAfterTheReviewWentInactiveReleasesTheOtherPanesPin() throws {
        let harness = Harness()
        _ = harness.installReview()   // pins rightId to the left (lens) provider
        #expect(harness.rightId == harness.leftId)
        // The panes are NOT on the two copies — entering an Organize lens re-focused the shared left
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
        #expect(harness.workspace == .filing)
        // Unchanged from where the harness started: this path refuses, so it must not
        // navigate. (Asserted against `.toFile` rather than the destination, so a
        // coordinator that DID navigate here fails instead of passing by coincidence.)
        #expect(harness.organizeLens == .toFile)
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
        #expect(harness.workspace == .filing)
        // Unchanged from where the harness started: this path refuses, so it must not
        // navigate. (Asserted against `.toFile` rather than the destination, so a
        // coordinator that DID navigate here fails instead of passing by coincidence.)
        #expect(harness.organizeLens == .toFile)
    }

    /// The success path, end to end on a real temp tree: the confirmed trash actually removes the
    /// right copy, the review is torn down with its Compare setup restored, the Duplicates list
    /// drops just that copy, and the user lands back on the Duplicates lens. Needs a real fixture because
    /// the keeper-drift gate stats the keeper (existence AND, for files, byte size vs the scan
    /// snapshot) before anything is trashed.
    @Test func confirmingTrashesTheRightCopyAndReturnsToDuplicates() async throws {
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
        harness.lensProviderRoot = root.path
        // A folder review carries the scan's per-entry baselines; the directory half of the gate
        // re-walks against them, and nil would (correctly) refuse the trash.
        let ignored = DuplicateFinderOptions.defaultIgnoredNames
        let keepSnapshot = await FileSyncManager.folderContentSnapshot(
            ofPath: keep.path, ignoredNames: ignored, fileManager: FileManager.default)
        let deleteSnapshot = await FileSyncManager.folderContentSnapshot(
            ofPath: copy.path, ignoredNames: ignored, fileManager: FileManager.default)
        let review = harness.installReview(keepSnapshot: keepSnapshot, deleteSnapshot: deleteSnapshot)
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
        harness.workspace = .compare
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
        #expect(harness.workspace == .filing)
        #expect(harness.organizeLens == .duplicates)
        #expect(harness.syncManager.duplicateGroups.isEmpty)
        // And the pre-review Compare setup came back (the pinned right pane released).
        #expect(harness.rightId == "dropbox")
    }

    /// **The permanent-delete branch, driven for real** — which only became possible when
    /// `trashRightCopy` started passing `fileManager:` to `deleteItems`.
    ///
    /// Before that the removal took `FileManager.default` whatever the manager held, so staging a
    /// Trash-less volume achieved nothing: `trashItem` succeeded against the real temp directory,
    /// the copy went to the user's ACTUAL Trash, and the branch was unreachable from a test. That
    /// is why `DuplicateReviewLogHonestyTests` pins it by source scan, and why its doc used to say
    /// no injection could reach it.
    ///
    /// The discriminator is `permanentDeleteConfirmer`, which `deleteItems` asks ONLY once the
    /// trash has failed. With the removal on the injected manager it is asked, naming the copy;
    /// with the removal on `FileManager.default` it is never asked at all — so an empty box here
    /// means the two halves measured different filesystems. It also means this test never touches
    /// the real Trash: the double refuses that call outright.
    @Test func aPermanentlyDeletedRightCopyIsConfirmedAgainstTheManagersOwnFilesystem() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-review-perm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let keep = root.appendingPathComponent("Docs")
        let copy = root.appendingPathComponent("Backup/Docs")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: keep.appendingPathComponent("a.txt"))
        try Data("x".utf8).write(to: copy.appendingPathComponent("a.txt"))

        let harness = Harness(fileManager: TrashlessVolume())
        harness.lensProviderRoot = root.path
        let ignored = DuplicateFinderOptions.defaultIgnoredNames
        let keepSnapshot = await FileSyncManager.folderContentSnapshot(
            ofPath: keep.path, ignoredNames: ignored, fileManager: FileManager.default)
        let deleteSnapshot = await FileSyncManager.folderContentSnapshot(
            ofPath: copy.path, ignoredNames: ignored, fileManager: FileManager.default)
        let review = harness.installReview(keepSnapshot: keepSnapshot, deleteSnapshot: deleteSnapshot)
        harness.trashConfirmAnswer = true

        let askedAbout = PermanentDeleteBox()
        harness.syncManager.permanentDeleteConfirmer = { paths in
            askedAbout.paths = paths
            return true
        }

        harness.coordinator.trashRightCopy(review)
        await waitUntil("the right copy leaves the disk") {
            !FileManager.default.fileExists(atPath: copy.path)
        }

        #expect(askedAbout.paths.count == 1,
                """
                the permanent-delete confirmation was never raised, so the removal did not go \
                through the manager the drift gate measures — it used FileManager.default and \
                trashed the copy for real
                """)
        #expect(askedAbout.paths.first?.hasSuffix("Backup/Docs") == true,
                "the confirmation named \(askedAbout.paths) rather than the right copy")
        // The keeper is untouched, exactly as on the recoverable path.
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }

    /// **The review is the folder-ONLY flow, and its directory gate must see content.** The card
    /// offers Compare for every directory group, a review is designed to stay open, and while it
    /// is, the right folder can gain a file (a download landing, a provider sync) — trashing it
    /// then destroys the only instance of that file, under a banner saying the left copy is kept.
    /// The stat facts cannot catch this (a folder's stat size is not its contents), so the gate's
    /// directory verdict comes from the engine's shared re-walk against the scan's baseline.
    @Test func aRightFolderThatGainedAFileDuringTheReviewIsRefused() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-review-drift-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let keep = root.appendingPathComponent("Docs")
        let copy = root.appendingPathComponent("Backup/Docs")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: keep.appendingPathComponent("a.txt"))
        try Data("x".utf8).write(to: copy.appendingPathComponent("a.txt"))

        let harness = Harness()
        harness.lensProviderRoot = root.path
        harness.workspace = .compare
        harness.trashConfirmAnswer = true
        let ignored = DuplicateFinderOptions.defaultIgnoredNames
        let keepSnapshot = await FileSyncManager.folderContentSnapshot(
            ofPath: keep.path, ignoredNames: ignored, fileManager: FileManager.default)
        let deleteSnapshot = await FileSyncManager.folderContentSnapshot(
            ofPath: copy.path, ignoredNames: ignored, fileManager: FileManager.default)
        let review = harness.installReview(keepSnapshot: keepSnapshot, deleteSnapshot: deleteSnapshot)

        // The right copy gains a file AFTER the scan's baseline — during the open review.
        try Data("the only copy of this".utf8).write(to: copy.appendingPathComponent("new-edit.txt"))

        harness.coordinator.trashRightCopy(review)
        await waitUntil("the drift refusal surfaces") {
            harness.syncManager.banner?.severity == .warning
        }

        #expect(FileManager.default.fileExists(atPath: copy.path),
                "a folder that gained content nothing else has was trashed by the review")
        #expect(harness.syncManager.banner?.message.contains("changed since the scan") == true)
        #expect(harness.duplicateReview == review, "the review stays up so the user can rescan")
        #expect(harness.workspace == .compare, "a refusal must not navigate")
    }

    /// The KEEP side of the same content gate. The keeper still EXISTS — so the existence half
    /// that `aDriftedKeeperRefusesTheTrashAfterConfirmation` pins never fires — but its contents
    /// moved during the open review: what would be kept is no longer what the scan grouped, so
    /// trashing the right copy would destroy the last instance of the scanned content. Only the
    /// directory verdict from the shared re-walk can refuse this.
    @Test func aKeepFolderWhoseContentsDriftedDuringTheReviewIsRefused() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-review-keep-drift-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let keep = root.appendingPathComponent("Docs")
        let copy = root.appendingPathComponent("Backup/Docs")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: keep.appendingPathComponent("a.txt"))
        try Data("x".utf8).write(to: copy.appendingPathComponent("a.txt"))

        let harness = Harness()
        harness.lensProviderRoot = root.path
        harness.workspace = .compare
        harness.trashConfirmAnswer = true
        let ignored = DuplicateFinderOptions.defaultIgnoredNames
        let keepSnapshot = await FileSyncManager.folderContentSnapshot(
            ofPath: keep.path, ignoredNames: ignored, fileManager: FileManager.default)
        let deleteSnapshot = await FileSyncManager.folderContentSnapshot(
            ofPath: copy.path, ignoredNames: ignored, fileManager: FileManager.default)
        let review = harness.installReview(keepSnapshot: keepSnapshot, deleteSnapshot: deleteSnapshot)

        // The KEEPER loses its file after the scan's baseline — during the open review.
        try FileManager.default.removeItem(at: keep.appendingPathComponent("a.txt"))

        harness.coordinator.trashRightCopy(review)
        await waitUntil("the keep-drift refusal surfaces") {
            harness.syncManager.banner?.severity == .warning
        }

        #expect(FileManager.default.fileExists(atPath: copy.path),
                "the right copy is the last instance of the scanned content — it must stay")
        #expect(harness.syncManager.banner?.message.contains("no longer what the scan saw") == true)
        #expect(harness.duplicateReview == review, "the review stays up so the user can rescan")
        #expect(harness.workspace == .compare, "a refusal must not navigate")
    }

    /// A folder review with NO recorded baseline still refuses — but the banner must say the scan
    /// couldn't check the pair, not that something changed: the scan records a nil snapshot on a
    /// folder whose subtree held an unreadable descendant, a rescan reproduces nil, and the old
    /// wording claimed a change nobody measured while pointing at a rescan that could never clear
    /// it.
    @Test func aFolderReviewWithNoBaselineRefusesWithoutClaimingDrift() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-review-nil-baseline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let keep = root.appendingPathComponent("Docs")
        let copy = root.appendingPathComponent("Backup/Docs")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: keep.appendingPathComponent("a.txt"))
        try Data("x".utf8).write(to: copy.appendingPathComponent("a.txt"))

        let harness = Harness()
        harness.lensProviderRoot = root.path
        harness.workspace = .compare
        harness.trashConfirmAnswer = true
        // Both paths exist and match on disk; only the baselines are missing (nil snapshots are
        // installReview's default).
        let review = harness.installReview()

        harness.coordinator.trashRightCopy(review)
        await waitUntil("the no-baseline refusal surfaces") {
            harness.syncManager.banner?.severity == .warning
        }

        #expect(FileManager.default.fileExists(atPath: copy.path), "the refusal itself must stand")
        #expect(harness.syncManager.banner?.message.contains("couldn't be fully checked") == true)
        #expect(harness.syncManager.banner?.message.contains("no longer what the scan saw") != true,
                "no change was measured, so none may be claimed")
        #expect(harness.duplicateReview == review, "the review stays up")
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
        harness.lensProviderRoot = root.path
        harness.workspace = .compare
        harness.trashConfirmAnswer = true
        let first = harness.installReview()   // Docs (keep) ↔ Backup/Docs (delete candidate)

        harness.coordinator.trashRightCopy(first)
        await waitUntil("the keeper stat is in flight") { stat.isStatting }

        // Inside that window: back to Organize, compare another pair. The review the trash was
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
        #expect(harness.workspace == .compare)
    }

    /// The same window, entered through the other control that sits in it: "Done" is rendered
    /// directly beside the destructive button, so it is one stray click away during the whole stat.
    /// A trash that resumes afterwards deletes a copy for a review that no longer exists, and drags
    /// the user back to Organize from wherever they went.
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
        harness.lensProviderRoot = root.path
        harness.workspace = .compare
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
        #expect(harness.workspace == .compare, "an abandoned trash must not yank the user back to Organize")
    }

    // MARK: dispatchReview — returning to Compare mid-review

    @Test func returningToCompareRefocusesBothCopiesAndRescans() {
        let harness = Harness()
        let review = harness.installReview()
        // A lens detour reset the shared left pane elsewhere.
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

    // MARK: trashRightCopy — refusal logging, wording, and the queue-wait window

    /// The shared logger's most recent line containing `fragment`, awaiting a flush marker first
    /// so everything enqueued before it is visible (`Logger` appends asynchronously). Fixtures
    /// here embed a UUID in every path, so a fragment built from one can never match another
    /// suite's line.
    private func loggedLine(containing fragment: String) async -> String? {
        await Logger.shared.debug("review-coordinator flush marker").value
        return Logger.shared.entries.last { $0.message.contains(fragment) }?.message
    }

    /// **A keep-side refusal reaches the log, not just the banner.** The delete side always
    /// logged both of its refusal variants; the keep side set a banner and wrote NOTHING — a
    /// refusal visible on screen was absent from ~/sync-cloud.log, which he audits.
    @Test func aKeepSideRefusalIsLoggedLikeTheDeleteSide() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-review-keep-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let keep = root.appendingPathComponent("Docs")
        let copy = root.appendingPathComponent("Backup/Docs")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: keep.appendingPathComponent("a.txt"))
        try Data("x".utf8).write(to: copy.appendingPathComponent("a.txt"))

        let harness = Harness()
        harness.lensProviderRoot = root.path
        harness.workspace = .compare
        harness.trashConfirmAnswer = true
        let ignored = DuplicateFinderOptions.defaultIgnoredNames
        let keepSnapshot = await FileSyncManager.folderContentSnapshot(
            ofPath: keep.path, ignoredNames: ignored, fileManager: FileManager.default)
        let deleteSnapshot = await FileSyncManager.folderContentSnapshot(
            ofPath: copy.path, ignoredNames: ignored, fileManager: FileManager.default)
        let review = harness.installReview(keepSnapshot: keepSnapshot, deleteSnapshot: deleteSnapshot)
        // The KEEPER's contents drift during the open review.
        try FileManager.default.removeItem(at: keep.appendingPathComponent("a.txt"))

        harness.coordinator.trashRightCopy(review)
        await waitUntil("the keep-drift refusal surfaces") {
            harness.syncManager.banner?.severity == .warning
        }

        let line = try #require(await loggedLine(containing: "Refused to trash \(review.deletePath)"),
                                "the keep-side refusal wrote nothing to the log")
        #expect(line.contains(review.keepPath), "the line must name the drifted left copy")
        #expect(line.contains("no longer what the scan saw"))
        #expect(FileManager.default.fileExists(atPath: copy.path))
    }

    /// **The delete-side nil-baseline branch, actually reached.** The existing no-baseline test
    /// sets BOTH snapshots nil, so the keep gate refuses first and the delete-side wording was
    /// never exercised: a keep-valid/delete-nil review must refuse with the right-copy wording —
    /// and with the honest "unreadable, or nested too deep" phrasing, because the walk's depth
    /// cap and symlink-cycle guard record a nil baseline exactly like an unreadable descendant.
    @Test func aDeleteFolderWithNoBaselineRefusesWithTheRightCopyWording() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-review-delete-nil-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let keep = root.appendingPathComponent("Docs")
        let copy = root.appendingPathComponent("Backup/Docs")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: keep.appendingPathComponent("a.txt"))
        try Data("x".utf8).write(to: copy.appendingPathComponent("a.txt"))

        let harness = Harness()
        harness.lensProviderRoot = root.path
        harness.workspace = .compare
        harness.trashConfirmAnswer = true
        let keepSnapshot = await FileSyncManager.folderContentSnapshot(
            ofPath: keep.path, ignoredNames: DuplicateFinderOptions.defaultIgnoredNames,
            fileManager: FileManager.default)
        // Keep side fully checked; the DELETE side carries no baseline.
        let review = harness.installReview(keepSnapshot: keepSnapshot, deleteSnapshot: nil)

        harness.coordinator.trashRightCopy(review)
        await waitUntil("the delete-side no-baseline refusal surfaces") {
            harness.syncManager.banner?.severity == .warning
        }

        let message = try #require(harness.syncManager.banner?.message)
        #expect(message.contains("right copy couldn't be fully checked"),
                "the refusal is not the delete-side wording: “\(message)”")
        #expect(message.contains("too deep"),
                "the wording claims only unreadability, but the depth cap and cycle guard produce nil baselines too: “\(message)”")
        #expect(!message.contains("left copy"),
                "the keep-side wording fired for a keep side that was fully checked: “\(message)”")
        let line = try #require(await loggedLine(containing: "Refused to trash \(review.deletePath)"))
        #expect(line.contains("no baseline"))
        #expect(FileManager.default.fileExists(atPath: copy.path), "the refusal itself must stand")
        #expect(harness.duplicateReview == review, "the review stays up")
    }

    /// **Drift during the queue wait is refused at the last check.** `deleteItems` routes through
    /// the serialized op queue, so a long operation queued ahead of the review's trash inserts
    /// its whole duration between the pre-trash verdict and the removal — a file landing in the
    /// right copy during that window used to be trashed on the stale verdict, destroying its only
    /// instance under a banner saying the left copy is kept.
    @Test func aRightCopyThatGainsAFileDuringTheQueueWaitIsRefused() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-review-queue-drift-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let keep = root.appendingPathComponent("Docs")
        let copy = root.appendingPathComponent("Backup/Docs")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: keep.appendingPathComponent("a.txt"))
        try Data("x".utf8).write(to: copy.appendingPathComponent("a.txt"))

        let harness = Harness()
        harness.lensProviderRoot = root.path
        harness.workspace = .compare
        harness.trashConfirmAnswer = true
        let ignored = DuplicateFinderOptions.defaultIgnoredNames
        let keepSnapshot = await FileSyncManager.folderContentSnapshot(
            ofPath: keep.path, ignoredNames: ignored, fileManager: FileManager.default)
        let deleteSnapshot = await FileSyncManager.folderContentSnapshot(
            ofPath: copy.path, ignoredNames: ignored, fileManager: FileManager.default)
        let review = harness.installReview(keepSnapshot: keepSnapshot, deleteSnapshot: deleteSnapshot)

        // A long operation is already on the queue when the trash is requested.
        let latch = ReviewTestLatch()
        let blockerRunning = ReviewTestFlag()
        let blocker = Task { await harness.syncManager.enqueueFileOperation { @Sendable in
            blockerRunning.set()
            await latch.wait()
        } }
        await waitUntil("the blocking operation holds the queue") { blockerRunning.isSet }

        harness.coordinator.trashRightCopy(review)
        // The pre-trash verdict passes (nothing has drifted yet); the delete parks in the queue.
        await waitUntil("the review's delete is queued behind the blocker") {
            harness.syncManager.activeFileOperationsCount == 2
        }
        // The right copy gains a file IN the queue-wait window — after the pre-trash verdict.
        try Data("the only copy of this".utf8).write(to: copy.appendingPathComponent("landed-late.txt"))
        await latch.open()
        await waitUntil("the drift refusal surfaces") {
            harness.syncManager.banner?.severity == .warning
        }
        _ = await blocker.value

        #expect(FileManager.default.fileExists(atPath: copy.path),
                "a folder that gained content during the queue wait was trashed on a verdict from before the gain")
        #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("landed-late.txt").path))
        #expect(harness.syncManager.banner?.message.contains("changed since the scan") == true)
        #expect(harness.duplicateReview == review, "the review stays up so the user can rescan")
        #expect(harness.workspace == .compare, "a refusal must not navigate")
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
