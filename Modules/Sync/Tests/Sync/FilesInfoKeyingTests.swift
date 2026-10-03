import Foundation
import Testing
@testable import Sync

/// Pins `filesInfo(fromTree:basePath:)`'s keys.
///
/// A key is the path of NAMES from the base down to the node, read off the tree's shape — the
/// function's doc says why. Before that, each key was stripped off the node's id; `legacyKey`
/// below is that strip as it first shipped, verbatim. The two must agree wherever the strip was
/// right, which is every node whose id continues its parent's: every node the walk lists in place,
/// in any script or normalization, under a base spelled either way. The first group pins that, each
/// case against a written-out key AND the strip — two implementations agreeing proves only that
/// they agree, and the literal is what says the agreed answer is the right one.
///
/// The second group pins where they part, on purpose. A node whose id does NOT continue its
/// parent's is what the walk makes of a folder linked in from outside — listed in the link's place
/// as the real folder — and of anything reached through a folder symlink, whose listing comes back
/// resolved. It is keyed where it sits, because that is where the disk walk keys it.
@Suite struct FilesInfoKeyingTests {

    /// The id strip as it first shipped, kept exactly as it was.
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

    /// One branch of a well-formed tree, as the walk builds it: a node per component of `relative`,
    /// each id its parent's id plus its own name, under `base` exactly as spelled.
    private func branch(under base: String, _ relative: String) -> FileNode {
        let names = relative.split(separator: "/").map(String.init)
        var ids: [String] = []
        for name in names { ids.append((ids.last ?? base) + "/" + name) }
        var node = FileNode(id: ids[ids.count - 1], name: names[names.count - 1], isDirectory: false)
        for i in stride(from: names.count - 2, through: 0, by: -1) {
            node = FileNode(id: ids[i], name: names[i], isDirectory: true, children: [node])
        }
        return node
    }

    /// The key every node got, by the node's id — the map read back the other way. Ids are unique
    /// in every tree this is used on, so a node keyed twice is a failure, not a trap.
    private func keysByID(_ tree: [FileNode], basePath: String) -> [String: String] {
        let pairs = FileDiffEngine.filesInfo(fromTree: tree, basePath: basePath).map { ($0.value.url.path, $0.key) }
        let byID = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        #expect(byID.count == pairs.count, "a node was keyed twice: \(pairs.sorted { $0.0 < $1.0 })")
        return byID
    }

    /// Every node of a well-formed tree keyed as written out, and as the strip keyed it.
    private func check(_ tree: [FileNode], base: String, expected: [String: String], _ what: String) {
        let keys = keysByID(tree, basePath: base)
        #expect(keys == expected, "\(what): got \(keys)")
        for (id, key) in keys {
            let legacy = legacyKey(id, basePath: base)
            #expect(key == legacy, "\(what): \(id) diverged from the id strip (\(legacy))")
        }
    }

    // MARK: - Where the shape and the id strip agree

    @Test func keysAnAsciiTree() {
        check([branch(under: "/a/b", "c.txt"), branch(under: "/a/b", "d/e.txt")], base: "/a/b",
              expected: ["/a/b/c.txt": "c.txt", "/a/b/d": "d", "/a/b/d/e.txt": "d/e.txt"], "ASCII")
    }

    @Test func keysNonAsciiNamesUnderAnAsciiBase() {
        check([branch(under: "/a/b", "café.txt"), branch(under: "/a/b", "🗂/x.txt")], base: "/a/b",
              expected: ["/a/b/café.txt": "café.txt", "/a/b/🗂": "🗂", "/a/b/🗂/x.txt": "🗂/x.txt"],
              "non-ASCII names")
    }

    /// A multi-byte base, where a byte count and a grapheme count of it disagree — which the strip
    /// had to get right, and which the shape never counts at all.
    @Test func keysATreeUnderANonAsciiBase() {
        check([branch(under: "/a/café", "x.txt")], base: "/a/café",
              expected: ["/a/café/x.txt": "x.txt"], "accented base")
        check([branch(under: "/a/🗂", "x.txt")], base: "/a/🗂",
              expected: ["/a/🗂/x.txt": "x.txt"], "emoji base")
    }

