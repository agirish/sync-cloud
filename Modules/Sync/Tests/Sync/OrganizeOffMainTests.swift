import Foundation
import Testing
@testable import Sync

/// Organize's heavy steps moved off the main thread, and what each move had to keep exactly.
///
/// The orders and sets below are compared against the comparator they replaced, written out here,
/// because the point of each change is that nothing a person sees moves — and a resumed document
/// survey compares its saved plan with a new one string for string.
@Suite struct OrganizeOffMainTests {

    /// The comparator `relativeFolderPaths` and `documentsToRead` used before, verbatim.
    static func oldOrder(_ paths: [String], then inOrder: (String, String) -> Bool) -> [String] {
        paths.sorted { a, b in
            let da = a.split(separator: "/").count, db = b.split(separator: "/").count
            if da != db { return da < db }
            return inOrder(a, b)
        }
    }

    /// Paths where "depth" is easy to get subtly wrong: doubled and trailing slashes (empty
    /// components are not counted), a leading slash, and a combining accent straight after a slash —
    /// which `split` on `Character` treats as part of the slash's grapheme, so that `/` does not
    /// separate. A byte-counting depth would order every one of these differently.
    static let awkward = ["a//b", "/abs/x", "a/\u{301}b/c", "z", "a/b/", "b/a", "a/b", "é/x",
                          "e\u{301}/y", "A/b/c/d", "a b/c", "1/2/3", "10/2", "2/10", "", "/",
                          "x/../y", "./q", "Finance/US", "Finance", "finance/us/2024", "Ünïcode/ß"]

    @Test func shallowestFirstIsTheOldOrderToTheByte() {
        for paths in [Self.awkward, Self.awkward.reversed(), Self.awkward.shuffled()] {
            #expect(FilingEngine.shallowestFirst(paths, then: <) == Self.oldOrder(paths, then: <))
            let localized: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
            #expect(FilingEngine.shallowestFirst(paths, then: localized) == Self.oldOrder(paths, then: localized))
        }
    }

    /// The survey plan, through the real `documentsToRead`.
    @Test func aSurveyPlanKeepsItsOrder() {
        var documents: [String: FilingSurvey.Stamp] = [:]
        for (i, p) in Self.awkward.enumerated() { documents[p + ".pdf"] = FilingSurvey.Stamp(size: i, modified: i) }
        let plan = FilingSurvey.documentsToRead(tree: FilingSurvey.Tree(folders: [:], documents: documents),
                                                corpus: nil)
        let readable = documents.keys.filter {
            FilingSurvey.readableExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }
        #expect(plan.count == readable.count && plan.count > 15, "the fixture stopped exercising the sort")
        #expect(plan == Self.oldOrder(readable, then: <))
    }

    @Test func theFolderSetIsTheSortedListsSet() {
        func dir(_ id: String, _ children: [FileNode] = []) -> FileNode {
            FileNode(id: id, name: (id as NSString).lastPathComponent, isDirectory: true, children: children)
        }
        let taxonomy = [dir("/r/Finance", [dir("/r/Finance/US", [dir("/r/Finance/US/2024")]),
                                           dir("/r/Finance/Taxes.numbers")]),
                        dir("/r/Health", [dir("/r/Health/Kaiser")]), dir("/r/Résumé")]
        let set = FilingEngine.relativeFolderPathSet(of: taxonomy)
        #expect(set.count >= 6)
        #expect(set == Set(FilingEngine.relativeFolderPaths(of: taxonomy, limit: .max)))
    }

    // MARK: - The already-filed index

    static func record(_ path: String, _ hex: String) -> ContentHashRecord {
        ContentHashRecord(path: path, mtime: 0, size: 1, hex: hex, storedAt: Date(timeIntervalSince1970: 0))
    }

