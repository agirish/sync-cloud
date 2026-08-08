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

    /// **Widening a read set must not widen the expensive derivation hanging off it.**
    ///
    /// `filingTokensFromText` is NaturalLanguage entity recognition over up to 20,000 characters,
    /// and its only consumer is the keyword pass's re-suggest, which acts on files with no confident
    /// home. Deriving it for every file now being read spent minutes of CPU on tokens nothing would
    /// look at — a real scan sat at 189% CPU for eleven minutes — and would have silently changed
    /// the suggestions for files that already had a home. A counter, because the tokens themselves
    /// are indistinguishable either way: this is exactly the shape where an equality check passes
    /// vacuously.
    @Test func onlyTheHomelessFilesPayForEntityTokenization() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingCost")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = "Documents/Home/Utilities/T-Mobile/2025"
        try Self.write(root.appendingPathComponent("\(target)/.keep"), bytes: 1)
        // One file the keyword engine can place, one it cannot.
        try Self.write(root.appendingPathComponent("Downloads/Tax Statement 2025.pdf"))
        try Self.write(root.appendingPathComponent("Downloads/9f2a1c.pdf"))

        let vocabulary = "autopay unlimited talk voice appreciation paperless"
        final class Counts: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var snippets = 0, tokenized = 0
            func snippet() { lock.lock(); snippets += 1; lock.unlock() }
            func token() { lock.lock(); tokenized += 1; lock.unlock() }
        }
        let counts = Counts()
        let m = FileSyncManager()
        m.filingContentExtractor = { _ in Set(FilingRouter.tokenize(vocabulary)) }
        m.filingSnippetExtractor = { _ in counts.snippet(); return vocabulary }
        m.filingTokensFromText = { counts.token(); return Set(FilingRouter.tokenize($0)) }
        m.filingFolderProfile = Self.profile([target])
        m.filingMemory = Self.memory(target, vocabulary.split(separator: " ").map(String.init))
        m.filingClassifier = { _, _, _ in [:] }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        // Counted at phase 2, which is why the post-scan state is not the yardstick: phase 2.5 goes
        // on to place the homeless file, so by the end both have homes and the distinction under
        // test has disappeared from `filingSuggestions`.
        #expect(counts.snippets == 2, "both files must be READ — that is what the menu needs")
        #expect(counts.tokenized == 1,
                "only the file the keyword engine could not place has a consumer for these tokens")
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

    // MARK: Reading a scan on request

    /// The scan must NOTICE a PDF it read and got nothing from — that is what puts the offer on the
    /// card — and must not spend the 0.5–2.1 s of rendering and Vision it would take to fix it.
    @Test func aPdfThatYieldsNoTextIsRecordedButNotRead() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingScan")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = "Documents/Home/Leases"
        try Self.write(root.appendingPathComponent("\(target)/.keep"), bytes: 1)
        try Self.write(root.appendingPathComponent("Downloads/scanned.pdf"))
        try Self.write(root.appendingPathComponent("Downloads/readable.pdf"))

        final class Calls: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var ocr: [String] = []
            func ocr(_ p: String) { lock.lock(); ocr.append(p); lock.unlock() }
        }
        let calls = Calls()
        let m = FileSyncManager()
        m.filingContentExtractor = { _ in [] }
        // The scanned one reads as nothing; the other has a text layer.
        m.filingSnippetExtractor = { p in p.hasSuffix("scanned.pdf") ? nil : "lease tenancy landlord" }
        m.filingTokensFromText = { Set(FilingRouter.tokenize($0)) }
        m.filingOCRExtractor = { p in calls.ocr(p); return "WILSON PROPERTY MANAGEMENT lease tenancy" }
        m.filingFolderProfile = Self.profile([target])
        m.filingMemory = Self.memory(target, ["lease", "tenancy", "landlord"])
        m.filingClassifier = { _, _, _ in [:] }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        #expect(m.filingUnreadableScans.contains(root.appendingPathComponent("Downloads/scanned.pdf").path))
        #expect(!m.filingUnreadableScans.contains(root.appendingPathComponent("Downloads/readable.pdf").path))
        #expect(calls.ocr.isEmpty, "the scan spent OCR it was supposed to only offer")
    }

    /// And the offer, taken: OCR runs once, its text routes the file, and the card stops offering.
    @Test func readingAScanRoutesItAndRetiresTheOffer() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingScanRead")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = "Documents/Home/Leases"
        try Self.write(root.appendingPathComponent("\(target)/.keep"), bytes: 1)
        try Self.write(root.appendingPathComponent("Downloads/scanned.pdf"))

        final class Calls: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var count = 0
            func hit() { lock.lock(); count += 1; lock.unlock() }
        }
        let calls = Calls()
        let m = FileSyncManager()
        m.filingContentExtractor = { _ in [] }
        m.filingSnippetExtractor = { _ in nil }
        m.filingTokensFromText = { Set(FilingRouter.tokenize($0)) }
        m.filingOCRExtractor = { _ in calls.hit(); return "lease tenancy landlord rent" }
        m.filingFolderProfile = Self.profile([target])
        m.filingMemory = Self.memory(target, ["lease", "tenancy", "landlord"])
        m.filingClassifier = { _, _, _ in [:] }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        let s = try #require(m.filingSuggestions.first)
        #expect(s.best == nil, "the fixture needs a file with no home before the read")
        #expect(m.filingUnreadableScans.contains(s.filePath))

        let routed = await m.readScan(for: s)
        #expect(routed)
        #expect(calls.count == 1)
        let after = try #require(m.filingSuggestions.first?.best)
        #expect(after.path == root.appendingPathComponent(target).path)
        #expect(after.fromContent, "the home must be marked as read from the document")
        #expect(!m.filingUnreadableScans.contains(s.filePath), "the offer stayed up after being taken")
    }

    /// OCR that finds nothing retires the offer too — otherwise the button invites the same
    /// multi-second wait again, for the same nothing.
    @Test func aScanThatOcrsToNothingStopsBeingOffered() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingScanEmpty")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.write(root.appendingPathComponent("Documents/Home/Leases/.keep"), bytes: 1)
        try Self.write(root.appendingPathComponent("Downloads/scanned.pdf"))
        let m = FileSyncManager()
        m.filingContentExtractor = { _ in [] }
        m.filingSnippetExtractor = { _ in nil }
        m.filingTokensFromText = { Set(FilingRouter.tokenize($0)) }
        m.filingOCRExtractor = { _ in nil }
        m.filingFolderProfile = Self.profile(["Documents/Home/Leases"])
        m.filingMemory = Self.memory("Documents/Home/Leases", ["lease"])
        m.filingClassifier = { _, _, _ in [:] }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        let s = try #require(m.filingSuggestions.first)
        #expect(await m.readScan(for: s) == false)
        #expect(!m.filingUnreadableScans.contains(s.filePath))
    }
}
