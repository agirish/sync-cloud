import Foundation
import os
import Testing
import Events
import EventsTestSupport
@testable import Sync

/// The re-survey end to end, on a real tree. ``FilingSurvey``'s unit tests pin the rules; these pin
/// the feature (a folder created after the last survey becomes a destination), the cost claim
/// (counted by what got opened), and the refusals that keep a bad walk off the artifacts.
@Suite @MainActor struct FilingResurveyTests {

    /// Records every path the extractor was asked to open, which is the whole cost of a survey.
    typealias Reads = LockedBox<[String]>

    static func write(_ url: URL, _ contents: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    /// Enough ordinary English that ``FilingSurvey/isDecodable(_:)`` accepts it; the glyph-soup
    /// filter rejects a two-word fixture too.
    static func page(_ subject: String) -> String {
        "\(subject). Your account statement for this service period is enclosed with the total "
            + "amount due and the payment date. Please retain this notice for your records."
    }

    /// A tree with two established folders, each holding two documents.
    static func makeTree() throws -> (FileSyncManager, URL, URL, Reads, URL) {
        let root = try makeCanonicalTempRoot(prefix: "Resurvey")
        let docs = root.appendingPathComponent("Documents")
        try write(docs.appendingPathComponent("Home/PG&E/2024/jan.pdf"), page("Pacific Gas and Electric"))
        try write(docs.appendingPathComponent("Home/PG&E/2024/feb.pdf"), page("Pacific Gas and Electric"))
        try write(docs.appendingPathComponent("Health/Kaiser/eob-1.pdf"), page("Kaiser Permanente cardiology"))
        try write(docs.appendingPathComponent("Health/Kaiser/eob-2.pdf"), page("Kaiser Permanente cardiology"))

        let profiles = root.appendingPathComponent("profiles")
        let reads = Reads()
        let manager = FileSyncManager()
        manager.filingProfilesDirectory = profiles
        manager.filingFolderProfile = FolderProfile(profileId: "t", root: docs.path, folders: [:],
                                                    personTokens: [])
        // The seam the app injects; reading the file means an unopened document adds no tokens.
        manager.filingSnippetExtractor = { path in
            reads.note(path)
            return try? String(contentsOfFile: path, encoding: .utf8)
        }
        return (manager, docs, profiles, reads, root)
    }

    /// The two artifacts a survey writes, and their bytes now.
    static func artifactsBefore(_ profiles: URL) throws -> (corpus: URL, memory: URL, corpusBytes: Data, memoryBytes: Data) {
        let corpus = profiles.appendingPathComponent("t/filing-corpus.json")
        let memory = profiles.appendingPathComponent("t/filing-memory.json")
        return (corpus, memory, try Data(contentsOf: corpus), try Data(contentsOf: memory))
    }

    // MARK: - A walk that read nothing must never be mistaken for an empty tree

    /// A root that can't be listed leaves both artifacts as they were. Its one unexplored marker is
    /// dropped by `flatten`, so `merge` would see an empty tree, as if every document was deleted,
    /// and empty both. Asserted on the bytes: the report can't tell the two apart.
    @Test func aRootThatCannotBeListedLeavesTheArtifactsExactlyAsTheyWere() async throws {
        let (manager, docs, profiles, _, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await manager.resurveyFilingMemory(root: docs)

        let (corpusURL, memoryURL, corpusBefore, memoryBefore) = try Self.artifactsBefore(profiles)
        let learnedBefore = try #require(manager.filingMemory).folders.count
        #expect(learnedBefore > 0, "fixture: there must be something to lose")

        // In use, TCC revocation or an unreachable root; an unlistable folder walks the same.
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: docs.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docs.path) }

        let report = await manager.resurveyFilingMemory(root: docs)

        #expect(report.changed == false)
        #expect(try Data(contentsOf: corpusURL) == corpusBefore,
                "the corpus was rewritten from a walk that read nothing")
        #expect(try Data(contentsOf: memoryURL) == memoryBefore,
                "the folder memory was rewritten from a walk that read nothing")
        #expect(manager.filingMemory?.folders.count == learnedBefore,
                "the published memory must still describe the tree")
    }

    /// A corpus on disk that can't be parsed refuses the survey. From an empty corpus the pass
    /// would write a near-empty memory over the learned content, and the moved fingerprint would
    /// discard every cached verdict. An absent corpus still surveys from scratch.
    @Test func anUnreadableCorpusLeavesBothArtifactsExactlyAsTheyWere() async throws {
        let (manager, docs, profiles, _, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await manager.resurveyFilingMemory(root: docs)

        let (corpusURL, memoryURL, _, memoryBefore) = try Self.artifactsBefore(profiles)
        let learnedBefore = try #require(manager.filingMemory).folders.count
        #expect(learnedBefore > 0, "fixture: there must be something to lose")

        // A truncated corpus, as a crash or a full disk leaves behind.
        let corrupt = Data("{ \"documents\": { \"a.pdf\": ".utf8)
        try corrupt.write(to: corpusURL)

        // A new document appears, so the pass has something to read and every reason to write.
        try Self.write(docs.appendingPathComponent("Home/PG&E/2024/mar.pdf"),
                       Self.page("Pacific Gas and Electric"))
        let report = await manager.resurveyFilingMemory(root: docs)

        #expect(report.changed == false, "the survey ran on a corpus it could not read")
        #expect(try Data(contentsOf: memoryURL) == memoryBefore,
                "the folder memory was rewritten from an empty corpus")
        #expect(try Data(contentsOf: corpusURL) == corrupt,
                "the unreadable corpus was overwritten rather than left for inspection")
        #expect(manager.filingMemory?.folders.count == learnedBefore,
                "the published memory must still describe the tree")
    }

    /// The same refusal for a corpus that can't be opened (mode 000 here, an ACL or I/O error in
    /// use). It is not `.absent`: an atomic write needs permission on the directory, not the file,
    /// so a survey that went ahead would destroy the corpus bytes. Asserted on the bytes.
    @Test func aCorpusThatCannotBeOpenedLeavesBothArtifactsExactlyAsTheyWere() async throws {
        if geteuid() == 0 {
            Issue.record("""
                Skipped: running as root (euid 0), where chmod 000 does not restrict access, so \
                this fixture cannot distinguish an unreadable corpus from a readable one.
                """)
            return
        }
        let (manager, docs, profiles, _, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await manager.resurveyFilingMemory(root: docs)

        let (corpusURL, memoryURL, corpusBefore, memoryBefore) = try Self.artifactsBefore(profiles)
        let fm = FileManager.default
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: corpusURL.path) }
        let learnedBefore = try #require(manager.filingMemory).folders.count
        #expect(learnedBefore > 0, "fixture: there must be something to lose")

        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: corpusURL.path)
        #expect((try? Data(contentsOf: corpusURL)) == nil, "fixture: the corpus was still readable")

        // A new document appears, so the pass has something to read and every reason to write.
        try Self.write(docs.appendingPathComponent("Home/PG&E/2024/mar.pdf"),
                       Self.page("Pacific Gas and Electric"))
        let report = await manager.resurveyFilingMemory(root: docs)

        #expect(report.changed == false, "the survey ran on a corpus it could not open")
        #expect(try Data(contentsOf: memoryURL) == memoryBefore,
                "the folder memory was rewritten from an empty corpus")
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: corpusURL.path)
        #expect(try Data(contentsOf: corpusURL) == corpusBefore,
                "the unopenable corpus was overwritten — the learned content is gone, not kept")
        #expect(manager.filingMemory?.folders.count == learnedBefore,
                "the published memory must still describe the tree")
    }

    /// An unreadable `filing-memory.json` refuses the survey too. `FilingProfileStore.decode`
    /// answers nil for it as for an absent one, so the survey would atomically replace it (needing
    /// only directory permission). Refusing costs a survey; continuing costs the file.
    @Test func anUnreadableMemoryLeavesBothArtifactsExactlyAsTheyWere() async throws {
        if geteuid() == 0 {
            Issue.record("Skipped: running as root (euid 0), where chmod 000 restricts nothing.")
            return
        }
        let (manager, docs, profiles, _, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await manager.resurveyFilingMemory(root: docs)

        let (corpusURL, memoryURL, corpusBefore, memoryBefore) = try Self.artifactsBefore(profiles)
        let fm = FileManager.default
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: memoryURL.path) }

        // The state a launch reaches with an unreadable memory: nothing was loaded from it.
        manager.filingMemory = nil
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: memoryURL.path)
        #expect((try? Data(contentsOf: memoryURL)) == nil, "fixture: the memory was still readable")

        try Self.write(docs.appendingPathComponent("Home/PG&E/2024/mar.pdf"),
                       Self.page("Pacific Gas and Electric"))
        let report = await manager.resurveyFilingMemory(root: docs)

        #expect(report.changed == false, "the survey ran over a memory it could not read")
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: memoryURL.path)
        #expect(try Data(contentsOf: memoryURL) == memoryBefore,
                "the unreadable folder memory was replaced — the bytes are gone, not kept")
        #expect(try Data(contentsOf: corpusURL) == corpusBefore,
                "the corpus was rewritten by a pass that had already been refused")
    }

    /// The other direction, so the refusals above aren't "the survey stopped working": with an
    /// absent memory the survey runs and writes one, as a first survey does.
    @Test func anAbsentMemoryStillSurveys() async throws {
        let (manager, docs, profiles, _, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await manager.resurveyFilingMemory(root: docs)
        let memoryURL = profiles.appendingPathComponent("t/filing-memory.json")
        try FileManager.default.removeItem(at: memoryURL)
        manager.filingMemory = nil

        let report = await manager.resurveyFilingMemory(root: docs)
        #expect(report.changed, "an absent memory must be rebuilt, not refused")
        #expect(FileManager.default.fileExists(atPath: memoryURL.path))
    }

    /// The same for the corpus: with none at all the survey runs and writes one.
    @Test func anAbsentCorpusStillSurveysFromScratch() async throws {
        let (manager, docs, profiles, _, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await manager.resurveyFilingMemory(root: docs)
        let corpusURL = profiles.appendingPathComponent("t/filing-corpus.json")
        try FileManager.default.removeItem(at: corpusURL)

        let report = await manager.resurveyFilingMemory(root: docs)

        #expect(FileManager.default.fileExists(atPath: corpusURL.path),
                "an absent corpus must be rebuilt, not refused")
        #expect(report.documentsRead > 0, "a survey with no corpus must read the tree")
    }

    // MARK: - The window stays live

    /// Refresh decodes the corpus and builds the memory off the main thread; on a real corpus the
    /// build alone can hold the window over a second. Two hops around the snippet read (flatten,
    /// decode, choose asking availability; merge, build, write), and the witness runs in each.
    @Test func theCorpusDecodeAndTheMemoryBuildRunOffTheMainThread() async throws {
        let (manager, docs, profiles, _, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await manager.resurveyFilingMemory(root: docs)
        try Self.write(docs.appendingPathComponent("Health/Kaiser/eob-3.pdf"), Self.page("Kaiser Permanente cardiology"))

        let hops = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let availability = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        manager.filingResurveyOffMainWitness = { hops.withLock { $0.append(Thread.isMainThread) } }
        manager.filingDocumentIsAvailable = { path in
            availability.withLock { $0.append(Thread.isMainThread) }
            return FilingSurvey.isAvailable(path)
        }
        let report = await manager.resurveyFilingMemory(root: docs)

        #expect(report.changed && report.documentsRead == 1, "the fixture stopped exercising a write")
        #expect(FileManager.default.fileExists(atPath: profiles.appendingPathComponent("t/filing-memory.json").path))
        #expect(hops.withLock { $0 } == [false, false],
                "both hops must run, and neither on the main thread")
        let asked = availability.withLock { $0 }
        try #require(!asked.isEmpty, "the availability check was never asked — the probe is vacuous")
        #expect(!asked.contains(true), "the first hop's availability checks ran on the main thread")
    }

    // MARK: - The thing that was asked for

    /// A folder created after the last survey, holding one filed document, becomes a destination the
    /// router ranks first.
    @Test func aFolderAddedAfterTheLastSurveyBecomesRoutable() async throws {
        let (manager, docs, _, _, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await manager.resurveyFilingMemory(root: docs)
        let fingerprint = manager.filingArtifactFingerprint

        // The user creates a folder in Finder and drops a bill into it.
        try Self.write(docs.appendingPathComponent("Home/Xfinity/2026/march.pdf"),
                       Self.page("Xfinity Comcast internet service"))
        #expect(try #require(manager.filingMemory).folders["Home/Xfinity/2026"] == nil)
        let report = await manager.resurveyFilingMemory(root: docs)
        #expect(report.changed)
        #expect(report.documentsRead == 1)
        #expect(manager.filingArtifactFingerprint != fingerprint)
        #expect(manager.filingArtifactFingerprint?.isEmpty == false)

        let memory = try #require(manager.filingMemory)
        let anchors = memory.folders["Home/Xfinity/2026"]?.anchors.map(\.token) ?? []
        #expect(anchors.contains("xfinity"))

        // The router, the consumer that matters, puts it first for the next one.
        let index = FilingRouter.makeIndex(destinations: ["Home/PG&E/2024", "Health/Kaiser",
                                                          "Home/Xfinity/2026"],
                                           profile: manager.filingFolderProfile, memory: memory)
        let ranking = FilingRouter.rank(fileName: "statement.pdf",
                                        contentSnippet: Self.page("Xfinity Comcast internet service"),
                                        index: index)
        #expect(ranking.candidates.first?.relativePath == "Home/Xfinity/2026")
    }

    // MARK: - What the survey says in the log

    /// A survey left behind by a cut-off re-derive is read back a moment after launch, off the main
    /// actor. A Refresh in that window could read the corpus as absent and write over the replay's.
    @Test func aRefreshIsRefusedWhileASurveyIsReadBack() async throws {
        let (manager, docs, _, _, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        manager.surveyReplaysInFlight = 2
        let refused = await manager.resurveyFilingMemory(root: docs)
        #expect(refused.foldersLearned == 0, "a Refresh ran while a survey replay was in flight")
        manager.surveyReplaysInFlight -= 1
        #expect(await manager.resurveyFilingMemory(root: docs).foldersLearned == 0,
                "one replay finishing let a Refresh in while another was still carrying")
        manager.surveyReplaysInFlight -= 1
        let ran = await manager.resurveyFilingMemory(root: docs)
        #expect(ran.foldersLearned > 0, "the control: the same Refresh learns once the replay is done")
    }

    /// The closing line counts folders as `N folder(s)`, never a bare "1 folders". Asserted on the
    /// literal form, since this fixture learns two and "2 folders" would read fine.
    @Test func theResurveyLineCountsFoldersInTheHouseForm() async throws {
        let log = LogCapture()
        let (manager, docs, _, _, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = await manager.resurveyFilingMemory(root: docs)
        #expect(report.foldersLearned > 0, "fixture: the survey must have learned something to count")

        // Matched on this run's summary, not just the prefix: `Logger.shared` is process-wide and
        // this file's tests run resurveys in parallel, so the last prefix match can be a
        // neighbour's (`docs/flaky-tests.md`, "Process-wide state, and suites running in parallel").
        let line = await log.entries.last {
            $0.message.hasPrefix("Refresh finished") && $0.message.contains(report.summary)
        }
        let message = try #require(line?.message, "the survey logged no closing line for this run")
        #expect(message.contains("\(report.foldersLearned) folder(s) now have learned content"),
                "house plural form missing — got: \(message)")
    }

    // MARK: - The cost claim

    /// One new document in a four-document tree costs one read, not four.
    @Test func onlyTheNewDocumentIsRead() async throws {
        let (manager, docs, _, reads, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await manager.resurveyFilingMemory(root: docs)
        reads.reset()

        try Self.write(docs.appendingPathComponent("Health/Kaiser/eob-3.pdf"),
                       Self.page("Kaiser Permanente radiology"))
        let report = await manager.resurveyFilingMemory(root: docs)
        #expect(report.documentsRead == 1)
        #expect(reads.paths.map { ($0 as NSString).lastPathComponent } == ["eob-3.pdf"])
    }

    /// Filing a document is a move, the most common change a tree sees, and must not cost a read.
    @Test func aFiledDocumentFollowsItsMoveWithoutBeingReopened() async throws {
        let (manager, docs, _, reads, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await manager.resurveyFilingMemory(root: docs)
        reads.reset()

        let from = docs.appendingPathComponent("Health/Kaiser/eob-1.pdf")
        let to = docs.appendingPathComponent("Health/Kaiser/2024/eob-1.pdf")
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: from, to: to)

        let report = await manager.resurveyFilingMemory(root: docs)
        #expect(reads.paths.isEmpty)
        #expect(report.documentsRelocated == 1)
        #expect(manager.filingMemory?.folders["Health/Kaiser/2024"]?.docs == 1)
        #expect(manager.filingMemory?.folders["Health/Kaiser"]?.docs == 1)
    }

    // MARK: - Not disturbing what it did not change

    /// A survey that finds nothing must not rewrite the memory, whose bytes key every cached
    /// verdict (a fresh timestamp alone would discard the cache), and costs no document reads.
    @Test func anUnchangedSurveyLeavesTheArtifactByteIdentical() async throws {
        let (manager, docs, profiles, reads, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = await manager.resurveyFilingMemory(root: docs)
        #expect(first.documentsRead == 4)
        #expect(reads.paths.count == 4)
        let url = FilingSurveyStore.memoryURL(id: "t", in: profiles)
        let before = try Data(contentsOf: url)
        let fingerprint = manager.filingArtifactFingerprint

        reads.reset()
        let report = await manager.resurveyFilingMemory(root: docs)
        #expect(report.documentsRead == 0)
        #expect(reads.paths.isEmpty)
        #expect(!report.changed)
        #expect(try Data(contentsOf: url) == before)
        #expect(manager.filingArtifactFingerprint == fingerprint)
    }

    /// An unchanged survey still moves the published stamp, since "last surveyed" means when the
    /// survey looked. It lands in memory and on disk, where the next launch's attach reads it.
    @Test func anUnchangedSurveyStillPublishesWhenItLooked() async throws {
        let (manager, docs, profiles, _, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await manager.resurveyFilingMemory(root: docs)

        let later = Date(timeIntervalSince1970: 1_756_400_000)
        _ = await manager.resurveyFilingMemory(root: docs, now: later)

        #expect(manager.filingSurveyedAt == later)
        #expect(FilingSurveyStore.surveyedAt(id: "t", in: profiles) == later)
    }

    /// The folder profile records what a folder *is*, mined from names. A survey has no business
    /// revising it, and the store that writes the memory must not touch it.
    @Test func theFolderProfileIsNeverWritten() async throws {
        let (manager, docs, profiles, _, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await manager.resurveyFilingMemory(root: docs)
        let profile = profiles.appendingPathComponent("t/folder-profile.json")
        #expect(!FileManager.default.fileExists(atPath: profile.path))
    }

    /// An undecodable document is opened once and stamped, not reopened every survey. A folder of
    /// scans is the worst case: the most expensive to read and the least rewarding.
    @Test func anUnreadableDocumentIsNotReopenedOnEverySurvey() async throws {
        let (manager, docs, _, reads, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.write(docs.appendingPathComponent("Health/Kaiser/scan.pdf"), "') ! ) ) ! A A @ A")
        _ = await manager.resurveyFilingMemory(root: docs)
        #expect(reads.paths.contains { $0.hasSuffix("scan.pdf") })

        reads.reset()
        let second = await manager.resurveyFilingMemory(root: docs)
        #expect(second.documentsRead == 0)
        #expect(reads.paths.isEmpty)
    }

    /// A document the extractor returns nothing for (an image-only scan) is still stamped, or it
    /// is reopened every survey. Also the other direction of the eviction guard below, so that
    /// guard can't become "never stamp a blank".
    @Test func aDocumentThatYieldsNothingIsStillStamped() async throws {
        let (manager, docs, profiles, reads, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.write(docs.appendingPathComponent("Health/Kaiser/imageonly.pdf"), "")
        manager.filingSnippetExtractor = { path in
            reads.note(path)
            return path.hasSuffix("imageonly.pdf") ? nil : (try? String(contentsOfFile: path, encoding: .utf8))
        }
        _ = await manager.resurveyFilingMemory(root: docs)
        #expect(reads.paths.contains { $0.hasSuffix("imageonly.pdf") })
        let corpus = try #require(FilingSurveyStore.corpus(id: "t", in: profiles))
        #expect(corpus.documents.keys.contains { $0.hasSuffix("imageonly.pdf") },
                "a readable-but-empty document must be stamped, or it is reopened every survey")

        reads.reset()
        let second = await manager.resurveyFilingMemory(root: docs)
        #expect(second.documentsRead == 0)
        #expect(reads.paths.isEmpty)
    }

    /// An evicted iCloud file is not an empty document. Both come back with nothing, and stamping
    /// it would permanently write off a whole offloaded folder in one pass.
    @Test func anUndownloadedDocumentIsSkippedRatherThanStampedBlank() async throws {
        let (manager, docs, _, reads, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.write(docs.appendingPathComponent("Health/Kaiser/offloaded.pdf"),
                       Self.page("Kaiser Permanente dermatology"))
        manager.filingDocumentIsAvailable = { !$0.hasSuffix("offloaded.pdf") }

        let first = await manager.resurveyFilingMemory(root: docs)
        #expect(first.documentsUnavailable == 1)
        #expect(!reads.paths.contains { $0.hasSuffix("offloaded.pdf") })

        // It comes back down, and the next survey learns from it rather than skipping it forever.
        manager.filingDocumentIsAvailable = { _ in true }
        reads.reset()
        let second = await manager.resurveyFilingMemory(root: docs)
        #expect(second.documentsRead == 1)
        #expect(second.documentsUnavailable == 0)
        #expect(reads.paths.contains { $0.hasSuffix("offloaded.pdf") })
    }

    /// The availability answer goes stale, and a blank stamp is permanent. It is asked before a
    /// batch that can take minutes; a file evicted meanwhile extracts as nothing, and a stamp on an
    /// unchanged size and mtime never invalidates. So empty results are re-asked.
    @Test func aDocumentEvictedWhileTheSurveyReadsIsNotStampedBlank() async throws {
        let (manager, docs, profiles, reads, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.write(docs.appendingPathComponent("Health/Kaiser/offloaded.pdf"),
                       Self.page("Kaiser Permanente dermatology"))

        // Available when the batch is chosen, gone by the time its empty result is stamped.
        let asked = Reads()
        manager.filingDocumentIsAvailable = { path in
            guard path.hasSuffix("offloaded.pdf") else { return true }
            asked.note(path)
            return asked.paths.count == 1        // true the first time, false the second
        }
        manager.filingSnippetExtractor = { path in
            reads.note(path)
            return path.hasSuffix("offloaded.pdf") ? nil : (try? String(contentsOfFile: path, encoding: .utf8))
        }

        let first = await manager.resurveyFilingMemory(root: docs)
        // Premise: it was judged available and opened. The counts below are the claim.
        #expect(reads.paths.contains { $0.hasSuffix("offloaded.pdf") }, "fixture: it must be opened")

        // The mid-read skip counts as unavailable, so `summary` doesn't claim full coverage.
        #expect(first.documentsRead == 4,
                "the evicted document is still counted as read — its page 1 never was")
        #expect(first.documentsUnavailable == 1,
                "the evicted document vanished from the report — the survey reads as complete")
        #expect(first.summary.contains("1 not downloaded yet"),
                "the sentence the user sees still claims the survey covered everything")

        let corpus = try #require(FilingSurveyStore.corpus(id: "t", in: profiles))
        #expect(corpus.documents.keys.contains { $0.hasSuffix("offloaded.pdf") } == false,
                "an evicted file was stamped, and the stamp can never invalidate")

        // It comes back down and the next survey learns from it, so nothing was written off.
        manager.filingDocumentIsAvailable = { _ in true }
        manager.filingSnippetExtractor = { path in
            reads.note(path)
            return try? String(contentsOfFile: path, encoding: .utf8)
        }
        reads.reset()
        let second = await manager.resurveyFilingMemory(root: docs)
        #expect(second.documentsRead == 1)
        #expect(reads.paths.contains { $0.hasSuffix("offloaded.pdf") })
    }

    // MARK: - The folder the artifacts came from is the identity, not the field inside them

    /// A re-survey writes back to the folder it read from, the profile's identity
    /// (``FilingProfileStore/active(in:)``); the `profileId` field decodes to `"default"` when a
    /// hand-built profile omits it. Keyed on the field, a tree read from `work/` would be written to
    /// `default/`, where nothing reads, and the fingerprint would turn the verdict cache off.
    @Test func theResurveyWritesBackToTheFolderItReadFromNotTheFieldInsideTheProfile() async throws {
        let (manager, docs, profiles, _, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        // What a profile that omits `profileId` produces.
        manager.filingFolderProfile = FolderProfile(profileId: "default", root: docs.path,
                                                    folders: [:], personTokens: [])
        manager.filingProfileDirectoryId = "work"

        let report = await manager.resurveyFilingMemory(root: docs)
        #expect(report.documentsRead > 0, "fixture: the pass has to have done something to misfile")

        #expect(FileManager.default.fileExists(
            atPath: profiles.appendingPathComponent("work/filing-memory.json").path),
                "the memory belongs in the folder the artifacts were read from")
        #expect(FileManager.default.fileExists(
            atPath: profiles.appendingPathComponent("work/filing-corpus.json").path),
                "so does the corpus — it is the half the next survey reads to scope itself")
        #expect(!FileManager.default.fileExists(
            atPath: profiles.appendingPathComponent("default").path),
                "nothing may be written under the field's name; that folder is where reads never go")

        // The republished fingerprint outlives the pass. Keyed on the field, it would hash a folder
        // with no artifacts: a digest disagreeing with every cached verdict until the next launch.
        #expect(manager.filingArtifactFingerprint == FilingProfileStore.fingerprint(id: "work", in: profiles))
        // Not the empty-folder digest: `""` recurs, so it would look like a stable answer forever.
        #expect(manager.filingArtifactFingerprint != FilingProfileStore.fingerprint(id: "default",
                                                                                   in: profiles))
    }

    /// With no directory id the field is still used, or every caller that never sets one (most
    /// tests, any non-app host) would silently stop re-surveying.
    @Test func withNoDirectoryIdTheFieldInsideTheProfileIsStillUsed() async throws {
        let (manager, docs, profiles, _, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(manager.filingProfileDirectoryId == nil, "fixture: the fallback is what is under test")

        _ = await manager.resurveyFilingMemory(root: docs)

        #expect(FileManager.default.fileExists(
            atPath: profiles.appendingPathComponent("t/filing-memory.json").path),
                "the profile field names 't', and with no directory id that is the right answer")
    }

    /// With no profile there is nothing to do, and saying so beats writing an empty memory over a
    /// tree nobody surveyed.
    @Test func aMachineWithNoProfileIsLeftAlone() async throws {
        let (manager, docs, profiles, _, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        manager.filingFolderProfile = nil
        manager.filingMemory = nil
        let report = await manager.resurveyFilingMemory(root: docs)
        #expect(report == .none)
        #expect(!FileManager.default.fileExists(atPath: profiles.path))
    }

    /// One mutator at a time: this survey refuses while a Restructure landing is in flight, whose
    /// re-derive awaits it would otherwise walk mid-reshape, racing the memory and fingerprint
    /// writes. A new document appears first, so deleting the flag guard must fail this.
    @Test func aFolderMemoryUpdateRefusesWhileALandingIsInFlight() async throws {
        let (manager, docs, profiles, _, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await manager.resurveyFilingMemory(root: docs)
        let corpusURL = profiles.appendingPathComponent("t/filing-corpus.json")
        let corpusBefore = try Data(contentsOf: corpusURL)

        try Self.write(docs.appendingPathComponent("Home/PG&E/2024/mar.pdf"),
                       Self.page("Pacific Gas and Electric"))
        manager.restructureLandingInProgress = true
        defer { manager.restructureLandingInProgress = false }
        let report = await manager.resurveyFilingMemory(root: docs)

        #expect(report == .none, "a landing is in flight — the survey must not run at all")
        #expect(try Data(contentsOf: corpusURL) == corpusBefore,
                "the corpus must not be rewritten under a live landing")
    }

    // MARK: - The profile's own folder, whatever the pane shows

    /// Refresh surveys the folder the profile was built from, not the one the pane shows: the
    /// corpus is keyed relative to it, so under another every learned document reads as gone. The
    /// other folder shares a path with the profile, and the profile's folder gains a document,
    /// which tells "surveyed the right folder" from "refused". Run as Organize asks, and with a
    /// walk of the other folder handed over as `taxonomy`, which must not stand in for the survey's
    /// own walk.
    @Test(arguments: [false, true])
    func aRefreshAskedAboutAnotherFolderSurveysTheProfilesOwn(handingOverItsWalk: Bool) async throws {
        let (manager, docs, profiles, reads, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await manager.resurveyFilingMemory(root: docs)
        let learned = Set(try #require(FilingSurveyStore.corpus(id: "t", in: profiles)).documents.keys)
        #expect(learned.count == 4, "fixture: the profile's own folder has been surveyed")

        let elsewhere = docs.deletingLastPathComponent().appendingPathComponent("Elsewhere")
        try Self.write(elsewhere.appendingPathComponent("Health/Kaiser/eob-1.pdf"), Self.page("Aetna dental claim"))
        try Self.write(elsewhere.appendingPathComponent("Finance/Chase/statement.pdf"), Self.page("Chase checking"))
        let added = docs.appendingPathComponent("Home/PG&E/2024/mar.pdf")
        try Self.write(added, Self.page("Pacific Gas and Electric"))
        reads.reset()

        let walk = handingOverItsWalk
            ? await FileSyncManager.buildTree(url: elsewhere, sortOption: .name) : nil
        let report = await manager.resurveyFilingMemory(root: elsewhere, taxonomy: walk)

        #expect(!reads.paths.contains { $0.hasPrefix(elsewhere.path + "/") },
                "opened documents from the folder the pane shows: \(reads.paths)")
        #expect(reads.paths == [added.path], "the profile's own new document was not read")
        let corpus = try #require(FilingSurveyStore.corpus(id: "t", in: profiles))
        #expect(Set(corpus.documents.keys) == learned.union(["Home/PG&E/2024/mar.pdf"]),
                "the corpus no longer describes the profile's folder")
        #expect(report.documentsDropped == 0)
        let memory = try Data(contentsOf: profiles.appendingPathComponent("t/filing-memory.json"))
        let header = try #require(try JSONSerialization.jsonObject(with: memory) as? [String: Any])
        #expect(header["root"] as? String == docs.path, "the memory now names another folder as its root")
    }

    /// Real profiles record `~/Documents`, while the fixtures above use absolute paths, so a guard
    /// that stopped expanding the tilde would refuse every real Refresh with them all green. Spelled
    /// through `~` and back down to the temp folder, so the expansion makes the path absolute.
    @Test func aRootRecordedThroughTheTildeIsExpandedAndSurveyed() async throws {
        let (manager, docs, profiles, reads, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let depth = NSHomeDirectory().split(separator: "/").count
        let spelled = "~/" + String(repeating: "../", count: depth) + docs.path.dropFirst()
        #expect((spelled as NSString).expandingTildeInPath != spelled, "premise: the tilde is what expands")
        manager.filingFolderProfile = FolderProfile(profileId: "t", root: spelled, folders: [:],
                                                    personTokens: [])
        _ = await manager.resurveyFilingMemory(root: docs)
        try Self.write(docs.appendingPathComponent("Home/PG&E/2024/mar.pdf"),
                       Self.page("Pacific Gas and Electric"))
        reads.reset()

        let report = await manager.resurveyFilingMemory(root: docs)

        #expect(report.documentsRead == 1)
        #expect(reads.paths.count == 1 && reads.paths[0].hasSuffix("/Documents/Home/PG&E/2024/mar.pdf"))
        let corpus = try #require(FilingSurveyStore.corpus(id: "t", in: profiles))
        #expect(corpus.documents.count == 5)
    }

    /// The other direction: a handed-over walk of the profile's own folder is used, so the pass
    /// walks nothing itself. The probe is tiny and the confirmer declines, so a pass that walked
    /// anyway would ask, and stop.
    @Test func aWalkOfTheProfilesOwnFolderIsUsedAsHandedOver() async throws {
        let (manager, docs, _, reads, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await manager.resurveyFilingMemory(root: docs)
        try Self.write(docs.appendingPathComponent("Home/PG&E/2024/mar.pdf"),
                       Self.page("Pacific Gas and Electric"))
        let walk = await FileSyncManager.buildTree(url: docs, sortOption: .name)
        manager.wholeTreeProbeBudget = 1
        var asked: LargeWalkPreflight?
        manager.largeWalkConfirmer = { asked = $0; return false }
        reads.reset()

        let report = await manager.resurveyFilingMemory(root: docs, taxonomy: walk)

        #expect(asked == nil, "the pass walked for itself instead of using the walk it was handed")
        #expect(report.documentsRead == 1)
        #expect(reads.paths == [docs.appendingPathComponent("Home/PG&E/2024/mar.pdf").path])
    }

    /// A profile folder that has emptied is not taken at its word: readable and empty, it passes
    /// the unlistable-root guard. Turning off iCloud's Desktop & Documents leaves exactly this, a
    /// new empty `~/Documents`. A tree really emptied is refused wrongly, at the cost of a click.
    @Test func aProfileFolderThatHoldsNoDocumentsLeavesTheArtifactsAsTheyWere() async throws {
        let (manager, docs, profiles, reads, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await manager.resurveyFilingMemory(root: docs)
        let (corpusURL, memoryURL, corpusBefore, memoryBefore) = try Self.artifactsBefore(profiles)
        #expect(try #require(FilingSurveyStore.corpus(id: "t", in: profiles)).documents.count == 4,
                "fixture: there must be something to lose")

        let fm = FileManager.default
        try fm.moveItem(at: docs, to: docs.deletingLastPathComponent().appendingPathComponent("Moved"))
        try fm.createDirectory(at: docs, withIntermediateDirectories: false)
        reads.reset()

        let report = await manager.resurveyFilingMemory(root: docs)

        #expect(report == .none)
        #expect(reads.paths.isEmpty)
        #expect(try Data(contentsOf: corpusURL) == corpusBefore, "the corpus was rewritten from an empty folder")
        #expect(try Data(contentsOf: memoryURL) == memoryBefore, "the memory was rewritten from an empty folder")
    }

    /// A profile that doesn't record its folder is not refreshed: a missing `root` decodes as `~`,
    /// and walking home would read every learned document as gone. A root not absolute once `~` is
    /// expanded would resolve against the working directory. The confirmer declines, so a
    /// regression that walks `~` stops before opening a document (listing `~` can still raise a
    /// privacy prompt). Each case asserts a log sentence only it produces, since a relative root
    /// would otherwise end in the unreadable-root refusal.
    @Test(arguments: [(#"{"profileId": "t", "folders": []}"#, "~",
                       "does not record which folder it describes"),
                      (#"{"profileId": "t", "root": "Documents", "folders": []}"#, "Documents",
                       "names “Documents” as its folder")])
    func aProfileThatRecordsNoFolderIsNotRefreshed(profileJSON: String, readsAs: String,
                                                    refusal: String) async throws {
        let (manager, docs, profiles, reads, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await manager.resurveyFilingMemory(root: docs)
        let (corpusURL, memoryURL, corpusBefore, memoryBefore) = try Self.artifactsBefore(profiles)

        manager.filingFolderProfile = try JSONDecoder().decode(FolderProfile.self,
                                                               from: Data(profileJSON.utf8))
        #expect(manager.filingFolderProfile?.root == readsAs,
                "premise: every other reader of `root` still sees what it always did")
        try Self.write(docs.appendingPathComponent("Home/PG&E/2024/mar.pdf"),
                       Self.page("Pacific Gas and Electric"))
        manager.wholeTreeProbeBudget = 1
        var asked: LargeWalkPreflight?
        manager.largeWalkConfirmer = { asked = $0; return false }
        reads.reset()
        let log = LogCapture()

        let report = await manager.resurveyFilingMemory(root: docs)

        #expect(report == .none)
        #expect(await log.holds(.warning, containing: refusal))
        #expect(asked == nil, "walked \(asked?.rootPath ?? "") on a guess")
        #expect(reads.paths.isEmpty)
        #expect(try Data(contentsOf: corpusURL) == corpusBefore)
        #expect(try Data(contentsOf: memoryURL) == memoryBefore)
    }
}

/// `FilingResurveyTests.Reads`, which `LargeWalkGuardTests` reads too.
extension LockedBox where Value == [String] {
    convenience init() { self.init([]) }
    var paths: [String] { withLock { $0 } }
    func note(_ p: String) { withLock { $0.append(p) } }
    func reset() { withLock { $0.removeAll() } }
}
