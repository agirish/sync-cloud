import Foundation
import Testing
import Events
@testable import Sync

/// The re-survey end to end, against a real directory tree.
///
/// The unit tests on ``FilingSurvey`` pin the rules; these pin the thing the user asked for — that a
/// folder created after the last survey stops being a name and starts being a destination — and the
/// cost claim that makes it usable, which is only observable by counting what got opened.
@Suite @MainActor struct FilingResurveyTests {

    /// Records every path the extractor was asked to open, which is the whole cost of a survey.
    final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var paths: [String] = []
        func note(_ p: String) { lock.lock(); paths.append(p); lock.unlock() }
        func reset() { lock.lock(); paths.removeAll(); lock.unlock() }
    }

    static func write(_ url: URL, _ contents: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    /// Enough ordinary English that ``FilingSurvey/isDecodable(_:)`` accepts it — the filter that
    /// exists to reject glyph soup rejects a two-word fixture too.
    static func page(_ subject: String) -> String {
        "\(subject). Your account statement for this service period is enclosed with the total "
            + "amount due and the payment date. Please retain this notice for your records."
    }

    /// A tree with two established folders, each holding two documents.
    static func makeTree() throws -> (FileSyncManager, URL, URL, Reads) {
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
        // The seam the app injects. Reading the file itself keeps the fixture honest: a document
        // whose text the survey never opened cannot accidentally contribute tokens.
        manager.filingSnippetExtractor = { path in
            reads.note(path)
            return try? String(contentsOfFile: path, encoding: .utf8)
        }
        return (manager, docs, profiles, reads)
    }

    // MARK: - A walk that read nothing must never be mistaken for an empty tree

    /// **The survey is the one pass here that WRITES, and it was the one without the guard.** A
    /// root that cannot be listed comes back as a single unexplored marker, `flatten` drops it, and
    /// what reaches `merge` is an empty tree — identical in shape to a tree whose every document
    /// was deleted. Both artifacts were then atomically replaced with empty ones and published,
    /// silently: the pass reports "0 documents read", which is also what an unchanged tree reports.
    ///
    /// Asserted on the BYTES on disk rather than on the report, because the report is exactly what
    /// could not tell the two apart.
    @Test func aRootThatCannotBeListedLeavesTheArtifactsExactlyAsTheyWere() async throws {
        let (manager, docs, profiles, _) = try Self.makeTree()
        _ = await manager.resurveyFilingMemory(root: docs)

        let corpusURL = profiles.appendingPathComponent("t/filing-corpus.json")
        let memoryURL = profiles.appendingPathComponent("t/filing-memory.json")
        let corpusBefore = try Data(contentsOf: corpusURL)
        let memoryBefore = try Data(contentsOf: memoryURL)
        let learnedBefore = try #require(manager.filingMemory).folders.count
        #expect(learnedBefore > 0, "fixture: there must be something to lose")

        // The real-world causes are TCC revocation and a briefly unreachable provider root; an
        // unlistable directory is the same walk result and the only one a test can arrange.
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

    /// **The same harm, through the corpus door.** `FilingSurveyStore.corpus` answered nil for a
    /// corpus that is ABSENT and for one that is on disk and unparseable, and the survey started
    /// from an empty corpus either way — merging whatever this pass read into nothing and writing
    /// the result over the memory. With the display asleep or files offloaded that is a near-empty
    /// memory over megabytes of learned content, and the moved fingerprint discards every cached
    /// classification with it.
    ///
    /// Absent still surveys from scratch, which is correct. Unreadable refuses, because nothing
    /// about the tree can be inferred from a file that could not be read.
    @Test func anUnreadableCorpusLeavesBothArtifactsExactlyAsTheyWere() async throws {
        let (manager, docs, profiles, _) = try Self.makeTree()
        _ = await manager.resurveyFilingMemory(root: docs)

        let corpusURL = profiles.appendingPathComponent("t/filing-corpus.json")
        let memoryURL = profiles.appendingPathComponent("t/filing-memory.json")
        let memoryBefore = try Data(contentsOf: memoryURL)
        let learnedBefore = try #require(manager.filingMemory).folders.count
        #expect(learnedBefore > 0, "fixture: there must be something to lose")

        // A half-written or truncated corpus — the shape a crash or a full disk leaves behind.
        let corrupt = Data("{ \"documents\": { \"a.pdf\": ".utf8)
        try corrupt.write(to: corpusURL)

        // A real document appears, so the pass has something to read and every reason to write.
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

    /// The other direction, so the refusal above cannot be "the survey stopped working": with NO
    /// corpus at all the survey runs and writes one, which is what a first survey is.
    @Test func anAbsentCorpusStillSurveysFromScratch() async throws {
        let (manager, docs, profiles, _) = try Self.makeTree()
        _ = await manager.resurveyFilingMemory(root: docs)
        let corpusURL = profiles.appendingPathComponent("t/filing-corpus.json")
        try FileManager.default.removeItem(at: corpusURL)

        let report = await manager.resurveyFilingMemory(root: docs)

        #expect(FileManager.default.fileExists(atPath: corpusURL.path),
                "an absent corpus must be rebuilt, not refused")
        #expect(report.documentsRead > 0, "a survey with no corpus must read the tree")
    }

    // MARK: - The thing that was asked for

    /// A folder created after the last survey, holding one filed document, becomes a destination the
    /// router ranks first — the whole feature, stated once.
    @Test func aFolderAddedAfterTheLastSurveyBecomesRoutable() async throws {
        let (manager, docs, _, _) = try Self.makeTree()
        _ = await manager.resurveyFilingMemory(root: docs)

        // The user creates a folder in Finder and drops a bill into it.
        try Self.write(docs.appendingPathComponent("Home/Xfinity/2026/march.pdf"),
                       Self.page("Xfinity Comcast internet service"))
        let report = await manager.resurveyFilingMemory(root: docs)
        #expect(report.changed)
        #expect(report.documentsRead == 1)

        let memory = try #require(manager.filingMemory)
        let anchors = memory.folders["Home/Xfinity/2026"]?.anchors.map(\.token) ?? []
        #expect(anchors.contains("xfinity"))

        // And the router — the consumer that matters — puts it first for the next one.
        let index = FilingRouter.makeIndex(destinations: ["Home/PG&E/2024", "Health/Kaiser",
                                                          "Home/Xfinity/2026"],
                                           profile: manager.filingFolderProfile, memory: memory)
        let ranking = FilingRouter.rank(fileName: "statement.pdf",
                                        contentSnippet: Self.page("Xfinity Comcast internet service"),
                                        index: index)
        #expect(ranking.candidates.first?.relativePath == "Home/Xfinity/2026")
    }

    /// Before the survey the same file has nowhere to go — without this, the test above could pass
    /// on a router that was already ranking the folder by its name.
    @Test func theSameFileHasNoLearnedHomeBeforeTheSurvey() async throws {
        let (manager, docs, _, _) = try Self.makeTree()
        _ = await manager.resurveyFilingMemory(root: docs)
        try Self.write(docs.appendingPathComponent("Home/Xfinity/2026/march.pdf"),
                       Self.page("Xfinity Comcast internet service"))
        // Deliberately NOT re-surveyed.
        let memory = try #require(manager.filingMemory)
        #expect(memory.folders["Home/Xfinity/2026"] == nil)
    }

    // MARK: - What the survey says in the log

    /// The closing line counts folders, and it must count them the way every other line in this app
    /// does: `N folder(s)`, never a bare plural that renders "1 folders".
    ///
    /// Worth a test rather than a careful reading because the count is interpolated — the wrong form
    /// is invisible on the tree this fixture builds (two folders learned, so "2 folders" reads fine)
    /// and only shows itself on the one-folder tree nobody writes a fixture for. So the assertion is
    /// on the literal house form, which is wrong in both cases or right in both.
    @Test func theResurveyLineCountsFoldersInTheHouseForm() async throws {
        let (manager, docs, _, _) = try Self.makeTree()
        let report = await manager.resurveyFilingMemory(root: docs)
        #expect(report.foldersLearned > 0, "fixture: the survey must have learned something to count")

        await Logger.shared.debug("resurvey-log flush marker").value
        // Matched on THIS run's summary, not merely on the prefix. `Logger.shared` is
        // process-wide and twenty-four call sites in this file run resurveys unserialized, so
        // `last { hasPrefix }` can hand back a neighbour's line — observed once, reporting
        // "5 folders changed" against a report that learned 2 (flaky-tests mechanism 3).
        let line = Logger.shared.entries.last {
            $0.message.hasPrefix("Folder memory re-surveyed") && $0.message.contains(report.summary)
        }
        let message = try #require(line?.message, "the survey logged no closing line for this run")
        #expect(message.contains("\(report.foldersLearned) folder(s) now have learned content"),
                "house plural form missing — got: \(message)")
    }

    // MARK: - The cost claim

    /// The claim the feature is sold on: a tree that has not changed costs no document reads.
    @Test func aSecondSurveyOfAnUnchangedTreeReadsNothing() async throws {
        let (manager, docs, _, reads) = try Self.makeTree()
        let first = await manager.resurveyFilingMemory(root: docs)
        #expect(first.documentsRead == 4)
        #expect(reads.paths.count == 4)

        reads.reset()
        let second = await manager.resurveyFilingMemory(root: docs)
        #expect(second.documentsRead == 0)
        #expect(reads.paths.isEmpty)
    }

    /// One new document in a four-document tree costs one read, not four.
    @Test func onlyTheNewDocumentIsRead() async throws {
        let (manager, docs, _, reads) = try Self.makeTree()
        _ = await manager.resurveyFilingMemory(root: docs)
        reads.reset()

        try Self.write(docs.appendingPathComponent("Health/Kaiser/eob-3.pdf"),
                       Self.page("Kaiser Permanente radiology"))
        let report = await manager.resurveyFilingMemory(root: docs)
        #expect(report.documentsRead == 1)
        #expect(reads.paths.map { ($0 as NSString).lastPathComponent } == ["eob-3.pdf"])
    }

    /// Filing a document is a move, and a move must not cost a read — it is the single most common
    /// change this tree ever sees.
    @Test func aFiledDocumentFollowsItsMoveWithoutBeingReopened() async throws {
        let (manager, docs, _, reads) = try Self.makeTree()
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

    /// **A survey that finds nothing must not rewrite the memory.** Its bytes are hashed into every
    /// cached classification's key, so a fresh timestamp over identical content would throw away the
    /// verdict cache to record that nothing happened.
    @Test func anUnchangedSurveyLeavesTheArtifactByteIdentical() async throws {
        let (manager, docs, profiles, _) = try Self.makeTree()
        _ = await manager.resurveyFilingMemory(root: docs)
        let url = FilingSurveyStore.memoryURL(id: "t", in: profiles)
        let before = try Data(contentsOf: url)
        let fingerprint = manager.filingArtifactFingerprint

        let report = await manager.resurveyFilingMemory(root: docs)
        #expect(!report.changed)
        #expect(try Data(contentsOf: url) == before)
        #expect(manager.filingArtifactFingerprint == fingerprint)
    }

    /// A real change does move the fingerprint — the other half, without which the test above passes
    /// on a survey that never writes anything.
    @Test func arealChangeMovesTheFingerprint() async throws {
        let (manager, docs, _, _) = try Self.makeTree()
        _ = await manager.resurveyFilingMemory(root: docs)
        let fingerprint = manager.filingArtifactFingerprint

        try Self.write(docs.appendingPathComponent("Home/Xfinity/2026/march.pdf"),
                       Self.page("Xfinity Comcast internet service"))
        _ = await manager.resurveyFilingMemory(root: docs)
        #expect(manager.filingArtifactFingerprint != fingerprint)
        #expect(manager.filingArtifactFingerprint?.isEmpty == false)
    }

    /// The folder profile records what a folder *is*, mined from names. A survey has no business
    /// revising it, and the store that writes the memory must not touch it.
    @Test func theFolderProfileIsNeverWritten() async throws {
        let (manager, docs, profiles, _) = try Self.makeTree()
        _ = await manager.resurveyFilingMemory(root: docs)
        let profile = profiles.appendingPathComponent("t/folder-profile.json")
        #expect(!FileManager.default.fileExists(atPath: profile.path))
    }

    /// An unreadable document is opened once and then stamped, not reopened every survey — the
    /// pathological case being a folder of scans, which is both the most expensive to read and the
    /// least rewarding.
    @Test func anUnreadableDocumentIsNotReopenedOnEverySurvey() async throws {
        let (manager, docs, _, reads) = try Self.makeTree()
        try Self.write(docs.appendingPathComponent("Health/Kaiser/scan.pdf"), "') ! ) ) ! A A @ A")
        _ = await manager.resurveyFilingMemory(root: docs)
        #expect(reads.paths.contains { $0.hasSuffix("scan.pdf") })

        reads.reset()
        let second = await manager.resurveyFilingMemory(root: docs)
        #expect(second.documentsRead == 0)
        #expect(reads.paths.isEmpty)
    }

    /// A document the extractor cannot read at all — an image-only scan, where nothing comes back
    /// rather than nonsense coming back — is stamped once and left alone.
    ///
    /// Distinct from the undecodable case above, and the distinction is what a mutation exposed: a
    /// survey that only records what it managed to read leaves this file unstamped and reopens it
    /// forever, which the glyph-soup fixture cannot show because that one *does* return text.
    @Test func aDocumentThatYieldsNothingIsStillStamped() async throws {
        let (manager, docs, _, reads) = try Self.makeTree()
        try Self.write(docs.appendingPathComponent("Health/Kaiser/imageonly.pdf"), "")
        manager.filingSnippetExtractor = { path in
            reads.note(path)
            return path.hasSuffix("imageonly.pdf") ? nil : (try? String(contentsOfFile: path, encoding: .utf8))
        }
        _ = await manager.resurveyFilingMemory(root: docs)
        #expect(reads.paths.contains { $0.hasSuffix("imageonly.pdf") })

        reads.reset()
        let second = await manager.resurveyFilingMemory(root: docs)
        #expect(second.documentsRead == 0)
        #expect(reads.paths.isEmpty)
    }

    /// **An evicted iCloud file is not an empty document.** Both come back with nothing, and
    /// stamping this one would write off a whole offloaded folder in a single pass — on a tree that
    /// lives in iCloud Documents, permanently.
    @Test func anUndownloadedDocumentIsSkippedRatherThanStampedBlank() async throws {
        let (manager, docs, _, reads) = try Self.makeTree()
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

    /// **The availability answer goes stale, and the stamp it licenses is permanent.** It is asked
    /// once, before a batch that takes minutes on a real tree; a file the provider evicts inside
    /// that window extracts as nothing and used to be stamped blank — against a size and mtime that
    /// do not move when the content comes back, so the write-off never invalidates. Exactly the
    /// outcome `isAvailable` exists to prevent, reached through a stale answer instead of a missing
    /// check.
    ///
    /// The blank is what makes it reachable: a document that produced text plainly had its bytes on
    /// disk, so only the empty results are re-asked.
    @Test func aDocumentEvictedWhileTheSurveyReadsIsNotStampedBlank() async throws {
        let (manager, docs, profiles, reads) = try Self.makeTree()
        try Self.write(docs.appendingPathComponent("Health/Kaiser/offloaded.pdf"),
                       Self.page("Kaiser Permanente dermatology"))

        // Available when the batch is chosen; gone by the time its (empty) result is stamped.
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
        #expect(first.documentsUnavailable == 0, "fixture: it must be judged available up front")
        #expect(reads.paths.contains { $0.hasSuffix("offloaded.pdf") }, "fixture: it must be opened")

        let corpus = try #require(FilingSurveyStore.corpus(id: "t", in: profiles))
        #expect(corpus.documents.keys.contains { $0.hasSuffix("offloaded.pdf") } == false,
                "an evicted file was stamped, and the stamp can never invalidate")

        // It comes back down, and the next survey learns from it — the proof that nothing was
        // written off. Now available at both asks, and the extractor returns its text.
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

    /// And the other direction, so the guard above cannot become "never stamp a blank": a document
    /// that is genuinely there and genuinely yields nothing is still stamped once, or the survey
    /// reopens every image-only scan forever. Same fixture as
    /// ``aDocumentThatYieldsNothingIsStillStamped``, stated against the availability seam.
    @Test func aBlankFromAFileThatIsStillThereIsStillStamped() async throws {
        let (manager, docs, profiles, reads) = try Self.makeTree()
        try Self.write(docs.appendingPathComponent("Health/Kaiser/imageonly.pdf"), "")
        manager.filingDocumentIsAvailable = { _ in true }
        manager.filingSnippetExtractor = { path in
            reads.note(path)
            return path.hasSuffix("imageonly.pdf") ? nil : (try? String(contentsOfFile: path, encoding: .utf8))
        }
        _ = await manager.resurveyFilingMemory(root: docs)

        let corpus = try #require(FilingSurveyStore.corpus(id: "t", in: profiles))
        #expect(corpus.documents.keys.contains { $0.hasSuffix("imageonly.pdf") },
                "a readable-but-empty document must be stamped, or it is reopened every survey")

        reads.reset()
        let second = await manager.resurveyFilingMemory(root: docs)
        #expect(second.documentsRead == 0)
        #expect(reads.paths.isEmpty)
    }

    /// With no artifacts and no extractor there is nothing to do, and saying so beats writing an
    /// empty memory over a tree nobody surveyed.
    @Test func aMachineWithNoProfileIsLeftAlone() async throws {
        let (manager, docs, profiles, _) = try Self.makeTree()
        manager.filingFolderProfile = nil
        manager.filingMemory = nil
        let report = await manager.resurveyFilingMemory(root: docs)
        #expect(report == .none)
        #expect(!FileManager.default.fileExists(atPath: profiles.path))
    }
}
