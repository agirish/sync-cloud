import Foundation
import Testing
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
        #expect(!manager.filingArtifactFingerprint.isEmpty)
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
