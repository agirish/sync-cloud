@testable import SyncCloud
import Sync
import Testing

/// What the large-folder prompt says, asserted on the pure text builders rather than by running
/// the alert: an `NSAlert` in a test suite is a hang, not a test.
@Suite struct LargeWalkAlertTests {
    private func preflight(_ pass: LargeWalkPreflight.Pass, root: String = "/Users/x/Stuff",
                           limit: Int = 400_000) -> LargeWalkPreflight {
        LargeWalkPreflight(pass: pass, rootPath: root, probeLimit: limit)
    }

    @Test func theMessageNamesTheFolderRatherThanThePath() {
        let text = SyncOperationAlerts.largeWalkMessage(preflight(.storageLens))
        #expect(text.contains("Stuff"))
        #expect(!text.contains("/Users/x"), "the prompt prints a whole path")
    }

    /// "More than", never a total: the probe stopped, so any figure would be invented, and too low
    /// for a reader deciding whether to wait.
    @Test func theCountIsALowerBoundAndNeverTheProbesOwnTally() {
        let p = preflight(.storageLens)
        let text = SyncOperationAlerts.largeWalkInformativeText(p)
        #expect(text.contains("more than"), "the prompt states a total for a tree nobody finished reading")
        #expect(text.contains("400,000"), "the prompt names no figure at all")
    }

    /// A pass that reads file content costs more, and its prompt says so. Asked of
    /// `readsFileContents`, so a new pass can't quietly inherit the cheaper sentence.
    @Test func onlyThePassesThatReadContentsSayTheyDo() {
        for pass in LargeWalkPreflight.Pass.allCases {
            let text = SyncOperationAlerts.largeWalkInformativeText(preflight(pass))
            #expect(text.contains("contents") == pass.readsFileContents,
                    "\(pass) says the wrong thing about reading file contents: “\(text)”")
            #expect(text.contains(pass.title), "the prompt does not name the pass: “\(text)”")
            // It can be cancelled, and "several minutes" without that reads as a commitment.
            #expect(text.contains("cancel"), "\(pass) prompt does not say the pass can be cancelled")
        }
    }
}
