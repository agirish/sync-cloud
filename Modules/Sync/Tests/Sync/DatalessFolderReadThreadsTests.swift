import Events
import EventsTestSupport
import Foundation
import Testing
@testable import Sync

/// Where `FileSyncManager.DatalessFolderReads` gets its threads. A listing of a folder whose
/// provider never answers holds its thread for good, so the listings must not draw on GCD's global
/// pool, which doesn't overcommit and holds at most 64 threads a process: 64 such listings took it
/// all, the deadlines' timers too, and no walk heard a verdict again (`docs/flaky-tests.md`, "A file
/// presenter whose answer waited for a GCD thread past the writer's deadline").
///
/// The listings here are the test's own closures, blocked until the test lets go (bounded at 30 s).
/// Every path is under this suite's own root, and no folder exists, so none resolves to another.
@Suite struct DatalessFolderReadThreadsTests {

    /// How many listings started, and how many came back.
    final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var startedCount = 0
        private var returnedCount = 0
        func start() { lock.lock(); startedCount += 1; lock.unlock() }
        func end() { lock.lock(); returnedCount += 1; lock.unlock() }
        var started: Int { lock.lock(); defer { lock.unlock() }; return startedCount }
        var returned: Int { lock.lock(); defer { lock.unlock() }; return returnedCount }
    }

    /// A listing whose provider answers only once the test signals `hold`, or after 30 s.
    static func listing(_ counts: Counts, _ hold: DispatchSemaphore) -> @Sendable () -> Bool {
        { counts.start(); let answered = hold.wait(timeout: .now() + 30) == .success; counts.end(); return answered }
    }

    /// Polls off the main actor: what it waits for is a dispatch thread, not a main-actor turn.
    static func waitFor(_ what: Comment, timeout: TimeInterval = 10,
                        sourceLocation: SourceLocation = #_sourceLocation,
                        _ condition: @Sendable () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(condition(), what, sourceLocation: sourceLocation)
    }

    /// Seventy folders that never answer: every one is asked, on a thread of its own, and every one
    /// is called unanswered at its deadline while its listing is still blocked. On a concurrent
    /// queue the 64th listing took the pool's last thread, no timer ran, and the reads came back only
    /// when the listings gave up at 30 s.
    @Test func listingsThatNeverAnswerLeaveEveryDeadlineOnTime() async {
        let root = "/dataless-threads/never"
        let count = 70
        let reads = FileSyncManager.DatalessFolderReads(deadline: .milliseconds(250), maxReadsOut: count)
        let counts = Counts()
        let hold = DispatchSemaphore(value: 0)

        let answers = await withTaskGroup(of: Bool?.self) { group in
            for i in 0..<count {
                group.addTask { await reads.read("\(root)/\(i)", Self.listing(counts, hold)) }
            }
            var answers: [Bool?] = []
            for await answer in group { answers.append(answer) }
            return answers
        }

        #expect(answers.count == count)
        #expect(answers.allSatisfy { $0 == nil }, "a folder that never answered was given an answer")
        #expect(counts.returned == 0,
                "\(counts.returned) listing(s) came back before the reads did — the verdicts waited for the listings to give up, not for their deadline")
        await Self.waitFor("only \(counts.started) of \(count) listings were asked — the rest are waiting for a thread") {
            counts.started == count
        }
        #expect(reads.unansweredPaths().count == count)

        for _ in 0..<count { hold.signal() }
        await Self.waitFor("the listings came back once let go") {
            (0..<count).allSatisfy { !reads.isOutstanding("\(root)/\($0)") }
        }
        #expect(counts.returned == count)
    }

    /// Past `maxReadsOut` a read waits for a thread, and its deadline still calls it unanswered,
    /// saying it was never asked rather than blaming the provider. Its listing runs as soon as one
    /// out comes back.
    @MainActor
    @Test func pastItsCapAReadWaitsForAThreadAndSaysItWasNotAsked() async {
        let root = "/dataless-threads/cap"
        let reads = FileSyncManager.DatalessFolderReads(deadline: .milliseconds(250), maxReadsOut: 2)
        let counts = Counts()
        let hold = DispatchSemaphore(value: 0)
        let log = LogCapture()

        let first = Task { await reads.read("\(root)/0", Self.listing(counts, hold)) }
        let second = Task { await reads.read("\(root)/1", Self.listing(counts, hold)) }
        await Self.waitFor("the first two listings were never asked") { counts.started == 2 }

        let third = await reads.read("\(root)/2", Self.listing(counts, hold))
        #expect(third == nil, "a folder never asked was given an answer")
        #expect(counts.started == 2, "a third listing was asked past the cap of 2")
        #expect(await log.holds(.warning, containing: "“\(root)/2” was not asked in 250 ms"))
        #expect(!(await log.holds(containing: "“\(root)/2” did not answer")),
                "a folder never asked was blamed on its provider")
        #expect(await first.value == nil)
        #expect(await second.value == nil)

        // One comes back, and its thread goes to the waiting listing.
        hold.signal()
        await Self.waitFor("the waiting listing was not asked once a thread came back") { counts.started == 3 }
        hold.signal(); hold.signal()
        await Self.waitFor("every listing came back once let go") {
            (0..<3).allSatisfy { !reads.isOutstanding("\(root)/\($0)") }
        }
        #expect(counts.returned == 3)
    }

    /// A folder forgotten while its listing waits for a thread is not asked later behind the
    /// fresh read a new walk starts: one read per folder, still.
    @Test func aForgottenReadWaitingForAThreadIsNotAskedLater() async {
        let root = "/dataless-threads/forget"
        let reads = FileSyncManager.DatalessFolderReads(deadline: .milliseconds(250), maxReadsOut: 1)
        let counts = Counts()
        let hold = DispatchSemaphore(value: 0)

        let first = Task { await reads.read("\(root)/0", Self.listing(counts, hold)) }
        await Self.waitFor("the first listing was never asked") { counts.started == 1 }
        #expect(await reads.read("\(root)/1", Self.listing(counts, hold)) == nil)
        #expect(reads.forgetUnanswered(under: ["\(root)/1"]) == 1)
        #expect(await first.value == nil)

        hold.signal()
        await Self.waitFor("the first listing came back once let go") { !reads.isOutstanding("\(root)/0") }
        // Give a wrongly kept listing the thread that just came back to start on.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(counts.started == 1, "the forgotten folder's listing was asked after it was forgotten")
        #expect(!reads.isOutstanding("\(root)/1"))
    }
}
