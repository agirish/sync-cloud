import Foundation
import Testing
@testable import Sync

/// What a background survey stands aside for, and — the half that needs a test — **which reason it
/// names when several are true at once.**
///
/// Several usually are: a duplicate scan heats the Mac, and a Mac left alone puts its display to
/// sleep. The card shows one sentence, so the order is a decision, and a decision nothing asserts
/// is one the next edit reverses by accident.
@Suite struct DocumentSurveyYieldTests {

    @Test func nothingInTheWayMeansCarryOn() {
        #expect(DocumentSurveyYield.pause(for: .clear) == nil)
    }

    // MARK: - Each reason on its own

    @Test func aVerificationStandsTheSurveyDown() {
        let conditions = DocumentSurveyConditions(isVerifying: true)
        #expect(DocumentSurveyYield.pause(for: conditions) == .yielding(to: "a verification"))
    }

    @Test func fileOperationsAreCountedInTheSentence() {
        #expect(DocumentSurveyYield.pause(for: DocumentSurveyConditions(activeFileOperations: 1))
                == .yielding(to: "a file operation"))
        #expect(DocumentSurveyYield.pause(for: DocumentSurveyConditions(activeFileOperations: 12))
                == .yielding(to: "12 file operations"))
    }

    @Test func aRunningScanIsNamed() {
        let conditions = DocumentSurveyConditions(runningScans: ["Duplicates"])
        #expect(DocumentSurveyYield.pause(for: conditions) == .yielding(to: "Duplicates"))
    }

    @Test func theDisplayAsleepIsItsOwnReason() {
        #expect(DocumentSurveyYield.pause(for: DocumentSurveyConditions(displayAsleep: true))
                == .displayAsleep)
    }

    @Test func heatAndLowPowerStandItDown() {
        #expect(DocumentSurveyYield.pause(for: DocumentSurveyConditions(heat: .serious)) == .thermal)
        #expect(DocumentSurveyYield.pause(for: DocumentSurveyConditions(heat: .critical)) == .thermal)
        #expect(DocumentSurveyYield.pause(for: DocumentSurveyConditions(lowPowerMode: true)) == .lowPower)
    }

    /// `.nominal` covers `ProcessInfo`'s `.fair` too, and that mapping lives in the app. Here the
    /// point is only that nominal is not a reason to stop — a survey that paused at `.fair` would
    /// spend most of an afternoon paused with nothing wrong.
    @Test func nominalHeatIsNotAReasonToStop() {
        #expect(DocumentSurveyYield.pause(for: DocumentSurveyConditions(heat: .nominal)) == nil)
    }

    // MARK: - The order, which is the actual decision

    /// Work the person started outranks everything about the machine. Standing aside for *their*
    /// scan is the reassuring answer, and it is the only reason that explains why their own work is
    /// not slower than usual.
    @Test func workTheUserStartedOutranksTheMachine() {
        let everything = DocumentSurveyConditions(
            isVerifying: true, activeFileOperations: 3, runningScans: ["Duplicates"],
            displayAsleep: true, heat: .critical, lowPowerMode: true)
        #expect(DocumentSurveyYield.pause(for: everything) == .yielding(to: "a verification"))
    }

    @Test func fileOperationsOutrankAScan() {
        let conditions = DocumentSurveyConditions(activeFileOperations: 2,
                                                  runningScans: ["Duplicates"], heat: .critical)
        #expect(DocumentSurveyYield.pause(for: conditions) == .yielding(to: "2 file operations"))
    }

    /// **The display outranks heat and low power**, because it is the one that is not a choice: the
    /// survey has not decided to stop, it has been stopped — iCloud is no longer handing files
    /// over. Saying "paused, the Mac is hot" there would name a reason the survey could have worked
    /// around, over one it could not.
    @Test func aSleepingDisplayOutranksHeatAndLowPower() {
        let conditions = DocumentSurveyConditions(displayAsleep: true, heat: .critical,
                                                  lowPowerMode: true)
        #expect(DocumentSurveyYield.pause(for: conditions) == .displayAsleep)
    }

    @Test func heatOutranksLowPower() {
        let conditions = DocumentSurveyConditions(heat: .serious, lowPowerMode: true)
        #expect(DocumentSurveyYield.pause(for: conditions) == .thermal)
    }

    /// The scans are named in rail order by the caller, and the first is the one shown. Pinned so a
    /// caller that starts building the array from a dictionary — where the order is whatever the
    /// hash gives — fails here rather than shipping a card whose sentence changes between launches.
    @Test func theFirstNamedScanIsTheOneShown() {
        let conditions = DocumentSurveyConditions(runningScans: ["To File", "Duplicates", "Storage"])
        #expect(DocumentSurveyYield.pause(for: conditions) == .yielding(to: "To File"))
    }

    // MARK: - What the card says

    @Test func everyReasonHasASentence() {
        let reasons: [DocumentSurveyPause] = [.user, .displayAsleep, .thermal, .lowPower,
                                              .yielding(to: "Duplicates")]
        for reason in reasons {
            #expect(!reason.sentence.isEmpty)
            #expect(reason.sentence.hasSuffix("."), "“\(reason.sentence)” is not a sentence")
        }
    }

    /// Only the user's own Pause does not clear itself, and the card's verb turns on that: *Resumes
    /// on its own · Resume now* against a plain *Resume*.
    @Test func onlyTheUsersPauseDoesNotClearItself() {
        #expect(DocumentSurveyPause.user.resumesOnItsOwn == false)
        for reason: DocumentSurveyPause in [.displayAsleep, .thermal, .lowPower,
                                            .yielding(to: "Storage")] {
            #expect(reason.resumesOnItsOwn, "“\(reason.sentence)” claims it needs a click")
        }
    }

    /// The display's sentence must explain the stall rather than merely naming it — that is the
    /// whole reason the signal is observed at all, and a card that said only "Paused" would leave
    /// a frozen count looking like a hang.
    @Test func theDisplaySentenceExplainsTheStall() {
        let sentence = DocumentSurveyPause.displayAsleep.sentence
        #expect(sentence.contains("display"))
        #expect(sentence.lowercased().contains("icloud"),
                "the sentence does not say WHY a sleeping display stops the reading")
    }
}
