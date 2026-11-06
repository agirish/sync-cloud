import Foundation
import Testing
@testable import Sync

/// Times a real pane load's phases against real directories on this machine.
///
/// Inert unless `SYNCCLOUD_WALK_BENCHMARK` names the roots to walk (colon-separated, tilde
/// allowed), so an ordinary `swift test` — and CI — never runs it:
///
/// ```sh
/// SYNCCLOUD_WALK_BENCHMARK="~/Documents:~/Library/CloudStorage/OneDrive-Personal/Documents" \
///   swift test -c release --filter TreeWalkBenchmark
/// ```
///
/// The log's per-load records time `buildTree` end to end; attributing cost to a phase (listing,
/// per-node stat, fan-out, sort) needs the phases run separately against the same directory. The
/// decomposition is by subtraction between three passes over the identical tree:
///
/// | pass              | does                                              |
/// |-------------------|---------------------------------------------------|
/// | `listing`         | recursive `contentsOfDirectory`, nothing else      |
/// | `listing + stat`  | the same walk, plus one `resourceValues` per child |
/// | `buildTree`       | production: the above, fanned out, built, sorted   |
///
/// `listing + stat` minus `listing` is the stat cost; `buildTree` minus `listing + stat` is the
/// fan-out, node construction and sort together (negative when the fan-out pays off, since the
/// baselines are single-threaded). The baselines are harness yardsticks, not production code.
///
/// Every measurement is reported cold, then warm: a repeat walk reads the filesystem cache the
/// first one filled, worth several times the wall clock. `.serialized` is load-bearing:
/// swift-testing runs a suite's tests in parallel, and a differential walking the same roots
/// inflates every timing. A benchmark must be the only thing running.
@Suite(.serialized) struct TreeWalkBenchmark {

    /// Roots from the environment, or none — in which case every test here returns immediately.
    private static var roots: [URL] {
        guard let raw = ProcessInfo.processInfo.environment["SYNCCLOUD_WALK_BENCHMARK"], !raw.isEmpty else { return [] }
        return raw.split(separator: ":").map { URL(fileURLWithPath: (String($0) as NSString).expandingTildeInPath) }
    }

    /// Warm repeats per phase. Small, since each is a full walk of a real root; all are printed,
    /// not averaged, because the spread is part of the answer.
    private static let warmRepeats = 3

    private static func ms(_ body: () throws -> Void) rethrows -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        try body()
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    private static func msAsync(_ body: () async -> Void) async -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        await body()
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    private static func line(_ text: String) { print("BENCH \(text)") }

    private static func report(_ phase: String, _ samples: [Double]) {
        let text = samples.enumerated()
            .map { "\($0.offset == 0 ? "cold" : "warm\($0.offset)") \(String(format: "%.0f", $0.element)) ms" }
            .joined(separator: ", ")
        line(String(format: "  %-22@ %@", phase as NSString, text as NSString))
    }

    // MARK: - Harness baselines

