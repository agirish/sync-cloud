import Foundation
import Testing
@testable import Sync

/// Prices the ObjC bridge that `FileNode.id` and `FileNode.name` carry, at every place the app
/// actually spends them.
///
/// `FileNode.id` is `URL.path` and `FileNode.name` is `URL.lastPathComponent`; both come back from
/// Foundation lazily bridged from `NSString`, so a hash or a comparison of one can take the ObjC
/// slow path instead of running over native UTF-8. `NameCheckBenchmark` established the multiplier
/// for ONE consumer (the row badge's memo: 77–135 ns native against 1.2–2.1 µs bridged). This asks
/// the question that decides whether anything should change: which of the app's OTHER per-node
/// paths pay it, how much of a real pane load that is, and what forcing native storage at
/// construction would cost the walk — which is already at the floor of directory enumeration
/// (~785 ms per 40,000 nodes) and must not be made slower to speed up a lookup.
///
/// Inert unless `SYNCCLOUD_BRIDGE_BENCHMARK` names the roots to walk (colon-separated, tilde
/// allowed), so an ordinary `swift test` — and CI — never runs it:
///
/// ```sh
/// SYNCCLOUD_BRIDGE_BENCHMARK="~/Documents:~/Library/CloudStorage/OneDrive-Personal" \
///   arch -arm64 swift test -c release --filter BridgedStringBenchmark
/// ```
///
/// **Every measurement interleaves its arms.** Medians on this machine drift several percent
/// between identical runs, so a bridged batch timed before a native batch measures the drift as
/// much as the bridge. Each repeat runs every arm once, and the arm order reverses on odd repeats
/// so a within-repeat warming trend cannot favour whichever arm goes first. All samples are
/// printed, never just the median.
@Suite(.serialized) struct BridgedStringBenchmark {

    // MARK: - Inputs

    private static var roots: [URL] {
        guard let raw = ProcessInfo.processInfo.environment["SYNCCLOUD_BRIDGE_BENCHMARK"], !raw.isEmpty else { return [] }
        return raw.split(separator: ":").map { URL(fileURLWithPath: (String($0) as NSString).expandingTildeInPath) }
    }

    /// Repeats per arm. Small, because each one is tens of thousands of operations and the
    /// spread between repeats is itself part of the answer.
    private static let repeats = 5

    /// One walked root, exactly as the production walk sees it: `URL.path` and
    /// `URL.lastPathComponent` straight from Foundation, with no round-trip that would quietly
    /// nativize them.
    private struct Corpus {
        let label: String
        /// Absolute paths — what `FileNode.id` holds.
        let paths: [String]
        /// Leaf names — what `FileNode.name` holds.
        let names: [String]
        /// Sibling groups, parent path → its children's names, so the per-level sort can be
        /// priced on the shape a real pane actually sorts rather than one 40,000-item array.
        let siblingGroups: [[String]]
        /// The walk root, for the relative-key measurement.
        let base: String
    }

