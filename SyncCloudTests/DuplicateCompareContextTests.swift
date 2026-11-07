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
