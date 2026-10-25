import Foundation
import Testing
@testable import Sync

/// The duplicate scan never uses what sits under an ignored name — `.git`, `node_modules`,
/// `.build` — because `DuplicateFinder.collect` stops at the name. It used to hash, fingerprint and
/// link-check those subtrees anyway: a repository's objects were read for digests nothing could
/// group, every PDF in `node_modules` was parsed, and their hard links (a local clone shares its
/// objects that way) were counted in the scan's "outside duplicate detection" note.
@Suite struct DuplicateIgnoredSubtreeTests {

    @MainActor
    @Test func nothingUnderAnIgnoredNameIsHashedReadOrCounted() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DupIgnoredSubtree")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        func write(_ rel: String, _ byte: UInt8, count: Int = 4096) throws -> URL {
            let url = root.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: byte, count: count).write(to: url)
            return url
        }
        // Controls, outside any ignored name: a real identical pair, a document, a hard link.
        _ = try write("A/notes.txt", 0x41)
        _ = try write("B/notes.txt", 0x41)
        _ = try write("Docs/bill.pdf", 0x50, count: 900)
        let linked = try write("Links/original.bin", 0x4C, count: 3000)
        try fm.linkItem(at: linked, to: root.appendingPathComponent("Links/second.bin"))
        // The same shapes under ignored names, each a candidate for every pass if it were walked:
        // same-size objects, a document, and a hard-linked pair.
        let object = try write("proj/.git/objects/pack.bin", 0x47)
        _ = try write("clone/.git/objects/pack.bin", 0x47)
        try fm.linkItem(at: object, to: root.appendingPathComponent("proj/.git/objects/linked.bin"))
        _ = try write("app/node_modules/pkg/manual.pdf", 0x51, count: 900)
        _ = try write("app/.build/out.pdf", 0x52, count: 900)

        let read = ReadPaths()
        let cache = ContentHashCache()
        let manager = FileSyncManager()
        await manager.findDuplicates(root: root, cache: cache,
                                     textFingerprint: { path in read.add(path); return nil },
                                     fingerprintCache: nil)

        let ignored = ["/.git/", "/node_modules/", "/.build/"]
        let documents = read.all
        #expect(documents.contains { $0.hasSuffix("/Docs/bill.pdf") }, "the control document was never read")
        #expect(!documents.contains { p in ignored.contains { p.contains($0) } },
                "read documents under an ignored name: \(documents.sorted())")
        // Two links outside, none inside: the note counts only what the scan could group.
        #expect(manager.duplicateScanSkips.multiLink == 2, "\(manager.duplicateScanSkips)")
        // Hashed: the control pair (2) and the outside links (2, same size); nothing in `.git`.
        let hashed = await cache.count
        #expect(hashed == 4, "the scan hashed \(hashed) files")
        // The control pair still groups (as the folders `A` and `B`, which hold only it).
        #expect(manager.duplicateGroups.contains { g in g.copies.contains { $0.path.hasSuffix("/B") } },
                "the control pair stopped grouping: \(manager.duplicateGroups.map(\.name))")
    }
}

/// The document reader's calls, gathered from its `@Sendable` closure.
private final class ReadPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
}
