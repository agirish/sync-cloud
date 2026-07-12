import Testing
@testable import Sync

/// The Filing scan publishes suggestions only once, at the very end, so the scanning view must make
/// clear the later phases are still refining. These pin the status strings that carry that signal.
@Suite struct FilingScanPhaseTests {
    private typealias Phase = FileSyncManager.FilingScanPhase

    @Test func earlyPassesAreLabeledPhase1() {
        #expect(Phase.scanningFolder("Downloads").status == "Phase 1 · scanning Downloads…")
        #expect(Phase.learningFolders.status.hasPrefix("Phase 1 · "))
    }

    @Test func laterPassesReassureSuggestionsStillImproving() {
        let two = Phase.readingContent(3).status
        #expect(two.contains("Phase 2"))
        #expect(two.contains("still improving"))

        let three = Phase.findingHomes.status
        #expect(three.contains("Phase 3"))
        #expect(three.contains("still improving"))
    }

    @Test func documentCountPluralizes() {
        #expect(Phase.readingContent(1).status.contains("1 document —"))
        #expect(Phase.readingContent(2).status.contains("2 documents —"))
    }

    @Test func tryAnotherIsNotAPhaseInTheSequence() {
        // The single-file re-ask shouldn't claim a phase number.
        #expect(!Phase.lookingForDifferent.status.contains("Phase"))
    }
}
