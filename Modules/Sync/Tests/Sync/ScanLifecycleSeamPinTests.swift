import Foundation
import Testing
@testable import Sync

/// Characterization pins for the ScanLifecycle seam, written BEFORE the shim-reduction /
/// status-vocabulary unification and run green against the pre-change code.
///
/// Two sections:
/// - "State machine" pins exercise each of the six lifecycles through the manager's
///   `beginScan` / `updateScan` / `endScan` / `completeScan` helpers. They read only the
///   lifecycle objects, so they must pass unchanged before and after the migration.
/// - "Seam spelling" pins record what each lens's status answers when idle at the public
///   seam. Before the migration three lenses spelled idle as `""` (through a `?? ""`
///   forwarder) and three as `nil`; the migration unifies all six on `nil` (the lifecycle's
///   own spelling) and these pins were updated in the same commit, deliberately.
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

    // MARK: Seam spellings (updated deliberately with the migration)

    /// One spelling answers "idle" at the public seam for every lens: the lifecycle's own
    /// `status == nil`. Before the migration, three lenses (Storage, Names, Automations
    /// preview) spelled idle as `""` through `?? ""` forwarders and three as `nil`; the
    /// forwarders are gone and this pin was updated to the unified spelling in the same
    /// commit, deliberately. The pre-migration version of this test (asserting
    /// `storageLensStatus == ""` etc.) ran green against the pre-change code first.
    @MainActor
    @Test func idleStatusSpellsNilAtThePublicSeamForEveryLens() {
        let manager = FileSyncManager()
        for lens in Self.lenses {
            #expect(manager[keyPath: lens.path].status == nil, "\(lens.name): idle spells nil")
        }
    }

    /// A mid-scan status shows through the unified seam identically for every lens (distinct
    /// from the UI fallbacks, so this cannot pass via a fallback).
    @MainActor
    @Test func midScanStatusShowsThroughTheUnifiedSeam() {
        let manager = FileSyncManager()
        for lens in Self.lenses {
            manager.beginScan(lens.path, status: "PIN \(lens.name) status")
            #expect(manager[keyPath: lens.path].status == "PIN \(lens.name) status",
                    "\(lens.name): mid-scan status shows through the unified seam")
        }
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
