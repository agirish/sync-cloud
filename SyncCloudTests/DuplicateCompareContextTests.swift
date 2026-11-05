import Testing
import Foundation
import Sync
@testable import SyncCloud

/// "Trash Right Copy" checks the copy it destroys.
///
/// The context carries the delete candidate's scan facts, not just its path, so the trash gate can
/// check the dangerous half: the keeper is the file being kept, the candidate the one destroyed. A
/// Compare review stays open, and meanwhile the provider can re-download the right copy or you can
/// edit it. Unchecked, the button would trash the only instance of the new content; the same
/// action from the Duplicates card refuses.
@Suite struct DuplicateCompareContextTests {

    /// The fields exist. This is a value type, so constructing one is a stronger check that the
    /// facts are carried than a source scan.
    @Test func theContextCarriesBothCopiesScanFacts() {
        let scanned = Date(timeIntervalSince1970: 1_700_000_000)
        let ctx = DuplicateCompareContext(
            groupName: "report.pdf", keepPath: "/a/report.pdf", deletePath: "/b/report.pdf",
            keepIsDirectory: false, keepScannedSize: 100, keepScannedDate: scanned,
            deleteIsDirectory: false, deleteScannedSize: 100, deleteScannedDate: scanned,
            keepContentSnapshot: nil, deleteContentSnapshot: nil,
            keeperRelativePath: "a/report.pdf", redundantRelativePath: "b/report.pdf",
            restore: SavedCompareState(leftProviderId: "l", rightProviderId: "r",
                                       leftRelativePath: "", rightRelativePath: ""))
        #expect(ctx.deleteScannedSize == 100)
        #expect(ctx.deleteScannedDate == scanned)
        #expect(ctx.deleteIsDirectory == false)
    }

    /// The folder facts exist too: a directory review carries the scan's per-entry baseline for
    /// each copy, because stat facts can't answer for a directory. The trash gate's directory
    /// verdict is computed against it.
    @Test func theContextCarriesBothFolderBaselines() {
        let baseline = FolderContentSnapshot(
            entries: ["a.txt": .file(size: 100, modificationDate: nil)],
            ignoredNames: DuplicateFinderOptions.defaultIgnoredNames)
        let ctx = DuplicateCompareContext(
            groupName: "Docs", keepPath: "/a/Docs", deletePath: "/b/Docs",
            keepIsDirectory: true, keepScannedSize: 100, keepScannedDate: nil,
            deleteIsDirectory: true, deleteScannedSize: 100, deleteScannedDate: nil,
            keepContentSnapshot: baseline, deleteContentSnapshot: baseline,
            keeperRelativePath: "a/Docs", redundantRelativePath: "b/Docs",
            restore: SavedCompareState(leftProviderId: "l", rightProviderId: "r",
                                       leftRelativePath: "", rightRelativePath: ""))
        #expect(ctx.keepContentSnapshot == baseline)
        #expect(ctx.deleteContentSnapshot == baseline)
    }

    /// The scenario, as the gate answers it. The right copy is re-downloaded during the review:
    /// same path, new bytes. The keeper is untouched, so a keeper-only check would pass and trash
    /// it. Asked of the candidate, the same gate refuses.
    @Test func aRightCopyRewrittenDuringTheReviewIsRefused() {
        let scanned = Date(timeIntervalSince1970: 1_700_000_000)
        // The keeper: unchanged, and a keeper-only gate is therefore satisfied.
        #expect(PaneLogic.duplicateCopyMatchesScan(
            exists: true, isDirectory: false, statSucceeded: true,
            currentSize: 4_096, scannedSize: 4_096,
            currentDate: scanned, scannedDate: scanned))
        // The candidate: re-downloaded, so its bytes are new, and the gate refuses.
        #expect(!PaneLogic.duplicateCopyMatchesScan(
            exists: true, isDirectory: false, statSucceeded: true,
            currentSize: 5_120, scannedSize: 4_096,
            currentDate: Date(timeIntervalSince1970: 1_700_009_999), scannedDate: scanned))
    }
}