    /// The per-lookup existence check gives the answer the build-time one gave, for every identity —
    /// including one whose every copy is gone and one with a copy in the excluded folder.
    @Test func checkingExistenceAtLookupMatchesCheckingItAtBuild() {
        let hashes = [Self.record("/P/TODO/a.pdf", "h1"), Self.record("/P/Work/Pay/b.pdf", "h1"),
                      Self.record("/P/Gone/c.pdf", "h1"), Self.record("/P/Gone/d.pdf", "h2"),
                      Self.record("/P/Health/e.pdf", "h3"), Self.record("/P/Health/Sub/f.pdf", "h3"),
                      Self.record("/Elsewhere/g.pdf", "h3")]
        let fingerprints = [Self.record("/P/Work/Pay/b.pdf", "t1"), Self.record("/P/Gone/c.pdf", "t1")]
        let exists: (String) -> Bool = { !$0.contains("/Gone/") }
        for root in ["/P", "/P/"] {
            let checked = DocumentIdentityIndex.build(hashes: hashes, fingerprints: fingerprints,
                                                      providerRoot: root, existsOnDisk: exists)
            let unchecked = DocumentIdentityIndex.build(hashes: hashes, fingerprints: fingerprints,
                                                        providerRoot: root, existsOnDisk: { _ in true })
            for id in ["b:h1", "b:h2", "b:h3", "f:t1", "b:nope"] {
                for excluding in [nil, "TODO", "Health", "Work/Pay"] {
                    #expect(unchecked.folders(holding: id, excluding: excluding, providerRoot: root,
                                              existsOnDisk: exists)
                            == checked.folders(holding: id, excluding: excluding), "\(id) \(String(describing: excluding))")
                }
            }
            #expect(unchecked.holdsAnyPath(existsOnDisk: exists) == !checked.isEmpty)
        }
        let allGone = DocumentIdentityIndex.build(hashes: [Self.record("/P/Gone/x.pdf", "h")], fingerprints: [],
                                                  providerRoot: "/P", existsOnDisk: { _ in true })
        #expect(!allGone.holdsAnyPath(existsOnDisk: exists))
    }
}

/// The cached identity index, driven through the phase the To File scan runs.
@MainActor
@Suite struct AlreadyFiledIndexCacheTests {

    static func write(_ url: URL, _ bytes: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try bytes.write(to: url)
    }

    static func card(_ loose: URL, _ root: URL) -> FilingSuggestion {
        FilingSuggestion(filePath: loose.path, fileName: loose.lastPathComponent, size: 4096,
                         modificationDate: nil,
                         candidates: [FilingDestination(path: root.appendingPathComponent("Work").path,
                                                        confidence: .high, reasons: ["r"], newSegments: [])],
                         providerRoot: root.path)
    }

    /// **The index is reused while its files are unchanged, and a copy deleted since still stops
    /// vouching.** Caching the index on its files' dates is only safe because existence is no
    /// longer baked into it: the index files do not change when a filed copy is deleted, so a
    /// cached index with the check built in would keep citing a folder that no longer holds it.
    @Test func aCachedIndexStillSeesAFiledCopyDeleted() async throws {
        let root = try makeCanonicalTempRoot(prefix: "AlreadyFiledCache")
        defer { try? FileManager.default.removeItem(at: root) }
        let indexDir = root.appendingPathComponent("index")
        try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x50, count: 4096)
        let filed = root.appendingPathComponent("Work/Pay/payslip.jpg")
        let loose = root.appendingPathComponent("Downloads/Payslip.jpg")
        try Self.write(filed, payload)
        try Self.write(loose, payload)
        let hex = await FileSyncManager.hashFiles([filed.path], fileManager: FileManager.default, cache: nil)[filed.path] ?? ""
        try #require(!hex.isEmpty)
        ContentHashIndexStore.saveInBackground([ContentHashRecord(path: filed.path, mtime: 0, size: 4096, hex: hex,
                                                                  storedAt: Date())],
                                               to: indexDir.appendingPathComponent("content-hash-index.json"))
        ContentHashIndexStore.waitForPendingWrites()

        let m = FileSyncManager()
        m.contentIndexDirectory = indexDir
        let first = await m.markingAlreadyFiled([Self.card(loose, root)], providerRoot: root.path)
        #expect(first.first?.alreadyFiledAt == ["Work/Pay"])
        let built = try #require(m.filingAlreadyFiledIndex, "the scan did not keep its index")

        try FileManager.default.removeItem(at: filed)
        let second = await m.markingAlreadyFiled([Self.card(loose, root)], providerRoot: root.path)
        #expect(m.filingAlreadyFiledIndex?.key == built.key, "an unchanged index file must not be rebuilt")
        #expect(second.first?.isAlreadyFiled == false,
                "a filed copy deleted since the index was built still vouched for its folder")

        // And a changed index file is read again: the copy, filed somewhere new.
        let refiled = root.appendingPathComponent("Work/Payslips/payslip.jpg")
        try Self.write(refiled, payload)
        ContentHashIndexStore.saveInBackground([ContentHashRecord(path: refiled.path, mtime: 0, size: 4096,
                                                                  hex: hex, storedAt: Date()),
                                                ContentHashRecord(path: filed.path, mtime: 0, size: 4096,
                                                                  hex: hex, storedAt: Date())],
                                               to: indexDir.appendingPathComponent("content-hash-index.json"))
        ContentHashIndexStore.waitForPendingWrites()
        let third = await m.markingAlreadyFiled([Self.card(loose, root)], providerRoot: root.path)
        #expect(m.filingAlreadyFiledIndex?.key != built.key)
        #expect(third.first?.alreadyFiledAt == ["Work/Payslips"])
    }
}
