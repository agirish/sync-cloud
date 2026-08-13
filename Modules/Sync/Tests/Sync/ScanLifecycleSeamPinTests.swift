import Foundation
import Testing
@testable import Sync

/// Pins for the ScanLifecycle seam, as it stands after the shim-reduction / status-vocabulary
/// unification. (The file was added with that migration, so nothing here can claim to have run
/// against the pre-change code — what it does claim is that the state machine below is the one
/// all six lenses share, and that it answers idle the same way for every one of them.)
///
/// Three sections:
/// - "State machine" pins exercise each of the six lifecycles through the manager's
///   `beginScan` / `updateScan` / `endScan` / `completeScan` helpers. They read only the
///   lifecycle objects, so they are independent of which forwarders survive.
/// - "Idle spelling" pins record that an idle status is nil for every lens, and that an empty
///   or whitespace-only status normalizes to that same nil however it is written — the
///   invariant every reader's `status ?? "Analyzing…"` fallback now rests on.
/// - "Surviving forwarders" pins record that the legacy per-lens names still stand exactly in
///   front of their own lifecycle's fields, through the whole scan cycle.
///
/// Every mid-scan status string here is distinct from the UI fallbacks ("Analyzing…",
/// "Previewing…") and from the idle spellings ("" / nil), so no assertion can pass by
/// hitting a fallback instead of the pinned value.
@Suite struct ScanLifecycleSeamPinTests {

    /// The six lifecycles, by name, so failures name the lens.
    @MainActor
    private static let lenses: [(name: String, path: ReferenceWritableKeyPath<FileSyncManager, ScanLifecycle>)] = [
        ("duplicates", \.duplicateScanLifecycle),
        ("storage", \.storageLensLifecycle),
        ("names", \.nameScanLifecycle),
        ("filing", \.filingScanLifecycle),
        ("filingSurvey", \.filingSurveyLifecycle),
        ("automationDryRun", \.automationDryRunLifecycle),
    ]

    // MARK: State machine (migration-invariant)

    @MainActor
    @Test func idleReadingIsIdenticalAcrossAllSixLenses() {
        let manager = FileSyncManager()
        for lens in Self.lenses {
            let lifecycle = manager[keyPath: lens.path]
            #expect(lifecycle.isRunning == false, "\(lens.name): idle isRunning")
            #expect(lifecycle.status == nil, "\(lens.name): idle status is nil at the lifecycle")
            #expect(lifecycle.hasCompleted == false, "\(lens.name): idle hasCompleted")
            #expect(lifecycle.root == nil, "\(lens.name): idle root")
            #expect(lifecycle.completedAt == nil, "\(lens.name): idle completedAt")
            #expect(lifecycle.isRestored == false, "\(lens.name): idle isRestored")
        }
    }

