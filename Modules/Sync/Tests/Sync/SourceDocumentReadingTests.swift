import Foundation
import Testing
@testable import Sync

/// Read Documents for a source's own survey (Google Drive): it reads into that survey and never the
/// active profile, downloads what is cloud-only first (GL, GO), routes and answers with what it
/// learned, and survives Learn Its Folders Again (GP).
@Suite @MainActor struct SourceDocumentReadingTests {

    nonisolated private static let text = "chase bank statement account summary for the period ending march"

    /// Thread-safe list of paths a closure saw.
    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var _paths: [String] = []
        var paths: [String] { lock.withLock { _paths } }
        func note(_ p: String) { lock.withLock { _paths.append(p) } }
    }

    /// Cloud-only until fetched — the one state a test cannot stage on disk.
    final class Cloud: @unchecked Sendable {
        private let lock = NSLock()
        private var offline: Set<String>
        init(_ paths: Set<String>) { offline = paths }
        func isAvailable(_ p: String) -> Bool { lock.withLock { !offline.contains(p) } }
        func land(_ p: String) { lock.withLock { _ = offline.remove(p) } }
    }

    struct Fixture {
        let f: SourceSurveyTests.Fixture
        let documents: [String]
        var manager: FileSyncManager { f.manager }
    }

    /// Google Drive's tree with three documents, its folders learned, and an extractor.
    static func learned() async throws -> Fixture {
        let f = try SourceSurveyTests.fixture()
        let docs = ["Personal/Letters/a.txt", "School/Divit/b.txt", "Feb 2026/c.txt"].map {
            f.google.appendingPathComponent($0).path
        }
        for d in docs { try Self.text.write(toFile: d, atomically: true, encoding: .utf8) }
        f.manager.filingSnippetExtractor = { try? String(contentsOfFile: $0, encoding: .utf8) }
        f.manager.resolveFilingSurvey(providerRoot: f.google.path, folders: ["Personal", "School"])
        guard case .success = await f.manager.learnSourceSurvey(root: f.google.path) else {
            throw CancellationError()
        }
        return Fixture(f: f, documents: docs)
    }

    private func real(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }

    // MARK: The run

    /// Given a fetch, a cloud-only document is downloaded and then read; one that never lands is
    /// counted unavailable and not stamped.
    @Test func aRunWithAFetchDownloadsThenReads() async {
        let root = URL(fileURLWithPath: "/tree")
        let plan = ["A/one.pdf", "A/two.pdf", "B/three.pdf"]
        let stamps = Dictionary(uniqueKeysWithValues: plan.enumerated().map {
            ($1, FilingSurvey.Stamp(size: 100 + $0, modified: 1_700_000_000))
        })
        let cloud = Cloud([root.appendingPathComponent("A/two.pdf").path, root.appendingPathComponent("B/three.pdf").path])
        let fetched = Seen(), read = Seen()
        let run = DocumentSurveyRun(
            profileId: "p", root: root, salt: "abcd", plan: plan, stamps: stamps,
            environment: .init(readDocument: { read.note($0); return Self.text },
                               isAvailable: { cloud.isAvailable($0) },
                               fetch: { path in
                                   fetched.note(path)
                                   if path.hasSuffix("two.pdf") { cloud.land(path) }
                               }))
        let report = await run.run()
        #expect(fetched.paths.map { ($0 as NSString).lastPathComponent } == ["two.pdf", "three.pdf"])
        #expect(read.paths.map { ($0 as NSString).lastPathComponent } == ["one.pdf", "two.pdf"])
        #expect(report.documentsRead == 2)
        #expect(report.documentsUnavailable == 1)
        #expect(report.read["B/three.pdf"] == nil, "a download that never landed is not stamped")
    }

    // MARK: On the manager

    /// The reading lands in the source's own survey: its memory, its entry dated, To File and Ask
    /// Claude using it — and the active profile's memory untouched.
    @Test(.timeLimit(.minutes(1)))
    func readingASourceLearnsIntoItsOwnSurvey() async throws {
        let x = try await Self.learned()
        defer { try? FileManager.default.removeItem(at: x.f.base) }
        let m = x.manager
        let id = try #require(m.filingSurveyInUse?.ownProfileId)
        let cloudOnly = x.documents[1]
        let cloud = Cloud([cloudOnly, real(cloudOnly)])
        let fetched = Seen()
        m.documentSurveyIsAvailable = { cloud.isAvailable($0) }
        m.sourceDocumentFetch = { fetched.note($0); cloud.land($0); cloud.land(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path) }
        #expect(m.filingRoutingMemory == nil, "premise: folders only")
        let fingerprintBefore = m.filingRoutingFingerprint

        let plan = try await m.planSourceDocumentSurvey(sourceRoot: x.f.google.path).get()
        #expect(plan.total == 3)
        #expect(plan.toDownload == 1)
        #expect(plan.profileId == id)
        #expect(plan.sourceRoot.map(real) == real(x.f.google.path))

        let report = try await m.runDocumentSurvey(plan: plan).get()
        #expect(report.isComplete)
        #expect(report.documentsRead == 3)
        #expect(fetched.paths.count == 1 && fetched.paths.first.map(real) == real(cloudOnly))
        #expect(m.documentSurveySourceRoot == nil)

        #expect(FilingProfileStore.memory(id: id, in: x.f.profiles) != nil, "memory written under the source's id")
        #expect(m.filingMemory == nil, "the active profile's memory was not replaced")
        let entry = try #require(SourceSurveyStore.entry(forRoot: x.f.google.path, in: x.f.profiles))
        #expect(entry.documentsRead == 3)
        #expect(entry.documentsReadAt != nil)
        #expect(m.filingSurveyInUse?.ownDocumentsRead == 3)
        #expect(m.filingRoutingMemory?.profileId == id)
        #expect(m.filingRoutingFingerprint != fingerprintBefore, "verdicts asked before the reading are not replayed after")
        #expect(m.filingHelpSurvey(for: x.documents[0])?.memory?.profileId == id)

        #expect(await m.planSourceDocumentSurvey(sourceRoot: x.f.google.path) == .failure(.sourceAlreadyRead))
    }

    /// The primary survey's reading still never downloads: a cloud-only document is left unread.
    @Test(.timeLimit(.minutes(1)))
    func thePrimarySurveysReadingNeverFetches() async throws {
        let (manager, docs, _, _, root) = try FilingResurveyTests.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fetched = Seen()
        manager.sourceDocumentFetch = { fetched.note($0) }
        manager.documentSurveyIsAvailable = { _ in false }
        let plan = try await manager.planDocumentSurvey(root: docs).get()
        #expect(plan.sourceRoot == nil && plan.toDownload == 0)
        let report = try await manager.runDocumentSurvey(plan: plan).get()
        #expect(fetched.paths.isEmpty)
        #expect(report.documentsUnavailable == plan.total)
    }

    @Test func aSourceWithNoOwnSurveyIsRefused() async throws {
        let f = try SourceSurveyTests.fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        f.manager.filingSnippetExtractor = { _ in nil }
        #expect(await f.manager.planSourceDocumentSurvey(sourceRoot: f.google.path) == .failure(.noSourceSurvey))
    }

    /// GP: learning the folders again keeps what was read — carried to the new survey, minus the
    /// folders that are gone.
    @Test(.timeLimit(.minutes(1)))
    func learningAgainKeepsWhatWasRead() async throws {
        let x = try await Self.learned()
        defer { try? FileManager.default.removeItem(at: x.f.base) }
        let m = x.manager
        _ = try await m.runDocumentSurvey(plan: try await m.planSourceDocumentSurvey(sourceRoot: x.f.google.path).get()).get()
        let oldId = try #require(m.filingSurveyInUse?.ownProfileId)
        let readAt = try #require(SourceSurveyStore.entry(forRoot: x.f.google.path, in: x.f.profiles)?.documentsReadAt)
        let before = try #require(FilingProfileStore.memory(id: oldId, in: x.f.profiles))
        #expect(before.folders["Feb 2026"] != nil, "premise")
        try FileManager.default.removeItem(at: x.f.google.appendingPathComponent("Feb 2026"))

        guard case .success(let use?) = await m.learnSourceSurvey(root: x.f.google.path, now: Date().addingTimeInterval(5)) else {
            Issue.record("learning again failed")
            return
        }
        let newId = try #require(use.ownProfileId)
        #expect(newId != oldId)
        let carried = try #require(FilingProfileStore.memory(id: newId, in: x.f.profiles))
        #expect(carried.profileId == newId)
        #expect(carried.folders["Feb 2026"] == nil, "a folder that is gone stops counting")
        #expect(carried.folders["School/Divit"] == before.folders["School/Divit"])
        #expect(FilingSurveyStore.corpusRead(id: newId, in: x.f.profiles).corpus?.documents.count == 3)
        #expect(use.ownDocumentsReadAt == readAt)
        #expect(m.filingRoutingMemory?.profileId == newId)
        #expect(await m.planSourceDocumentSurvey(sourceRoot: x.f.google.path) == .failure(.sourceAlreadyRead),
                "nothing is read again")
    }

    /// Learning again or forgetting while that source's documents are read would pull the survey out
    /// from under the reading; a Setup save of the primary survey does not stop it.
    @Test func aReadingSourceIsNeitherRelearnedNorForgottenNorStoppedForSetup() async throws {
        let x = try await Self.learned()
        defer { try? FileManager.default.removeItem(at: x.f.base) }
        let m = x.manager
        let id = try #require(m.filingSurveyInUse?.ownProfileId)
        m.documentSurveySourceRoot = x.f.google.path
        m.documentSurveyRun = DocumentSurveyRun(profileId: id, root: x.f.google, salt: "s", plan: [], stamps: [:],
                                                environment: .init(readDocument: { _ in nil }))
        defer { m.documentSurveyRun = nil; m.documentSurveySourceRoot = nil }

        #expect(await m.learnSourceSurvey(root: x.f.google.path) == .failure(.readingDocuments))
        m.forgetSourceSurvey(root: x.f.google.path)
        #expect(SourceSurveyStore.entry(forRoot: x.f.google.path, in: x.f.profiles)?.profileId == id)
        #expect(await m.stopDocumentSurveyBeforeReplacingProfile(savingFolder: x.f.primary) == .nothingStopped)
    }

    /// Forgetting a read survey forgets the reading with it.
    @Test(.timeLimit(.minutes(1)))
    func forgettingDropsTheReading() async throws {
        let x = try await Self.learned()
        defer { try? FileManager.default.removeItem(at: x.f.base) }
        let m = x.manager
        _ = try await m.runDocumentSurvey(plan: try await m.planSourceDocumentSurvey(sourceRoot: x.f.google.path).get()).get()
        m.forgetSourceSurvey(root: x.f.google.path)
        #expect(SourceSurveyStore.entry(forRoot: x.f.google.path, in: x.f.profiles) == nil)
        #expect(m.filingRoutingMemory == nil)
    }
}