    private static func corpus(under root: URL, limit: Int = 60_000) -> Corpus? {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return nil }
        var paths: [String] = []
        var names: [String] = []
        var groups: [String: [String]] = [:]
        for case let url as URL in e {
            paths.append(url.path)
            names.append(url.lastPathComponent)
            groups[url.deletingLastPathComponent().path, default: []].append(url.lastPathComponent)
            if paths.count >= limit { break }
        }
        guard !paths.isEmpty else { return nil }
        return Corpus(label: root.lastPathComponent, paths: paths, names: names,
                      siblingGroups: Array(groups.values), base: root.path)
    }

    /// The same strings with guaranteed-native storage, by round-tripping the UTF-8 — the same
    /// helper `NameCheckBenchmark.nativized` uses, and the operation a nativize-at-construction
    /// change would perform in the walk.
    private static func nativized(_ strings: [String]) -> [String] {
        strings.map { String(decoding: Array($0.utf8), as: UTF8.self) }
    }

    // MARK: - Harness

    private static func ns(_ count: Int, _ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / Double(max(count, 1))
    }

    /// Runs `arms` `repeats` times each, one repeat at a time and alternating the order, and
    /// prints every sample plus the median and the spread. `count` divides each sample into a
    /// per-item figure.
    private static func compare(_ measurement: String, root: String, count: Int,
                                arms: [(String, () -> Void)]) {
        // One untimed pass per arm, so no arm is charged for first-touch faults or for warming
        // shared ICU/allocator state that the arm running second would find already warm.
        for (_, body) in arms { body() }

        var samples: [String: [Double]] = [:]
        for repeat_ in 0..<repeats {
            let order = repeat_.isMultiple(of: 2) ? Array(arms.indices) : Array(arms.indices.reversed())
            for i in order {
                let (name, body) = arms[i]
                samples[name, default: []].append(ns(count, body))
            }
        }
        for (name, _) in arms {
            let values = samples[name]!.sorted()
            let median = values[values.count / 2]
            let all = samples[name]!.map { String(format: "%.0f", $0) }.joined(separator: " ")
            print(String(format: "BENCH %@ · %@ · %@: median %.0f ns/item · min %.0f max %.0f · samples [%@]",
                         root, measurement, name, median, values.first!, values.last!, all))
        }
        // The ratios the whole investigation is about, stated rather than left to be eyeballed:
        // every arm against the first, which is always the unchanged production storage. Above 1
        // means production is paying that multiple; BELOW 1 means the change would LOSE here.
        let base = samples[arms[0].0]!.sorted()[repeats / 2]
        for (name, _) in arms.dropFirst() {
            let other = samples[name]!.sorted()[repeats / 2]
            print(String(format: "BENCH %@ · %@ · RATIO %@/%@ = %.2fx",
                         root, measurement, arms[0].0, name, base / max(other, 0.0001)))
        }
    }

    private var sink = 0

    // MARK: - The measurements

    @Test mutating func priceTheBridge() {
        let roots = Self.roots
        guard !roots.isEmpty else { return }

        for root in roots {
            guard let c = Self.corpus(under: root) else { continue }
            let nativePaths = Self.nativized(c.paths)
            let nativeNames = Self.nativized(c.names)
            print("BENCH root \(c.label): \(c.paths.count) nodes, \(Set(c.paths).count) distinct paths, "
                  + "\(c.siblingGroups.count) directories, \(Set(c.names).count) distinct names")

            measureDictionaryLookups(c, nativePaths: nativePaths)
            measureSelectionSet(c, nativePaths: nativePaths)
            measurePaneChildrenIndexBuild(c, nativePaths: nativePaths)
            measureSort(c)
            measureNameRules(c, nativePaths: nativePaths, nativeNames: nativeNames)
            measureRelativeKey(c, nativePaths: nativePaths)
            measureNativizationCost(c)
        }
        print("BENCH sink \(sink)")
    }

    /// The `DiffStatusIndex` shape: the dictionary's KEYS are native (the index builds them by
    /// concatenating root + "/" + relativePath), and only the QUERY is a bridged `node.id`. This
    /// is the per-render cost of a badge lookup, and it is the one place where the bridge is paid
    /// without the app having any say in how the table was built.
    private mutating func measureDictionaryLookups(_ c: Corpus, nativePaths: [String]) {
        // The table is keyed from a SECOND, independent nativization. Keying it from
        // `nativePaths` — the very array the native arm then queries with — would hand that arm
        // `String.==`'s identical-storage short circuit on every hit, which is a property of the
        // benchmark's own bookkeeping and not of native storage. Equal but distinct allocations
        // are what a real lookup compares.
        var table: [String: Int] = [:]
        table.reserveCapacity(nativePaths.count)
        for (i, p) in Self.nativized(c.paths).enumerated() { table[p] = i }

        var s = 0
        Self.compare("dict lookup (native-keyed table)", root: c.label, count: c.paths.count, arms: [
            ("bridged query", { for p in c.paths where table[p] != nil { s += 1 } }),
            ("native query", { for p in nativePaths where table[p] != nil { s += 1 } }),
        ])
        sink &+= s
    }

    /// The pane's `selection: Set<String>` and the ignore-path set: `contains(node.id)` per row.
    private mutating func measureSelectionSet(_ c: Corpus, nativePaths: [String]) {
        // Independently nativized, for the identical-storage reason given above.
        let set = Set(Self.nativized(c.paths))
        var s = 0
        Self.compare("Set.contains (native-keyed set)", root: c.label, count: c.paths.count, arms: [
            ("bridged query", { for p in c.paths where set.contains(p) { s += 1 } }),
            ("native query", { for p in nativePaths where set.contains(p) { s += 1 } }),
        ])
        sink &+= s
    }

    /// The `PaneChildrenIndex` shape: built once per publish, and its keys ARE `node.id`, so a
    /// bridged id is hashed on the way IN as well as on the way out.
    private mutating func measurePaneChildrenIndexBuild(_ c: Corpus, nativePaths: [String]) {
        var s = 0
        Self.compare("dict build (node.id as key)", root: c.label, count: c.paths.count, arms: [
            ("bridged keys", {
                var m: [String: Int] = [:]
                m.reserveCapacity(c.paths.count)
                for (i, p) in c.paths.enumerated() { m[p] = i }
                s &+= m.count
            }),
            ("native keys", {
                var m: [String: Int] = [:]
                m.reserveCapacity(nativePaths.count)
                for (i, p) in nativePaths.enumerated() { m[p] = i }
                s &+= m.count
            }),
        ])
        sink &+= s
    }

    /// `FileSyncManager.sortLevel` over every real sibling group, which is the whole per-level
    /// sort one publish performs. `localizedStandardCompare` is an `NSString` method, so this is
    /// the arm where nativizing could plausibly LOSE: a native string has to be bridged TO
    /// `NSString` for every comparison, while a lazily-bridged one already is one.
    private mutating func measureSort(_ c: Corpus) {
        // Real directory membership, not just real group sizes: each level holds the names that
        // actually sit side by side in that folder, so the comparisons are the ones a publish
        // really performs. Built once, outside timing; the two arms differ only in storage.
        func levels(_ transform: (String) -> String) -> [[FileNode]] {
            c.siblingGroups.map { group in
                group.map { name in
                    let s = transform(name)
                    return FileNode(id: s, name: s, isDirectory: false)
                }
            }
        }
        let bridgedLevels = levels { $0 }
        let nativeLevels = levels { String(decoding: Array($0.utf8), as: UTF8.self) }

        var s = 0
        Self.compare("sortLevel by name (localizedStandardCompare)", root: c.label, count: c.names.count, arms: [
            ("bridged names", { for level in bridgedLevels { s &+= FileSyncManager.sortLevel(nodes: level, by: .name).count } }),
            ("native names", { for level in nativeLevels { s &+= FileSyncManager.sortLevel(nodes: level, by: .name).count } }),
        ])
        sink &+= s
    }

    /// `ProviderNameRules`' byte-level fast paths — `pathHasNothingToNormalize` iterates
    /// `path.utf8`, and `f6ba96e7` added it precisely so the 94%-ASCII common case would be cheap.
    /// If a bridged string cannot serve its UTF-8 contiguously, that loop pays an ObjC call per
    /// byte and the fast path is delivering far less than it appears to.
    private mutating func measureNameRules(_ c: Corpus, nativePaths: [String], nativeNames: [String]) {
        var s = 0
        Self.compare("pathHasNothingToNormalize (utf8 scan)", root: c.label, count: c.paths.count, arms: [
            ("bridged", { for p in c.paths where ProviderNameRules.pathHasNothingToNormalize(p) { s += 1 } }),
            ("native", { for p in nativePaths where ProviderNameRules.pathHasNothingToNormalize(p) { s += 1 } }),
        ])
        Self.compare("nearNameKey(foldCase: true)", root: c.label, count: c.paths.count, arms: [
            ("bridged", { for p in c.paths { s &+= ProviderNameRules.nearNameKey(forRelativePath: p, foldCase: true).utf8.count } }),
            ("native", { for p in nativePaths { s &+= ProviderNameRules.nearNameKey(forRelativePath: p, foldCase: true).utf8.count } }),
        ])
        Self.compare("hasNothingToNormalize (leaf names)", root: c.label, count: c.names.count, arms: [
            ("bridged", { for n in c.names where ProviderNameRules.hasNothingToNormalize(n) { s += 1 } }),
            ("native", { for n in nativeNames where ProviderNameRules.hasNothingToNormalize(n) { s += 1 } }),
        ])
        sink &+= s
    }

    /// The `FileDiffEngine.flatten` shape: `id.utf8.starts(with: baseUTF8)` then
    /// `String(decoding:)` the remainder — one per node at scan setup, and the reason the diff's
    /// own dictionary ends up natively keyed whatever `FileNode.id` holds.
    private mutating func measureRelativeKey(_ c: Corpus, nativePaths: [String]) {
        let baseUTF8 = Array(c.base.utf8)
        func relativeKey(_ id: String) -> String {
            if id.utf8.starts(with: baseUTF8) {
                let rest = id.utf8.dropFirst(baseUTF8.count)
                if rest.isEmpty { return "" }
                if rest.first == UInt8(ascii: "/") { return String(decoding: rest.dropFirst(), as: UTF8.self) }
            }
            return id
        }
        var s = 0
        Self.compare("relativeKey (utf8 prefix + decode)", root: c.label, count: c.paths.count, arms: [
            ("bridged", { for p in c.paths { s &+= relativeKey(p).utf8.count } }),
            ("native", { for p in nativePaths { s &+= relativeKey(p).utf8.count } }),
        ])
        sink &+= s
    }

    /// What nativizing at construction would cost, per node, if it were added to the walk: the
    /// UTF-8 round-trip itself, against a baseline that reads the same `URL` properties and keeps
    /// them as-is. Both arms re-derive the strings from `URL`s, so the comparison is between two
    /// versions of `leafNode` rather than between a string copy and nothing.
    ///
    /// The arms accumulate their nodes into an array and sink its COUNT. An earlier version sank
    /// `n.id.utf8.count` instead, which quietly made the comparison meaningless: reading the UTF-8
    /// of a bridged string is itself the expensive thing being measured, so the as-is arm was
    /// charged ~1 µs per node that the nativized arms were not, and the round-trip looked about
    /// four times cheaper than it is. Nothing in a sink may touch the strings under test.
    private mutating func measureNativizationCost(_ c: Corpus) {
        let urls = c.paths.map { URL(fileURLWithPath: $0) }
        var s = 0
        func build(_ make: (URL) -> FileNode) -> Int {
            var out: [FileNode] = []
            out.reserveCapacity(urls.count)
            for u in urls { out.append(make(u)) }
            return out.count
        }
        Self.compare("node construction (URL -> stored strings)", root: c.label, count: urls.count, arms: [
            ("as-is (today)", {
                s &+= build { FileNode(id: $0.path, name: $0.lastPathComponent, isDirectory: false) }
            }),
            ("nativize id only", {
                s &+= build { FileNode(id: String(decoding: Array($0.path.utf8), as: UTF8.self),
                                       name: $0.lastPathComponent, isDirectory: false) }
            }),
            ("nativize id + name", {
                s &+= build { FileNode(id: String(decoding: Array($0.path.utf8), as: UTF8.self),
                                       name: String(decoding: Array($0.lastPathComponent.utf8), as: UTF8.self),
                                       isDirectory: false) }
            }),
        ])
        sink &+= s
    }

    // MARK: - End to end, on a real built tree

    /// Every microbenchmark above prices one operation. This one asks whether the total shows up:
    /// it walks a real root with the production `buildTree`, then times the whole-tree phases a
    /// pane load actually runs, over THREE versions of the same tree — production's storage, `id`
    /// alone forced native, and `id` and `name` both forced native.
    ///
    /// The `id`-only arm is not a curiosity. Every dictionary and set in the app is keyed on the
    /// path, and none of them is keyed on the leaf name; the one whole-tree consumer that reads
    /// `name` is the per-level sort, which goes through `localizedStandardCompare` — an `NSString`
    /// method that a bridged string is already prepared for and a native one is not. So the two
    /// fields pull in opposite directions, and splitting them is what tells the difference between
    /// a change worth making and one that pays for its own win.
    ///
    /// The walk itself is timed in the same run, so any saving can be stated against the cost it
    /// would be traded for rather than against a figure remembered from another investigation.
    @Test func priceARealPaneLoad() async {
        let roots = Self.roots
        guard !roots.isEmpty else { return }

        for root in roots {
            var walkSamples: [Double] = []
            var tree: [FileNode] = []
            for _ in 0..<3 {
                let start = DispatchTime.now().uptimeNanoseconds
                tree = await FileSyncManager.buildTree(url: root, sortOption: .name)
                walkSamples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            let count = Self.nodeCount(tree)
            guard count > 0 else { continue }
            let warmWalk = walkSamples.dropFirst().sorted()
            print(String(format: "BENCH %@ · buildTree (production, warm): median %.1f ms for %d nodes · samples [%@]",
                         root.lastPathComponent, warmWalk[warmWalk.count / 2], count,
                         walkSamples.map { String(format: "%.1f", $0) }.joined(separator: " ")))

            let idOnly = Self.nativize(tree, id: true, name: false)
            let both = Self.nativize(tree, id: true, name: true)
            let treeRoot = root.path
            var s = 0

            Self.compare("publish: PaneRow.project", root: root.lastPathComponent, count: count, arms: [
                ("as-is", { s &+= PaneRow.project(tree, side: .left, version: 1).count }),
                ("native id", { s &+= PaneRow.project(idOnly, side: .left, version: 1).count }),
                ("native id+name", { s &+= PaneRow.project(both, side: .left, version: 1).count }),
            ])

            func pane(_ nodes: [FileNode]) -> PaneTree {
                PaneTree(side: .left, version: 1, nodes: nodes,
                         rows: PaneRow.project(nodes, side: .left, version: 1))
            }
            let asIsPane = pane(tree), idOnlyPane = pane(idOnly), bothPane = pane(both)
            Self.compare("publish: PaneChildrenIndex", root: root.lastPathComponent, count: count, arms: [
                ("as-is", { s &+= PaneChildrenIndex(tree: asIsPane, treeRoot: treeRoot).isDirectory(atPath: treeRoot) ? 1 : 0 }),
                ("native id", { s &+= PaneChildrenIndex(tree: idOnlyPane, treeRoot: treeRoot).isDirectory(atPath: treeRoot) ? 1 : 0 }),
                ("native id+name", { s &+= PaneChildrenIndex(tree: bothPane, treeRoot: treeRoot).isDirectory(atPath: treeRoot) ? 1 : 0 }),
            ])

            Self.compare("scan: FileDiffEngine.filesInfo(fromTree:)", root: root.lastPathComponent, count: count, arms: [
                ("as-is", { s &+= FileDiffEngine.filesInfo(fromTree: tree, basePath: treeRoot).count }),
                ("native id", { s &+= FileDiffEngine.filesInfo(fromTree: idOnly, basePath: treeRoot).count }),
                ("native id+name", { s &+= FileDiffEngine.filesInfo(fromTree: both, basePath: treeRoot).count }),
            ])

            // `buildTree` returned this tree already sorted by name, and Swift's sort detects an
            // existing run — so this prices a RE-sort (what toggling the sort option back to name
            // costs), not the walk's own first sort. The unsorted case is `measureSort`, which
            // builds its levels straight from enumerator order over real sibling groups.
            Self.compare("re-sort of a sorted tree: sort(by: .name)", root: root.lastPathComponent, count: count, arms: [
                ("as-is", { s &+= FileSyncManager.sort(nodes: tree, by: .name).count }),
                ("native id", { s &+= FileSyncManager.sort(nodes: idOnly, by: .name).count }),
                ("native id+name", { s &+= FileSyncManager.sort(nodes: both, by: .name).count }),
            ])

            // What the walk would pay to hand the phases above a native tree, against a control
            // that rebuilds every node WITHOUT the round-trip — so this is the price of nativizing
            // rather than the price of reconstructing a tree, which the walk does anyway.
            Self.compare("walk surcharge (whole-tree transform)", root: root.lastPathComponent, count: count, arms: [
                ("no-op rebuild (control)", { s &+= Self.nodeCount(Self.nativize(tree, id: false, name: false)) }),
                ("nativize id", { s &+= Self.nodeCount(Self.nativize(tree, id: true, name: false)) }),
                ("nativize id+name", { s &+= Self.nodeCount(Self.nativize(tree, id: true, name: true)) }),
            ])
            print("BENCH \(root.lastPathComponent) · sink \(s)")
        }
    }

    private static func nodeCount(_ nodes: [FileNode]) -> Int {
        nodes.reduce(0) { $0 + 1 + nodeCount($1.children ?? []) }
    }

    /// The candidate change applied to an already-built tree, per field. Rebuilding every node
    /// either way makes the all-false case an exact control for the transform's own cost. `kind`
    /// is left alone throughout: it is equally bridged (it comes from `URLResourceValues`), but it
    /// is outside the change under consideration and only the `.kind` sort reads it.
    private static func nativize(_ nodes: [FileNode], id: Bool, name: Bool) -> [FileNode] {
        func nat(_ s: String) -> String { String(decoding: Array(s.utf8), as: UTF8.self) }
        return nodes.map { n in
            FileNode(id: id ? nat(n.id) : n.id, name: name ? nat(n.name) : n.name,
                     isDirectory: n.isDirectory,
                     children: n.children.map { nativize($0, id: id, name: name) },
                     modificationDate: n.modificationDate, fileSize: n.fileSize, tags: n.tags,
                     kind: n.kind, isUnexplored: n.isUnexplored, isSymbolicLink: n.isSymbolicLink)
        }
    }
}
