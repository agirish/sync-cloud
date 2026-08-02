import Foundation
import Testing
@testable import Sync

/// Pins `filesInfo(fromTree:basePath:)`'s key derivation against the implementation it replaced.
///
/// That implementation stripped the base with `String(id.dropFirst(basePath.count))` — a GRAPHEME
/// count, recomputed per node, which is why flattening a tree cost more the deeper the pane was
/// focused. The replacement strips by BYTES and keeps the grapheme version as a fallback, so the
/// two must agree on every input, not merely on ASCII.
///
/// `legacyKey` below is that original code, verbatim. Each case asserts the new implementation
/// against it AND against a written-out expectation, because two implementations agreeing proves
/// only that they agree — the literal is what says the agreed answer is the right one.
@Suite struct FilesInfoKeyingTests {

    /// The pre-change key derivation, kept exactly as it was.
    private func legacyKey(_ id: String, basePath: String) -> String {
        var relativePath = id
        if relativePath.hasPrefix(basePath) {
            relativePath = String(relativePath.dropFirst(basePath.count))
        }
        if relativePath.hasPrefix("/") {
            relativePath.removeFirst()
        }
        return relativePath
    }

    /// Drives the real function and reads the key back out. A node id that keys to "" is dropped
    /// unless it is an unexplored directory, so the probe node is a plain file and "" comes back
    /// as nil — which is itself the behaviour the empty-key cases assert.
    private func newKey(_ id: String, basePath: String) -> String? {
        let node = FileNode(id: id, name: (id as NSString).lastPathComponent, isDirectory: false)
        return FileDiffEngine.filesInfo(fromTree: [node], basePath: basePath).keys.first
    }

    private func check(_ id: String, base: String, expected: String?, _ what: String) {
        let new = newKey(id, basePath: base)
        #expect(new == expected, "\(what): got \(new as Any), expected \(expected as Any)")
        // The legacy function has no notion of "dropped", so compare it only where a key exists.
        let legacy = legacyKey(id, basePath: base)
        #expect(new ?? "" == legacy, "\(what): diverged from the pre-change implementation (\(legacy))")
    }

    @Test func stripsAnAsciiBase() {
        check("/a/b/c.txt", base: "/a/b", expected: "c.txt", "direct child")
        check("/a/b/d/e.txt", base: "/a/b", expected: "d/e.txt", "nested child")
    }

    @Test func stripsAnAsciiBaseFromANonAsciiPath() {
        check("/a/b/café.txt", base: "/a/b", expected: "café.txt", "accented leaf")
        check("/a/b/🗂/x.txt", base: "/a/b", expected: "🗂/x.txt", "emoji folder")
    }

    @Test func stripsANonAsciiBase() {
        // The base itself is multi-byte, so a byte count and a grapheme count disagree — the
        // case the hoisted `baseUTF8.count` has to get right.
        check("/a/café/x.txt", base: "/a/café", expected: "x.txt", "accented base")
        check("/a/🗂/x.txt", base: "/a/🗂", expected: "x.txt", "emoji base")
    }

    /// The reason the grapheme fallback survives. `hasPrefix` compares by canonical equivalence,
    /// so a precomposed base matches a decomposed path; their BYTES do not, and slicing by byte
    /// count would cut a character in half. APFS stores names as given, so both spellings are
    /// reachable on one volume.
    @Test func stripsABaseSpelledInADifferentUnicodeNormalization() {
        let precomposed = "/a/caf\u{00E9}"                // é as one code point
        let decomposed = "/a/cafe\u{0301}/x.txt"          // e + combining acute
        // Premises, asserted rather than assumed: canonically equal, byte-wise different. If
        // either stops holding, the case below is testing nothing and should say so loudly.
        #expect(decomposed.hasPrefix(precomposed), "premise: canonically equivalent")
        #expect(!Array(decomposed.utf8).starts(with: Array(precomposed.utf8)), "premise: bytes differ")
        check(decomposed, base: precomposed, expected: "x.txt", "NFD path under an NFC base")

        let nfdBase = "/a/cafe\u{0301}"
        let nfcPath = "/a/caf\u{00E9}/x.txt"
        check(nfcPath, base: nfdBase, expected: "x.txt", "NFC path under an NFD base")
    }

    /// The mirror image of the normalization case above, and the one the first version of the
    /// byte fast path got wrong: the base's BYTES are a prefix of the path, but canonically it is
    /// NOT a prefix, because the boundary lands inside a grapheme cluster. Base "/a/cafe" ends in
    /// a plain "e"; the path's "e" carries a combining acute, making it "é" — one Character.
    /// Slicing by byte count produced "\u{0301}/x.txt", a key starting with a naked combining
    /// mark, where the pre-change code kept the whole path.
    @Test func aByteMatchThatSplitsAGraphemeIsNotTreatedAsAPrefix() {
        let base = "/a/cafe"
        let id = "/a/cafe\u{0301}/x.txt"
        #expect(Array(id.utf8).starts(with: Array(base.utf8)), "premise: the bytes DO match")
        #expect(!id.hasPrefix(base), "premise: as Strings it is NOT a prefix")
        check(id, base: base, expected: "a/cafe\u{0301}/x.txt", "grapheme-splitting byte match")
    }

    /// A base that is a byte-prefix of a SIBLING's name. Both implementations strip it and leave
    /// the name's tail glued to the key — pinned not because it is desirable but because it is
    /// what shipped, and this change must not quietly alter it.
    @Test func aSiblingSharingTheBasesPrefixKeysTheSameAsBefore() {
        check("/a/bb/x.txt", base: "/a/b", expected: "b/x.txt", "sibling sharing the prefix")
    }

