import Testing
import Foundation
@testable import Sync

/// **The walk half of `FileNode.isCoveredElsewhere`** — does the tree builder notice that a folder
/// it linked in is one it also reaches directly, and does it decline to say so when it isn't?
///
/// Both directions matter and they pull opposite ways. Mark too little and a `~` scan counts
/// `~/Documents` twice (Storage over by its whole size, Duplicates offering to Trash it as a copy
/// of itself — both measured on a real machine 2026-09-08). Mark too much and a scan rooted AT the
/// iCloud container loses that folder from its totals entirely, because there the link is the only
/// route to it.
@Suite(.serialized) struct CoveredWalkTests {

    /// A root holding `Documents/a.txt` and a container that links `Documents` back in — the shape
    /// macOS's Desktop & Documents syncing really makes.
    ///
    /// **The spelling is taken from the filesystem, not predicted.** Neither
    /// `URL.resolvingSymlinksInPath()` nor `NSString`'s equivalent turns `/var/folders/…` into
    /// `/private/var/folders/…` on this platform, but `contentsOfDirectory(at:)` returns the
    /// resolved form — and a link table keyed on the other spelling silently never matches, so the
    /// substitution under test never runs and the suite passes while measuring nothing. That
    /// mistake produced two wrong conclusions before it was caught, including "no fixture can
    /// reproduce this".
    static func fixture() throws -> (root: URL, real: URL, container: URL) {
        let fm = FileManager.default
        let raw = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("covered-\(UUID().uuidString)")
        try fm.createDirectory(at: raw, withIntermediateDirectories: true)
        try Data().write(to: raw.appendingPathComponent(".seed"))
        let root = try fm.contentsOfDirectory(at: raw, includingPropertiesForKeys: nil, options: [])[0]
            .deletingLastPathComponent()
        let real = root.appendingPathComponent("Documents")
        let container = root.appendingPathComponent("Library/CloudDocs")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 1000).write(to: real.appendingPathComponent("a.txt"))
        try fm.createSymbolicLink(at: container.appendingPathComponent("Documents"), withDestinationURL: real)
        return (root, real, container)
    }

    static func links(_ f: (root: URL, real: URL, container: URL)) -> PathBoundary.LinkedFolders {
        [PathBoundary.normalizedRoot(f.container.path): ["Documents": f.real.path]]
    }

    static func nodes(_ ns: [FileNode], id: String, into out: inout [FileNode]) {
        for n in ns { if n.id == id { out.append(n) }; if n.isDirectory { nodes(n.children ?? [], id: id, into: &out) } }
    }

    /// Walking the root reaches `Documents` twice, with ONE id — and only the second is marked.
    @Test func aFolderReachedTwiceIsMarkedOnceAndCountedOnce() async throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = await FileSyncManager.buildTree(url: f.root, sortOption: .name,
                                                   linkedFolders: Self.links(f))
        var hits: [FileNode] = []
        Self.nodes(tree, id: f.real.path, into: &hits)

        // The premise the whole flag exists for: the substitution really does put the SAME path in
        // the tree twice, and neither copy is a symlink — so `isSymbolicLink` could never have
        // caught this.
        #expect(hits.count == 2, "the fixture did not reproduce the double reach (hits: \(hits.count)) — the link table probably never matched")
        #expect(hits.allSatisfy { $0.isSymbolicLink != true }, "a copy is flagged as a symlink; this case is defined by NOT being one")
        #expect(hits.filter { $0.isCoveredElsewhere == true }.count == 1,
                "expected exactly one of the two reaches to be marked, got \(hits.map(\.isCoveredElsewhere))")

        // And the direct one — the shorter route — is the copy left unmarked.
        var direct: [FileNode] = []
        Self.nodes(tree, id: f.real.path, into: &direct)
        #expect(direct.first?.isCoveredElsewhere != true,
                "the DIRECT reach was marked; the tree is walked in listing order, so the shorter route must survive")

        #expect(StorageLensAnalyzer.analyze(tree: tree, now: Date()).totalBytes == 1000,
                "Storage counted the 1000-byte file more than once")
    }

    /// **Rooted at the container, the link is the ONLY route** — nothing may be marked, or that
    /// source loses the folder from every total it reports.
    @Test func aFolderReachedOnlyThroughTheLinkIsNotMarked() async throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = await FileSyncManager.buildTree(url: f.container, sortOption: .name,
                                                   linkedFolders: Self.links(f))
        var hits: [FileNode] = []
        Self.nodes(tree, id: f.real.path, into: &hits)
        #expect(hits.count == 1, "premise: the container reaches Documents exactly once")
        #expect(hits.first?.isCoveredElsewhere != true,
                "the container's only route to Documents was marked as covered elsewhere — its bytes would vanish from this source")
        #expect(StorageLensAnalyzer.analyze(tree: tree, now: Date()).totalBytes == 1000,
                "the container's own total lost the linked folder")
    }

    /// A walk with no link table is untouched — the flag must never appear on an ordinary tree.
    @Test func anOrdinaryWalkMarksNothing() async throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = await FileSyncManager.buildTree(url: f.root, sortOption: .name, linkedFolders: [:])
        func anyMarked(_ ns: [FileNode]) -> Bool {
            ns.contains { $0.isCoveredElsewhere == true || anyMarked($0.children ?? []) }
        }
        #expect(!anyMarked(tree), "a walk with no linked folders produced a covered-elsewhere mark")
    }
}
