import Testing
import Foundation
@testable import SyncCloud

/// **"Trash right copy" checks the copy it destroys.**
///
/// The context carried `keepPath`, `keepIsDirectory`, `keepScannedSize` — and nothing about the
/// delete candidate beyond its path, so the check the comment claimed ("mirrors the FULL gate the
/// other duplicate-removal paths honor") was structurally impossible on the half that matters. The
/// engine calls the removal candidate the dangerous half and has always checked it: the keeper is
/// the file being kept, the candidate is the file being destroyed.
///
/// A Compare review is designed to stay open. While it is, the provider re-downloads the right copy
/// or you edit it — and the button trashed the only instance of the new content, saying the left
/// copy is kept. The same action from the Duplicates card would have refused.
@Suite struct DuplicateCompareContextTests {

    /// The fields exist at all — a source-level guard would be weaker, but this is a value type, so
    /// constructing one is the honest check that the facts are carried.
    @Test func theContextCarriesBothCopiesScanFacts() {
        let scanned = Date(timeIntervalSince1970: 1_700_000_000)
        let ctx = DuplicateCompareContext(
            groupName: "report.pdf", keepPath: "/a/report.pdf", deletePath: "/b/report.pdf",
            keepIsDirectory: false, keepScannedSize: 100, keepScannedDate: scanned,
            deleteIsDirectory: false, deleteScannedSize: 100, deleteScannedDate: scanned,
            keeperRelativePath: "a/report.pdf", redundantRelativePath: "b/report.pdf",
            restore: SavedCompareState(leftProviderId: "l", rightProviderId: "r",
                                       leftRelativePath: "", rightRelativePath: ""))
        #expect(ctx.deleteScannedSize == 100)
        #expect(ctx.deleteScannedDate == scanned)
        #expect(ctx.deleteIsDirectory == false)
    }

    /// **The scenario, as the gate answers it.** The right copy is re-downloaded during the review:
    /// same path, new bytes. The keeper is untouched, so a keeper-only check passes and the trash
    /// runs — which is the defect. Asked of the candidate, the same gate refuses.
    @Test func aRightCopyRewrittenDuringTheReviewIsRefused() {
        let scanned = Date(timeIntervalSince1970: 1_700_000_000)
        // The keeper: unchanged, and a keeper-only gate is therefore satisfied.
        #expect(PaneLogic.duplicateCopyMatchesScan(
            exists: true, isDirectory: false, statSucceeded: true,
            currentSize: 4_096, scannedSize: 4_096,
            currentDate: scanned, scannedDate: scanned))
        // The candidate: re-downloaded, so its bytes are new. This is the check that did not exist.
        #expect(!PaneLogic.duplicateCopyMatchesScan(
            exists: true, isDirectory: false, statSucceeded: true,
            currentSize: 5_120, scannedSize: 4_096,
            currentDate: Date(timeIntervalSince1970: 1_700_009_999), scannedDate: scanned))
    }
}
