import Testing
import Foundation
@testable import Sync

/// **Storage's scope is a re-analysis, not a filter — and this is the predicate that enforces it.**
///
/// Every other Organize lens narrows rows it already holds, so a scope change costs nothing and the
/// rows on screen stay true. A treemap cannot be narrowed: subsetting one misstates every
/// proportion in it, which is why Storage refuses to let *search* subset it either. So a scope
/// change has to produce a report about the new root, and until it does, the one in hand is about
/// somewhere else.
///
/// **The bug this was written against had shipped.** `restoreStorageLens` refuses while a report is
/// in hand — that guard is what stops the trigger trio re-reading the store on every pane move — so
/// changing the scope updated the header and left the previous root's treemap underneath it. The
/// screen said "Legal" in the chip and "Documents" in the scanned-folder chip, over Documents'
/// numbers. Nothing crashed and no test failed, because the only assertion anywhere was that the
/// restore is *attempted*.
@Suite struct StorageScopeSubjectTests {

    private let root = "/Users/x/Documents"

    private func scope(_ relative: String) -> OrganizeScope {
        OrganizeScope(path: "\(root)/\(relative)", providerRoot: root)!
    }

    @Test func aReportForAnotherRootCannotStandUnderAScope() {
        // The shipped failure, stated directly.
        #expect(!OrganizeAim.storageReportStandsUnder(scope: scope("Legal"),
                                                      reportRoot: "\(root)/Finance"))
        // …including the pane root itself, which is the commonest case: analyze the whole tree,
        // then scope to a subfolder.
        #expect(!OrganizeAim.storageReportStandsUnder(scope: scope("Legal"), reportRoot: root))
    }

    @Test func aReportForTheScopeRootStands() {
        #expect(OrganizeAim.storageReportStandsUnder(scope: scope("Legal"),
                                                     reportRoot: "\(root)/Legal"))
    }

    /// **Compared through the same standardization the rest of this type uses.**
    ///
    /// A raw `!=` would call these different roots and clear a report that was already correct —
    /// which is worse than the bug it fixes, because the cure is re-walking the tree. The scope is
    /// stored normalized while `storageLensRoot` is whatever `URL` the analysis was handed.
    @Test func spellingsOfOneRootAreOneRoot() {
        let s = scope("Legal")
        for spelling in ["\(root)/Legal", "\(root)/Legal/", "\(root)//Legal",
                         "\(root)/./Legal", "\(root)/Finance/../Legal"] {
            #expect(OrganizeAim.storageReportStandsUnder(scope: s, reportRoot: spelling),
                    "\(spelling) was read as a different root from the scope, so a correct report would be thrown away and the tree walked again")
        }
    }

    /// **No scope means the pane's own rules, which are the ones Storage has always had.**
    ///
    /// Wandering is not re-declaring. The report persists while you browse, the header chip names
    /// the root it describes, and `paneMovedAway` offers to re-aim. Answering `false` here would
    /// have made a pane click throw away a report the user never asked to lose — a regression
    /// dressed as a fix.
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

    /// The clear-then-restore composition this predicate gates, end to end on a real store.
    ///
    /// Asserted on the manager rather than only on the predicate, because the predicate being right
    /// is not the claim — the claim is that a scoped root gets *its own* report back, and that the
    /// two coexist rather than clobber. `StorageLensStore` keys by absolute path, which is what
    /// makes that free; this is what proves it.
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
                              reclaimCandidates: [], totalBytes: total)
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

        // The bug: with a report in hand, restoring the narrower root is refused outright.
        #expect(m.restoreStorageLens(root: narrow) == false)
        #expect(m.storageLensReport?.totalBytes == 900, "the wide report survived a restore of the narrow root — which is the stale-under-scope state")

        // The fix: clear first, exactly as `restoreStorageLensIfShowing` now does.
        m.clearStorageLens()
        #expect(m.restoreStorageLens(root: narrow))
        #expect(m.storageLensReport?.totalBytes == 100)
        #expect(m.storageLensRoot?.path == narrow.path)

        // And the wide root's snapshot was NOT destroyed by clearing — going back is instant.
        m.clearStorageLens()
        #expect(m.restoreStorageLens(root: wide))
        #expect(m.storageLensReport?.totalBytes == 900)
    }
}
