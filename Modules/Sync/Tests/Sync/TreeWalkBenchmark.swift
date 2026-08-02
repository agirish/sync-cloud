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
/// It exists because the disk log cannot answer "is the walk slow, and where" even with the
/// per-load records `loadTree` now writes: those are honest end-to-end numbers, but the walk's
/// internals — the directory listing, the per-node stat, the fan-out, the sort — are one
/// `buildTree` call from outside. Attributing cost to a phase needs the phases run separately
/// against the same directory, which is this.
///
/// The decomposition is by SUBTRACTION between three passes over the identical tree:
///
/// | pass              | does                                              |
/// |-------------------|---------------------------------------------------|
/// | `listing`         | recursive `contentsOfDirectory`, nothing else      |
/// | `listing + stat`  | the same walk, plus one `resourceValues` per child |
/// | `buildTree`       | production: the above, fanned out, built, sorted   |
///
/// `listing + stat` minus `listing` is the stat cost; `buildTree` minus `listing + stat` is
/// what the fan-out, node construction and per-level sort together are worth (it can be
/// NEGATIVE — that is the fan-out paying off, since the two baselines are single-threaded).
/// The baselines are harness code, deliberately: they are a yardstick for production's walk,
/// never a claim about what production does.
///
/// Every measurement is reported cold-first-then-warm. A repeat walk reads a filesystem cache
/// the first one populated, and on these roots that is worth several times the wall clock — a
/// single number with no cache state attached is exactly the kind of figure this whole
/// investigation exists to distrust.
/// `.serialized` is load-bearing: swift-testing runs a suite's tests in PARALLEL by default, so
/// the differential check was walking both real roots while `phaseTimings` was timing them, and
/// every number came back inflated and irreproducible. A benchmark must be the only thing running.
@Suite(.serialized) struct TreeWalkBenchmark {

    /// Roots from the environment, or none — in which case every test here returns immediately.
    private static var roots: [URL] {
        guard let raw = ProcessInfo.processInfo.environment["SYNCCLOUD_WALK_BENCHMARK"], !raw.isEmpty else { return [] }
        return raw.split(separator: ":").map { URL(fileURLWithPath: (String($0) as NSString).expandingTildeInPath) }
    }

    /// Warm repeats per phase. Small on purpose: each one is a full walk of a real pane root,
    /// and the spread between repeats is itself part of the answer, so they are all printed
    /// rather than averaged into a single number that hides it.
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