    /// A base spelled in the other Unicode normalization from the tree's ids. APFS stores names as
    /// given, so both spellings are reachable on one volume; the strip needed a grapheme-count
    /// fallback to survive it, and the shape never reads the base's spelling at all.
    @Test func keysATreeUnderABaseSpelledInTheOtherNormalization() {
        let precomposed = "/a/caf\u{00E9}"                // é as one code point
        let decomposed = "/a/cafe\u{0301}"                // e + combining acute
        // Premises, asserted rather than assumed: canonically equal, byte-wise different. If
        // either stops holding, the cases below are testing nothing and should say so loudly.
        #expect((decomposed + "/x.txt").hasPrefix(precomposed), "premise: canonically equivalent")
        #expect(!Array(decomposed.utf8).starts(with: Array(precomposed.utf8)), "premise: bytes differ")
        check([branch(under: decomposed, "x.txt")], base: precomposed,
              expected: [decomposed + "/x.txt": "x.txt"], "NFD tree under an NFC base")
        check([branch(under: precomposed, "x.txt")], base: decomposed,
              expected: [precomposed + "/x.txt": "x.txt"], "NFC tree under an NFD base")
        // The one thing the shape keying reads of the base is whether a node IS it, and that has to
        // hold across the two spellings as well — an unreadable root spelled one way, under a base
        // spelled the other, is still the root, and still suppresses the whole side.
        let unreadableRoot = FileNode(id: decomposed, name: "cafe\u{0301}", isDirectory: true, children: [],
                                      isUnexplored: true)
        let map = FileDiffEngine.filesInfo(fromTree: [unreadableRoot], basePath: precomposed)
        #expect(map[""]?.isUnexplored == true && map.count == 1, "the root was not recognized: \(Array(map.keys))")
    }

    @Test func theBaseItselfIsDropped() {
        // A plain file AT the base keys to "" under the strip and is not recorded; nor may the
        // shape record it under its own name.
        let map = FileDiffEngine.filesInfo(fromTree: [FileNode(id: "/a/b", name: "b", isDirectory: false)],
                                           basePath: "/a/b")
        #expect(map.isEmpty, "\(map.keys)")
        #expect(legacyKey("/a/b", basePath: "/a/b").isEmpty)
    }

    /// The root-key case the empty key exists for: an unexplored directory AT the base records
    /// itself under "" so `computeDifferences` can suppress whole-side Missing rows.
    @Test func anUnexploredRootStillRecordsTheRootKey() {
        let root = FileNode(id: "/a/b", name: "b", isDirectory: true, children: [], isUnexplored: true)
        let map = FileDiffEngine.filesInfo(fromTree: [root], basePath: "/a/b")
        #expect(map[""]?.isUnexplored == true)
        #expect(map[""]?.url.path == "/a/b")
        #expect(map.count == 1, "the root was keyed by its name as well: \(map.keys)")
    }

    /// A base node that DOES carry children. No walk returns one, but the strip keyed them from the
    /// base, and so does the shape — from the base, not from under the base's own name.
    @Test func theBasesOwnChildrenKeyFromTheBase() {
        let root = FileNode(id: "/a/b", name: "b", isDirectory: true, children: [branch(under: "/a/b", "d/e.txt")])
        check([root], base: "/a/b", expected: ["/a/b/d": "d", "/a/b/d/e.txt": "d/e.txt"], "the base's children")
    }

    // MARK: - Where they part, on purpose

    /// **A folder the walk lists in a link's place is keyed where it sits.** The walk substitutes the
    /// real folder for one linked in from outside — iCloud Drive's `Documents` — so its id and every
    /// id under it say where the folder really is (`/U/Documents`), nowhere near the base. The strip
    /// keyed them off those ids, near-absolute, where the disk walk keys them under the link. The
    /// base here is the container's parent (a Compare on `~/Library`): no table at the base names
    /// the link, so no lookup in one could have fixed it.
    @Test func aLinkedFolderIsKeyedWhereTheWalkListedIt() {
        let tree = [FileNode(id: "/L/c", name: "c", isDirectory: true, children: [
            FileNode(id: "/U/Documents", name: "Documents", isDirectory: true, children: [
                FileNode(id: "/U/Documents/x.txt", name: "x.txt", isDirectory: false),
            ]),
        ])]
        let map = FileDiffEngine.filesInfo(fromTree: tree, basePath: "/L")
        #expect(Set(map.keys) == ["c", "c/Documents", "c/Documents/x.txt"])
        #expect(map["c/Documents/x.txt"]?.url.path == "/U/Documents/x.txt", "the entry still names the real file")
        #expect(legacyKey("/U/Documents/x.txt", basePath: "/L") == "U/Documents/x.txt", "what the strip made of it")
    }

