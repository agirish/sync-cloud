import Foundation
import Testing
@testable import FileExplorer

/// The document survey card's words and its bar.
///
/// **What this screen says has been wrong more often than what it draws**, which is why the copy is
/// static functions a test can read rather than string literals inside a view body. The assertions
/// below are mostly about honesty: that the offer states its cost, that a pause explains itself,
/// and that a finished survey names what it could not read.
@Suite struct DocumentSurveyCardTests {

    // MARK: - Time remaining

    /// **"About", always, and rounded above the hour.** The estimate is a rate over a serial read
    /// of wildly uneven documents; "1 h 47 min left" claims a precision it does not have, and a
    /// figure that ticks every minute invites someone to sit and watch it.
    @Test func remainingIsRoundedAndHedged() {
        #expect(DocumentSurveyCardText.remaining(30) == "under a minute left")
        #expect(DocumentSurveyCardText.remaining(60) == "about 1 min left")
        #expect(DocumentSurveyCardText.remaining(14 * 60) == "about 14 min left")
        #expect(DocumentSurveyCardText.remaining(60 * 60) == "about 1 h left")
        // 1 h 47 rounds down to the five-minute mark.
        #expect(DocumentSurveyCardText.remaining((107 * 60)) == "about 1 h 45 min left")
        #expect(DocumentSurveyCardText.remaining((110 * 60)) == "about 1 h 50 min left")
    }

    @Test func remainingNeverGoesNegative() {
        #expect(DocumentSurveyCardText.remaining(-500) == "under a minute left")
    }

    // MARK: - The offer

