import Testing
import Foundation
import Sync
@testable import SyncCloud

/// "Trash Right Copy" checks the copy it destroys: the context carries the delete candidate's scan
/// facts, not just its path, because during an open review the right copy can be re-downloaded or
/// edited, and trashing it then would destroy the only instance of the new content.
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