    /// **A folder the walk reaches twice is keyed once per route.** At Home, `~/Documents` is a
    /// child of the base AND where the container's link leads; the walk lists it in both places
    /// with one id, and marks the container's copy `isCoveredElsewhere`. The strip keyed both copies
    /// onto the direct one's keys, so the container's vanished, where the disk walk lists both —
    /// and that flag is for consumers that add the tree up, not for this one.
    @Test func aFolderReachedTwiceIsKeyedOncePerRoute() {
        let note = FileNode(id: "/H/Documents/x.txt", name: "x.txt", isDirectory: false)
        let tree = [
            FileNode(id: "/H/Documents", name: "Documents", isDirectory: true, children: [note]),
            FileNode(id: "/H/Library", name: "Library", isDirectory: true, children: [
                FileNode(id: "/H/Library/c", name: "c", isDirectory: true, children: [
                    FileNode(id: "/H/Documents", name: "Documents", isDirectory: true, children: [note],
                             isCoveredElsewhere: true),
                ]),
            ]),
        ]
        let map = FileDiffEngine.filesInfo(fromTree: tree, basePath: "/H")
        #expect(Set(map.keys) == ["Documents", "Documents/x.txt", "Library", "Library/c",
                                  "Library/c/Documents", "Library/c/Documents/x.txt"])
        #expect(map["Library/c/Documents/x.txt"]?.url.path == "/H/Documents/x.txt")
        #expect(legacyKey("/H/Documents/x.txt", basePath: "/H") == "Documents/x.txt",
                "what the strip made of BOTH copies")
    }

    /// **So where a node's id says it lives never enters its key — only its own name does.** These
    /// are inputs the strip once pinned as "what shipped": a sibling sharing the base's prefix kept
    /// the tail of its name, a path outside the base kept the path, and a byte match that split a
    /// grapheme kept the whole path. Each keyed a node off its absolute path — the shape of the
    /// defect above — where a top-level node is a child of the base, keyed by its name.
    @Test func aTopLevelNodeIsKeyedByItsNameWhereverItsPathPoints() {
        let cases: [(id: String, base: String, legacy: String)] = [
            ("/a/bb/x.txt", "/a/b", "b/x.txt"),
            ("/z/x.txt", "/a/b", "z/x.txt"),
            ("/a/cafe\u{0301}/x.txt", "/a/cafe", "a/cafe\u{0301}/x.txt"),
        ]
        for c in cases {
            let map = FileDiffEngine.filesInfo(fromTree: [FileNode(id: c.id, name: "x.txt", isDirectory: false)],
                                               basePath: c.base)
            #expect(Array(map.keys) == ["x.txt"], "\(c.id)")
            #expect(legacyKey(c.id, basePath: c.base) == c.legacy, "\(c.id): what the strip made of it")
        }
    }

    /// Where a comparison's base sits relative to a container that links folders in from outside
    /// it — iCloud Drive's container, with Desktop & Documents syncing on.
    enum LinkedContainerPlacement: String, CaseIterable, Sendable {
        /// The base IS the container: a Compare at iCloud Drive itself.
        case atTheContainer
        /// The base is the container's parent: a Compare on `~/Library`, which sits two levels
        /// above the real container — one is enough for the mechanism.
        case aboveTheContainer
        /// The base also holds the folders the links lead to: a Compare at Home (`~`), where
        /// `~/Documents` is reached directly AND through the container.
        case aboveTheContainerAndItsTargets

        /// The container below the base, `""` when it is the base.
        var container: String {
            switch self {
            case .atTheContainer: ""
            case .aboveTheContainer: "CloudDocs"
            case .aboveTheContainerAndItsTargets: "Library/CloudDocs"
            }
        }

        var baseHoldsTheTargets: Bool { self == .aboveTheContainerAndItsTargets }
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
    ///
    /// **A folder linked in from outside the root is one of those shapes** — iCloud Drive's
    /// `Documents`, at the container. The walk lists it as the folder it points at, so its nodes
    /// carry the REAL path, which the base is no prefix of; keyed by plain prefix they came out
    /// near-absolute (`private/var/…/Documents/report.txt`) while the disk walk keyed them through
    /// the link (`Documents/report.txt`), and a warm Compare at the container offered to copy the
    /// whole folder into `<other side>/Users/…/Documents`. The table is the fixture's own.
    ///
    /// **And the base need not BE the container** — run at every distance one can sit from it.
    /// One level above it (a Compare on `~/Library`) the walk still substitutes the links where it
    /// lists the container, and the warm map keyed those nodes near-absolute again, because the
    /// table it consulted names the container, not the base. At an ancestor that also holds the
    /// links' targets (a Compare at Home), the real folder is reached twice — directly, and through
    /// the container, where the walk marks it `isCoveredElsewhere` — and both routes keyed onto the
    /// direct one's keys, so the container's copy of the subtree vanished from the map while the
    /// disk walk listed it under the container.
    @Test(arguments: LinkedContainerPlacement.allCases)
    func warmAndColdBranchesProduceTheSameMap(_ placement: LinkedContainerPlacement) async throws {
        let fm = FileManager.default
        let root = try makeCanonicalTempRoot(prefix: "WarmColdAgreement")
        let outside = try makeCanonicalTempRoot(prefix: "WarmColdAgreementOutside")
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: outside) }

        // Shapes that have historically diverged or been handled specially: nested dirs, an
        // empty dir, a dotfile, non-ASCII and NFD names, a name with a trailing space, a name that
        // opens with a combining mark (one Character with the `/` before it, so a Character-wise
        // strip left the disk walk's key its slash), a symlink to a file (a broken link is dropped
        // by both, pinned elsewhere), and two folders linked into a container from outside it,
        // the container sitting where `placement` says.
        try fm.createDirectory(at: root.appendingPathComponent("dir/sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appendingPathComponent("dir/a.txt"))
        try Data("bb".utf8).write(to: root.appendingPathComponent("dir/sub/b.txt"))
        try Data("c".utf8).write(to: root.appendingPathComponent(".hidden"))
        try Data("d".utf8).write(to: root.appendingPathComponent("caf\u{00E9}.txt"))
        try Data("e".utf8).write(to: root.appendingPathComponent("nfd-cafe\u{0301}.txt"))
        try Data("f".utf8).write(to: root.appendingPathComponent("trailing space .txt"))
        try Data("j".utf8).write(to: root.appendingPathComponent("\u{0301}combining-first.txt"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.txt"),
                                  withDestinationURL: root.appendingPathComponent("dir/a.txt"))
        let container = placement.container.isEmpty ? root : root.appendingPathComponent(placement.container)
        let targets = placement.baseHoldsTheTargets ? root : outside
        let prefix = placement.container.isEmpty ? "" : placement.container + "/"
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        let documents = targets.appendingPathComponent("Documents")
        try fm.createDirectory(at: documents.appendingPathComponent("Family"), withIntermediateDirectories: true)
        try Data("g".utf8).write(to: documents.appendingPathComponent("report.txt"))
        try Data("hh".utf8).write(to: documents.appendingPathComponent("Family/note.txt"))
        try Data("k".utf8).write(to: documents.appendingPathComponent("\u{0301}combining-first.txt"))
        try fm.createSymbolicLink(at: container.appendingPathComponent("Documents"), withDestinationURL: documents)
        let desktop = targets.appendingPathComponent("Desktop")
        try fm.createDirectory(at: desktop, withIntermediateDirectories: true)
        try Data("i".utf8).write(to: desktop.appendingPathComponent("shot.png"))
        try fm.createSymbolicLink(at: container.appendingPathComponent("Desktop"), withDestinationURL: desktop)
        let links: PathBoundary.LinkedFolders = [container.path: ["Documents": documents.path,
                                                                  "Desktop": desktop.path]]

        let cold = try FileDiffEngine.getFilesInDirectory(root)
        let tree = await FileSyncManager.buildTree(url: root, sortOption: .name, linkedFolders: links)
        let warm = FileDiffEngine.filesInfo(fromTree: tree, basePath: root.path)

        #expect(!cold.isEmpty, "premise: the fixture produced entries")
        #expect(!cold.keys.contains { $0.unicodeScalars.first == "/" }, "a disk-walk key kept its leading slash")
        #expect(cold[prefix + "Documents/Family/note.txt"] != nil && cold[prefix + "Desktop/shot.png"] != nil,
                "premise: the disk walk went through both links")
        if placement.baseHoldsTheTargets {
            #expect(cold["Documents/Family/note.txt"] != nil && cold["Desktop/shot.png"] != nil,
                    "premise: the disk walk reached the targets directly too")
            let substituted = FileSyncManager.subtree(atPath: container.path, under: root.path, in: tree) ?? []
            #expect(substituted.filter { $0.isCoveredElsewhere == true }.map(\.name).sorted() == ["Desktop", "Documents"],
                    "premise: the walk reached the targets twice and marked the container's route")
        }
        #expect(Set(warm.keys) == Set(cold.keys),
                "key sets differ — warm-only \(Set(warm.keys).subtracting(cold.keys).sorted()), cold-only \(Set(cold.keys).subtracting(warm.keys).sorted())")
        for (key, coldInfo) in cold {
            guard let warmInfo = warm[key] else { continue }   // reported by the key-set check
            if key == prefix + "Documents" || key == prefix + "Desktop" {
                // The entries the branches SPELL differently, by design: the enumerator reports
                // each link it listed, the walk the folder it substituted. One folder either way.
                #expect(warmInfo.url.path == targets.appendingPathComponent((key as NSString).lastPathComponent).path)
                #expect(coldInfo.url.resolvingSymlinksInPath() == warmInfo.url.resolvingSymlinksInPath(),
                        "\(key): the two branches name different folders")
            } else {
                #expect(warmInfo.url.path == coldInfo.url.path, "\(key): url.path")
            }
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

    /// The other way a node's id stops continuing its parent's, and the commoner: **`contentsOfDirectory(at:)`
    /// hands back symlink-RESOLVED URLs for a folder reached through a symlink** — listing
    /// `dlink/sub` returns `real/sub/deep`, measured. So the tree's ids go real from two levels below
    /// any folder link, and everywhere under a base reached through one.
    enum FolderSymlinkShape: String, CaseIterable, Sendable {
        /// A folder symlink inside the base: the strip keyed `dlink/sub/deep` onto `real/sub/deep`,
        /// and the link's copy vanished.
        case aLinkInsideTheBase
        /// A pane focused inside a linked folder: every key came out near-absolute.
        case aBaseInsideALinkedFolder
        /// A root spelled through a symlink, `/var/…` for `/private/var/…`: near-absolute again.
        case aBaseSpelledThroughASymlink
    }

    @Test(arguments: FolderSymlinkShape.allCases)
    func warmAndColdBranchesAgreeThroughAFolderSymlink(_ shape: FolderSymlinkShape) async throws {
        let fm = FileManager.default
        let root = try makeCanonicalTempRoot(prefix: "WarmColdSymlink")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("real/sub/deep"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("real/sub/deep/x.txt"))
        try Data("yy".utf8).write(to: root.appendingPathComponent("real/sub/y.txt"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("dlink"), withDestinationURL: root.appendingPathComponent("real"))
        let base: URL
        switch shape {
        case .aLinkInsideTheBase: base = root
        case .aBaseInsideALinkedFolder: base = root.appendingPathComponent("dlink/sub")
        case .aBaseSpelledThroughASymlink:
            #expect(root.path.hasPrefix("/private/var/"), "premise: the temp root lives under /private/var")
            base = URL(fileURLWithPath: String(root.path.dropFirst("/private".count)), isDirectory: true)
        }

        let cold = try FileDiffEngine.getFilesInDirectory(base)
        let tree = await FileSyncManager.buildTree(url: base, sortOption: .name)
        let warm = FileDiffEngine.filesInfo(fromTree: tree, basePath: base.path)

        // Premise: the shape under test really occurs — some node's id does not continue its
        // parent's (or, at the top, the base's). Should a listing ever stop resolving links, this
        // says so instead of passing over nothing.
        func breaks(_ nodes: [FileNode], under parent: String) -> Bool {
            nodes.contains { !$0.id.hasPrefix(parent + "/") || breaks($0.children ?? [], under: $0.id) }
        }
        #expect(breaks(tree, under: base.path), "premise: every id continued its parent's")
        #expect(!cold.isEmpty, "premise: the disk walk listed the fixture")
        #expect(Set(warm.keys) == Set(cold.keys),
                "key sets differ — warm-only \(Set(warm.keys).subtracting(cold.keys).sorted()), cold-only \(Set(cold.keys).subtracting(warm.keys).sorted())")
        for (key, coldInfo) in cold {
            guard let warmInfo = warm[key] else { continue }   // reported by the key-set check
            // The two branches may SPELL one item differently — the enumerator through the link it
            // descended, the walk by the path its listing handed back — so compare what they name.
            #expect(warmInfo.url.resolvingSymlinksInPath() == coldInfo.url.resolvingSymlinksInPath(),
                    "\(key): the two branches name different items")
            #expect(warmInfo.isDirectory == coldInfo.isDirectory, "\(key): isDirectory")
            #expect(warmInfo.isUnexplored == coldInfo.isUnexplored, "\(key): isUnexplored")
            #expect(warmInfo.fileSize == coldInfo.fileSize, "\(key): fileSize")
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
