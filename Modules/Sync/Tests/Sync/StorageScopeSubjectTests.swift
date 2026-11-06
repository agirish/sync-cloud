import Testing
import Foundation
@testable import Sync

/// Storage's scope is a re-analysis, not a filter, and this predicate enforces it. Other Organize
/// lenses narrow rows they already hold; a treemap can't be narrowed without misstating every
/// proportion (which is why search can't subset it either). So a scope change needs a report about
/// the new root, and until then the one in hand is about somewhere else. `restoreStorageLens`
/// refuses while a report is in hand (that keeps pane moves from re-reading the store), so without
/// this check a scope change would relabel the header over the previous root's treemap.
@Suite struct StorageScopeSubjectTests {

    private let root = "/Users/x/Documents"

    private func scope(_ relative: String) -> OrganizeScope {
        OrganizeScope(path: "\(root)/\(relative)", providerRoot: root)!
    }

    @Test func aReportForAnotherRootCannotStandUnderAScope() {
        // A report for another root doesn't stand under the scope.
        #expect(!OrganizeAim.storageReportStandsUnder(scope: scope("Legal"),
                                                      reportRoot: "\(root)/Finance"))
        // …including the pane root itself, the commonest case: analyze the whole tree, then scope
        // to a subfolder.
        #expect(!OrganizeAim.storageReportStandsUnder(scope: scope("Legal"), reportRoot: root))
    }

    @Test func aReportForTheScopeRootStands() {
        #expect(OrganizeAim.storageReportStandsUnder(scope: scope("Legal"),
                                                     reportRoot: "\(root)/Legal"))
    }

    /// Compared through the same standardization the rest of this type uses. A raw `!=` would call
    /// these different roots and clear a correct report, and the cure is re-walking the tree. The
    /// scope is stored normalized; `storageLensRoot` is whatever `URL` the analysis was handed.
    @Test func spellingsOfOneRootAreOneRoot() {
        let s = scope("Legal")
        for spelling in ["\(root)/Legal", "\(root)/Legal/", "\(root)//Legal",
                         "\(root)/./Legal", "\(root)/Finance/../Legal"] {
            #expect(OrganizeAim.storageReportStandsUnder(scope: s, reportRoot: spelling),
                    "\(spelling) was read as a different root from the scope, so a correct report would be thrown away and the tree walked again")
        }
    }

    /// No scope means the pane's own rules. Wandering is not re-declaring: the report persists while
    /// you browse, the header chip names the root it describes, and `paneMovedAway` offers to
    /// re-aim. Answering `false` here would make a pane click throw away a report.
    @Test func withNoScopeTheReportAlwaysStands() {
        #expect(OrganizeAim.storageReportStandsUnder(scope: nil, reportRoot: "\(root)/Finance"))
        #expect(OrganizeAim.storageReportStandsUnder(scope: nil, reportRoot: root))
    }

    /// Nothing on screen cannot contradict anything, and must not provoke a pointless clear.
    @Test func noReportStandsVacuously() {
        #expect(OrganizeAim.storageReportStandsUnder(scope: scope("Legal"), reportRoot: nil))
        #expect(OrganizeAim.storageReportStandsUnder(scope: scope("Legal"), reportRoot: ""))
        #expect(OrganizeAim.storageReportStandsUnder(scope: nil, reportRoot: nil))
    }

    /// The clear-then-restore sequence this predicate gates, end to end on a real store. Asserted on
    /// the manager because the claim is that a scoped root gets its own report back and that the two
    /// coexist; `StorageLensStore` keys by absolute path, which makes that work.
    @MainActor
    @Test func clearingLetsTheScopedRootRestoreItsOwnReport() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("storage-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appendingPathComponent("storage-lens.json")

        func entry(_ n: String, _ b: Int) -> StorageEntry {
            StorageEntry(path: "/root/\(n)", name: n, bytes: b, modified: Date(timeIntervalSince1970: 0))
        }
        func report(_ total: Int) -> StorageLensReport {
            StorageLensReport(treemap: [], largest: [entry("a", total)], stale: [],
                              reclaimCandidates: [], totalBytes: total, fileCount: 1,
                              staleCount: 0, reclaimCount: 0, reclaimableBytes: 0)
        }

        let wide = URL(fileURLWithPath: root)
        let narrow = URL(fileURLWithPath: "\(root)/Legal")
        StorageLensStore.saveInBackground(
            StorageLensSnapshot(root: wide.path, report: report(900), completedAt: Date()), to: store)
        StorageLensStore.saveInBackground(
            StorageLensSnapshot(root: narrow.path, report: report(100), completedAt: Date()), to: store)
        StorageLensStore.waitForPendingWrites()

        let m = FileSyncManager()
        m._storageLensStoreURL = store

        #expect(m.restoreStorageLens(root: wide))
        #expect(m.storageLensReport?.totalBytes == 900)

        // With a report in hand, restoring the narrower root is refused outright.
        #expect(m.restoreStorageLens(root: narrow) == false)
        #expect(m.storageLensReport?.totalBytes == 900, "the wide report survived a restore of the narrow root — which is the stale-under-scope state")

        // So clear first, as `restoreStorageLensIfShowing` does.
        m.clearStorageLens()
        #expect(m.restoreStorageLens(root: narrow))
        #expect(m.storageLensReport?.totalBytes == 100)
        #expect(m.storageLensRoot?.path == narrow.path)

        // And clearing didn't destroy the wide root's snapshot, so going back is instant.
        m.clearStorageLens()
        #expect(m.restoreStorageLens(root: wide))
        #expect(m.storageLensReport?.totalBytes == 900)
    }
}
