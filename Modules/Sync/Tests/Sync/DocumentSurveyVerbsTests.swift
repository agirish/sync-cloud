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
}
