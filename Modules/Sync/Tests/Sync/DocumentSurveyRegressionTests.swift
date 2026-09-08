import Foundation
import Testing
@testable import Sync

/// The defects an adversarial pass over RD11 turned up, each pinned by the shape that would have
/// shipped without it.
///
/// **All four were silent.** Every suite was green, every module built, and nothing logged a
/// complaint — the failures were a survey that would never read a document, a resume that could
/// never resume, a card that lied about its own state, and a summary that understated the one
/// number it exists to state plainly.
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

    /// **A deadlock, and a total one.** `runDocumentSurvey` takes `filingSurveyLifecycle` for its
    /// whole duration — it *is* the survey's running flag — and the yield conditions listed that
    /// same lifecycle among the scans to stand aside for. So the survey paused on its own flag at
    /// the first poll, before opening a single document, and stayed there. The card would have read
    /// "paused while folder memory runs" underneath the thing that was running.
    ///
    /// Asserted against the rule rather than the manager, because the rule is what was wrong: a set
    /// of conditions naming no scan must not produce a pause, and the driver is what must not name
    /// its own.
    @Test func aSurveyDoesNotYieldToItsOwnLifecycle() {
        // What the driver now hands over while it holds `filingSurveyLifecycle`: no scan at all.
        #expect(DocumentSurveyYield.pause(for: .clear) == nil)
        // And the shape that deadlocked, so the assertion above is not vacuous — if "folder memory"
        // ever reappears in the driver's list, THIS is the value it would build.
        let deadlocking = DocumentSurveyConditions(runningScans: ["folder memory"])
        #expect(DocumentSurveyYield.pause(for: deadlocking) == .yielding(to: "folder memory"),
                """
                the rule no longer pauses for a named scan — the deadlock's mechanism is gone, \
                and so is this test's subject
                """)
    }

    /// The driver's own list, read from source: it must not name the lifecycle it holds.
    ///
    /// A source scan because the value is assembled inside a `@MainActor` method over six published
    /// properties, and standing a `FileSyncManager` up in this package to read one array back would
    /// be a great deal of machinery to assert one line.
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

    /// **The salt made every resume impossible, on exactly the machines that run a first survey.**
    /// With no corpus and no memory, the plan minted a fresh random salt, so the resume's salt
    /// never matched the checkpoint's and `adoptCheckpoint` refused it as another run's — telling
    /// the user their progress belonged to a different folder.
    ///
    /// Pinned at the level the bug lived: a checkpoint written under one salt is adopted when the
    /// run carries that salt, and refused when it does not. The driver's half is that it now reads
    /// the checkpoint's salt before minting one.
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

    /// The driver reads the checkpoint's salt before minting one — the other half of the fix.
    @Test func thePlanPrefersAResumableCheckpointsSalt() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sync/FileSyncManager+DocumentSurvey.swift")
        let source = try #require(try? String(contentsOf: file, encoding: .utf8))
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(code.contains("resumableSalt"),
                """
                the plan no longer consults the checkpoint's salt, so a first survey on a fresh \
                machine mints a new one every time and can never be resumed
                """)
    }

    // MARK: - 3. A card that says paused under a survey that is reading

    /// **Progress is published the instant a pause clears, ahead of the gate.**
    ///
    /// `ProgressPublishGate` admits on whole percent, so a resume published nothing until the count
    /// crossed the next point — about 75 documents, over a minute, on a 7,558-document run. For
    /// that whole minute the card said "paused — the display is asleep" over a survey that was
    /// reading, which is the same class of failure as a frozen count and prompts the same response.
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

    /// A pause whose REASON changes republishes; one that stays the same does not.
    ///
    /// Without the first half the card would keep saying "paused while Duplicates runs" after
    /// Duplicates finished and the display went to sleep — a true sentence about the wrong cause.
    /// Without the second it would republish once a second for as long as the pause lasted, which
    /// is a re-render of the window's root view once a second, all night.
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

    /// **`read` survived a resume and `unavailable` did not**, so a survey stopped and carried on
    /// reported every not-downloaded document from the first sitting as though it had never been
    /// looked at — understating precisely the figure `DocumentSurveyReport.summary` exists to state.
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

    /// **A resume across a changed tree skipped work and called itself complete.**
    ///
    /// `resumes(profileId:rootPath:salt:)` settles whose run a checkpoint is; it says nothing about
    /// whether the tree still holds the same documents. Between sittings files are added, deleted
    /// and renamed, so `documentsToRead` returns a different list — and the old index points at an
    /// unrelated document in the new one, with everything before it never visited. The run then
    /// reported itself complete having skipped documents it never opened.
    ///
    /// The read is always worth keeping; the index is not. So a changed plan restarts the index and
    /// leans on the skip, and the assertion here is the one that matters: every document in the new
    /// plan is read exactly once, across both sittings.
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

        // ...and every document in the NEW plan is now in the corpus. This is the assertion that
        // failed before: with the stale index, the first entries of the new plan were never visited.
        for path in after {
            #expect(report.read[path] != nil,
                    """
                    \(path) is in the plan and was never read — the run walked from a stale index \
                    and reported itself complete anyway
                    """)
        }
        #expect(report.isComplete)
    }

    /// An UNCHANGED plan still resumes by index — the cheap path is not lost to the fix above.
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

    /// A checkpoint written before the field existed still decodes — the default is a low count,
    /// not a decode failure that would cost the whole survey.
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
