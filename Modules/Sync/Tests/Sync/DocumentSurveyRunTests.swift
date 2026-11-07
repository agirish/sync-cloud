import Foundation
import Testing
@testable import Sync

/// The survey's state machine, driven entirely from injected closures — no `FileSyncManager`, no
/// display, no thermal sensor, no PDF.
///
/// Nothing here races a clock. `now` is injected and `whilePaused` is the seam a test uses to
/// change the world between polls, so a pause that clears "after two ticks" is two calls, not two
/// sleeps (`docs/flaky-tests.md`, "Tests racing a real-time window").
@Suite struct DocumentSurveyRunTests {

    // MARK: Fixtures

    private func makeDir() throws -> URL { try makeProfilesDir(prefix: "survey-run") }

    private let root = URL(fileURLWithPath: "/tree")

    private func plan(_ n: Int) -> [String] {
        (0..<n).map { "Folder\($0 / 10)/doc\($0).pdf" }
    }

    private func stamps(for plan: [String]) -> [String: FilingSurvey.Stamp] {
        var out: [String: FilingSurvey.Stamp] = [:]
        for (i, path) in plan.enumerated() {
            out[path] = FilingSurvey.Stamp(size: 100 + i, modified: 1_700_000_000 + i)
        }
        return out
    }

    /// Text that survives `FilingSurvey.isDecodable`: enough ordinary words not to read as glyph
    /// soup, as a short "abc" fixture would.
    private let readableText = "chase bank statement account summary for the period ending march"

    /// A mutable clock and counter the closures can share. `@unchecked Sendable` with a lock, since
    /// the environment's closures are `@Sendable` and the actor calls them from its own isolation.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _reads: [String] = []
        private var _published: [DocumentSurveyProgress] = []
        private var _clock = Date(timeIntervalSince1970: 1_700_000_000)
        private var _pauseTicks = 0

        var reads: [String] { lock.withLock { _reads } }
        var published: [DocumentSurveyProgress] { lock.withLock { _published } }
        var pauseTicks: Int { lock.withLock { _pauseTicks } }
        var now: Date { lock.withLock { _clock } }

