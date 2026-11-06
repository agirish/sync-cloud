import Foundation
import Testing
@testable import Sync

/// How routing is wired into a real scan, which the router's unit tests can't see: how many times
/// a page is read, how often the index is rebuilt, and what reaches the model.
@Suite @MainActor struct FilingScanRouterWiringTests {

    /// Counts every call to each extractor seam, so "read once" is asserted rather than described.
    final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var snippets: [String] = []
        private(set) var tokens: [String] = []
        func snippet(_ p: String) { lock.lock(); snippets.append(p); lock.unlock() }
        func token(_ p: String) { lock.lock(); tokens.append(p); lock.unlock() }
    }

    /// `root` is the tree the profile describes. A scan of another tree uses the profile only when
    /// half or more of that tree's folders are in it, so a fixture meaning "this tree's survey"
    /// records the tree it scans.
    static func profile(_ folders: [String], root: String = "~") -> FolderProfile {
        let entries = folders.map {
            FolderProfileEntry(path: $0, role: .destination, naming: nil, anchors: [],
                               acceptsNewFiles: nil, fileCount: 2, subfolderCount: 0, axes: [:])
        }
        return FolderProfile(profileId: "t", root: root,
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
            m.filingFolderProfile = profile(["Documents/Home/Utilities/PG&E/2023"], root: root.path)
            m.filingMemory = memory("Documents/Home/Utilities/PG&E/2023", ["pge", "electric"])
        }
        return (m, root)
    }

    /// One read per file, three consumers. Tokens are derived from the text the router needs anyway,
    /// so the keyword pass must not read the page again.
    @Test func aPageIsReadOnceWhenTheRouterIsActive() async throws {
        let reads = Reads()
        let (m, root) = try Self.makeScan(reads, withRouter: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        let bill = reads.snippets.filter { $0.hasSuffix("9829custbill.pdf") }
        #expect(bill.count == 1, "page read \(bill.count) times, expected once")
        #expect(reads.tokens.isEmpty, "the token extractor re-read a page the router already had")
    }

    /// Without a profile the scan reads through the token extractor, not the snippet one, so an
    /// unsurveyed tree is unaffected.
    @Test func withoutAProfileTheOldReadPathIsUsed() async throws {
        let reads = Reads()
        let (m, root) = try Self.makeScan(reads, withRouter: false)
        defer { try? FileManager.default.removeItem(at: root) }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        #expect(!reads.tokens.isEmpty, "the content extractor must still be the reader here")
        #expect(reads.snippets.filter { $0.hasSuffix("9829custbill.pdf") }.isEmpty)
    }

    /// The index is rebuilt only when the taxonomy moves: it costs ~85 ms on a real tree, and the
    /// folder set is usually identical from one scan to the next.
    @Test func theIndexIsReusedUntilTheTaxonomyChanges() {
        let m = FileSyncManager()
        m.filingFolderProfile = Self.profile(["A/B", "A/C"])
        m.filingMemory = Self.memory("A/B", ["kaiser"])

        m.prepareFilingRouter(destinations: ["A/B", "A/C"])
        #expect(m.filingRouterIndex != nil)
        #expect(m.filingRouterIndexBuilds == 1)

        // Same set, different order. Only the counter can see a rebuild here, since the new index
        // would equal the old.
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

    /// A real tree is wider than the classifier's folder budget, so a menu filled shallowest-first
    /// can't contain a deep document's home. Here 300 shallow decoys crowd out a depth-4 folder the
    /// router wants, and the model must be shown it anyway. Also, the page routing already read is
    /// handed to the classifier, even when the filename looks meaningful.
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
        m.filingFolderProfile = Self.profile([target, "Documents/Records/Consular"], root: root.path)
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

        // For contrast, the depth-ordered list the scan caches: 250 folders, without the target, so
        // the tree really does truncate.
        #expect(m.filingLastTaxonomyFolders.count == 250)
        #expect(!m.filingLastTaxonomyFolders.contains(target),
                "the decoys no longer crowd out the target — the fixture has gone stale")
        #expect(seen.menu.contains(target), "the router's own pick never reached the model: \(seen.menu.count) folders")
        // A meaningful filename no longer costs the model the page that was already read for it.
        #expect(seen.snippets.contains { $0 == vocabulary })
    }

    /// Only files with no confident home pay for entity tokenization. `filingTokensFromText` runs
    /// NaturalLanguage over up to 20,000 characters, and its only consumer is the keyword re-suggest
    /// for homeless files; for every read file it would burn minutes of CPU and change suggestions
    /// for files that had a home. Counted, since the tokens look the same either way.
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
        m.filingFolderProfile = Self.profile([target], root: root.path)
        m.filingMemory = Self.memory(target, vocabulary.split(separator: " ").map(String.init))
        m.filingClassifier = { _, _, _ in [:] }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        // Counted at phase 2: routing later places the homeless file, so by the end both have homes
        // and `filingSuggestions` can't show the distinction.
        #expect(counts.snippets == 2, "both files must be READ — that is what the menu needs")
        #expect(counts.tokenized == 1,
                "only the file the keyword engine could not place has a consumer for these tokens")
    }

    /// A file that already has a home is still ranked and read. Skipped, the model would judge it
    /// from its filename alone against a menu built for every other file, while the router, given
    /// page 1, ranks its real home first. The loose file's name is one the keyword engine can place,
    /// so it reaches routing with a confident home.
    @Test func aFileThatAlreadyHasAHomeStillGetsRankedAndRead() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingHomed")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = "Documents/Home/Utilities/T-Mobile/2025"
        try Self.write(root.appendingPathComponent("\(target)/.keep"), bytes: 1)
        try Self.write(root.appendingPathComponent("Documents/Finance/US/.keep"), bytes: 1)
        try Self.write(root.appendingPathComponent("Downloads/Tax Statement 2025.pdf"))
        // The target must be out of reach of the structural fallback, or `menu.contains(target)`
        // passes on a tree small enough to list whole.
        for i in 0..<300 {
            try Self.write(root.appendingPathComponent("Documents/Decoy\(String(format: "%03d", i))/.keep"),
                           bytes: 1)
        }

        let vocabulary = "autopay unlimited talk voice appreciation paperless"
        let m = FileSyncManager()
        m.filingContentExtractor = { _ in Set(FilingRouter.tokenize(vocabulary)) }
        m.filingSnippetExtractor = { _ in vocabulary }
        m.filingTokensFromText = { Set(FilingRouter.tokenize($0)) }
        m.filingFolderProfile = Self.profile([target], root: root.path)
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

    /// The scan notes a PDF it read and got nothing from, which puts the offer on the card, but
    /// doesn't spend the 0.5–2.1 s of rendering and Vision it would take to read it.
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
        m.filingFolderProfile = Self.profile([target], root: root.path)
        m.filingMemory = Self.memory(target, ["lease", "tenancy", "landlord"])
        m.filingClassifier = { _, _, _ in [:] }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        #expect(m.filingUnreadableScans.contains(root.appendingPathComponent("Downloads/scanned.pdf").path))
        #expect(!m.filingUnreadableScans.contains(root.appendingPathComponent("Downloads/readable.pdf").path))
        #expect(calls.ocr.isEmpty, "the scan spent OCR it was supposed to only offer")
    }

    /// The offer, taken: OCR runs once, its text routes the file, and the card stops offering.
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
        m.filingFolderProfile = Self.profile([target], root: root.path)
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

    /// OCR that finds nothing retires the offer too, or the button invites the same multi-second
    /// wait for the same nothing.
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
        m.filingFolderProfile = Self.profile(["Documents/Home/Leases"], root: root.path)
        m.filingMemory = Self.memory("Documents/Home/Leases", ["lease"])
        m.filingClassifier = { _, _, _ in [:] }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        let s = try #require(m.filingSuggestions.first)
        #expect(await m.readScan(for: s) == false)
        #expect(!m.filingUnreadableScans.contains(s.filePath))
    }

    /// Read scan routes only against its own provider's index. A To File scan of another provider
    /// replaces the cached index and root before it walks, and one cancelled mid-run never
    /// republishes, so this provider's cards can sit over another's cache. Unguarded, the card
    /// would route to the other provider's `Leases` and "File here" would move it across accounts.
    @Test func readScanRefusesACacheFromAnotherProvider() async throws {
        let rootA = try makeCanonicalTempRoot(prefix: "FilingScanReadA")
        let rootB = try makeCanonicalTempRoot(prefix: "FilingScanReadB")
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let target = "Documents/Home/Leases"
        for root in [rootA, rootB] {
            try Self.write(root.appendingPathComponent("\(target)/.keep"), bytes: 1)
            try Self.write(root.appendingPathComponent("Downloads/scanned.pdf"))
        }
        let m = FileSyncManager()
        m.filingContentExtractor = { _ in [] }
        m.filingSnippetExtractor = { _ in nil }
        m.filingTokensFromText = { Set(FilingRouter.tokenize($0)) }
        m.filingOCRExtractor = { _ in "lease tenancy landlord rent" }
        // Surveyed in A; B copies A's layout, so it borrows A's survey and builds an index.
        m.filingFolderProfile = Self.profile(["Documents", "Documents/Home", target], root: rootA.path)
        m.filingMemory = Self.memory(target, ["lease", "tenancy", "landlord"])
        m.filingClassifier = { _, _, _ in [:] }

        // Provider B's cache, captured; then provider A's cards on screen.
        await m.findFilingSuggestions(folder: rootB.appendingPathComponent("Downloads"), providerRoot: rootB)
        let otherIndex = try #require(m.filingRouterIndex)
        await m.findFilingSuggestions(folder: rootA.appendingPathComponent("Downloads"), providerRoot: rootA)
        let s = try #require(m.filingSuggestions.first)
        #expect(s.providerRoot == rootA.path)
        #expect(s.best == nil, "the fixture needs a file with no home before the read")
        #expect(m.filingUnreadableScans.contains(s.filePath))

        // What a cancelled scan of B leaves behind: B's index and root under A's cards.
        m.filingRouterIndex = otherIndex
        m.filingLastProviderRoot = rootB.path

        m.banner = nil
        #expect(await m.readScan(for: s) == false)
        let after = try #require(m.filingSuggestions.first)
        #expect(after.best == nil,
                "Read scan routed provider A's card onto \(after.best?.path ?? "-") from provider B's index")
        #expect(!(after.best?.path.hasPrefix(rootB.path) ?? false))
        // The refusal isn't silent: it says to scan again, and stops offering a read this list
        // can't make.
        let banner = try #require(m.banner, "Read scan was refused without a word")
        #expect(banner.message.contains("Scan this folder again"), "\(banner.message)")
        #expect(!m.filingUnreadableScans.contains(s.filePath), "the dead offer stayed up")
    }
}