    /// The one state that asks for a decision is the one that has to state the price.
    @Test func theOfferSaysWhatItCostsAndWhatItBuys() {
        let detail = DocumentSurveyCardText.detail(for: .offered(documents: 7558))
        #expect(detail.contains("7,558"), "the offer does not say how many documents")
        #expect(detail.contains("3 h"), "the offer does not say how long")
        #expect(detail.lowercased().contains("background"))
        #expect(detail.lowercased().contains("pausable"),
                "the offer does not say the commitment can be taken back")
    }

    /// **The count is optional, and the copy has to hold up without it.** Knowing how many
    /// documents would be read means walking the whole tree, which is not something to do every
    /// time Organize opens — and the cheap numbers lying around are the wrong ones: the profile's
    /// summed `fileCount` is every file, 11,835 against the 11,019 the survey opens on the
    /// reference tree. Overstating the work by 7% in the sentence someone decides on is worse than
    /// not stating it, so the card says how long without saying how many, and promises the count
    /// before it opens anything.
    @Test func theOfferHoldsUpBeforeAnythingHasBeenCounted() {
        let detail = DocumentSurveyCardText.detail(for: .offered(documents: nil))
        #expect(!detail.isEmpty)
        #expect(detail.contains("hours"), "the uncounted offer does not say how long")
        #expect(detail.lowercased().contains("paused"))
        #expect(detail.contains("says how many"),
                "the uncounted offer does not promise the count it is withholding")
        // And it must not invent one.
        #expect(!detail.contains("11,835"))
        #expect(!detail.contains("7,558"))
    }

    /// No bar before anything has happened, and none after it is done — in the first case there is
    /// nothing to draw, in the second a full bar is a second way of saying "Documents read".
    @Test func onlyTheRunningStatesDrawABar() {
        #expect(DocumentSurveyCardText.fraction(for: .offered(documents: 10)) == nil)
        #expect(DocumentSurveyCardText.fraction(for: .finished(summary: "x", unreadableTypes: 0)) == nil)
        #expect(DocumentSurveyCardText.fraction(for: .interrupted(done: 1, total: 4)) == 0.25)
        #expect(DocumentSurveyCardText.fraction(
            for: .running(done: 2, total: 4, folder: nil, secondsRemaining: nil, pause: nil)) == 0.5)
    }

    /// An empty plan must not divide by zero — it is reachable on a tree of nothing but Office
    /// documents, which is a real shape rather than a hypothetical one.
    @Test func anEmptyPlanDoesNotDivideByZero() {
        #expect(DocumentSurveyCardText.fraction(
            for: .running(done: 0, total: 0, folder: nil, secondsRemaining: nil, pause: nil)) == nil)
    }

    // MARK: - Running and paused

    @Test func theRunningTitleCountsAgainstTheTotal() {
        let title = DocumentSurveyCardText.title(
            for: .running(done: 2871, total: 7558, folder: "Health/Medical/Kaiser",
                          secondsRemaining: 6600, pause: nil))
        #expect(title.contains("2,871"))
        #expect(title.contains("7,558"))
        #expect(!title.lowercased().contains("paused"))
    }

    @Test func theRunningDetailNamesTheFolderAndTheTime() {
        let detail = DocumentSurveyCardText.detail(
            for: .running(done: 2871, total: 7558, folder: "Health/Medical/Kaiser",
                          secondsRemaining: 6600, pause: nil))
        #expect(detail.contains("Health/Medical/Kaiser"))
        #expect(detail.contains("about 1 h 50 min left"))
    }

    /// **The ETA is withheld rather than guessed**, and the card has to say something in its place.
    /// A blank where a number belongs reads as a bug.
    @Test func anAbsentETAStillSaysSomething() {
        let detail = DocumentSurveyCardText.detail(
            for: .running(done: 3, total: 7558, folder: nil, secondsRemaining: nil, pause: nil))
        #expect(!detail.isEmpty)
        #expect(detail.lowercased().contains("how long"))
    }

    /// **A paused card must not look like a stalled one.** The title says paused, and the detail
    /// carries the reason rather than the ETA — an estimate under a survey that is not running is
    /// a number counting down to nothing.
    @Test func aPausedCardSaysSoAndGivesTheReason() {
        let pause = DocumentSurveyCardState.PauseNote(
            sentence: "Paused — the display is asleep, so iCloud has stopped handing files over.",
            resumesOnItsOwn: true)
        let state = DocumentSurveyCardState.running(done: 2871, total: 7558, folder: "Health",
                                                    secondsRemaining: 6600, pause: pause)
        #expect(DocumentSurveyCardText.title(for: state).contains("paused at"))
        let detail = DocumentSurveyCardText.detail(for: state)
        #expect(detail.contains("display is asleep"))
        #expect(detail.contains("Resumes on its own"),
                "a pause that clears itself does not say so, so the card reads as needing a click")
        #expect(!detail.contains("1 h 50"), "a paused card is counting down to nothing")
    }

    /// The user's own pause does NOT claim to resume on its own — it is the one that does not.
    @Test func aUserPauseDoesNotPromiseToResumeItself() {
        let pause = DocumentSurveyCardState.PauseNote(sentence: "Paused.", resumesOnItsOwn: false)
        let detail = DocumentSurveyCardText.detail(
            for: .running(done: 1, total: 4, folder: nil, secondsRemaining: nil, pause: pause))
        #expect(!detail.contains("Resumes on its own"))
    }

    // MARK: - Interrupted, which is decision 3's whole surface

    /// **It states the remainder, not the original ask.** "4,687 still to read" is a far easier
    /// second decision than the three hours the first card asked for, and it is the reason an
    /// offered resume is viable at all rather than a survey that sits at 38% for ever.
    @Test func theInterruptedCardSaysHowLittleIsLeft() {
        let state = DocumentSurveyCardState.interrupted(done: 2871, total: 7558)
        #expect(DocumentSurveyCardText.title(for: state).contains("2,871 of 7,558"))
        let detail = DocumentSurveyCardText.detail(for: state)
        #expect(detail.contains("4,687"), "the card does not say how much is actually left")
        #expect(!detail.contains("3 h"), "it is re-asking the original three-hour question")
    }

    /// **Nothing left to read is a different sentence, not a zero.**
    ///
    /// This test used to assert "0 still to read", which was the copy at the time and read as a
    /// bug on screen — reached for real when the corpus write fails after a complete pass, where
    /// the checkpoint is kept, the remainder is zero, and what is actually left is the write.
    /// A hand-edited checkpoint claiming more done than planned lands in the same branch, which is
    /// why the clamp is still asserted: what must never appear is a negative.
    @Test func nothingLeftToReadSaysWhatIsActuallyLeft() {
        for state: DocumentSurveyCardState in [.interrupted(done: 7558, total: 7558),
                                               .interrupted(done: 99, total: 10)] {
            let detail = DocumentSurveyCardText.detail(for: state)
            #expect(detail.contains("still has to be written"),
                    "the card does not say what is actually outstanding")
            #expect(!detail.contains("still to read"),
                    "the card offers to read documents when none are left")
            // A NEGATIVE NUMBER, not a hyphen — the sentence legitimately says "re-reading".
            #expect(detail.range(of: "-[0-9]", options: .regularExpression) == nil,
                    "a negative remainder reached the copy")
            #expect(!DocumentSurveyCardText.title(for: state).contains("paused at"),
                    "a survey that read everything is described as paused part way")
        }
    }

    // MARK: - Finished

    /// **The completion names what it could NOT open.** A summary that reports only what it managed
    /// reads as complete when it was not, and Office formats are the largest single gap in a
    /// derived survey — 816 of 11,835 documents on the reference tree.
    @Test func theCompletionNamesTheFormatsItCouldNotRead() {
        let detail = DocumentSurveyCardText.detail(
            for: .finished(summary: "10,203 documents read.", unreadableTypes: 816))
        #expect(detail.contains("10,203 documents read."))
        #expect(detail.contains("816"))
        #expect(detail.contains("Word"))
    }

    /// And says nothing about them when there were none — a zero stated is a claim nobody asked for.
    @Test func aCleanCompletionDoesNotMentionFormatsAtAll() {
        let detail = DocumentSurveyCardText.detail(
            for: .finished(summary: "12 documents read.", unreadableTypes: 0))
        #expect(detail == "12 documents read.")
    }

    // MARK: - Every state

    /// **Finishing is not a pause, and rendering it as one said three false things at once.**
    /// It first arrived as a `PauseNote`, which made the card read "Reading documents · paused at
    /// 7,558 of 7,558 … Resumes on its own" — over a survey that was not paused, could not be
    /// resumed, and was doing the least interruptible minutes of its work — while offering a Pause
    /// button for something with nothing to pause.
    @Test func finishingSaysWhatItIsDoingRatherThanClaimingToBePaused() {
        let state = DocumentSurveyCardState.finishing(done: 7558)
        let title = DocumentSurveyCardText.title(for: state)
        #expect(!title.lowercased().contains("paused"), "finishing still reports itself as paused")
        #expect(title.contains("7,558"))
        let detail = DocumentSurveyCardText.detail(for: state)
        #expect(!detail.contains("Resumes on its own"),
                "finishing promises a resume for something that is not stopped")
        #expect(detail.lowercased().contains("nothing to do"),
                "finishing does not tell the reader there is nothing for them to do")
        // No bar: the reading has stopped counting, and a full one would be counting it anyway.
        #expect(DocumentSurveyCardText.fraction(for: state) == nil)
    }

    @Test func everyStateHasATitleAndADetail() {
        let states: [DocumentSurveyCardState] = [
            .offered(documents: 100),
            .offered(documents: nil),
            .running(done: 1, total: 100, folder: "A", secondsRemaining: 60, pause: nil),
            .running(done: 1, total: 100, folder: "A", secondsRemaining: 60,
                     pause: .init(sentence: "Paused.", resumesOnItsOwn: false)),
            .finishing(done: 100),
            .interrupted(done: 1, total: 100),
            .finished(summary: "done.", unreadableTypes: 0),
        ]
        for state in states {
            #expect(!DocumentSurveyCardText.title(for: state).isEmpty)
            #expect(!DocumentSurveyCardText.detail(for: state).isEmpty)
        }
    }
}
