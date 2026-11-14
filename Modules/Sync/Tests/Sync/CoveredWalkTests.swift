import Testing
import Foundation
@testable import Sync

/// The walk half of `FileNode.isCoveredElsewhere`: the tree builder marks a linked-in folder it
/// also reaches directly, and only then. Mark too little and a `~` scan counts `~/Documents` twice
/// (Storage over by its size, Duplicates offering to Trash it as a copy of itself). Mark too much
/// and a scan rooted at the iCloud container loses the folder, since there the link is the only
/// route to it.
@Suite(.serialized) struct CoveredWalkTests {

    /// A root holding `Documents/a.txt` and a container that links `Documents` back in, the shape
    /// macOS's Desktop & Documents syncing makes. The root is canonical, or the link table, keyed
    /// on the other spelling, never matches and the suite measures nothing.
    static func fixture() throws -> (root: URL, real: URL, container: URL) {
        let fm = FileManager.default
        let root = try makeCanonicalTempRoot(prefix: "covered")
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

    /// Walking the root reaches `Documents` twice with one id, and only the second is marked.
    @Test func aFolderReachedTwiceIsMarkedOnceAndCountedOnce() async throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = await FileSyncManager.buildTree(url: f.root, sortOption: .name,
                                                   linkedFolders: Self.links(f))
        var hits: [FileNode] = []
        Self.nodes(tree, id: f.real.path, into: &hits)

        // The premise: the substitution puts the same path in the tree twice, and neither copy is
        // a symlink, so `isSymbolicLink` can't catch it.
        #expect(hits.count == 2, "the fixture did not reproduce the double reach (hits: \(hits.count)) — the link table probably never matched")
        #expect(hits.allSatisfy { $0.isSymbolicLink != true }, "a copy is flagged as a symlink; this case is defined by NOT being one")
        #expect(hits.filter { $0.isCoveredElsewhere == true }.count == 1,
                "expected exactly one of the two reaches to be marked, got \(hits.map(\.isCoveredElsewhere))")

        // The direct one, the shorter route, is the copy left unmarked.
        #expect(hits.first?.isCoveredElsewhere != true,
                "the DIRECT reach was marked; the tree is walked in listing order, so the shorter route must survive")

        #expect(StorageLensAnalyzer.analyze(tree: tree, now: Date()).totalBytes == 1000,
                "Storage counted the 1000-byte file more than once")
    }

    /// Rooted at the container, the link is the only route: nothing may be marked, or that source
    /// loses the folder from every total it reports.
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

    /// A walk with no link table is untouched: the flag never appears on an ordinary tree.
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
