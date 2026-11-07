import Foundation
import Testing
@testable import Sync

/// Document-survey failures that would be silent: green suites, no log line. A survey that never
/// reads a document, a resume that can never resume, a card wrong about its own state, a summary
/// that understates the one number it exists to state, and a resume that skips work.
@Suite struct DocumentSurveyRegressionTests {

    private func makeDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("survey-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"),
                                                withIntermediateDirectories: true)
        return dir
    }

    private let root = URL(fileURLWithPath: "/tree")
    private let page = "chase bank statement for the account ending march with invoice ACCT99182 due"

    private func plan(_ n: Int) -> [String] { (0..<n).map { "F\($0 / 5)/doc\($0).pdf" } }

    private func stamps(_ paths: [String]) -> [String: FilingSurvey.Stamp] {
        var out: [String: FilingSurvey.Stamp] = [:]
        for (i, p) in paths.enumerated() { out[p] = .init(size: 10 + i, modified: 1_700_000_000 + i) }
        return out
    }

    // MARK: - 1. The survey must not stand aside for itself

    /// A deadlock: `runDocumentSurvey` holds `filingSurveyLifecycle` for its whole run (it is the
    /// survey's running flag), so if the yield conditions named that lifecycle, the survey would
    /// pause on its own flag at the first poll and never read a document. Asserted against the
    /// rule: conditions naming no scan produce no pause, and the driver must not name its own.
    @Test func aSurveyDoesNotYieldToItsOwnLifecycle() {
        // What the driver hands over while it holds `filingSurveyLifecycle`: no scan at all.
        #expect(DocumentSurveyYield.pause(for: .clear) == nil)
        // The deadlocking shape, so the assertion above isn't vacuous: if the driver's list named
        // "folder memory", this is the value it would build.
        let deadlocking = DocumentSurveyConditions(runningScans: ["folder memory"])
        #expect(DocumentSurveyYield.pause(for: deadlocking) == .yielding(to: "folder memory"),
                """
                the rule no longer pauses for a named scan — the deadlock's mechanism is gone, \
                and so is this test's subject
                """)
    }

    /// The driver's own list, read from source: it must not name the lifecycle it holds.
    ///
    /// A source scan because the list is built inside a `@MainActor` method over six published
    /// properties, and standing up a `FileSyncManager` here to read it back is a lot of machinery
    /// for one line.
    @Test func theDriverDoesNotNameTheLifecycleItHolds() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sync/FileSyncManager+DocumentSurvey.swift")
        let source = try #require(try? String(contentsOf: file, encoding: .utf8))
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        try #require(code.contains("func documentSurveyConditions"),
                     "the driver could not be read — this check would be vacuous")
        #expect(!code.contains("scans.append(\"folder memory\")"),
                """
                the survey names its own lifecycle among the scans it stands aside for. It holds \
                that lifecycle for its whole run, so it would pause on the first poll and never \
                read a document.
                """)
        // The positive control: the other five ARE named, so this is a scan of a real list.
        #expect(code.contains("scans.append(\"Duplicates\")"))
    }

    // MARK: - 2. A resume has to be able to resume

    /// A first survey has no corpus or memory, so its plan mints a random salt. A resume that
    /// minted a new one would never match the checkpoint, and `adoptCheckpoint` would refuse it as
    /// another run's. A checkpoint is adopted when the run carries its salt and refused when it
    /// doesn't; the driver's half is reading the checkpoint's salt before minting one.
    @Test func aRunCarryingTheCheckpointsSaltAdoptsIt() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = plan(10)
        try DocumentSurveyCheckpointStore.write(
            DocumentSurveyCheckpoint(profileId: "p", rootPath: root.path, salt: "SALT-A",
                                     plan: paths, nextIndex: 4, read: [:],
                                     startedAt: Date(), updatedAt: Date()),
            id: "p", in: dir)

        let carrying = DocumentSurveyRun(
            profileId: "p", root: root, salt: "SALT-A", plan: paths, stamps: stamps(paths),
            environment: .init(readDocument: { _ in nil }), directory: dir)
        #expect(await carrying.adoptCheckpoint() == nil)
        #expect(await carrying.resumableProgress == (4, 10))

        let fresh = DocumentSurveyRun(
            profileId: "p", root: root, salt: "SALT-B", plan: paths, stamps: stamps(paths),
            environment: .init(readDocument: { _ in nil }), directory: dir)
        #expect(await fresh.adoptCheckpoint() == .checkpointIsForAnotherRun,
                """
                a freshly minted salt still adopts a checkpoint written under another — the two \
                hash spaces would then be mixed in one corpus
                """)
    }

    /// The driver reads the checkpoint's salt before minting one: the other half of the rule. A
    /// first survey (`makeTree` has no corpus and no memory) planned beside an unfinished one for
    /// the same folder carries that run's salt; without the checkpoint it mints its own, so the
    /// salt below can only have come from the file.
    @MainActor @Test func thePlanPrefersAResumableCheckpointsSalt() async throws {
        let (manager, docs, profiles, _, root) = try FilingResurveyTests.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fresh = try await manager.planDocumentSurvey(root: docs).get()
        #expect(fresh.salt != "SALT-RESUME")

        try DocumentSurveyCheckpointStore.write(
            DocumentSurveyCheckpoint(profileId: "t", rootPath: fresh.root.path, salt: "SALT-RESUME",
                                     plan: fresh.paths, nextIndex: 1, read: [:],
                                     startedAt: Date(), updatedAt: Date()),
            id: "t", in: profiles)
        let resumed = try await manager.planDocumentSurvey(root: docs).get()
        #expect(resumed.salt == "SALT-RESUME", """
                the plan no longer consults the checkpoint's salt, so a first survey on a fresh \
                machine mints a new one every time and can never be resumed
                """)
    }

    // MARK: - 3. A card that says paused under a survey that is reading

    /// Progress is published the instant a pause clears, ahead of the gate. `ProgressPublishGate`
    /// admits on whole percent, so otherwise a resume publishes nothing until the next point (over
    /// a minute on a large run), and the card says "paused" over a survey that is reading.
    @Test func clearingAPausePublishesImmediately() async throws {
        final class Signal: @unchecked Sendable {
            let lock = NSLock(); var paused = true; var published: [DocumentSurveyProgress] = []
            func read() -> DocumentSurveyPause? { lock.withLock { paused ? .displayAsleep : nil } }
            func clear() { lock.withLock { paused = false } }
            func record(_ p: DocumentSurveyProgress) { lock.withLock { published.append(p) } }
            var all: [DocumentSurveyProgress] { lock.withLock { published } }
        }
        let signal = Signal()
        let paths = plan(300)
        let run = DocumentSurveyRun(
            profileId: "p", root: root, salt: "abcd", plan: paths, stamps: stamps(paths),
            environment: .init(readDocument: { _ in self.page },
                               shouldPause: { signal.read() },
                               whilePaused: { signal.clear() },
                               publish: { signal.record($0) }))
        _ = await run.run()

        // The publication right after the last paused one must be a reading one, and must arrive
        // while the count is still low — not 1% of 300 documents later.
        let states = signal.all
        guard let lastPausedIndex = states.lastIndex(where: \.isPaused) else {
            Issue.record("nothing was ever published as paused — the fixture did not pause")
            return
        }
        let next = states[(lastPausedIndex + 1)...].first
        #expect(next?.isPaused == false, "the card stayed paused after the pause cleared")
        #expect((next?.completed ?? .max) <= 1,
                """
                the first reading publication came \(next?.completed ?? -1) documents after the \
                resume — the card said paused all the way through them
                """)
    }

    /// A pause whose reason changes republishes; a steady one does not. Otherwise the card either
    /// keeps naming a cause that has passed ("paused while Duplicates runs" after the display went
    /// to sleep), or re-renders the window's root view on every poll, all night.
    @Test func aChangingPauseReasonRepublishesAndASteadyOneDoesNot() async {
        final class Signal: @unchecked Sendable {
            let lock = NSLock(); var ticks = 0; var published: [DocumentSurveyProgress] = []
            func read() -> DocumentSurveyPause? {
                lock.withLock {
                    if ticks < 3 { return .yielding(to: "Duplicates") }
                    if ticks < 6 { return .displayAsleep }
                    return nil
                }
            }
            func tick() { lock.withLock { ticks += 1 } }
            func record(_ p: DocumentSurveyProgress) { lock.withLock { published.append(p) } }
            var paused: [DocumentSurveyPause] { lock.withLock { published.compactMap(\.pause) } }
        }
        let signal = Signal()
        let paths = plan(4)
        let run = DocumentSurveyRun(
            profileId: "p", root: root, salt: "abcd", plan: paths, stamps: stamps(paths),
            environment: .init(readDocument: { _ in self.page },
                               shouldPause: { signal.read() },
                               whilePaused: { signal.tick() },
                               publish: { signal.record($0) }))
        _ = await run.run()

        let reasons = signal.paused
        #expect(reasons.contains(.yielding(to: "Duplicates")))
        #expect(reasons.contains(.displayAsleep), "a changed reason was never published")
        // Six polls, two distinct reasons — so at most a handful of publications, not one per poll.
        #expect(reasons.count <= 3,
                """
                \(reasons.count) pause publications for 2 reasons — a steady pause is \
                re-rendering the window on every poll
                """)
    }

    // MARK: - 4. The count the summary promises to be honest about

    /// The unavailable count survives a resume, as `read` does. Otherwise a resumed survey forgets
    /// the first sitting's not-downloaded documents, understating the very figure
    /// `DocumentSurveyReport.summary` exists to state.
    @Test func theUnavailableCountSurvivesAResume() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = plan(10)
        // Three were offline when the first sitting ran.
        try DocumentSurveyCheckpointStore.write(
            DocumentSurveyCheckpoint(profileId: "p", rootPath: root.path, salt: "abcd",
                                     plan: paths, nextIndex: 5, read: [:],
                                     documentsUnavailable: 3,
                                     startedAt: Date(), updatedAt: Date()),
            id: "p", in: dir)

        let run = DocumentSurveyRun(
            profileId: "p", root: root, salt: "abcd", plan: paths, stamps: stamps(paths),
            environment: .init(readDocument: { _ in self.page }), directory: dir)
        #expect(await run.adoptCheckpoint() == nil)
        let report = await run.run()

        #expect(report.documentsUnavailable == 3,
                "the first sitting's 3 not-downloaded documents were forgotten on resume")
        #expect(report.isComplete)
    }

    // MARK: - 5. An index means nothing against a plan it was not counted in

    /// `resumes(profileId:rootPath:salt:)` says whose run a checkpoint is, not whether the tree
    /// still holds the same documents. Between sittings files change, `documentsToRead` returns a
    /// different list, and the old index would point into it at random, skipping everything before
    /// and still reporting complete. The reads are worth keeping; the index is not. So a changed
    /// plan restarts the index and relies on the skip: every document in the new plan is read
    /// exactly once across both sittings.
    @Test func aChangedPlanRestartsTheIndexRatherThanTrustingIt() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The first sitting stopped at 4 of 10, under the plan as it was then.
        let before = plan(10)
        let alreadyRead = Dictionary(uniqueKeysWithValues: before.prefix(4).map {
            ($0, FilingSurvey.document(fromPage1: page, stamp: .init(size: 1, modified: 2), salt: "abcd"))
        })
        try DocumentSurveyCheckpointStore.write(
            DocumentSurveyCheckpoint(profileId: "p", rootPath: root.path, salt: "abcd",
                                     plan: before, nextIndex: 4, read: alreadyRead,
                                     startedAt: Date(), updatedAt: Date()),
            id: "p", in: dir)

        // The tree changed: three of the originals are gone and two are new.
        let after = Array(before.dropFirst(3)) + ["F9/new-a.pdf", "F9/new-b.pdf"]
        var stampMap = stamps(after)
        for (k, v) in stamps(before) where stampMap[k] == nil { stampMap[k] = v }

        final class Opened: @unchecked Sendable {
            let lock = NSLock(); var paths: [String] = []
            func note(_ p: String) { lock.withLock { paths.append(p) } }
            var all: [String] { lock.withLock { paths } }
        }
        let opened = Opened()
        let run = DocumentSurveyRun(
            profileId: "p", root: root, salt: "abcd", plan: after, stamps: stampMap,
            environment: .init(readDocument: { opened.note($0); return self.page }), directory: dir)
        #expect(await run.adoptCheckpoint() == nil)
        let report = await run.run()

        // Nothing already read was opened again...
        let readAgain = opened.all.filter { path in
            alreadyRead.keys.contains { path.hasSuffix($0) }
        }
        #expect(readAgain.isEmpty, "a document read in the first sitting was opened a second time")

        // ...and every document in the new plan is now in the corpus. Trusting the stale index
        // must make this fail: the new plan's first entries would never be visited.
        for path in after {
            #expect(report.read[path] != nil,
                    """
                    \(path) is in the plan and was never read — the run walked from a stale index \
                    and reported itself complete anyway
                    """)
        }
        #expect(report.isComplete)
    }

    /// An unchanged plan still resumes by index: the cheap path survives the rule above.
    @Test func anUnchangedPlanStillResumesByIndex() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = plan(10)
        let alreadyRead = Dictionary(uniqueKeysWithValues: paths.prefix(4).map {
            ($0, FilingSurvey.document(fromPage1: page, stamp: .init(size: 1, modified: 2), salt: "abcd"))
        })
        try DocumentSurveyCheckpointStore.write(
            DocumentSurveyCheckpoint(profileId: "p", rootPath: root.path, salt: "abcd",
                                     plan: paths, nextIndex: 4, read: alreadyRead,
                                     startedAt: Date(), updatedAt: Date()),
            id: "p", in: dir)
        let run = DocumentSurveyRun(
            profileId: "p", root: root, salt: "abcd", plan: paths, stamps: stamps(paths),
            environment: .init(readDocument: { _ in self.page }), directory: dir)
        #expect(await run.adoptCheckpoint() == nil)
        #expect(await run.resumableProgress == (4, 10))
    }

    /// A checkpoint without `documentsUnavailable` still decodes: the default is a low count, not a
    /// decode failure that would cost the whole survey.
    @Test func aCheckpointWithoutTheFieldStillDecodes() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"kind":"survey-progress","schemaVersion":1,"profileId":"p","rootPath":"/tree","salt":"abcd","nextIndex":2}"#.utf8)
            .write(to: DocumentSurveyCheckpointStore.url(id: "p", in: dir))
        guard case .loaded(let back) = DocumentSurveyCheckpointStore.read(id: "p", in: dir) else {
            Issue.record("a checkpoint predating documentsUnavailable no longer decodes")
            return
        }
        #expect(back.documentsUnavailable == 0)
        #expect(back.nextIndex == 2)
    }
}
