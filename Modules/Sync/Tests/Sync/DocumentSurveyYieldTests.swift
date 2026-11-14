import Foundation
import Testing
@testable import Sync

/// What a background survey stands aside for, and which reason it names when several are true at
/// once. Several usually are: a duplicate scan heats the Mac, and a Mac left alone puts its
/// display to sleep. The card shows one sentence, so the order is a decision, pinned here so an
/// edit can't reverse it by accident.
@Suite struct DocumentSurveyYieldTests {

    // MARK: - Each reason on its own

    @Test func fileOperationsAreCountedInTheSentence() {
        #expect(DocumentSurveyYield.pause(for: DocumentSurveyConditions(activeFileOperations: 1))
                == .yielding(to: "a file operation"))
        #expect(DocumentSurveyYield.pause(for: DocumentSurveyConditions(activeFileOperations: 12))
                == .yielding(to: "12 file operations"))
    }

    @Test func heatAndLowPowerStandItDown() {
        #expect(DocumentSurveyYield.pause(for: DocumentSurveyConditions(heat: .serious)) == .thermal)
        #expect(DocumentSurveyYield.pause(for: DocumentSurveyConditions(heat: .critical)) == .thermal)
        #expect(DocumentSurveyYield.pause(for: DocumentSurveyConditions(lowPowerMode: true)) == .lowPower)
    }

    /// `.nominal` covers `ProcessInfo`'s `.fair` too (that mapping lives in the app). Nominal is no
    /// reason to stop: a survey that paused at `.fair` would sit paused for hours with nothing wrong.
    @Test func nominalHeatIsNotAReasonToStop() {
        #expect(DocumentSurveyYield.pause(for: DocumentSurveyConditions(heat: .nominal)) == nil)
    }

    // MARK: - The order, which is the actual decision

    /// Work the person started outranks everything about the machine: standing aside for *their*
    /// work is the reassuring answer, and the one that explains why it isn't slower than usual.
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

    /// The display outranks heat and low power because it is not a choice: with the display asleep
    /// iCloud stops handing files over. "Paused, the Mac is hot" would name a reason the survey
    /// could work around over one it can't.
    @Test func aSleepingDisplayOutranksHeatAndLowPower() {
        let conditions = DocumentSurveyConditions(displayAsleep: true, heat: .critical,
                                                  lowPowerMode: true)
        #expect(DocumentSurveyYield.pause(for: conditions) == .displayAsleep)
    }

    @Test func heatOutranksLowPower() {
        let conditions = DocumentSurveyConditions(heat: .serious, lowPowerMode: true)
        #expect(DocumentSurveyYield.pause(for: conditions) == .thermal)
    }

    /// The caller names the scans in rail order, and the first is shown. Pinned so an array built
    /// from a dictionary (hash order) fails here, not as a card whose sentence changes per launch.
    @Test func theFirstNamedScanIsTheOneShown() {
        let conditions = DocumentSurveyConditions(runningScans: ["To File", "Duplicates", "Storage"])
        #expect(DocumentSurveyYield.pause(for: conditions) == .yielding(to: "To File"))
    }

    // MARK: - Resume now

    /// `pause(for:)` is the head of `reasons(for:)`: one order, so the sentence the card shows and
    /// the causes *Resume now* waives can't drift apart.
    @Test func theCardsReasonIsTheHeadOfEveryReason() {
        let cases: [DocumentSurveyConditions] = [
            .clear,
            DocumentSurveyConditions(isVerifying: true, activeFileOperations: 3,
                                     runningScans: ["Duplicates"], displayAsleep: true,
                                     heat: .critical, lowPowerMode: true),
            DocumentSurveyConditions(runningScans: ["To File", "Storage"], heat: .serious),
            DocumentSurveyConditions(displayAsleep: true, lowPowerMode: true),
            DocumentSurveyConditions(lowPowerMode: true)]
        for conditions in cases {
            #expect(DocumentSurveyYield.reasons(for: conditions).first?.pause
                    == DocumentSurveyYield.pause(for: conditions))
        }
        let all = DocumentSurveyConditions(isVerifying: true, activeFileOperations: 1,
                                           runningScans: ["To File", "Storage"], displayAsleep: true,
                                           heat: .serious, lowPowerMode: true)
        #expect(DocumentSurveyYield.reasons(for: all).map(\.cause)
                == [.verification, .fileOperations, .scan("To File"), .scan("Storage"),
                    .displayAsleep, .heat, .lowPower])
    }

    /// Every cause in force at the click is read through until it clears, then the waiver is
    /// forgotten, so the same cause coming back pauses again.
    @Test func resumeNowHoldsUntilItsCauseClears() {
        var override = DocumentSurveyOverride()
        let hotAndDuplicates = DocumentSurveyConditions(runningScans: ["Duplicates"], heat: .serious)
        #expect(override.pause(for: hotAndDuplicates) == .yielding(to: "Duplicates"))

        override.waive(hotAndDuplicates)
        #expect(override.pause(for: hotAndDuplicates) == nil,
                "a reason behind the one on the card was left standing")
        // Hotter is the same cause: the person said to read through the heat.
        #expect(override.pause(for: DocumentSurveyConditions(runningScans: ["Duplicates"],
                                                             heat: .critical)) == nil)
        // Duplicates finishes; the heat stays waived.
        #expect(override.pause(for: DocumentSurveyConditions(heat: .serious)) == nil)
        // Duplicates again is a new run of it, not the one read through.
        #expect(override.pause(for: hotAndDuplicates) == .yielding(to: "Duplicates"))
        // The Mac cools, then heats again: paused again.
        #expect(override.pause(for: .clear) == nil)
        #expect(override.pause(for: DocumentSurveyConditions(heat: .serious)) == .thermal)
    }

    /// A cause not in force at the click pauses as usual, including one ranked below a waived
    /// one, which a waiver keyed on the card's single sentence would hide.
    @Test func resumeNowDoesNotWaiveWhatArrivesAfterIt() {
        var override = DocumentSurveyOverride()
        override.waive(DocumentSurveyConditions(runningScans: ["Duplicates"]))
        #expect(override.pause(for: DocumentSurveyConditions(runningScans: ["Duplicates"],
                                                             displayAsleep: true))
                == .displayAsleep)
    }

    /// The file-operation sentence carries a count; the cause does not. A second copy starting
    /// must not re-pause a survey somebody just told to carry on.
    @Test func aChangingCountIsNotANewCause() {
        var override = DocumentSurveyOverride()
        override.waive(DocumentSurveyConditions(activeFileOperations: 1))
        #expect(override.pause(for: DocumentSurveyConditions(activeFileOperations: 2)) == nil)
    }

    /// Nothing in force, nothing waived: a click that lands after the pause cleared must not
    /// pre-approve the next one.
    @Test func resumeNowWithNothingInForceWaivesNothing() {
        var override = DocumentSurveyOverride()
        override.waive(.clear)
        #expect(override.waived.isEmpty)
        #expect(override.pause(for: DocumentSurveyConditions(lowPowerMode: true)) == .lowPower)
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

    /// The display's sentence must explain the stall, not just name it: a card that said only
    /// "Paused" would leave a frozen count looking like a hang.
    @Test func theDisplaySentenceExplainsTheStall() {
        let sentence = DocumentSurveyPause.displayAsleep.sentence
        #expect(sentence.contains("display"))
        #expect(sentence.lowercased().contains("icloud"),
                "the sentence does not say WHY a sleeping display stops the reading")
    }
}