    @MainActor
    @Test func midScanReadingPublishesRunningFlagAndStatus() {
        let manager = FileSyncManager()
        for lens in Self.lenses {
            let epoch = manager.beginScan(lens.path, status: "PIN mid-scan \(lens.name)")
            #expect(manager[keyPath: lens.path].isRunning, "\(lens.name): running after beginScan")
            #expect(manager[keyPath: lens.path].status == "PIN mid-scan \(lens.name)",
                    "\(lens.name): beginScan status shows through")
            // A current-epoch update publishes and reports so.
            #expect(manager.updateScan(lens.path, epoch: epoch, status: "PIN update \(lens.name)"),
                    "\(lens.name): current-epoch update accepted")
            #expect(manager[keyPath: lens.path].status == "PIN update \(lens.name)",
                    "\(lens.name): updated status shows through")
            // Mid-scan, completion labels are untouched.
            #expect(manager[keyPath: lens.path].hasCompleted == false, "\(lens.name): mid-scan hasCompleted")
        }
    }

    @MainActor
    @Test func endScanClearsRunningStateAndStatusForEveryLens() {
        let manager = FileSyncManager()
        for lens in Self.lenses {
            manager.beginScan(lens.path, status: "PIN \(lens.name)")
            manager.endScan(lens.path)
            #expect(manager[keyPath: lens.path].isRunning == false, "\(lens.name): endScan clears running")
            #expect(manager[keyPath: lens.path].status == nil, "\(lens.name): endScan clears status to nil")
        }
    }

    @MainActor
    @Test func completedReadingCarriesRootAndTimestampNotRestored() {
        let manager = FileSyncManager()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        for (index, lens) in Self.lenses.enumerated() {
            let root = URL(fileURLWithPath: "/pin/\(lens.name)")
            manager.beginScan(lens.path, status: "PIN \(lens.name)")
            manager.completeScan(lens.path, root: root, at: stamp.addingTimeInterval(Double(index)))
            manager.endScan(lens.path)
            let lifecycle = manager[keyPath: lens.path]
            #expect(lifecycle.hasCompleted, "\(lens.name): completed flag set")
            #expect(lifecycle.root == root, "\(lens.name): root labels the results")
            #expect(lifecycle.completedAt == stamp.addingTimeInterval(Double(index)),
                    "\(lens.name): completedAt is the scan's own stamp")
            #expect(lifecycle.isRestored == false, "\(lens.name): a fresh scan is not restored")
        }
    }

    @MainActor
    @Test func restoredReadingKeepsTheOriginalStampAndSetsRestored() {
        let manager = FileSyncManager()
        let original = Date(timeIntervalSince1970: 1_600_000_000)
        for lens in Self.lenses {
            let root = URL(fileURLWithPath: "/pin/restored/\(lens.name)")
            manager.restoreScan(lens.path, root: root, completedAt: original)
            let lifecycle = manager[keyPath: lens.path]
            #expect(lifecycle.hasCompleted, "\(lens.name): restore counts as completed")
            #expect(lifecycle.root == root, "\(lens.name): restored root")
            #expect(lifecycle.completedAt == original, "\(lens.name): restore keeps the ORIGINAL stamp")
            #expect(lifecycle.isRestored, "\(lens.name): restored flag set")
        }
    }

    /// The epoch/staleness guard: an update presenting a superseded epoch must drop itself —
    /// after endScan (epoch bumped) and after a new beginScan (superseded scan).
    @MainActor
    @Test func staleEpochUpdatesDropThemselvesForEveryLens() {
        let manager = FileSyncManager()
        for lens in Self.lenses {
            // Stale after endScan: the ended scan's queued hop must not republish.
            let first = manager.beginScan(lens.path, status: "PIN live \(lens.name)")
            manager.endScan(lens.path)
            #expect(manager.updateScan(lens.path, epoch: first, status: "PIN stale \(lens.name)") == false,
                    "\(lens.name): update after endScan dropped")
            #expect(manager[keyPath: lens.path].status == nil,
                    "\(lens.name): dropped update must not write status")

            // Stale after supersedence: the old scan's hop must not scribble on the new scan.
            let second = manager.beginScan(lens.path, status: "PIN second \(lens.name)")
            #expect(manager.updateScan(lens.path, epoch: first, status: "PIN stale \(lens.name)") == false,
                    "\(lens.name): superseded update dropped")
            #expect(manager[keyPath: lens.path].status == "PIN second \(lens.name)",
                    "\(lens.name): the live scan's status survives the stale hop")
            #expect(manager.updateScan(lens.path, epoch: second, status: "PIN third \(lens.name)"),
                    "\(lens.name): the live epoch still publishes")
            manager.endScan(lens.path)
        }
    }

    // MARK: Idle spelling — nil, and nothing else, however it is written

    /// **An empty status can never reach a reader.** Every lens's spinner line now spells its
    /// fallback `status ?? "Analyzing…"`, where before the migration it asked `isEmpty` too — so
    /// a writer passing `""` would paint a blank line under a live spinner instead of the
    /// fallback. `ScanLifecycle.status` normalizes empty-or-whitespace to nil on write, at the
    /// one boundary all three write paths go through, which is what makes that unbuildable
    /// rather than merely unbuilt.
    ///
    /// Exercised at `beginScan` and `updateScan` here, and by direct assignment below — the
    /// third path, open to every file in the module because the setter is `internal(set)`.
    @MainActor
    @Test func anEmptyOrBlankStatusNormalizesToNilAtEveryWritePath() {
        let manager = FileSyncManager()
        for lens in Self.lenses {
            for blank in ["", " ", "\n", " \t "] {
                let epoch = manager.beginScan(lens.path, status: blank)
                #expect(manager[keyPath: lens.path].status == nil,
                        "\(lens.name): beginScan(\(blank.debugDescription)) must read back as idle-nil")
                #expect(manager[keyPath: lens.path].isRunning,
                        "\(lens.name): a blank status still starts the scan")
                // A real status, then a blank one over the top of it: the blank must not survive
                // as "" — the reader would show an empty line rather than its fallback.
                #expect(manager.updateScan(lens.path, epoch: epoch, status: "PIN real \(lens.name)"))
                #expect(manager[keyPath: lens.path].status == "PIN real \(lens.name)",
                        "\(lens.name): a real status is still published verbatim")
                #expect(manager.updateScan(lens.path, epoch: epoch, status: blank))
                #expect(manager[keyPath: lens.path].status == nil,
                        "\(lens.name): updateScan(\(blank.debugDescription)) must read back as idle-nil")
                manager.endScan(lens.path)
            }
        }
    }

    /// Direct assignment is normalized too — the path `FileSyncManager+Filing`'s "Try another"
    /// re-ask uses, and the one no helper can guard. And a status that merely *contains*
    /// whitespace is stored VERBATIM: normalizing means collapsing the blank cases to nil, not
    /// trimming what the lens chose to say.
    @MainActor
    @Test func aDirectStatusAssignmentIsNormalizedButNeverTrimmed() {
        let manager = FileSyncManager()
        manager.filingScanLifecycle.status = " Looking for a different folder… "
        #expect(manager.filingScanLifecycle.status == " Looking for a different folder… ",
                "a non-blank status keeps its own spacing")
        manager.filingScanLifecycle.status = "   "
        #expect(manager.filingScanLifecycle.status == nil, "whitespace-only assigns as idle-nil")
        manager.filingScanLifecycle.status = "PIN direct"
        #expect(manager.filingScanLifecycle.status == "PIN direct")
        manager.filingScanLifecycle.status = ""
        #expect(manager.filingScanLifecycle.status == nil, "empty assigns as idle-nil")
    }

    // MARK: Surviving forwarders

    /// The kept running/has-completed forwarders follow their OWN lifecycle across the whole
    /// cycle, including back to idle — which the mid-scan snapshot below never observes.
    ///
    /// This is what replaced two pins that asked the lifecycle for its status twice in one
    /// expectation: before the migration those read the deleted `?? ""` shims and so compared two
    /// different expressions, but with the shims gone both sides were the same stored property
    /// and neither could fail on its own. The forwarders that DID survive are the seam still
    /// worth pinning.
    @MainActor
    @Test func keptForwardersFollowTheirOwnLifecycleBackToIdle() {
        let manager = FileSyncManager()

        #expect(!manager.isFindingDuplicates && !manager.isBuildingStorageLens
                && !manager.isScanningNames && !manager.isSuggestingFiles,
                "every running forwarder starts idle")

        manager.beginScan(\.duplicateScanLifecycle, status: "PIN dup")
        #expect(manager.isFindingDuplicates == manager.duplicateScanLifecycle.isRunning)
        #expect(manager.isFindingDuplicates, "duplicates: forwarder follows the scan start")
        #expect(!manager.isScanningNames, "one lens's scan does not move another's forwarder")
        manager.endScan(\.duplicateScanLifecycle)
        #expect(manager.isFindingDuplicates == manager.duplicateScanLifecycle.isRunning)
        #expect(!manager.isFindingDuplicates, "duplicates: forwarder follows the scan end")

        manager.beginScan(\.storageLensLifecycle, status: "PIN storage")
        #expect(manager.isBuildingStorageLens, "storage: forwarder follows the scan start")
        manager.endScan(\.storageLensLifecycle)
        #expect(!manager.isBuildingStorageLens, "storage: forwarder follows the scan end")

        manager.beginScan(\.nameScanLifecycle, status: "PIN names")
        #expect(manager.isScanningNames, "names: forwarder follows the scan start")
        manager.endScan(\.nameScanLifecycle)
        #expect(!manager.isScanningNames, "names: forwarder follows the scan end")

        manager.beginScan(\.filingScanLifecycle, status: "PIN filing")
        #expect(manager.isSuggestingFiles, "filing: forwarder follows the scan start")
        manager.endScan(\.filingScanLifecycle)
        #expect(!manager.isSuggestingFiles, "filing: forwarder follows the scan end")

        // The has-completed forwarders are set by completion, not by the scan ending: all four
        // scans above ran and ended, and none of them completed.
        #expect(!manager.hasFoundDuplicates && !manager.hasScannedNames
                && !manager.hasSuggestedFiling,
                "ending a scan without completing it leaves the has-completed forwarders false")
        manager.completeScan(\.nameScanLifecycle, root: URL(fileURLWithPath: "/pin/names"))
        #expect(manager.hasScannedNames, "names: completion shows through the forwarder")
        #expect(!manager.hasFoundDuplicates && !manager.hasSuggestedFiling,
                "and shows through that lens's forwarder ONLY")
    }

    /// The surviving legacy forwarders still read and write their lifecycle's fields exactly.
    @MainActor
    @Test func survivingForwardersMirrorTheirLifecycleFields() {
        let manager = FileSyncManager()

        manager.beginScan(\.duplicateScanLifecycle, status: "PIN dup")
        #expect(manager.isFindingDuplicates)
        manager.completeScan(\.duplicateScanLifecycle, root: URL(fileURLWithPath: "/pin/dup"))
        #expect(manager.hasFoundDuplicates)
        #expect(manager.duplicateScanRoot == "/pin/dup")
        manager.duplicateScanRoot = "/pin/dup2"
        #expect(manager.duplicateScanLifecycle.root == URL(fileURLWithPath: "/pin/dup2"))

        manager.beginScan(\.storageLensLifecycle, status: "PIN storage")
        #expect(manager.isBuildingStorageLens)
        manager.completeScan(\.storageLensLifecycle, root: URL(fileURLWithPath: "/pin/storage"))
        #expect(manager.storageLensRoot == URL(fileURLWithPath: "/pin/storage"))

        manager.beginScan(\.nameScanLifecycle, status: "PIN names")
        #expect(manager.isScanningNames)
        manager.completeScan(\.nameScanLifecycle, root: URL(fileURLWithPath: "/pin/names"))
        #expect(manager.hasScannedNames)
        #expect(manager.nameScanRoot == URL(fileURLWithPath: "/pin/names"))

        manager.beginScan(\.filingScanLifecycle, status: "PIN filing")
        #expect(manager.isSuggestingFiles)
        manager.completeScan(\.filingScanLifecycle, root: URL(fileURLWithPath: "/pin/filing"))
        #expect(manager.hasSuggestedFiling)
        #expect(manager.filingScanFolder == "/pin/filing")
        manager.filingScanFolder = "/pin/filing2"
        #expect(manager.filingScanLifecycle.root == URL(fileURLWithPath: "/pin/filing2"))
    }
}
