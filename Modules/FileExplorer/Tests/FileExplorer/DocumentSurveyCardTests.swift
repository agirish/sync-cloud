import Foundation
import Testing
import Sync
@testable import FileExplorer

/// The document survey card's words and its bar.
///
/// The copy is static functions a test can read, not literals in a view body, because the words
/// are what go wrong. The checks are mostly about honesty: the offer states its cost, a pause
/// explains itself, and a finished survey names what it could not read.
@Suite struct DocumentSurveyCardTests {

    // MARK: - Time remaining

    /// "About", always, and rounded above the hour. The estimate is a rate over very uneven
    /// documents, so "1 h 47 min left" claims a precision it lacks, and a per-minute tick invites
    /// watching.
    @Test func remainingIsRoundedAndHedged() {
        #expect(DocumentSurveyCardText.remaining(30) == "under a minute left")
        #expect(DocumentSurveyCardText.remaining(60) == "about 1 min left")
        #expect(DocumentSurveyCardText.remaining(14 * 60) == "about 14 min left")
        #expect(DocumentSurveyCardText.remaining(60 * 60) == "about 1 h left")
        // 1 h 47 rounds down to the five-minute mark.
        #expect(DocumentSurveyCardText.remaining((107 * 60)) == "about 1 h 45 min left")
        #expect(DocumentSurveyCardText.remaining((110 * 60)) == "about 1 h 50 min left")
        // Never negative.
        #expect(DocumentSurveyCardText.remaining(-500) == "under a minute left")
    }

    // MARK: - The offer