    /// Recursive listing with no per-child metadata fetch: the floor cost of enumerating the tree.
    private static func listingOnly(_ url: URL) -> Int {
        var count = 0
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: []) else { return 0 }
        for child in children {
            count += 1
            // `isDirectory` from a bare URL still costs a stat, so this is the floor Foundation
            // allows, one syscall per child, not a zero-syscall one.
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else { continue }
            count += listingOnly(child)
        }
        return count
    }

    /// The same walk, plus the exact `resourceValues` fetch `TreeBuilder.stat` performs per
    /// node — same keys, same prefetch on the listing call.
    private static func listingAndStat(_ url: URL) -> Int {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey, .typeIdentifierKey]
        let keySet = Set(keys)
        var count = 0
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: []) else { return 0 }
        for child in children {
            guard let values = try? child.resourceValues(forKeys: keySet) else { continue }
            count += 1
            if values.isDirectory == true { count += listingAndStat(child) }
        }
        return count
    }

    // MARK: - The measurement

    @Test func phaseTimings() async throws {
        let roots = Self.roots
        guard !roots.isEmpty else { return }

        for root in roots {
            Self.line("root \(root.path)")

            // Production's deep walk first: its cold number is what the app's first load pays,
            // and everything after reads the cache it filled.
            var nodeCount = 0
            var deep: [Double] = []
            for _ in 0...Self.warmRepeats {
                var tree: [FileNode] = []
                let elapsed = await Self.msAsync {
                    tree = await FileSyncManager.buildTree(url: root, sortOption: .name)
                }
                nodeCount = FileSyncManager.countItems(in: tree)
                deep.append(elapsed)
            }
            Self.line("  \(nodeCount) nodes")
            Self.report("buildTree deep", deep)

            // The shallow first-paint pass: a separate `buildTree`, not a prefix of the deep
            // walk, so a cold navigation pays both.
            var shallowCount = 0
            var shallow: [Double] = []
            for _ in 0...Self.warmRepeats {
                var tree: [FileNode] = []
                let elapsed = await Self.msAsync {
                    tree = await FileSyncManager.buildTree(url: root, sortOption: .name, maxDepth: 1)
                }
                shallowCount = tree.count
                shallow.append(elapsed)
            }
            Self.report("buildTree shallow(\(shallowCount))", shallow)

            // The Tags sort is the one option that adds a per-file xattr fetch (`includeTags`),
            // which the walk's doc says costs ~4x everything else; this gives it a number here.
            var tagged: [Double] = []
            for _ in 0...Self.warmRepeats {
                tagged.append(await Self.msAsync { _ = await FileSyncManager.buildTree(url: root, sortOption: .tags) })
            }
            Self.report("buildTree (tags sort)", tagged)

            var listing: [Double] = []
            for _ in 0...Self.warmRepeats {
                listing.append(Self.ms { _ = Self.listingOnly(root) })
            }
            Self.report("listing only", listing)

            var stat: [Double] = []
            for _ in 0...Self.warmRepeats {
                stat.append(Self.ms { _ = Self.listingAndStat(root) })
            }
            Self.report("listing + stat", stat)

            // Sort and filter never touch the disk, so they are timed off one warm build.
            let tree = await FileSyncManager.buildTree(url: root, sortOption: .name)
            var sort: [Double] = []
            for _ in 0...Self.warmRepeats {
                sort.append(Self.ms { _ = FileSyncManager.sort(nodes: tree, by: .dateModified) })
            }
            Self.report("full-tree re-sort", sort)

            var filter: [Double] = []
            for _ in 0...Self.warmRepeats {
                filter.append(Self.ms {
                    _ = FileSyncManager.computeFilteredState(
                        rawLeftTree: tree, rawRightTree: [], rawDifferences: [],
                        showHidden: false, ignoredPaths: [], ignorePatterns: [],
                        verifiedSameDifferenceIds: [], syncingDifferenceIds: [],
                        dropDriveDateNoise: false)
                })
            }
            Self.report("applyFilters compute", filter)

            // The in-memory map the cached-tree scan path builds, which touches no disk.
            var flatten: [Double] = []
            for _ in 0...Self.warmRepeats {
                flatten.append(Self.ms { _ = FileDiffEngine.filesInfo(fromTree: tree, basePath: root.path) })
            }
            Self.report("filesInfo(fromTree:)", flatten)

            // The replaced implementation, timed back to back on the same tree under the same
            // load: a number from an earlier run compares machine states, not code.
            var legacy: [Double] = []
            for _ in 0...Self.warmRepeats {
                legacy.append(Self.ms { _ = Self.legacyFilesInfo(fromTree: tree, basePath: root.path) })
            }
            Self.report("  (pre-change filesInfo)", legacy)

            // The scan's cold path, which walks the disk to build the same map, measured beside
            // it: comparing the two paths needs both numbers.
            var coldMap: [Double] = []
            for _ in 0...Self.warmRepeats {
                coldMap.append(Self.ms { _ = try? FileDiffEngine.getFilesInDirectory(root) })
            }
            Self.report("getFilesInDirectory (disk)", coldMap)

            // Decompose `filesInfo` by building the same map up a piece at a time, so its cost
            // lands on a named part.
            var walkOnly: [Double] = []
            for _ in 0...Self.warmRepeats {
                walkOnly.append(Self.ms { _ = Self.traverseOnly(tree) })
            }
            Self.report("  ├ traversal only", walkOnly)

            // Every key's length goes into a printed sink, so no keying arm can be optimised away.
            var keySink = 0
            var keyed: [Double] = []
            for _ in 0...Self.warmRepeats {
                keyed.append(Self.ms { keySink &+= Self.traverseAndKey(tree, basePath: root.path) })
            }
            Self.report("  ├ + relative-path key", keyed)

            // The same step two other ways, under the same load: the id strip the shape keys
            // replaced, and shape keys built from `FileNode.name`, which `filesInfo` doesn't use
            // because `name` stays bridged (`nativePath`).
            var stripKeyed: [Double] = []
            for _ in 0...Self.warmRepeats {
                stripKeyed.append(Self.ms { keySink &+= Self.traverseAndStripKey(tree, basePath: root.path) })
            }
            Self.report("  │  (by id strip, pre-change)", stripKeyed)

            var nameKeyed: [Double] = []
            for _ in 0...Self.warmRepeats {
                nameKeyed.append(Self.ms { keySink &+= Self.traverseAndNameKey(tree, basePath: root.path) })
            }
            Self.report("  │  (from FileNode.name)", nameKeyed)
            Self.line("  │  (key bytes, all arms: \(keySink))")

            var hinted: [Double] = []
            for _ in 0...Self.warmRepeats {
                hinted.append(Self.ms { _ = Self.rebuiltMap(tree, basePath: root.path, hintURLKind: true) })
            }
            Self.report("  ├ + map, hinted URL", hinted)

            var unhinted: [Double] = []
            for _ in 0...Self.warmRepeats {
                unhinted.append(Self.ms { _ = Self.rebuiltMap(tree, basePath: root.path, hintURLKind: false) })
            }
            Self.report("  └ + map, unhinted URL", unhinted)
        }
    }

    /// Times the scan's other half: `computeDifferences`, which reads the two maps `filesInfo`
    /// builds. Skipped unless `SYNCCLOUD_WALK_BENCHMARK` names at least two roots. The rows below
    /// the total time its parts over the same real keys: `nearNameKey` runs for every key of both
    /// sides at setup and again per unmatched entry, so its per-call cost multiplies.
    @Test func diffPhase() async throws {
        let roots = Self.roots
        guard roots.count >= 2 else { return }

        let leftTree = await FileSyncManager.buildTree(url: roots[0], sortOption: .name)
        let rightTree = await FileSyncManager.buildTree(url: roots[1], sortOption: .name)
        let leftInfo = FileDiffEngine.filesInfo(fromTree: leftTree, basePath: roots[0].path)
        let rightInfo = FileDiffEngine.filesInfo(fromTree: rightTree, basePath: roots[1].path)
        Self.line("diff \(leftInfo.count) vs \(rightInfo.count) entries")

        let left = CloudProvider(id: "l", displayName: "L", imageName: "", rootPath: roots[0].path, type: .iCloud)
        let right = CloudProvider(id: "r", displayName: "R", imageName: "", rootPath: roots[1].path, type: .oneDrive)

        var total: [Double] = []
        var diffCount = 0
        for _ in 0...Self.warmRepeats {
            total.append(Self.ms {
                let d = FileDiffEngine.computeDifferences(
                    left: left, leftURL: roots[0], right: right, rightURL: roots[1],
                    leftFilesInfo: leftInfo, rightFilesInfo: rightInfo,
                    caseInsensitive: true, dateToleranceSeconds: 1)
                diffCount = d.count
            })
        }
        Self.report("computeDifferences(\(diffCount))", total)

        // Every key of both sides through nearNameKey once, as the setup loops do.
        let allKeys = Array(leftInfo.keys) + Array(rightInfo.keys)
        var nearName: [Double] = []
        for _ in 0...Self.warmRepeats {
            nearName.append(Self.ms {
                for k in allKeys { _ = ProviderNameRules.nearNameKey(forRelativePath: k, foldCase: true) }
            })
        }
        Self.report("  nearNameKey x\(allKeys.count)", nearName)

        // And what one call is made of. `normalizedComponent` runs per PATH COMPONENT, so this
        // row counts components, not paths.
        let components = allKeys.flatMap { $0.split(separator: "/", omittingEmptySubsequences: false).map(String.init) }
        var normalize: [Double] = []
        for _ in 0...Self.warmRepeats {
            normalize.append(Self.ms {
                for c in components { _ = ProviderNameRules.normalizedComponent(c) }
            })
        }
        Self.report("  ├ normalizedComponent x\(components.count)", normalize)

        var precompose: [Double] = []
        for _ in 0...Self.warmRepeats {
            precompose.append(Self.ms {
                for c in components { _ = c.precomposedStringWithCanonicalMapping }
            })
        }
        Self.report("  │  ├ precomposed only", precompose)

        var trim: [Double] = []
        for _ in 0...Self.warmRepeats {
            trim.append(Self.ms {
                for c in components { _ = c.trimmingCharacters(in: .whitespacesAndNewlines) }
            })
        }
        Self.report("  │  └ one trim only", trim)

        var lower: [Double] = []
        for _ in 0...Self.warmRepeats {
            lower.append(Self.ms { for k in allKeys { _ = k.lowercased() } })
        }
        Self.report("  └ lowercased x\(allKeys.count)", lower)

        // How many of these real components does the fast path actually take?
        let clean = components.filter(ProviderNameRules.hasNothingToNormalize)
        Self.line("  \(clean.count)/\(components.count) components take the fast path")

        // The replaced nearNameKey, timed in the same run and checked against the current one on
        // every real key: breadth no fixture list reaches. `ProviderNameFastPathTests` is the depth.
        var legacyNearName: [Double] = []
        for _ in 0...Self.warmRepeats {
            legacyNearName.append(Self.ms {
                for k in allKeys { _ = Self.legacyNearNameKey(k, foldCase: true) }
            })
        }
        Self.report("  (pre-change nearNameKey)", legacyNearName)

        var diverged: [String] = []
        for k in allKeys {
            for foldCase in [true, false] where
                ProviderNameRules.nearNameKey(forRelativePath: k, foldCase: foldCase)
                    != Self.legacyNearNameKey(k, foldCase: foldCase) {
                diverged.append(k)
            }
        }
        #expect(diverged.isEmpty, "nearNameKey diverged on \(diverged.count) real keys: \(diverged.prefix(5))")
        Self.line("  differential: \(allKeys.count) real keys identical under both foldCase values")
    }

    /// `nearNameKey` exactly as it stood before the fast paths.
    private static func legacyNearNameKey(_ path: String, foldCase: Bool) -> String {
        func legacyComponent(_ name: String) -> String {
            let precomposed = name.precomposedStringWithCanonicalMapping
            var trimmed = precomposed.trimmingCharacters(in: .whitespacesAndNewlines)
            while trimmed.hasSuffix(".") { trimmed.removeLast() }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? precomposed : trimmed
        }
        let normalized = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { legacyComponent(String($0)) }
            .joined(separator: "/")
        return foldCase ? normalized.lowercased() : normalized
    }

    /// Differential check of `filesInfo(fromTree:)` against the implementation it replaced, over
    /// real pane trees: every key and field. `FilesInfoKeyingTests` pins the awkward cases; this
    /// is the breadth, and needs the user's real directories, so it is env-gated.
    ///
    /// Where a node's id doesn't continue its parent's, the two differ by design: the old one
    /// stripped the id, `filesInfo` keys the node where it sits. That is any root holding iCloud
    /// Drive's container (the container, `~/Library`, `~`), reached through a symlink, or with a
    /// folder symlink two or more levels deep. Every other root must match, keys byte for byte.
    @Test func matchesThePreChangeImplementationOnRealTrees() async throws {
        let roots = Self.roots
        guard !roots.isEmpty else { return }

        for root in roots {
            let tree = await FileSyncManager.buildTree(url: root, sortOption: .name)
            let new = FileDiffEngine.filesInfo(fromTree: tree, basePath: root.path)
            let old = Self.legacyFilesInfo(fromTree: tree, basePath: root.path)

            #expect(new.count == old.count, "\(root.lastPathComponent): map sizes differ")
            #expect(Set(new.keys) == Set(old.keys), "\(root.lastPathComponent): key sets differ")
            // Byte for byte too: `Set<String>` compares by canonical equivalence, so an NFC key
            // and its NFD twin pass the line above.
            #expect(Set(new.keys.map { Array($0.utf8) }) == Set(old.keys.map { Array($0.utf8) }),
                    "\(root.lastPathComponent): keys spelled differently")
            var mismatches: [String] = []
            for (key, oldInfo) in old {
                guard let newInfo = new[key] else { mismatches.append("\(key): missing"); continue }
                // `.path` is what every production consumer reads; the rest are copied off the node.
                if newInfo.url.path != oldInfo.url.path { mismatches.append("\(key): url.path") }
                if newInfo.modificationDate != oldInfo.modificationDate { mismatches.append("\(key): date") }
                if newInfo.fileSize != oldInfo.fileSize { mismatches.append("\(key): size") }
                if newInfo.isDirectory != oldInfo.isDirectory { mismatches.append("\(key): isDirectory") }
                if newInfo.isUnexplored != oldInfo.isUnexplored { mismatches.append("\(key): isUnexplored") }
            }
            #expect(mismatches.isEmpty, "\(root.lastPathComponent): \(mismatches.prefix(5))")
            Self.line("differential \(root.lastPathComponent): \(new.count) entries identical")
        }
    }

    /// `filesInfo(fromTree:)` as it was before its keying and URL changes, for comparison.
    private static func legacyFilesInfo(fromTree nodes: [FileNode], basePath: String) -> [String: FileDiffEngine.FileInfo] {
        var result: [String: FileDiffEngine.FileInfo] = [:]
        func add(_ node: FileNode) {
            var relativePath = node.id
            if relativePath.hasPrefix(basePath) { relativePath = String(relativePath.dropFirst(basePath.count)) }
            if relativePath.hasPrefix("/") { relativePath.removeFirst() }
            if !relativePath.isEmpty {
                result[relativePath] = FileDiffEngine.FileInfo(
                    url: URL(fileURLWithPath: node.id),
                    modificationDate: node.modificationDate,
                    fileSize: node.fileSize,
                    isDirectory: node.isDirectory,
                    isUnexplored: node.isDirectory && node.isUnexplored == true)
            } else if node.isDirectory, node.isUnexplored == true {
                result[""] = FileDiffEngine.FileInfo(
                    url: URL(fileURLWithPath: node.id),
                    modificationDate: node.modificationDate,
                    fileSize: node.fileSize,
                    isDirectory: true,
                    isUnexplored: true)
            }
            for child in node.children ?? [] { add(child) }
        }
        for node in nodes { add(node) }
        return result
    }

    // MARK: - filesInfo decomposition
    //
    // Each does more than the one before, so consecutive differences attribute the cost. The
    // hinted `rebuiltMap` is `filesInfo`'s own shape; the unhinted one differs only in omitting
    // `isDirectory:`, which makes the URL initializer check the file system.

    private static func traverseOnly(_ nodes: [FileNode]) -> Int {
        var n = 0
        func visit(_ node: FileNode) {
            n += 1
            for child in node.children ?? [] { visit(child) }
        }
        for node in nodes { visit(node) }
        return n
    }

    /// `filesInfo`'s key, built the way it builds it: from the tree's shape, each component the
    /// last component of a node's id.
    private static func leaf(of id: String) -> Substring {
        guard let slash = id.utf8.lastIndex(of: UInt8(ascii: "/")) else { return id[...] }
        return Substring(id.unicodeScalars[id.utf8.index(after: slash)...])
    }

    /// `traverseAndKey` with the old key: the id with the base stripped off.
    private static func traverseAndStripKey(_ nodes: [FileNode], basePath: String) -> Int {
        var n = 0
        func visit(_ node: FileNode) {
            var relativePath = node.id
            if relativePath.hasPrefix(basePath) { relativePath = String(relativePath.dropFirst(basePath.count)) }
            if relativePath.hasPrefix("/") { relativePath.removeFirst() }
            n &+= relativePath.utf8.count
            for child in node.children ?? [] { visit(child) }
        }
        for node in nodes { visit(node) }
        return n
    }

    /// `traverseAndKey` with each component read from the bridged `FileNode.name`.
    private static func traverseAndNameKey(_ nodes: [FileNode], basePath: String) -> Int {
        var n = 0
        func visit(_ node: FileNode, key: String) {
            n &+= key.utf8.count
            guard let children = node.children, !children.isEmpty else { return }
            let prefix = key + "/"
            for child in children { visit(child, key: prefix + child.name) }
        }
        for node in nodes where node.id != basePath { visit(node, key: node.name) }
        return n
    }

    private static func traverseAndKey(_ nodes: [FileNode], basePath: String) -> Int {
        var n = 0
        func visit(_ node: FileNode, key: String) {
            n &+= key.utf8.count
            guard let children = node.children, !children.isEmpty else { return }
            let prefix = key + "/"
            for child in children {
                var childKey = prefix
                childKey.append(contentsOf: leaf(of: child.id))
                visit(child, key: childKey)
            }
        }
        for node in nodes where node.id != basePath { visit(node, key: String(leaf(of: node.id))) }
        return n
    }

    private static func rebuiltMap(_ nodes: [FileNode], basePath: String, hintURLKind: Bool) -> [String: FileDiffEngine.FileInfo] {
        var result: [String: FileDiffEngine.FileInfo] = [:]
        func visit(_ node: FileNode, key: String) {
            let url = hintURLKind
                ? URL(fileURLWithPath: node.id, isDirectory: node.isDirectory)
                : URL(fileURLWithPath: node.id)
            result[key] = FileDiffEngine.FileInfo(
                url: url,
                modificationDate: node.modificationDate,
                fileSize: node.fileSize,
                isDirectory: node.isDirectory,
                isUnexplored: node.isDirectory && node.isUnexplored == true)
            guard let children = node.children, !children.isEmpty else { return }
            let prefix = key + "/"
            for child in children {
                var childKey = prefix
                childKey.append(contentsOf: leaf(of: child.id))
                visit(child, key: childKey)
            }
        }
        for node in nodes where node.id != basePath { visit(node, key: String(leaf(of: node.id))) }
        return result
    }

    // MARK: - The Columns index

    /// What keying the Columns index by composed paths costs against plain id keys.
    /// `PaneChildrenIndex` is rebuilt on every publish, on the main actor, so its build time is
    /// what the user feels. Walked with the production budget. Each root is timed as walked (every
    /// directory below a link keyed by a composed path) and re-spelled so every id continues its
    /// parent's (nothing to compose: the per-id check alone). The arms alternate order per repeat.
    ///
    /// The differential: every directory, asked by the path `PaneBrowsePath` composes for it, must
    /// list exactly its own rows; where every id continues its parent's, the index must answer
    /// every id the id-keyed map does, with the same rows. It prints how many directories have a
    /// composed path that isn't their id.
    @Test func columnIndexBuild() async throws {
        let roots = Self.roots
        guard !roots.isEmpty else { return }

        for root in roots {
            let walked = await FileSyncManager.buildTree(url: root, sortOption: .name,
                                                         budget: .init(FileSyncManager.paneNodeBudget))
            Self.line("index \(root.path): \(FileSyncManager.countItems(in: walked)) nodes")
            for (label, tree) in [("as walked", walked), ("re-spelled", Self.respelled(walked, in: root.path))] {
                let pane = PaneTree(side: .left, version: 1, nodes: tree,
                                    rows: PaneRow.project(tree, side: .left, version: 1))
                var current: [Double] = [], legacy: [Double] = []
                var sink = 0
                for round in 0...Self.warmRepeats {
                    let arms: [(inout [Double]) -> Void] = [
                        { $0.append(Self.ms { sink &+= PaneChildrenIndex(tree: pane, treeRoot: root.path).isDirectory(atPath: root.path) ? 1 : 0 }) },
                        { $0.append(Self.ms { sink &+= Self.legacyChildrenIndex(pane.rows).count }) },
                    ]
                    if round % 2 == 0 { arms[0](&current); arms[1](&legacy) } else { arms[1](&legacy); arms[0](&current) }
                }
                Self.report("PaneChildrenIndex, \(label)", current)
                Self.report("  (pre-change, id keys)", legacy)

                let index = PaneChildrenIndex(tree: pane, treeRoot: root.path)
                var directories = 0, composedElsewhere = 0
                var misses: [String] = []
                func visit(_ rows: [PaneRow], names: [String]) {
                    for row in rows where row.info.isDirectory {
                        let down = names + [String(TreeShape.leaf(of: row.node.id))]
                        let path = PaneBrowsePath(components: down).currentDirectory(treeRoot: root.path)
                        directories += 1
                        if path != row.node.id { composedElsewhere += 1 }
                        if index.children(atPath: path)?.map(\.id) != (row.children ?? []).map(\.id), misses.count < 5 {
                            misses.append(path)
                        }
                        visit(row.children ?? [], names: down)
                    }
                }
                visit(pane.rows, names: [])
                #expect(misses.isEmpty, "\(root.lastPathComponent), \(label): composed paths listing the wrong rows: \(misses)")
                if composedElsewhere == 0 {
                    let unanswered = Self.legacyChildrenIndex(pane.rows)
                        .filter { index.children(atPath: $0.key)?.map(\.id) != $0.value.map(\.id) }.count
                    #expect(unanswered == 0, "\(root.lastPathComponent), \(label): \(unanswered) ids answered differently")
                }
                Self.line("  \(directories) directories, \(composedElsewhere) composed elsewhere than their id (sink \(sink))")
            }
        }
    }

    /// `PaneChildrenIndex`'s map keyed the old way, each directory by its own id.
    private static func legacyChildrenIndex(_ rows: [PaneRow]) -> [String: [PaneRow]] {
        var map: [String: [PaneRow]] = [:]
        var unexplored: Set<String> = []
        func index(_ rows: [PaneRow]) {
            for row in rows {
                if row.info.isDirectory {
                    map[row.node.id] = row.children ?? []
                    if row.node.isUnexplored == true { unexplored.insert(row.node.id) }
                }
                if let children = row.children { index(children) }
            }
        }
        index(rows)
        return map
    }

    /// `nodes` with every id re-spelled as its parent's plus its leaf, from `directory` down: the
    /// tree a walk would build with no links below it, stored natively as `nativePath` stores ids.
    private static func respelled(_ nodes: [FileNode], in directory: String) -> [FileNode] {
        nodes.map { node in
            let id = String(decoding: Array((directory + "/" + TreeShape.leaf(of: node.id)).utf8), as: UTF8.self)
            return FileNode(id: id, name: node.name, isDirectory: node.isDirectory,
                            children: node.children.map { respelled($0, in: id) },
                            modificationDate: node.modificationDate, fileSize: node.fileSize, tags: node.tags,
                            kind: node.kind, isUnexplored: node.isUnexplored, isSymbolicLink: node.isSymbolicLink,
                            isCoveredElsewhere: node.isCoveredElsewhere)
        }
    }
}
