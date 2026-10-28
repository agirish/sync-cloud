import Foundation
import Testing
import Events
import EventsTestSupport
@testable import Sync

/// **The two survey verbs that did not do what they said**, driven through the manager the card
/// calls — `FilingResurveyTests.makeTree()`'s four documents and profile `t`.
///
/// *Resume now* sat beside "Resumes on its own" and cleared only the person's own Pause, which was
/// not set: the next poll asked the machine again and the survey stayed paused. *Start over* ran
/// the start path, which adopts the progress on disk — so it resumed, exactly as Resume did.
///
/// The pause polls once a second (`documentSurveyEnvironment`'s `whilePaused`), so the waits here
/// are bounded deadlines on a condition, never sleeps that decide the verdict
/// (`docs/flaky-tests.md`, "Tests racing a real-time window").
@Suite @MainActor struct DocumentSurveyVerbsTests {

    /// Polls `condition` until it holds or `seconds` pass, and says which.
    private func waitUntil(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// The run, in a task the test can wait on with a deadline — a run that never resumes must
    /// fail here, not hang the suite.
    private final class Running {
        var finished = false
        var task: Task<Void, Never>?
    }

    private func start(_ manager: FileSyncManager,
                       _ plan: FileSyncManager.DocumentSurveyPlan) -> Running {
        let running = Running()
        running.task = Task { @MainActor in
            _ = await manager.runDocumentSurvey(plan: plan)
            running.finished = true
        }
        return running
    }

    /// Ends a run left paused, so a failing case cleans up after itself.
    private func finish(_ manager: FileSyncManager, _ running: Running) async {
        await manager.stopDocumentSurvey()
        await running.task?.value
    }

    // MARK: - Resume now

    /// **The bug, as the person met it:** paused because the Mac is running hot, *Resume now*
    /// clicked — and nothing read. It now reads through the heat until the run is done.
    @Test func resumeNowReadsThroughAPauseTheMachineAskedFor() async throws {
        let (manager, docs, _, reads, root) = try FilingResurveyTests.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        manager.machineConditions = { MachineConditions(heat: .serious) }
        let plan = try await manager.planDocumentSurvey(root: docs).get()
        let running = start(manager, plan)

        let paused = await waitUntil(seconds: 20) { manager.documentSurveyProgress?.pause == .thermal }
        #expect(paused, "premise: the heat never paused the run, so the rest proves nothing")
        #expect(reads.paths.isEmpty, "premise: it read while paused")

        await manager.resumeDocumentSurvey()

        let done = await waitUntil(seconds: 20) { running.finished }
        #expect(done, "Resume now left the survey paused — the Mac is still hot, and it waited")
        #expect(reads.paths.count == plan.total)
        await finish(manager, running)
    }

    /// **A cause that was not in force at the click still pauses.** The waiver is for what the
    /// person saw — a display that sleeps afterwards stops the reading as it always did.
    @Test func resumeNowDoesNotWaiveACauseThatArrivesLater() async throws {
        let (manager, docs, _, _, root) = try FilingResurveyTests.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        final class Machine { var now = MachineConditions(lowPowerMode: true) }
        let machine = Machine()
        manager.machineConditions = { machine.now }
        let plan = try await manager.planDocumentSurvey(root: docs).get()
        let running = start(manager, plan)
        #expect(await waitUntil(seconds: 20) { manager.documentSurveyProgress?.pause == .lowPower })

        await manager.resumeDocumentSurvey()
        // Before the next poll: Low Power Mode stays on and the display goes to sleep.
        machine.now = MachineConditions(displayAsleep: true, lowPowerMode: true)

        let pausedAgain = await waitUntil(seconds: 20) {
            manager.documentSurveyProgress?.pause == .displayAsleep
        }
        #expect(pausedAgain, "a sleeping display was read through on a waiver given for Low Power Mode")
        #expect(!running.finished)
        await finish(manager, running)
    }

    /// **Resume after the person's own Pause undoes that Pause and nothing more.** A machine reason
    /// standing behind it was never on the card, so it is not waived on their behalf — the card
    /// now shows it, with its own *Resume now*.
    @Test func resumeAfterAPauseDoesNotWaiveTheMachinesReason() async throws {
        let (manager, docs, _, reads, root) = try FilingResurveyTests.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        manager.machineConditions = { MachineConditions(heat: .critical) }
        let plan = try await manager.planDocumentSurvey(root: docs).get()
        let running = start(manager, plan)
        #expect(await waitUntil(seconds: 20) { manager.documentSurveyProgress?.pause == .thermal })
        await manager.pauseDocumentSurvey()
        #expect(await waitUntil(seconds: 20) { manager.documentSurveyProgress?.pause == .user })

        await manager.resumeDocumentSurvey()

        #expect(await waitUntil(seconds: 20) { manager.documentSurveyProgress?.pause == .thermal },
                "Resume after Pause did not hand the card back to the heat")
        #expect(reads.paths.isEmpty, "the heat was waived by a click that only undid a Pause")
        await finish(manager, running)
    }

