import Testing
import Foundation
import Sync
@testable import SyncCloud

/// Accepting a person offer twice used to race two sweeps with last-write-wins.
///
/// The gather walks every surveyed document — 10,171 on the real tree — behind a 4.9 MB corpus
/// read, so a second ⌘↩ arrives while the first is still going. Nothing held the first task, so
/// nothing cancelled it, and whichever finished last wrote the slot: accept Aditi, change your
/// mind, accept Girish, and the answer on screen could be Aditi's under Girish's name.
///
/// Two decisions guard that, and they are opposite ends of the same window. ``shouldStart`` is
/// asked when the second accept arrives; ``awaits`` is asked when a sweep finishes and wants to
/// write. The sweep's own cancellation is tested in `PersonFilesTests` — this is the slot half,
/// which is where the wrong answer actually reached the screen.
@Suite struct PersonGatherSupersedeTests {

    private static let aditi = Person(id: "aditi", displayName: "Aditi",
                                      fullNames: ["Aditi Abhishek"])
    private static let girish = Person(id: "girish", displayName: "Girish",
                                       fullNames: ["Girish Krishnamurthy"])
    private static let answer = PersonFileSet(personId: "aditi", herFolders: [], elsewhere: [])

    private typealias Scope = ContentView.PersonScope

    // MARK: Starting

    @Test func repeatingTheSameAcceptMidSweepDoesNotRestartIt() {
        // The one case that must NOT start: it is the same question, and restarting throws away
        // a sweep already partway through the corpus.
        let running = Scope(person: Self.aditi, phase: .gathering)
        #expect(!Scope.shouldStart(Self.aditi, given: running))
    }

    @Test func everyOtherAcceptStarts() {
        // Each of these is a different question from what the slot holds, so each must start —
        // and they are listed separately because a `shouldStart` that answered `false` more
        // broadly would leave ⌘↩ doing nothing at all, which is the bug this feature is fixing.
        #expect(Scope.shouldStart(Self.aditi, given: nil),
                "an accept with an empty slot did not start a gather")
        #expect(Scope.shouldStart(Self.girish, given: Scope(person: Self.aditi, phase: .gathering)),
                "switching person mid-sweep did not start the new gather")
        #expect(Scope.shouldStart(Self.aditi, given: Scope(person: Self.aditi,
                                                          phase: .ready(Self.answer))),
                "re-asking after the answer landed did not re-gather")
        #expect(Scope.shouldStart(Self.aditi, given: Scope(person: Self.aditi,
                                                          phase: .failed("no survey"))),
                "retrying after a failure did not start a gather — the failure would be permanent")
    }

    // MARK: Writing the answer

    @Test func aSupersededSweepMayNotWriteItsAnswer() {
        // **The race, stated.** Aditi's sweep finishes after Girish's accept has taken the slot.
        // Cancellation usually stops it first, but a sweep that had already left the loop when
        // the cancel landed still reaches this check — and without it, Aditi's files appear
        // under Girish's name.
        let slot = Scope(person: Self.girish, phase: .gathering)
        #expect(!Scope.awaits(Self.aditi, in: slot))
    }

    @Test func aClearedSlotTakesNoAnswer() {
        // Esc or the ✕ during the sweep: the answer arriving afterwards must not re-open the
        // view the user just dismissed.
        #expect(!Scope.awaits(Self.aditi, in: nil))
    }

    @Test func aSlotThatAlreadyHasAnAnswerTakesNoOther() {
        // Belt to the cancellation's braces: two sweeps for the SAME person (possible only if
        // a cancel is dropped) must not overwrite each other. `.gathering` is the only phase
        // that is waiting for anything.
        let done = Scope(person: Self.aditi, phase: .ready(Self.answer))
        #expect(!Scope.awaits(Self.aditi, in: done))
    }

    @Test func theSweepThatOwnsTheSlotDoesWrite() {
        // Non-vacuity: without this, a broken `awaits` returning false always would pass every
        // assertion above and no gather would ever paint an answer.
        let mine = Scope(person: Self.aditi, phase: .gathering)
        #expect(Scope.awaits(Self.aditi, in: mine))
    }
}