    /// The one state that asks for a decision is the one that has to state the price.
    @Test func theOfferSaysWhatItCostsAndWhatItBuys() {
        let detail = DocumentSurveyCardText.detail(for: .offered(documents: 7558))
        #expect(detail.contains("7,558"), "the offer does not say how many documents")
        #expect(detail.contains("About 4 h for 7,558 documents"), "the offer does not say how long: \(detail)")
        #expect(detail.lowercased().contains("background"))
        #expect(detail.lowercased().contains("pausable"),
                "the offer does not say the commitment can be taken back")
    }

    /// A small library is offered in minutes: the card prices through `DocumentSurveyCost`, so a
    /// dozen documents don't cost "About 3 h".
    @Test func theOfferForAFewDocumentsSaysAFewMinutes() {
        let detail = DocumentSurveyCardText.detail(for: .offered(documents: 12))
        #expect(detail.contains("A few minutes for 12 documents, in the background."), "\(detail)")
        #expect(!detail.contains("3 h"))
    }

    /// A walk that found no document offers no read: the card says there is nothing to read,
    /// prices nothing, and its verb looks again.
    @MainActor @Test func aWalkThatFoundNothingOffersNoRead() throws {
        let detail = DocumentSurveyCardText.detail(for: .offered(documents: 0))
        #expect(detail.hasSuffix("No document here is in a format this app can open, so there is nothing to read yet."),
                "\(detail)")
        #expect(!detail.contains("0 documents") && !detail.contains("A few minutes"), "\(detail)")

        let card = DocumentSurveyCard(state: .offered(documents: 0), accent: .blue, onStart: {})
        #expect(card.verbs.map(\.title) == ["Look Again"])
        // The control: one document is still offered as a read.
        let one = DocumentSurveyCard(state: .offered(documents: 1), accent: .blue, onStart: {})
        #expect(one.verbs.map(\.title) == ["Read My Documents"])
    }

    /// The count is optional, and the copy holds up without it: counting walks the whole tree, too
    /// much for every Organize open. So the uncounted card says how long, not how many, and
    /// promises the count before it opens anything.
    @Test func theOfferHoldsUpBeforeAnythingHasBeenCounted() {
        let detail = DocumentSurveyCardText.detail(for: .offered(documents: nil))
        #expect(!detail.isEmpty)
        #expect(detail.contains("hours"), "the uncounted offer does not say how long")
        #expect(detail.lowercased().contains("paused"))
        #expect(detail.contains("says how many"),
                "the uncounted offer does not promise the count it is withholding")
        // It must not invent one.
        #expect(!detail.contains("11,835"))
        #expect(!detail.contains("7,558"))
    }

    /// No bar before anything has happened, and none once done, where a full bar would only repeat
    /// "Documents read". A settled receipt is not a to-do: no bar, no badge, as on Storage's card.
    @Test func onlyTheRunningStatesDrawABar() {
        #expect(DocumentSurveyCardText.fraction(for: .offered(documents: 10)) == nil)
        #expect(DocumentSurveyCardText.fraction(for: .finished(summary: "x", unreadableTypes: 0)) == nil)
        #expect(DocumentSurveyCardText.fraction(for: .settled(folders: 2306, lastRead: nil)) == nil)
        #expect(DocumentSurveyCardText.fraction(for: .interrupted(done: 1, total: 4)) == 0.25)
        #expect(DocumentSurveyCardText.fraction(
            for: .running(done: 2, total: 4, folder: nil, secondsRemaining: nil, pause: nil)) == 0.5)
    }

    /// An empty plan must not divide by zero; a tree of nothing but Office documents produces one.
    @Test func anEmptyPlanDoesNotDivideByZero() {
        #expect(DocumentSurveyCardText.fraction(
            for: .running(done: 0, total: 0, folder: nil, secondsRemaining: nil, pause: nil)) == nil)
    }

    // MARK: - Running and paused

    /// The title counts against the total; the detail names the folder and the time.
    @Test func theRunningTitleCountsAgainstTheTotal() {
        let running = DocumentSurveyCardState.running(done: 2871, total: 7558, folder: "Health/Medical/Kaiser",
                                                      secondsRemaining: 6600, pause: nil)
        let title = DocumentSurveyCardText.title(for: running)
        #expect(title.contains("2,871"))
        #expect(title.contains("7,558"))
        #expect(!title.lowercased().contains("paused"))
        let detail = DocumentSurveyCardText.detail(for: running)
        #expect(detail.contains("Health/Medical/Kaiser"))
        #expect(detail.contains("about 1 h 50 min left"))
    }

    /// A withheld ETA still leaves the card saying something: a blank where a number belongs reads
    /// as a bug.
    @Test func anAbsentETAStillSaysSomething() {
        let detail = DocumentSurveyCardText.detail(
            for: .running(done: 3, total: 7558, folder: nil, secondsRemaining: nil, pause: nil))
        #expect(!detail.isEmpty)
        #expect(detail.lowercased().contains("how long"))
    }

    /// A paused card must not look stalled: the title says paused, and the detail gives the reason
    /// instead of an ETA that would count down to nothing.
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

    /// A live survey's state says who paused it: paused by the Mac, it says so and that it goes on
    /// by itself; paused by the reader, only that it is paused. Finishing is its own state.
    @Test func aLiveSurveySaysWhoPausedIt() {
        func live(_ phase: DocumentSurveyProgress.Phase, done: Int = 40,
                  folder: String? = nil) -> DocumentSurveyCardState {
            .live(DocumentSurveyProgress(completed: done, total: 300, phase: phase, currentFolder: folder,
                                         startedAt: Date(timeIntervalSince1970: 1_780_315_200),
                                         readingSeconds: 60))
        }
        let hot = live(.paused(.thermal))
        #expect(DocumentSurveyCardText.title(for: hot) == "Reading documents · paused at 40 of 300")
        #expect(DocumentSurveyCardText.detail(for: hot) == "Paused — the Mac is running hot. Resumes on its own.")
        let mine = live(.paused(.user))
        #expect(DocumentSurveyCardText.title(for: mine) == "Reading documents · paused at 40 of 300")
        #expect(DocumentSurveyCardText.detail(for: mine) == "Paused.")
        #expect(DocumentSurveyCardText.title(for: live(.reading, folder: "Taxes")) == "Reading documents · 40 of 300")
        #expect(live(.finishing, done: 300) == .finishing(done: 300))
    }

    /// The user's own pause doesn't claim to resume on its own, because it doesn't.
    @Test func aUserPauseDoesNotPromiseToResumeItself() {
        let pause = DocumentSurveyCardState.PauseNote(sentence: "Paused.", resumesOnItsOwn: false)
        let detail = DocumentSurveyCardText.detail(
            for: .running(done: 1, total: 4, folder: nil, secondsRemaining: nil, pause: pause))
        #expect(!detail.contains("Resumes on its own"))
    }

    // MARK: - Interrupted, which is decision 3's whole surface

    /// The interrupted card states the remainder, not the original ask: "4,687 still to read" is
    /// an easier second decision than the three hours first asked for.
    @Test func theInterruptedCardSaysHowLittleIsLeft() {
        let state = DocumentSurveyCardState.interrupted(done: 2871, total: 7558)
        #expect(DocumentSurveyCardText.title(for: state).contains("2,871 of 7,558"))
        let detail = DocumentSurveyCardText.detail(for: state)
        #expect(detail.contains("4,687"), "the card does not say how much is actually left")
        #expect(!detail.contains("3 h"), "it is re-asking the original three-hour question")
    }

    /// Nothing left to read is its own sentence, not "0 still to read": the corpus write failed
    /// after a complete pass, so what's left is the write. A hand-edited checkpoint claiming more
    /// done than planned lands here too, so no negative count may appear.
    @Test func nothingLeftToReadSaysWhatIsActuallyLeft() {
        for state: DocumentSurveyCardState in [.interrupted(done: 7558, total: 7558),
                                               .interrupted(done: 99, total: 10)] {
            let detail = DocumentSurveyCardText.detail(for: state)
            #expect(detail.contains("still has to be saved"),
                    "the card does not say what is actually outstanding")
            #expect(!detail.contains("still to read"),
                    "the card offers to read documents when none are left")
            // A negative number, not a hyphen: the sentence legitimately says "re-reading".
            #expect(detail.range(of: "-[0-9]", options: .regularExpression) == nil,
                    "a negative remainder reached the copy")
            #expect(!DocumentSurveyCardText.title(for: state).contains("paused at"),
                    "a survey that read everything is described as paused part way")
        }
    }

    // MARK: - Finished

    /// The completion names what it could not open, or it reads as complete when it wasn't. Office
    /// formats are the largest single gap in a derived survey.
    @Test func theCompletionNamesTheFormatsItCouldNotRead() {
        let detail = DocumentSurveyCardText.detail(
            for: .finished(summary: "10,203 documents read.", unreadableTypes: 816))
        #expect(detail.contains("10,203 documents read."))
        #expect(detail.contains("816"))
        #expect(detail.contains("Word"))
    }

    /// It says nothing about them when there were none.
    @Test func aCleanCompletionDoesNotMentionFormatsAtAll() {
        let detail = DocumentSurveyCardText.detail(
            for: .finished(summary: "12 documents read.", unreadableTypes: 0))
        #expect(detail == "12 documents read.")
    }

    // MARK: - Settled: the receipt, and the gap it closed

    /// Once the documents have been read, the card becomes a receipt: what was learned, when, and
    /// a refresh that says it reads only what changed.
    @Test func theSettledReceiptStatesWhatIsKnownAndOffersTheRefresh() {
        let detail = DocumentSurveyCardText.detail(
            for: .settled(folders: 2306, lastRead: Date().addingTimeInterval(-3 * 86_400)))
        #expect(detail.contains("2,306"), "the receipt does not say how much was learned")
        #expect(detail.contains("days ago"), "the receipt does not say when")
        #expect(detail.lowercased().contains("only what has changed"),
                "the receipt does not say what refreshing costs, so Refresh reads as a full re-run")
        #expect(DocumentSurveyCardText.title(for: .settled(folders: 1, lastRead: nil))
                == "Documents read")
    }

    /// A corpus with no stamp (an older one, or the offline builder's) has no date. The card says
    /// what it knows rather than inventing a "just now".
    @Test func aSettledReceiptWithNoStampSaysWhatItKnows() {
        let detail = DocumentSurveyCardText.detail(for: .settled(folders: 2306, lastRead: nil))
        #expect(detail.contains("2,306"))
        #expect(!detail.contains("read "), "a missing stamp was rendered as a claim about when")
        #expect(detail.lowercased().contains("only what has changed"))
        // An empty tree still says something.
        let empty = DocumentSurveyCardState.settled(folders: 0, lastRead: nil)
        #expect(!DocumentSurveyCardText.title(for: empty).isEmpty && !DocumentSurveyCardText.detail(for: empty).isEmpty)
    }

    /// Singular and plural, verb included, so a one-folder tree never reads "1 folder have learned
    /// content".
    @Test func theSettledReceiptCountsGrammatically() {
        let one = DocumentSurveyCardText.detail(for: .settled(folders: 1, lastRead: nil))
        #expect(one.contains("1 folder has learned content"))
        #expect(!one.contains("folder have"))
        let many = DocumentSurveyCardText.detail(for: .settled(folders: 2306, lastRead: nil))
        #expect(many.contains("2,306 folders have learned content"))
    }

    // MARK: - Every state

    /// Finishing is not a pause. Shown as one, the card would say "paused … Resumes on its own" over
    /// a survey that isn't paused, can't be resumed, and is in its least interruptible minutes.
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
        // No bar: the reading has stopped counting.
        #expect(DocumentSurveyCardText.fraction(for: state) == nil)
    }

    // MARK: - The verbs do what they say

    /// Start Over asks, and a yes runs `onStartOver`, never `onStart`, which adopts the progress on
    /// disk and so would resume. A no runs nothing.
    @MainActor @Test func startOverAsksThenRunsTheVerbThatDiscards() throws {
        final class Calls { var log: [String] = [] }
        for answer in [true, false] {
            let calls = Calls()
            var asked: (Int, Int)?
            var card = DocumentSurveyCard(state: .interrupted(done: 4_687, total: 11_019),
                                          accent: .blue,
                                          onStart: { calls.log.append("start") },
                                          onStartOver: { calls.log.append("start over") },
                                          onResume: { calls.log.append("resume") })
            card.confirmStartOver = { asked = ($0, $1); return answer }
            let verb = try #require(card.verbs.first { $0.title == "Start Over" })

            verb.run()

            #expect(asked.map { [$0.0, $0.1] } == [4_687, 11_019], "Start over did not ask first")
            #expect(calls.log == (answer ? ["start over"] : []),
                    "answered \(answer ? "Start Over" : "Cancel"), it ran \(calls.log)")
        }
    }

    /// Its question says what the click costs, in counts, keeps the answer that discards the reading
    /// off Return, and puts Cancel on Esc, like the app's other leave questions.
    @MainActor @Test func theStartOverQuestionSaysWhatItCostsAndKeepsReturnOffIt() {
        let alert = DocumentSurveyCard.startOverAlert(done: 4_687, total: 11_019)
        #expect(alert.informativeText.contains("4,687 documents"))
        #expect(alert.informativeText.contains("11,019"))
        #expect(alert.buttons.map(\.title) == ["Start Over", "Cancel"])
        #expect(alert.buttons[0].keyEquivalent.isEmpty, "Return starts over")
        #expect(alert.buttons[0].hasDestructiveAction)
        #expect(alert.buttons[1].keyEquivalent == "\u{1b}", "Esc doesn’t cancel")
    }

    /// Resume Now and Start Over both carry a tooltip saying what they do.
    @MainActor @Test func resumeNowAndStartOverHaveTooltips() throws {
        let paused = DocumentSurveyCard(
            state: .running(done: 10, total: 100, folder: nil, secondsRemaining: nil,
                            pause: .init(sentence: "Paused — the Mac is running hot.",
                                         resumesOnItsOwn: true)),
            accent: .blue, onResume: {}, onStop: {})
        let resumeNow = try #require(paused.verbs.first { $0.title == "Resume Now" })
        #expect(resumeNow.help?.isEmpty == false)
        let interrupted = DocumentSurveyCard(state: .interrupted(done: 1, total: 2), accent: .blue,
                                             onStartOver: {}, onResume: {})
        let startOver = try #require(interrupted.verbs.first { $0.title == "Start Over" })
        #expect(startOver.help?.isEmpty == false)
    }
}
