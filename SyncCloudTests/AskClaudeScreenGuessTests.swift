import Foundation
import Testing
@testable import SyncCloud

/// The screen guess (TE347c) with a stand-in model: what Send waits for, and how long. No test
/// times the wait: the full app run starves the main actor for 20 s and more (`docs/flaky-tests.md`).
/// A wait that should end early is given an hour's deadline instead, so a regression shows as the
/// test's time limit, never as a slow but passing run.
@MainActor
@Suite struct AskClaudeScreenGuessTests {

    private let context = AskClaudeScreenGuess.Context(workspace: "Browse", fileOpen: false)

    final class Calls { var count = 0 }

    /// No answer (Apple Intelligence off, a failure) ends the wait at once and sends the screen,
    /// and the next Send asks again rather than waiting on a guess that will never come.
    @Test(.timeLimit(.minutes(2))) func noAnswerSendsTheScreenAtOnceAndIsAskedAgain() async {
        let calls = Calls()
        let guess = AskClaudeScreenGuess(wait: .seconds(3600), asker: { _, _ in calls.count += 1; return nil })
        #expect(await guess.withholds("How is the weather", context: context) == false)
        #expect(await guess.withholds("How is the weather", context: context) == false)
        #expect(calls.count == 2)
    }

    @Test func aNoKeepsTheScreenHereAndAYesSendsIt() async {
        let guess = AskClaudeScreenGuess(wait: .seconds(30), asker: { question, _ in question.contains("folder") })
        #expect(await guess.withholds("How is the weather", context: context) == true)
        #expect(await guess.withholds("What’s in this folder", context: context) == false)
    }

    /// A guess slower than Send's wait sends the screen; one made while typing is used at Send.
    @Test func aSlowGuessSendsTheScreenAndAnEarlyOneIsUsed() async {
        let slow = AskClaudeScreenGuess(wait: .milliseconds(100), asker: { _, _ in try? await Task.sleep(for: .seconds(30)); return false })
        #expect(await slow.withholds("Tell me a joke", context: context) == false)
        let calls = Calls()
        let early = AskClaudeScreenGuess(wait: .seconds(30), asker: { _, _ in calls.count += 1; return false })
        early.start("Tell me a joke", context: context)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await early.withholds("Tell me a joke", context: context) == true)
        #expect(calls.count == 1, "the guess made while typing was asked again at Send")
    }

    /// Stopped while waiting: it returns at once instead of spinning to the deadline.
    @Test(.timeLimit(.minutes(2))) func aStopEndsTheWait() async {
        let guess = AskClaudeScreenGuess(wait: .seconds(3600), asker: { _, _ in try? await Task.sleep(for: .seconds(3600)); return false })
        let waiting = Task { await guess.withholds("Tell me a joke", context: context) }
        try? await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        #expect(await waiting.value == false)
    }
}
