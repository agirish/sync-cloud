import Foundation
import Testing
@testable import Sync

/// How phase 2.5 is wired into a real scan — the parts unit tests on the router itself cannot see:
/// how many times a page is read, and how often the index is rebuilt.
@Suite @MainActor struct FilingScanRouterWiringTests {

    /// Counts every call to each extractor seam, so "read once" is asserted rather than described.
    final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var snippets: [String] = []
        private(set) var tokens: [String] = []
        func snippet(_ p: String) { lock.lock(); snippets.append(p); lock.unlock() }
        func token(_ p: String) { lock.lock(); tokens.append(p); lock.unlock() }
    }

    static func profile(_ folders: [String]) -> FolderProfile {
        let entries = folders.map {
            FolderProfileEntry(path: $0, role: .destination, naming: nil, anchors: [],
                               acceptsNewFiles: nil, fileCount: 2, subfolderCount: 0, axes: [:])
        }
        return FolderProfile(profileId: "t", root: "~",
                             folders: Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a }),
                             personTokens: [])
    }

    static func memory(_ folder: String, _ anchors: [String]) -> FilingMemory {
        FilingMemory(profileId: "t", salt: "s", folders: [
            folder: FilingMemoryEntry(docs: 4,
                                      anchors: anchors.map { FilingMemoryToken(token: $0, weight: 4.0) },
                                      idHashes: []),
        ])
    }

    static func write(_ url: URL, bytes: Int = 5000) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    /// `filingReadsContents` defaults to true, which is what this exercises.
    static func makeScan(_ reads: Reads, withRouter: Bool) throws -> (FileSyncManager, URL) {
        let root = try makeCanonicalTempRoot(prefix: "FilingWiring")
        try write(root.appendingPathComponent("Documents/Home/Utilities/PG&E/2023/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Downloads/9829custbill.pdf"))
        let m = FileSyncManager()
        m.filingContentExtractor = { p in reads.token(p); return ["pge"] }
        m.filingSnippetExtractor = { p in reads.snippet(p); return "PG&E gas and electric 2023" }
        m.filingTokensFromText = { _ in ["pge"] }
        if withRouter {
            m.filingFolderProfile = profile(["Documents/Home/Utilities/PG&E/2023"])
            m.filingMemory = memory("Documents/Home/Utilities/PG&E/2023", ["pge", "electric"])
        }
        return (m, root)
    }

    /// **One read per file, three consumers.** Tokens are derived from the text the router needs
    /// anyway, so the keyword pass must not read the page a second time.
    @Test func aPageIsReadOnceWhenTheRouterIsActive() async throws {
        let reads = Reads()
        let (m, root) = try Self.makeScan(reads, withRouter: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        let bill = reads.snippets.filter { $0.hasSuffix("9829custbill.pdf") }
        #expect(bill.count == 1, "page read \(bill.count) times, expected once")
        #expect(reads.tokens.isEmpty, "the token extractor re-read a page the router already had")
    }

    /// Without a profile the scan takes the path it always took — the token extractor, not the
    /// snippet one. Otherwise the "unchanged when unsurveyed" claim is only a claim.
    @Test func withoutAProfileTheOldReadPathIsUsed() async throws {
        let reads = Reads()
        let (m, root) = try Self.makeScan(reads, withRouter: false)
        defer { try? FileManager.default.removeItem(at: root) }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        #expect(!reads.tokens.isEmpty, "the content extractor must still be the reader here")
        #expect(reads.snippets.filter { $0.hasSuffix("9829custbill.pdf") }.isEmpty)
    }

    /// **The index is rebuilt only when the taxonomy moves.** It costs ~85 ms against a real tree
    /// and the folder set is usually identical from one scan to the next.
    @Test func theIndexIsReusedUntilTheTaxonomyChanges() {
        let m = FileSyncManager()
        m.filingFolderProfile = Self.profile(["A/B", "A/C"])
        m.filingMemory = Self.memory("A/B", ["kaiser"])

        m.prepareFilingRouter(destinations: ["A/B", "A/C"])
        #expect(m.filingRouterIndex != nil)
        #expect(m.filingRouterIndexBuilds == 1)

        // Same set, different order — a rebuild here would be invisible without the counter,
        // because the index it produced would equal the one it replaced.
        m.prepareFilingRouter(destinations: ["A/C", "A/B"])
        #expect(m.filingRouterIndexBuilds == 1, "the index was rebuilt for an unchanged taxonomy")

        m.prepareFilingRouter(destinations: ["A/B", "A/C", "A/D"])   // moved
        #expect(m.filingRouterIndexBuilds == 2)
        #expect(m.filingRouterIndex?.destinations.count == 3)

        // Replacing the artifacts must drop it, or a new profile would be scored with the old index.
        m.filingMemory = Self.memory("A/B", ["different"])
        #expect(m.filingRouterIndex == nil)
        #expect(m.filingRouterIndexKey == nil)
        m.prepareFilingRouter(destinations: ["A/B", "A/C", "A/D"])
        #expect(m.filingRouterIndexBuilds == 3, "a replaced profile must force a rebuild")
    }

    @Test func noArtifactsMeansNoIndex() {
        let m = FileSyncManager()
        m.prepareFilingRouter(destinations: ["A/B"])
        #expect(m.filingRouterIndex == nil)
    }

    /// **The whole bug, end to end.** A real tree is wider than the classifier's folder budget, and
    /// the budget used to be spent shallowest-first — so on a 5,012-folder tree the menu stopped at
    /// depth 3 and a document belonging five levels down was judged against a list that could not
    /// contain its home. Here 300 shallow decoys crowd out a depth-4 destination the router has
    /// every reason to want, and the model must be shown it anyway. Also pins the other half: the
    /// page phase 2.5 already read is handed to the classifier rather than thrown away because the
    /// filename looked meaningful.
    @Test func theFolderTheRouterWantsReachesTheModelPastTheDepthCap() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingMenu")
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<300 {
            try Self.write(root.appendingPathComponent("Documents/Decoy\(String(format: "%03d", i))/.keep"),
                           bytes: 1)
        }
        let target = "Documents/Records/Consular/Issuance"
        try Self.write(root.appendingPathComponent("\(target)/.keep"), bytes: 1)
        try Self.write(root.appendingPathComponent("Downloads/H1B Visa - Nov 2026.pdf"))

        let vocabulary = "consulate foil annotation nonimmigrant issuance reciprocity"
        let m = FileSyncManager()
        m.filingContentExtractor = { _ in Set(FilingRouter.tokenize(vocabulary)) }
        m.filingSnippetExtractor = { _ in vocabulary }
        m.filingTokensFromText = { Set(FilingRouter.tokenize($0)) }
        m.filingFolderProfile = Self.profile([target, "Documents/Records/Consular"])
        m.filingMemory = Self.memory("Documents/Records/Consular", vocabulary.split(separator: " ").map(String.init))

        final class Seen: @unchecked Sendable {
            var menu: [String] = []
            var snippets: [String?] = []
        }
        let seen = Seen()
        m.filingClassifier = { context, files, _ in
            seen.menu = context.taxonomyFolders
            seen.snippets = files.map(\.contentSnippet)
            return [:]
        }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        // The depth-ordered list the scan still caches, for contrast: 250 folders, and the target is
        // not among them. Without this the test could pass on a tree small enough not to truncate.
        #expect(m.filingLastTaxonomyFolders.count == 250)
        #expect(!m.filingLastTaxonomyFolders.contains(target),
                "the decoys no longer crowd out the target — the fixture has gone stale")
        #expect(seen.menu.contains(target), "the router's own pick never reached the model: \(seen.menu.count) folders")
        // A meaningful filename no longer costs the model the page that was already read for it.
        #expect(seen.snippets.contains { $0 == vocabulary })
    }

    /// **The file that already has a home is the one the model gets most wrong.** Phase 2.5 used to
    /// skip it — no ranking, so no shortlist and no page read — and phase 3 then asked about it
    /// from its filename alone, against a menu describing every file except that one. A T-Mobile
    /// bill named `DetailedBillApr2025.pdf` came back as a new `Finance/US/Accounts`, while the
    /// router, given page 1, ranks its real home first out of thousands of folders.
    ///
    /// The fixture's loose file carries a name the keyword engine CAN place, so it arrives at phase
    /// 2.5 with a confident home — which is the whole condition under test.
    @Test func aFileThatAlreadyHasAHomeStillGetsRankedAndRead() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingHomed")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = "Documents/Home/Utilities/T-Mobile/2025"
        try Self.write(root.appendingPathComponent("\(target)/.keep"), bytes: 1)
        try Self.write(root.appendingPathComponent("Documents/Finance/US/.keep"), bytes: 1)
        try Self.write(root.appendingPathComponent("Downloads/Tax Statement 2025.pdf"))
        // The target must be out of reach of the structural fallback, or `menu.contains(target)`
        // passes on a tree small enough to list whole — which is how the first version of this test
        // survived reverting the very change it is about.
        for i in 0..<300 {
            try Self.write(root.appendingPathComponent("Documents/Decoy\(String(format: "%03d", i))/.keep"),
                           bytes: 1)
        }

        let vocabulary = "autopay unlimited talk voice appreciation paperless"
        let m = FileSyncManager()
        m.filingContentExtractor = { _ in Set(FilingRouter.tokenize(vocabulary)) }
        m.filingSnippetExtractor = { _ in vocabulary }
        m.filingTokensFromText = { Set(FilingRouter.tokenize($0)) }
        m.filingFolderProfile = Self.profile([target])
        m.filingMemory = Self.memory(target, vocabulary.split(separator: " ").map(String.init))

        final class Seen: @unchecked Sendable {
            var menu: [String] = []
            var snippets: [String?] = []
        }
        let seen = Seen()
        m.filingClassifier = { context, files, _ in
            seen.menu = context.taxonomyFolders
            seen.snippets = files.map(\.contentSnippet)
            return [:]
        }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        let s = try #require(m.filingSuggestions.first)
        #expect(s.hasConfidentHome, "the fixture no longer exercises the confident-home path")
        #expect(seen.menu.contains(target), "the router never ranked a file that already had a home")
        #expect(seen.snippets.contains { $0 == vocabulary },
                "its page was never read, so the model judged it on the filename alone")
    }
}