        func recordRead(_ path: String, seconds: TimeInterval) {
            lock.withLock { _reads.append(path); _clock = _clock.addingTimeInterval(seconds) }
        }
        func recordPublish(_ p: DocumentSurveyProgress) { lock.withLock { _published.append(p) } }
        func tickPause(_ seconds: TimeInterval) {
            lock.withLock { _pauseTicks += 1; _clock = _clock.addingTimeInterval(seconds) }
        }
    }

    /// Lets a closure reach the run built with it, so "pause, then unpause from inside the pause
    /// loop" is deterministic instead of racing a task.
    private final class Holder: @unchecked Sendable {
        private let lock = NSLock()
        private var _run: DocumentSurveyRun?
        var run: DocumentSurveyRun? {
            get { lock.withLock { _run } }
            set { lock.withLock { _run = newValue } }
        }
    }

    /// An environment that reads every document successfully, one second apiece.
    private func environment(_ recorder: Recorder,
                             secondsPerRead: TimeInterval = 1,
                             text: String? = nil,
                             isAvailable: @escaping @Sendable (String) -> Bool = { _ in true },
                             shouldPause: @escaping @Sendable () -> DocumentSurveyPause? = { nil },
                             whilePaused: (@Sendable () async -> Void)? = nil)
    -> DocumentSurveyRun.Environment {
        let body = text ?? readableText
        return DocumentSurveyRun.Environment(
            readDocument: { path in
                recorder.recordRead(path, seconds: secondsPerRead)
                return body
            },
            isAvailable: isAvailable,
            shouldPause: shouldPause,
            whilePaused: whilePaused ?? { recorder.tickPause(60) },
            now: { recorder.now },
            publish: { recorder.recordPublish($0) })
    }

    // MARK: - The plain path

    @Test func itReadsEveryDocumentInThePlanOnce() async {
        let recorder = Recorder()
        let paths = plan(30)
        let run = DocumentSurveyRun(profileId: "p", root: root, salt: "abcd", plan: paths,
                                    stamps: stamps(for: paths), environment: environment(recorder))

        let report = await run.run()

        #expect(recorder.reads.count == 30)
        #expect(Set(recorder.reads).count == 30, "a document was read twice")
        #expect(report.documentsRead == 30)
        #expect(report.documentsBlank == 0)
        #expect(report.documentsUnavailable == 0)
        #expect(report.isComplete)
        #expect(report.stoppedAt == nil)
        #expect(report.read.count == 30)
    }

    /// The reads follow the plan's order. The plan is built shallowest-first so a person watching a
    /// counter sees the tree progress in a way they recognise; reading it out of order would make
    /// the *reading Health/Medical/Kaiser* line jump about.
    @Test func itReadsInThePlansOrder() async {
        let recorder = Recorder()
        let paths = plan(12)
        let run = DocumentSurveyRun(profileId: "p", root: root, salt: "abcd", plan: paths,
                                    stamps: stamps(for: paths), environment: environment(recorder))
        _ = await run.run()
        #expect(recorder.reads == paths.map { root.appendingPathComponent($0).path })
    }

    /// The page is this long to survive `FilingSurvey.isDecodable`, which wants eight words of
    /// three-plus letters before it believes text is words: a PDF whose fonts lack a `ToUnicode`
    /// map extracts nonsense, which must not become a folder's anchors. A four-word fixture is
    /// rightly rejected.
    @Test func tokensAreDerivedAndSalted() async {
        let recorder = Recorder()
        let paths = plan(1)
        let page = "chase bank statement for the account ending march with invoice ACCT99182 total due"
        let run = DocumentSurveyRun(profileId: "p", root: root, salt: "abcd", plan: paths,
                                    stamps: stamps(for: paths),
                                    environment: environment(recorder, text: page))
        let report = await run.run()

        let doc = report.read[paths[0]]
        #expect(doc?.anchors.contains("chase") == true, "ordinary words are kept as themselves")
        #expect(doc?.anchors.contains("acct99182") == false,
                "a digit-bearing token was kept as a readable anchor")
        #expect(doc?.idHashes.count == 1, "the digit-bearing token was not hashed")
        #expect(doc?.isBlank == false)
    }

    /// Two runs over the same page under different salts produce different hashes. That is why
    /// `resumes(profileId:rootPath:salt:)` refuses a cross-salt resume.
    @Test func aDifferentSaltProducesDifferentHashes() async {
        let page = "chase bank statement for the account ending march with invoice ACCT99182 total due"
        func hashes(salt: String) async -> [String] {
            let paths = plan(1)
            let run = DocumentSurveyRun(profileId: "p", root: root, salt: salt, plan: paths,
                                        stamps: stamps(for: paths),
                                        environment: environment(Recorder(), text: page))
            return await run.run().read[paths[0]]?.idHashes ?? []
        }
        let a = await hashes(salt: "abcd")
        let b = await hashes(salt: "0000")
        #expect(!a.isEmpty)
        #expect(a != b, """
                the salt does not reach the hash — a cross-salt resume would be harmless, and the \
                refusal that prevents one would be superstition
                """)
    }

    // MARK: - Availability

    /// Not-downloaded documents are counted and **not stamped** — a later survey reads them.
    @Test func anUnavailableDocumentIsCountedNotStamped() async {
        let recorder = Recorder()
        let paths = plan(10)
        let offline = Set(paths.prefix(3).map { root.appendingPathComponent($0).path })
        let run = DocumentSurveyRun(
            profileId: "p", root: root, salt: "abcd", plan: paths, stamps: stamps(for: paths),
            environment: environment(recorder, isAvailable: { !offline.contains($0) }))

        let report = await run.run()

        #expect(report.documentsUnavailable == 3)
        #expect(report.documentsRead == 7)
        #expect(recorder.reads.count == 7, """
                an unavailable document was opened anyway — that is what downloads the user's \
                offloaded library
                """)
        #expect(report.isComplete, "unavailable documents still count as decided")
    }

    /// Availability is asked before the read, but a provider can evict the file mid-read, which
    /// then yields "". Stamping that blank would be permanent (the stamp is keyed on size and
    /// mtime, which don't move when the content returns), so a re-ask decides between "read and
    /// empty" and "no longer there".
    @Test func aDocumentEvictedMidReadIsNotStampedBlank() async {
        let recorder = Recorder()
        let paths = plan(4)
        let victim = root.appendingPathComponent(paths[1]).path
        // Available on the pre-read ask, gone on the post-blank re-ask.
        final class Asks: @unchecked Sendable {
            let lock = NSLock(); var seen: [String: Int] = [:]
            func bump(_ p: String) -> Int { lock.withLock { seen[p, default: 0] += 1; return seen[p]! } }
        }
        let asks = Asks()
        let run = DocumentSurveyRun(
            profileId: "p", root: root, salt: "abcd", plan: paths, stamps: stamps(for: paths),
            environment: environment(recorder, text: "", isAvailable: { path in
                guard path == victim else { return true }
                return asks.bump(path) == 1
            }))

        let report = await run.run()

        #expect(report.read[paths[1]] == nil, "an evicted document was stamped blank, permanently")
        #expect(report.documentsUnavailable == 1)
        // The other three really are empty and are stamped blank: the distinction this test is
        // about.
        #expect(report.read[paths[0]]?.isBlank == true)
        #expect(report.documentsBlank == 3)
    }

    /// A document that yields nothing but is still on disk is stamped blank, so it is never opened
    /// again. Without this a folder of scans is re-read on every future survey.
    @Test func anEmptyReadOnAPresentFileIsStampedBlank() async {
        let recorder = Recorder()
        let paths = plan(5)
        let run = DocumentSurveyRun(profileId: "p", root: root, salt: "abcd", plan: paths,
                                    stamps: stamps(for: paths),
                                    environment: environment(recorder, text: ""))
        let report = await run.run()
        #expect(report.documentsBlank == 5)
        #expect(report.documentsRead == 5)
        #expect(report.documentsUnavailable == 0)
    }

    // MARK: - Pausing

    @Test func theUsersPauseSuspendsAndResumeCarriesOn() async {
        let recorder = Recorder()
        let paths = plan(6)
        let holder = Holder()
        // Unpauses from inside the pause loop, on the third poll, so the assertion below shows the
        // loop really suspended rather than reading a flag once.
        final class Ticks: @unchecked Sendable {
            let lock = NSLock(); var n = 0
            func bump() -> Int { lock.withLock { n += 1; return n } }
            var count: Int { lock.withLock { n } }
        }
        let ticks = Ticks()
        let run = DocumentSurveyRun(
            profileId: "p", root: root, salt: "abcd", plan: paths, stamps: stamps(for: paths),
            environment: environment(recorder, whilePaused: {
                recorder.tickPause(60)
                if ticks.bump() >= 3 { await holder.run?.resume() }
            }))
        holder.run = run

        await run.pause()
        let report = await run.run()

        #expect(ticks.count >= 3, "Pause did not suspend the loop — it read the flag and carried on")
        #expect(report.documentsRead == 6, "the run ended on a pause instead of resuming")
        #expect(report.isComplete)
        let paused = recorder.published.filter(\.isPaused)
        #expect(paused.allSatisfy { $0.pause == .user })
    }

    /// An environmental pause suspends and clears itself; the run carries on rather than ending.
    @Test func anEnvironmentalPauseSuspendsAndThenClears() async {
        let recorder = Recorder()
        let paths = plan(8)
        final class Signal: @unchecked Sendable {
            let lock = NSLock(); var polls = 0; var clearAfter: Int
            init(clearAfter: Int) { self.clearAfter = clearAfter }
            func read() -> DocumentSurveyPause? {
                lock.withLock { polls < clearAfter ? .displayAsleep : nil }
            }
            func tick() { lock.withLock { polls += 1 } }
        }
        let signal = Signal(clearAfter: 3)
        let run = DocumentSurveyRun(
            profileId: "p", root: root, salt: "abcd", plan: paths, stamps: stamps(for: paths),
            environment: environment(recorder,
                                     shouldPause: { signal.read() },
                                     whilePaused: { signal.tick(); recorder.tickPause(60) }))

        let report = await run.run()

        #expect(signal.polls >= 3, "the pause never actually suspended")
        #expect(report.documentsRead == 8, "the run ended on a pause instead of waiting it out")
        #expect(report.isComplete)
        let paused = recorder.published.filter(\.isPaused)
        #expect(!paused.isEmpty, "a pause was never published, so no card could show it")
        #expect(paused.allSatisfy { $0.pause == .displayAsleep })
    }

    /// The user's own Pause wins over an environmental reason: a card explaining away a button the
    /// person just pressed reads as the app arguing with them.
    @Test func theUsersPauseOutranksAnEnvironmentalOne() async {
        let recorder = Recorder()
        let paths = plan(3)
        let holder = Holder()
        let run = DocumentSurveyRun(
            profileId: "p", root: root, salt: "abcd", plan: paths, stamps: stamps(for: paths),
            environment: environment(recorder,
                                     shouldPause: { .thermal },
                                     whilePaused: {
                                         recorder.tickPause(60)
                                         // Ends the run from inside the pause, so the test cannot
                                         // hang on a reason that never clears.
                                         await holder.run?.stop()
                                     }))
        holder.run = run
        await run.pause()

        let report = await run.run()

        let paused = recorder.published.filter(\.isPaused)
        #expect(paused.first?.pause == .user,
                "an environmental reason was shown over the Pause the person just pressed")
        #expect(!report.isComplete)
    }

    // MARK: - Stopping

    @Test func stoppingEndsTheRunAndReportsWhere() async {
        let recorder = Recorder()
        let paths = plan(20)
        let dir = try? makeDir()
        defer { if let dir { try? FileManager.default.removeItem(at: dir) } }

        let run = DocumentSurveyRun(profileId: "p", root: root, salt: "abcd", plan: paths,
                                    stamps: stamps(for: paths), environment: environment(recorder),
                                    directory: dir, checkpointEvery: 5)
        await run.stop()
        let report = await run.run()

        #expect(report.stoppedAt == 0)
        #expect(!report.isComplete)
        #expect(report.documentsRead == 0)
    }

    // MARK: - Checkpointing and resuming

    @Test func itCheckpointsAsItGoesAndTheCheckpointIsNotACorpus() async throws {
        let recorder = Recorder()
        let paths = plan(20)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let run = DocumentSurveyRun(profileId: "p", root: root, salt: "abcd", plan: paths,
                                    stamps: stamps(for: paths), environment: environment(recorder),
                                    directory: dir, checkpointEvery: 5)
        _ = await run.run()

        guard case .loaded(let checkpoint) = DocumentSurveyCheckpointStore.read(id: "p", in: dir) else {
            Issue.record("nothing was checkpointed")
            return
        }
        #expect(checkpoint.progress == (20, 20))
        // The checkpoint invariant, where a run could break it: reading documents must never make
        // the corpus reader see anything.
        #expect(FilingSurveyStore.corpus(id: "p", in: dir) == nil)
    }

    /// The resume, end to end: a run stops half way, then a fresh run over the same plan adopts the
    /// checkpoint and reads only what the first didn't, so every document is read exactly once.
    @Test func aResumedRunReadsOnlyWhatIsLeft() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = plan(20)
        let stampMap = stamps(for: paths)

        // Stop after exactly 7 documents, from inside the read closure: deterministic, where a task
        // that stops "after a while" races and fails on a busy machine.
        let firstRecorder = Recorder()
        let holder = Holder()
        let first = DocumentSurveyRun(
            profileId: "p", root: root, salt: "abcd", plan: paths, stamps: stampMap,
            environment: DocumentSurveyRun.Environment(
                readDocument: { path in
                    firstRecorder.recordRead(path, seconds: 1)
                    if firstRecorder.reads.count >= 7 { await holder.run?.stop() }
                    return self.readableText
                },
                now: { firstRecorder.now },
                publish: { firstRecorder.recordPublish($0) }),
            directory: dir, checkpointEvery: 2)
        holder.run = first

        let firstReport = await first.run()
        let stoppedAt = try #require(firstReport.stoppedAt,
                                     "the first run finished; it cannot demonstrate a resume")
        #expect(stoppedAt == 7)

        let secondRecorder = Recorder()
        let second = DocumentSurveyRun(profileId: "p", root: root, salt: "abcd", plan: paths,
                                       stamps: stampMap, environment: environment(secondRecorder),
                                       directory: dir, checkpointEvery: 2)
        #expect(await second.adoptCheckpoint() == nil)
        let secondReport = await second.run()

        #expect(secondReport.isComplete)
        #expect(secondReport.read.count == 20, "the resumed run lost what the first had read")
        // No document was opened twice across the two runs.
        let opened = firstRecorder.reads + secondRecorder.reads
        #expect(opened.count == 20, "\(opened.count) reads for 20 documents — work was repeated")
        #expect(Set(opened).count == 20)
    }

    @Test func aCheckpointForAnotherRunIsRefusedNotMerged() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = plan(5)

        try DocumentSurveyCheckpointStore.write(
            DocumentSurveyCheckpoint(profileId: "p", rootPath: "/somewhere/else", salt: "abcd",
                                     plan: paths, nextIndex: 3, read: [:],
                                     startedAt: Date(), updatedAt: Date()),
            id: "p", in: dir)

        let run = DocumentSurveyRun(profileId: "p", root: root, salt: "abcd", plan: paths,
                                    stamps: stamps(for: paths), environment: environment(Recorder()),
                                    directory: dir)
        #expect(await run.adoptCheckpoint() == .checkpointIsForAnotherRun)
        // And it did not adopt anything: the run still has the whole plan to do.
        #expect(await run.resumableProgress == (0, 5))
    }

    @Test func anUnreadableCheckpointIsRefusedRatherThanRestarted() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{ not json".utf8)
            .write(to: DocumentSurveyCheckpointStore.url(id: "p", in: dir))
        let paths = plan(5)
        let run = DocumentSurveyRun(profileId: "p", root: root, salt: "abcd", plan: paths,
                                    stamps: stamps(for: paths), environment: environment(Recorder()),
                                    directory: dir)
        #expect(await run.adoptCheckpoint() == .checkpointUnreadable)
    }

    @Test func noCheckpointIsAnOrdinaryFirstRun() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = plan(5)
        let run = DocumentSurveyRun(profileId: "p", root: root, salt: "abcd", plan: paths,
                                    stamps: stamps(for: paths), environment: environment(Recorder()),
                                    directory: dir)
        #expect(await run.adoptCheckpoint() == nil)
    }

    /// A run with nowhere to keep progress still runs, with no resume, rather than refusing: right
    /// for a preview or a test host.
    @Test func aRunWithNoDirectoryStillRuns() async {
        let recorder = Recorder()
        let paths = plan(4)
        let run = DocumentSurveyRun(profileId: "p", root: root, salt: "abcd", plan: paths,
                                    stamps: stamps(for: paths), environment: environment(recorder))
        #expect(await run.adoptCheckpoint() == nil)
        let report = await run.run()
        #expect(report.documentsRead == 4)
    }

    // MARK: - Publishing

    /// Progress publication is gated: each publish re-evaluates the window's root view, so
    /// publishing per document re-renders it once per document.
    @Test func progressPublicationIsBounded() async {
        let recorder = Recorder()
        let paths = plan(1000)
        let run = DocumentSurveyRun(profileId: "p", root: root, salt: "abcd", plan: paths,
                                    stamps: stamps(for: paths), environment: environment(recorder))
        _ = await run.run()

        let reading = recorder.published.filter { if case .reading = $0.phase { return true } else { return false } }
        #expect(reading.count <= 110,
                "\(reading.count) reading publications for 1,000 documents — the gate is not gating")
        #expect(reading.count > 50, "\(reading.count) publications is too few to animate a bar")
    }

    @Test func itPublishesAFinishingPhaseAtTheEnd() async {
        let recorder = Recorder()
        let paths = plan(5)
        let run = DocumentSurveyRun(profileId: "p", root: root, salt: "abcd", plan: paths,
                                    stamps: stamps(for: paths), environment: environment(recorder))
        _ = await run.run()
        #expect(recorder.published.last?.phase == .finishing,
                "a card reporting 5 of 5 and then sitting there looks hung")
    }

    /// A stopped run does not claim to be finishing: there is nothing to merge.
    @Test func aStoppedRunDoesNotClaimToBeFinishing() async {
        let recorder = Recorder()
        let paths = plan(5)
        let run = DocumentSurveyRun(profileId: "p", root: root, salt: "abcd", plan: paths,
                                    stamps: stamps(for: paths), environment: environment(recorder))
        await run.stop()
        _ = await run.run()
        #expect(recorder.published.last?.phase != .finishing)
    }

    @Test func theCurrentFolderIsNamedForTheCard() async {
        let recorder = Recorder()
        let paths = plan(200)
        let run = DocumentSurveyRun(profileId: "p", root: root, salt: "abcd", plan: paths,
                                    stamps: stamps(for: paths), environment: environment(recorder))
        _ = await run.run()
        let named = recorder.published.compactMap(\.currentFolder)
        #expect(!named.isEmpty, "no publication named a folder — the card's reading line is blank")
        #expect(named.allSatisfy { $0.hasPrefix("Folder") })
    }
}
