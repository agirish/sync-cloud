@testable import SyncCloud
import Sync
import Testing

/// **What the large-folder prompt actually says**, asserted on the pure text builders rather than
/// by running the alert — an `NSAlert` in a test suite is a hang, not a test.
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

    /// **"More than", never a total.** The probe stopped, so it genuinely does not know how much of
    /// the tree it did not see. A figure here would be a number the app invented — and it would be
    /// wrong in the direction that matters, since the reader is deciding whether to wait.
    @Test func theCountIsALowerBoundAndNeverTheProbesOwnTally() {
        let p = preflight(.storageLens)
        let text = SyncOperationAlerts.largeWalkInformativeText(p)
        #expect(text.contains("more than"), "the prompt states a total for a tree nobody finished reading")
        #expect(!text.contains("400,312"), "the prompt reports what the PROBE read as if it were the folder's size")
        #expect(text.contains("400,000"), "the prompt names no figure at all")
    }

    /// A pass that reads file CONTENT past the walk costs more, and its prompt says so — asked of
    /// `readsFileContents` rather than of one named case, which is what let Filing quietly inherit
    /// the cheaper sentence when it was added.
    @Test func onlyThePassesThatReadContentsSayTheyDo() {
        for pass in LargeWalkPreflight.Pass.allCases {
            let text = SyncOperationAlerts.largeWalkInformativeText(preflight(pass))
            #expect(text.contains("contents") == pass.readsFileContents,
                    "\(pass) says the wrong thing about reading file contents: “\(text)”")
            #expect(text.contains(pass.title), "the prompt does not name the pass: “\(text)”")
        }
    }

    /// Each pass's prompt is distinguishable from the others' — a prompt that described them
    /// identically would understate whichever one costs more.
    @Test func thePassesDoNotAllSayTheSameThing() {
        let texts = LargeWalkPreflight.Pass.allCases.map {
            SyncOperationAlerts.largeWalkInformativeText(preflight($0))
        }
        #expect(Set(texts).count == texts.count, "two passes share a prompt")
    }

    /// Both prompts say the pass can be stopped, because it can — every one of these has a cancel,
    /// and "several minutes" without that sentence reads as a commitment.
    @Test func bothPromptsSayItCanBeCancelled() {
        for pass in [LargeWalkPreflight.Pass.storageLens, .duplicates] {
            #expect(SyncOperationAlerts.largeWalkInformativeText(preflight(pass)).contains("cancel"),
                    "\(pass) prompt does not say the pass can be cancelled")
        }
    }
}
