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
}