    /// Recursive listing with no per-child metadata fetch at all. The floor: what it costs
    /// merely to enumerate every directory in the tree.
    private static func listingOnly(_ url: URL) -> Int {
        var count = 0
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: []) else { return 0 }
        for child in children {
            count += 1
            // `isDirectory` from a bare URL still costs a stat, so this baseline cannot avoid
            // one syscall per child — it is the listing floor as reachable from Foundation,
            // not a theoretical zero-syscall floor.
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

            // Production's own deep walk, first — everything after it is measured against a
            // filesystem cache this pass populated, and its own cold number is the one the
            // app's first load actually pays.
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

            // The shallow first-paint pass. Not a prefix of the deep walk — a separate
            // `buildTree` over the same directory — so a cold navigation pays both.
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

            // The Tags sort is the one option that adds a per-file xattr fetch to the walk
            // (`includeTags`), and the walk's own doc claims it costs ~4x everything else
            // combined. Measured here so that claim has a number on this machine.
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

            // Sort and filter operate on the finished tree with no disk access at all, so they
            // are timed off one warm build rather than re-walking.
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

            // The in-memory diff the cached-tree scan path runs — the branch whose wall time
            // varied 4x in the log with no disk access to blame it on.
            var flatten: [Double] = []
            for _ in 0...Self.warmRepeats {
                flatten.append(Self.ms { _ = FileDiffEngine.filesInfo(fromTree: tree, basePath: root.path) })
            }
            Self.report("filesInfo(fromTree:)", flatten)

            // The pre-change implementation, timed back-to-back with the current one on the same
            // tree under the same load. Comparing against a number recorded in an earlier run
            // would be comparing across machine states, which is how a "speedup" gets claimed for
            // what was really a quieter machine.
            var legacy: [Double] = []
            for _ in 0...Self.warmRepeats {
                legacy.append(Self.ms { _ = Self.legacyFilesInfo(fromTree: tree, basePath: root.path) })
            }
            Self.report("  (pre-change filesInfo)", legacy)

            // The branch `filesInfo(fromTree:)` exists to avoid — the scan's cold path, which
            // walks the disk and builds the same map. Measured beside it, because "the in-memory
            // path is slower than the disk path" is a claim about BOTH, and quoting only the
            // in-memory number would be an unsupported half of it.
            var coldMap: [Double] = []
            for _ in 0...Self.warmRepeats {
                coldMap.append(Self.ms { _ = try? FileDiffEngine.getFilesInDirectory(root) })
            }
            Self.report("getFilesInDirectory (disk)", coldMap)

            // `filesInfo` costs as much as the disk walk it exists to AVOID, which is the one
            // number here that does not look like physics. Decompose it by building the same
            // map back up a piece at a time, so the cost lands on a named part instead of on
            // "the in-memory diff" as a whole.
            var walkOnly: [Double] = []
            for _ in 0...Self.warmRepeats {
                walkOnly.append(Self.ms { _ = Self.traverseOnly(tree) })
            }
            Self.report("  ├ traversal only", walkOnly)

            var keyed: [Double] = []
            for _ in 0...Self.warmRepeats {
                keyed.append(Self.ms { _ = Self.traverseAndKey(tree, basePath: root.path) })
            }
            Self.report("  ├ + relative-path key", keyed)

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

    /// Differential check of `filesInfo(fromTree:)` against the implementation it replaced, over
    /// the REAL pane trees rather than constructed fixtures — the whole map, every key and every
    /// field, on tens of thousands of real paths. `FilesInfoKeyingTests` pins the awkward cases
    /// deterministically; this is the breadth behind them, and the reason it lives in the
    /// env-gated benchmark is that it needs the user's actual directories to be worth anything.
    @Test func matchesThePreChangeImplementationOnRealTrees() async throws {
        let roots = Self.roots
        guard !roots.isEmpty else { return }

        for root in roots {
            let tree = await FileSyncManager.buildTree(url: root, sortOption: .name)
            let new = FileDiffEngine.filesInfo(fromTree: tree, basePath: root.path)
            let old = Self.legacyFilesInfo(fromTree: tree, basePath: root.path)

            #expect(new.count == old.count, "\(root.lastPathComponent): map sizes differ")
            #expect(Set(new.keys) == Set(old.keys), "\(root.lastPathComponent): key sets differ")
            var mismatches: [String] = []
            for (key, oldInfo) in old {
                guard let newInfo = new[key] else { mismatches.append("\(key): missing"); continue }
                // `.path` is what every production consumer reads, so it is the field that must
                // match exactly; the rest are copied straight off the node and are checked too.
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

    /// `filesInfo(fromTree:)` exactly as it stood before the keying and URL changes.
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
    // Each of these does strictly more than the one above it, so consecutive differences
    // attribute the cost. The last one is `filesInfo`'s own shape; the one before it differs
    // ONLY in passing `isDirectory:` to the URL initializer — which is the difference between
    // a URL that is parsed and one that is resolved against the file system.

    private static func traverseOnly(_ nodes: [FileNode]) -> Int {
        var n = 0
        func visit(_ node: FileNode) {
            n += 1
            for child in node.children ?? [] { visit(child) }
        }
        for node in nodes { visit(node) }
        return n
    }

    private static func traverseAndKey(_ nodes: [FileNode], basePath: String) -> Int {
        var n = 0
        func visit(_ node: FileNode) {
            var relativePath = node.id
            if relativePath.hasPrefix(basePath) { relativePath = String(relativePath.dropFirst(basePath.count)) }
            if relativePath.hasPrefix("/") { relativePath.removeFirst() }
            n += relativePath.isEmpty ? 0 : 1
            for child in node.children ?? [] { visit(child) }
        }
        for node in nodes { visit(node) }
        return n
    }

    private static func rebuiltMap(_ nodes: [FileNode], basePath: String, hintURLKind: Bool) -> [String: FileDiffEngine.FileInfo] {
        var result: [String: FileDiffEngine.FileInfo] = [:]
        func visit(_ node: FileNode) {
            var relativePath = node.id
            if relativePath.hasPrefix(basePath) { relativePath = String(relativePath.dropFirst(basePath.count)) }
            if relativePath.hasPrefix("/") { relativePath.removeFirst() }
            if !relativePath.isEmpty {
                let url = hintURLKind
                    ? URL(fileURLWithPath: node.id, isDirectory: node.isDirectory)
                    : URL(fileURLWithPath: node.id)
                result[relativePath] = FileDiffEngine.FileInfo(
                    url: url,
                    modificationDate: node.modificationDate,
                    fileSize: node.fileSize,
                    isDirectory: node.isDirectory,
                    isUnexplored: node.isDirectory && node.isUnexplored == true)
            }
            for child in node.children ?? [] { visit(child) }
        }
        for node in nodes { visit(node) }
        return result
    }
}