    // MARK: - Start over

    /// A checkpoint two documents into `plan`, as an interrupted first sitting leaves it.
    private func interrupt(_ plan: FileSyncManager.DocumentSurveyPlan, docs: URL,
                           profiles: URL) throws {
        var read: [String: FilingCorpusDocument] = [:]
        for path in plan.paths.prefix(2) {
            read[path] = FilingSurvey.document(fromPage1: FilingResurveyTests.page("Read before"),
                                               stamp: try #require(plan.stamps[path]),
                                               salt: plan.salt)
        }
        try DocumentSurveyCheckpointStore.write(
            DocumentSurveyCheckpoint(profileId: plan.profileId, rootPath: docs.path, salt: plan.salt,
                                     plan: plan.paths, nextIndex: 2, read: read,
                                     startedAt: Date(), updatedAt: Date()),
            id: plan.profileId, in: profiles)
    }

    /// **Start over reads every document again**, where the start path alone — what the button
    /// ran — adopts the progress and opens only the two left. Both halves here, so the control
    /// shows the fixture really is resumable.
    @Test func startOverReadsEveryDocumentAgain() async throws {
        let (manager, docs, profiles, reads, root) = try FilingResurveyTests.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await manager.planDocumentSurvey(root: docs).get()
        try #require(plan.total == 4)

        // The control: carrying on opens only what is left.
        try interrupt(plan, docs: docs, profiles: profiles)
        #expect(manager.resumableDocumentSurvey(root: docs)?.done == 2, "premise: nothing to resume")
        _ = try await manager.runDocumentSurvey(plan: plan).get()
        #expect(reads.paths.count == 2, "premise: the start path did not resume the progress")

        // Interrupted again, then started over.
        try FileManager.default.removeItem(at: profiles.appendingPathComponent("t/filing-corpus.json"))
        try FileManager.default.removeItem(at: profiles.appendingPathComponent("t/filing-memory.json"))
        try interrupt(plan, docs: docs, profiles: profiles)
        reads.reset()
        let log = LogCapture()

        let report = try await manager.runDocumentSurvey(plan: plan, startingOver: true).get()

        #expect(Set(reads.paths) == Set(plan.paths.map { docs.appendingPathComponent($0).path }),
                "Start over opened \(reads.paths.count) of \(plan.total) — it resumed")
        #expect(report.isComplete)
        #expect(await log.holds(.info, containing: "Document survey: starting over — discarded "
                                + "progress at 2 of 4"))
    }

    /// **Progress that cannot be removed starts nothing**, since a run started beside it would
    /// adopt it — resuming, the thing not asked for. A directory where the file should be cannot
    /// be removed as one.
    @Test func startOverThatCannotClearTheProgressStartsNothing() async throws {
        let (manager, docs, profiles, reads, root) = try FilingResurveyTests.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await manager.planDocumentSurvey(root: docs).get()
        try interrupt(plan, docs: docs, profiles: profiles)
        let profileDir = profiles.appendingPathComponent("t")
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: profileDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: profileDir.path) }

        let result = await manager.runDocumentSurvey(plan: plan, startingOver: true)

        #expect(result == .failure(.couldNotDiscardProgress))
        #expect(reads.paths.isEmpty, "started — and so resumed — beside progress it could not clear")
    }

    // MARK: - A profile written while a reading runs (review M4)

    /// **A stop made for a new profile waits for the run to end, and keeps what it read.** Setup's
    /// Save writes the new profile straight after, and that write carries the progress across — so
    /// the run must be over, its progress on disk, before the call returns.
    @Test func aStopForANewProfileWaitsForTheRunToEnd() async throws {
        let (manager, docs, _, reads, root) = try FilingResurveyTests.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        // Hot once two documents are read, so the run stands paused with progress behind it.
        manager.machineConditions = {
            MachineConditions(heat: reads.paths.count >= 2 ? .serious : .nominal)
        }
        let plan = try await manager.planDocumentSurvey(root: docs).get()
        let result = Task { @MainActor in await manager.runDocumentSurvey(plan: plan) }
        #expect(await waitUntil(seconds: 20) { manager.documentSurveyProgress?.pause == .thermal },
                "premise: the run never paused, so the rest proves nothing")

        let stopped = await manager.stopDocumentSurveyBeforeReplacingProfile(savingFolder: docs)

        #expect(stopped == .stopped(plan.root), "a run stopped two documents in was reported as \(stopped)")
        #expect(manager.documentSurveyRun == nil,
                "the call returned with the run still going — the write after it copies stale progress")
        let answered = await result.value
        #expect(answered == .failure(.stoppedForNewProfile),
                "the stopped run answered \(answered) — a success puts “Stopped after …” on screen")
        #expect((manager.resumableDocumentSurvey(root: docs)?.done ?? 0) >= 2,
                "the progress was not on disk for the new profile to carry")
    }

    /// **Beside a hand-built profile nothing is stopped**: the write cannot replace it, so the
    /// reading of it is still the reading of the profile in use.
    @Test func aReadingOfAHandBuiltProfileIsNotStopped() async throws {
        let (manager, docs, profiles, _, root) = try FilingResurveyTests.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try FilingProfileStore.writeProfile(
            FolderProfile(profileId: "t", root: docs.path, folders: [:], personTokens: []),
            in: profiles, builtBy: "by hand")
        #expect(FilingProfileStore.activeProfileId(in: profiles) == "t", "premise: the hand-built one is active")
        manager.machineConditions = { MachineConditions(heat: .serious) }
        let plan = try await manager.planDocumentSurvey(root: docs).get()
        let running = start(manager, plan)
        #expect(await waitUntil(seconds: 20) { manager.documentSurveyProgress?.pause == .thermal })

        let stopped = await manager.stopDocumentSurveyBeforeReplacingProfile(savingFolder: docs)

        #expect(stopped == .nothingStopped, "a reading of the hand-built profile in use was stopped")
        #expect(manager.documentSurveyRun != nil)
        await finish(manager, running)
    }

    /// **A plan made for a profile since replaced is not run** — it would read into the old one.
    @Test func aPlanForAReplacedProfileIsNotRun() async throws {
        let (manager, docs, _, reads, root) = try FilingResurveyTests.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await manager.planDocumentSurvey(root: docs).get()
        // What Setup's Save and the attach after it leave behind.
        manager.filingProfileDirectoryId = "walk-later"

        let result = await manager.runDocumentSurvey(plan: plan)

        #expect(result == .failure(.profileReplaced))
        #expect(reads.paths.isEmpty, "the plan for profile \(plan.profileId) read into it")
    }

    /// **A reading the person paused carries on paused.** The run that carries it into the new
    /// profile started reading at once, through a Pause nobody took back.
    @Test func aReadingPausedByThePersonCarriesOnPaused() async throws {
        let (manager, docs, _, reads, root) = try FilingResurveyTests.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        final class Machine { var hot = true }
        let machine = Machine()
        manager.machineConditions = { MachineConditions(heat: machine.hot ? .serious : .nominal) }
        let plan = try await manager.planDocumentSurvey(root: docs).get()
        let first = start(manager, plan)
        #expect(await waitUntil(seconds: 20) { manager.documentSurveyProgress?.pause == .thermal })
        await manager.pauseDocumentSurvey()
        #expect(await waitUntil(seconds: 20) { manager.documentSurveyProgress?.pause == .user },
                "premise: the person's Pause never showed")

        #expect(await manager.stopDocumentSurveyBeforeReplacingProfile(savingFolder: docs) == .stopped(plan.root))
        await first.task?.value
        machine.hot = false
        let again = try await manager.planDocumentSurvey(root: docs).get()
        let carried = start(manager, again)

        // Asked of the new run itself: a progress value the stopped run published late reads the same.
        var heldByPause = false
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !carried.finished {
            if await manager.documentSurveyRun?.isPausedByUser == true { heldByPause = true; break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(heldByPause, "the carried reading did not keep the person's Pause (\(reads.paths.count) read)")
        #expect(reads.paths.isEmpty, "the carried reading read through the person's Pause")
        #expect(!carried.finished)
        await finish(manager, carried)

        // Taken by that run: the next one starts as any run does.
        let next = try await manager.planDocumentSurvey(root: docs).get()
        let report = try await manager.runDocumentSurvey(plan: next).get()
        #expect(report.isComplete, "a Pause carried once paused a later run too")
    }

    /// **Nothing is stopped while a reorganization lands**: the write refuses then, so the reading
    /// would stop for a Save that writes nothing, and its restart be refused for the same landing.
    @Test func aReadingIsNotStoppedForASaveALandingRefuses() async throws {
        let (manager, docs, _, _, root) = try FilingResurveyTests.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        manager.machineConditions = { MachineConditions(heat: .serious) }
        let plan = try await manager.planDocumentSurvey(root: docs).get()
        let running = start(manager, plan)
        #expect(await waitUntil(seconds: 20) { manager.documentSurveyProgress?.pause == .thermal })
        manager.restructureLandingInProgress = true

        let stopped = await manager.stopDocumentSurveyBeforeReplacingProfile(savingFolder: docs)

        #expect(stopped == .nothingStopped, "the reading was stopped for a Save the landing refuses")
        #expect(manager.documentSurveyRun != nil)
        manager.restructureLandingInProgress = false
        await finish(manager, running)
    }

    // MARK: - Review of the carry, 2026-10-27

    /// Stands a run paused by the person, and returns it.
    private func pausedByThePerson(_ manager: FileSyncManager, docs: URL) async throws -> Running {
        manager.machineConditions = { MachineConditions(heat: .serious) }
        let plan = try await manager.planDocumentSurvey(root: docs).get()
        let running = start(manager, plan)
        #expect(await waitUntil(seconds: 20) { manager.documentSurveyProgress?.pause == .thermal })
        await manager.pauseDocumentSurvey()
        #expect(await waitUntil(seconds: 20) { manager.documentSurveyProgress?.pause == .user })
        return running
    }

    /// **A Save of another folder carries no Pause forward.** The reading it stopped is not
    /// carried on, so a later run of that folder — Resume, Start over — started paused, and
    /// nobody had paused it.
    @Test(.timeLimit(.minutes(1)))
    func aSaveOfAnotherFolderCarriesNoPause() async throws {
        let (manager, docs, _, reads, root) = try FilingResurveyTests.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await pausedByThePerson(manager, docs: docs)
        let elsewhere = root.appendingPathComponent("Elsewhere")

        #expect(await manager.stopDocumentSurveyBeforeReplacingProfile(savingFolder: elsewhere)
                == .stopped(try #require(manager.documentSurveyFolder)))
        await first.task?.value
        manager.machineConditions = nil
        let plan = try await manager.planDocumentSurvey(root: docs).get()
        let report = try await manager.runDocumentSurvey(plan: plan).get()

        #expect(report.isComplete, "the later run started paused (\(reads.paths.count) read)")
    }

    /// **A carried Pause is taken by the next run to start, even one refused before it reads**,
    /// so it cannot wait for a later run nobody paused.
    @Test(.timeLimit(.minutes(1)))
    func aCarriedPauseIsTakenByARefusedRun() async throws {
        let (manager, docs, _, _, root) = try FilingResurveyTests.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await pausedByThePerson(manager, docs: docs)
        #expect(await manager.stopDocumentSurveyBeforeReplacingProfile(savingFolder: docs)
                == .stopped(try #require(manager.documentSurveyFolder)))
        await first.task?.value
        manager.machineConditions = nil
        let plan = try await manager.planDocumentSurvey(root: docs).get()

        let extractor = manager.filingSnippetExtractor
        manager.filingSnippetExtractor = nil
        #expect(await manager.runDocumentSurvey(plan: plan) == .failure(.noExtractor),
                "premise: the carried run is refused")
        manager.filingSnippetExtractor = extractor

        let report = try await manager.runDocumentSurvey(plan: plan).get()
        #expect(report.isComplete, "a Pause carried for a refused run paused the next one")
    }

    /// **The wait for a stop is bounded, and a run that outlasts it reads on.** A stop lands
    /// between documents; a document whose text never came held the Save — and the sheet, whose
    /// Back waits on it — for good.
    @Test(.timeLimit(.minutes(1)))
    func aStopThatDoesNotLandInTimeLeavesTheRunReading() async throws {
        let (manager, docs, _, reads, root) = try FilingResurveyTests.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        final class Gate: @unchecked Sendable {
            private let lock = NSLock()
            private var _entered = false, _released = false
            var entered: Bool { lock.lock(); defer { lock.unlock() }; return _entered }
            var released: Bool { lock.lock(); defer { lock.unlock() }; return _released }
            func enter() { lock.lock(); _entered = true; lock.unlock() }
            func release() { lock.lock(); _released = true; lock.unlock() }
        }
        let gate = Gate()
        manager.filingSnippetExtractor = { path in
            reads.note(path)
            gate.enter()
            // Bounded: released by the test, or at the suite's own limit.
            let deadline = Date().addingTimeInterval(50)
            while !gate.released, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            return try? String(contentsOfFile: path, encoding: .utf8)
        }
        manager.documentSurveyStopWait = .milliseconds(300)
        let plan = try await manager.planDocumentSurvey(root: docs).get()
        let result = Task { @MainActor in await manager.runDocumentSurvey(plan: plan) }
        #expect(await waitUntil(seconds: 20) { gate.entered }, "premise: no document read began")

        let stopped = await manager.stopDocumentSurveyBeforeReplacingProfile(savingFolder: docs)

        #expect(stopped == .stillReading, "the wait answered \(stopped)")
        #expect(manager.documentSurveyRun != nil, "the run was let go")
        gate.release()
        let report = try await result.value.get()
        #expect(report.isComplete, "the stop was not withdrawn: the run ended at \(report.stoppedAt ?? -1)")
    }

    /// **A profile write is refused while the documents are being read into the profile it would
    /// replace.** A Refresh holds the survey's lifecycle with no run to stop, and it wrote what it
    /// learned into the replaced profile when it finished. Beside a hand-built profile the write
    /// replaces nothing, and goes ahead.
    @Test func aWriteIsRefusedWhileARefreshReadsIntoTheProfileItWouldReplace() async throws {
        let (manager, docs, profiles, _, root) = try FilingResurveyTests.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = await FileSyncManager.buildTree(url: docs, sortOption: .name)
        _ = manager.beginScan(\.filingSurveyLifecycle, status: "Looking for new folders…")

        let refused = await manager.writeWalkProfile(tree: tree, root: docs)

        guard case .failure(.documentsBeingRead) = refused else {
            Issue.record("the write over a running Refresh came to \(refused)")
            manager.endScan(\.filingSurveyLifecycle)
            return
        }
        #expect(FilingProfileStore.activeProfileId(in: profiles) == nil, "the refused write named a profile")

        // Beside a hand-built profile nothing is replaced.
        _ = try FilingProfileStore.writeProfile(
            FolderProfile(profileId: "t", root: docs.path, folders: [:], personTokens: []),
            in: profiles, builtBy: "by hand")
        let beside = await manager.writeWalkProfile(tree: tree, root: docs)
        guard case .success(let report) = beside else {
            Issue.record("a write beside a hand-built profile was refused: \(beside)")
            return
        }
        #expect(!report.becameActive)
        manager.endScan(\.filingSurveyLifecycle)
    }

    /// **A Save the moment a run starts finds it, and stops it before it reads.** The run took its
    /// handle only after adopting the checkpoint — an await — so a Save in between found no run to
    /// stop, and the run then read into the profile the Save replaced.
    @Test(.timeLimit(.minutes(1)))
    func aSaveAsARunStartsFindsItBeforeItReads() async throws {
        let (manager, docs, _, reads, root) = try FilingResurveyTests.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await manager.planDocumentSurvey(root: docs).get()
        let result = Task { @MainActor in await manager.runDocumentSurvey(plan: plan) }
        // The first moment the run is seen under way — inside its first await.
        let deadline = Date().addingTimeInterval(20)
        while !manager.filingSurveyLifecycle.isRunning, Date() < deadline { await Task.yield() }
        #expect(manager.filingSurveyLifecycle.isRunning, "premise: the run never started")

        let stopped = await manager.stopDocumentSurveyBeforeReplacingProfile(savingFolder: docs)

        #expect(stopped == .stopped(plan.root), "a Save as the run started found \(stopped)")
        #expect(await result.value == .failure(.stoppedForNewProfile))
        #expect(reads.paths.isEmpty, "the run read \(reads.paths.count) document(s) after the Save")
    }
}