    @Test func aPathOutsideTheBaseKeepsItsPathMinusTheLeadingSlash() {
        check("/z/other.txt", base: "/a/b", expected: "z/other.txt", "unrelated path")
    }

    @Test func theBaseItselfIsDropped() {
        // Keys to "", and a plain file at the base is not recorded under the root key.
        #expect(newKey("/a/b", basePath: "/a/b") == nil)
        #expect(legacyKey("/a/b", basePath: "/a/b").isEmpty)
    }

    /// The root-key case the empty key exists for: an unexplored directory AT the base records
    /// itself under "" so `computeDifferences` can suppress whole-side Missing rows.
    @Test func anUnexploredRootStillRecordsTheRootKey() {
        let root = FileNode(id: "/a/b", name: "b", isDirectory: true, children: [], isUnexplored: true)
        let map = FileDiffEngine.filesInfo(fromTree: [root], basePath: "/a/b")
        #expect(map[""]?.isUnexplored == true)
        #expect(map[""]?.url.path == "/a/b")
    }

    /// The invariant `FileInfo`'s own doc claims — "the warm (tree) and cold (disk walk) scan
    /// branches agree" — asserted WHOLESALE over a real directory, rather than field by field on
    /// a few chosen keys as the existing symlink test does.
    ///
    /// It is here because the `isDirectory:` hint changed how the warm branch builds its URLs,
    /// and the two branches build them from entirely different sources: the cold one takes the
    /// enumerator's URLs, the warm one constructs them from a node's path string. Nothing
    /// previously compared the maps as a whole, so a divergence between them — the exact thing
    /// that makes a scan report differently depending on whether the cache happened to be warm —
    /// could only have been caught by noticing a wrong row in the UI.
    @Test func warmAndColdBranchesProduceTheSameMap() async throws {
        let fm = FileManager.default
        let root = try makeCanonicalTempRoot(prefix: "WarmColdAgreement")
        defer { try? fm.removeItem(at: root) }

        // Shapes that have historically diverged or been handled specially: nested dirs, an
        // empty dir, a dotfile, non-ASCII and NFD names, a name with a trailing space, and a
        // symlink to a file (a broken link is dropped by both, pinned elsewhere).
        try fm.createDirectory(at: root.appendingPathComponent("dir/sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appendingPathComponent("dir/a.txt"))
        try Data("bb".utf8).write(to: root.appendingPathComponent("dir/sub/b.txt"))
        try Data("c".utf8).write(to: root.appendingPathComponent(".hidden"))
        try Data("d".utf8).write(to: root.appendingPathComponent("caf\u{00E9}.txt"))
        try Data("e".utf8).write(to: root.appendingPathComponent("nfd-cafe\u{0301}.txt"))
        try Data("f".utf8).write(to: root.appendingPathComponent("trailing space .txt"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.txt"),
                                  withDestinationURL: root.appendingPathComponent("dir/a.txt"))

        let cold = try FileDiffEngine.getFilesInDirectory(root)
        let tree = await FileSyncManager.buildTree(url: root, sortOption: .name)
        let warm = FileDiffEngine.filesInfo(fromTree: tree, basePath: root.path)

        #expect(!cold.isEmpty, "premise: the fixture produced entries")
        #expect(Set(warm.keys) == Set(cold.keys),
                "key sets differ — warm-only \(Set(warm.keys).subtracting(cold.keys)), cold-only \(Set(cold.keys).subtracting(warm.keys))")
        for (key, coldInfo) in cold {
            guard let warmInfo = warm[key] else { continue }   // reported by the key-set check
            #expect(warmInfo.url.path == coldInfo.url.path, "\(key): url.path")
            #expect(warmInfo.isDirectory == coldInfo.isDirectory, "\(key): isDirectory")
            #expect(warmInfo.isUnexplored == coldInfo.isUnexplored, "\(key): isUnexplored")
            #expect(warmInfo.fileSize == coldInfo.fileSize, "\(key): fileSize")
            if let a = warmInfo.modificationDate, let b = coldInfo.modificationDate {
                #expect(abs(a.timeIntervalSince(b)) < 1, "\(key): modificationDate")
            } else {
                #expect((warmInfo.modificationDate == nil) == (coldInfo.modificationDate == nil), "\(key): date nil-ness")
            }
        }
    }

    /// The `isDirectory:` hint added to the URL initializer must not change what consumers read.
    /// Every production reader of `FileInfo.url` goes through `.path`.
    @Test func theDirectoryHintLeavesUrlPathUnchanged() {
        let dir = FileNode(id: "/a/b/sub", name: "sub", isDirectory: true, children: [])
        let file = FileNode(id: "/a/b/f.txt", name: "f.txt", isDirectory: false)
        let map = FileDiffEngine.filesInfo(fromTree: [dir, file], basePath: "/a/b")
        #expect(map["sub"]?.url.path == "/a/b/sub")
        #expect(map["f.txt"]?.url.path == "/a/b/f.txt")
        // And it reproduces exactly what the unhinted initializer resolves to, which is what
        // makes the hint an optimization rather than a different value.
        #expect(map["sub"]?.url == URL(fileURLWithPath: "/a/b/sub", isDirectory: true))
        #expect(map["f.txt"]?.url == URL(fileURLWithPath: "/a/b/f.txt", isDirectory: false))
    }
}
