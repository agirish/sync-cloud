import Foundation

// MARK: - Result models

/// One rounded area in the Storage Lens treemap — a top-level folder (or the synthetic "Files"
/// bucket for loose top-level files, or the folded "Other" tail). `bytes` is the recursive
/// rolled-up size of every leaf file beneath it.
public struct TreemapNode: Codable, Sendable, Equatable, Hashable {
    public let name: String
    /// Absolute path of the folder this area represents. Empty for the synthetic "Files"/"Other"
    /// buckets, which have no single on-disk home.
    public let path: String
    public let bytes: Int

    public init(name: String, path: String, bytes: Int) {
        self.name = name
        self.path = path
        self.bytes = bytes
    }
}

/// One file row in a Storage Lens ranked list (largest / stale / reclaim candidates).
public struct StorageEntry: Identifiable, Codable, Sendable, Equatable, Hashable {
    /// Absolute filesystem path — the row's identity.
    public let path: String
    public var id: String { path }
    public let name: String
    /// The file's own size in bytes.
    public let bytes: Int
    /// Last-modified date, when known. nil files are excluded from age-based lists.
    public let modified: Date?

    public init(path: String, name: String, bytes: Int, modified: Date?) {
        self.path = path
        self.name = name
        self.bytes = bytes
        self.modified = modified
    }
}

/// The full "where does my space go?" picture for one scanned root: a treemap of top areas plus
/// three ranked file lists. Purely descriptive — nothing here mutates the user's files.
public struct StorageLensReport: Codable, Sendable, Equatable {
    /// Top folders (and a synthetic "Files"/"Other" bucket) by rolled-up size, largest first.
    public let treemap: [TreemapNode]
    /// Biggest individual files, largest first.
    public let largest: [StorageEntry]
    /// Files untouched longer than the stale threshold, oldest first.
    public let stale: [StorageEntry]
    /// Large AND long-untouched files — the "worth making online-only" rows, largest first.
    public let reclaimCandidates: [StorageEntry]
    /// Total bytes of every leaf file in the scanned tree.
    public let totalBytes: Int

    // **The whole tree's numbers, counted before the lists are capped at `topN`.** The three lists
    // above are each the first `topN` rows, so their `count` is the cap on nearly any real tree,
    // and a headline built from them read "20 large · 20 untouched" everywhere, with a
    // "reclaimable" figure summing only the first 20 candidates. These are what the lists were
    // drawn from.
    //
    // **nil on a report saved before they existed** (every 6.0 snapshot). Its lists are capped
    // like any other, so filling these in from them restored the very "20 files · 20 untouched"
    // headline the totals were added to end; nil lets the headline say it needs a rescan instead.

    /// Every leaf file the analysis measured — the pool `largest` is the top of.
    public let fileCount: Int?
    /// Every file past the stale threshold, not only the `stale` rows shown.
    public let staleCount: Int?
    /// Every reclaim candidate, not only the `reclaimCandidates` rows shown.
    public let reclaimCount: Int?
    /// The bytes of every reclaim candidate.
    public let reclaimableBytes: Int?

    /// **The four totals are required.** They used to default to what the lists add up to, which
    /// is exact only for lists that were never capped — so a caller that forgot them got the
    /// capped "20 files · 20 untouched" counts back without a word. The analyzer passes the
    /// tree's own, and a hand-built report says what its tree holds. (Only the decoder can leave
    /// them unknown; see ``init(from:)``.)
    public init(
        treemap: [TreemapNode],
        largest: [StorageEntry],
        stale: [StorageEntry],
        reclaimCandidates: [StorageEntry],
        totalBytes: Int,
        fileCount: Int,
        staleCount: Int,
        reclaimCount: Int,
        reclaimableBytes: Int
    ) {
        self.treemap = treemap
        self.largest = largest
        self.stale = stale
        self.reclaimCandidates = reclaimCandidates
        self.totalBytes = totalBytes
        self.fileCount = fileCount
        self.staleCount = staleCount
        self.reclaimCount = reclaimCount
        self.reclaimableBytes = reclaimableBytes
    }

    /// Every field as given, nil totals included — the decoder's door.
    private init(treemap: [TreemapNode], largest: [StorageEntry], stale: [StorageEntry],
                 reclaimCandidates: [StorageEntry], totalBytes: Int, decodedFileCount: Int?,
                 staleCount: Int?, reclaimCount: Int?, reclaimableBytes: Int?) {
        self.treemap = treemap
        self.largest = largest
        self.stale = stale
        self.reclaimCandidates = reclaimCandidates
        self.totalBytes = totalBytes
        self.fileCount = decodedFileCount
        self.staleCount = staleCount
        self.reclaimCount = reclaimCount
        self.reclaimableBytes = reclaimableBytes
    }

    private enum CodingKeys: String, CodingKey {
        case treemap, largest, stale, reclaimCandidates, totalBytes
        case fileCount, staleCount, reclaimCount, reclaimableBytes
    }

    /// Reads a report saved before the totals existed — every snapshot written by 6.0 and earlier —
    /// with the totals nil. A required key would have thrown, and a snapshot that fails to decode
    /// is a Storage page that comes up empty after an update; falling back to the lists' lengths
    /// read the capped lists as the tree's counts again.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            treemap: c.decode([TreemapNode].self, forKey: .treemap),
            largest: c.decode([StorageEntry].self, forKey: .largest),
            stale: c.decode([StorageEntry].self, forKey: .stale),
            reclaimCandidates: c.decode([StorageEntry].self, forKey: .reclaimCandidates),
            totalBytes: c.decode(Int.self, forKey: .totalBytes),
            decodedFileCount: c.decodeIfPresent(Int.self, forKey: .fileCount),
            staleCount: c.decodeIfPresent(Int.self, forKey: .staleCount),
            reclaimCount: c.decodeIfPresent(Int.self, forKey: .reclaimCount),
            reclaimableBytes: c.decodeIfPresent(Int.self, forKey: .reclaimableBytes))
    }
}

// MARK: - Options

public struct StorageLensOptions: Sendable {
    /// A file untouched for at least this many days is "stale".
    public var staleThresholdDays: Int
    /// A reclaim candidate must be untouched for at least this many days (shorter than
    /// `staleThresholdDays` — a large file idle half a year is already worth offloading).
    public var reclaimStaleDays: Int
    /// A reclaim candidate must be at least this large (small idle files aren't worth surfacing).
    public var minReclaimBytes: Int
    /// Cap on each ranked list's row count.
    public var topN: Int
    /// Number of named areas in the treemap before the tail folds into "Other".
    public var treemapBuckets: Int

    public init(
        staleThresholdDays: Int = 365,
        reclaimStaleDays: Int = 180,
        minReclaimBytes: Int = 100_000_000,
        topN: Int = 20,
        treemapBuckets: Int = 8
    ) {
        self.staleThresholdDays = staleThresholdDays
        self.reclaimStaleDays = reclaimStaleDays
        self.minReclaimBytes = minReclaimBytes
        self.topN = topN
        self.treemapBuckets = treemapBuckets
    }
}

// MARK: - Analyzer

/// Turns an already-walked ``FileNode`` tree into a ``StorageLensReport``. Pure and deterministic
/// — no disk access — so it unit-tests off an in-memory tree, mirroring ``DuplicateFinder``.
///
/// Sizes are rolled up bottom-up: a directory's size is the sum of the leaf files beneath it (its
/// own inode size is never counted, and `isUnexplored` subtrees — whose `children == []` is a walk
/// artifact, not an observation — contribute nothing rather than a false zero).
public enum StorageLensAnalyzer {

    public static func analyze(
        tree: [FileNode],
        now: Date,
        options: StorageLensOptions = .init()
    ) -> StorageLensReport {
        // 1. Every leaf file, gathered once and reused for all three ranked lists.
        var leaves: [StorageEntry] = []
        collectLeaves(tree, into: &leaves)

        let totalBytes = leaves.reduce(0) { $0 + $1.bytes }

        // 2. Treemap over the top-level nodes.
        let treemap = buildTreemap(tree: tree, buckets: options.treemapBuckets)

        // 3. Largest files (skip zero-byte — they use no space).
        let largest = Array(
            leaves
                .filter { $0.bytes > 0 }
                .sorted(by: bytesDescThenPath)
                .prefix(options.topN)
        )

        // 4. Stale: untouched past the threshold, oldest first. Files with no mtime are excluded —
        //    staleness can't be judged without a date. Counted BEFORE the cap, so the report can
        //    say how many there are as well as which ones come first.
        let staleCutoff = now.addingTimeInterval(-Double(options.staleThresholdDays) * 86_400)
        let allStale = leaves.filter { entry in
            guard let m = entry.modified else { return false }
            return m < staleCutoff
        }
        let stale = Array(allStale.sorted(by: oldestThenPath).prefix(options.topN))

        // 5. Reclaim candidates: BOTH large AND long-untouched — the rows worth making online-only.
        //    Counted and summed before the cap, for the same reason.
        let reclaimCutoff = now.addingTimeInterval(-Double(options.reclaimStaleDays) * 86_400)
        let allReclaim = leaves.filter { entry in
            guard let m = entry.modified else { return false }
            return entry.bytes >= options.minReclaimBytes && m < reclaimCutoff
        }
        let reclaimCandidates = Array(allReclaim.sorted(by: bytesDescThenPath).prefix(options.topN))

        return StorageLensReport(
            treemap: treemap,
            largest: largest,
            stale: stale,
            reclaimCandidates: reclaimCandidates,
            totalBytes: totalBytes,
            fileCount: leaves.count,
            staleCount: allStale.count,
            reclaimCount: allReclaim.count,
            reclaimableBytes: allReclaim.reduce(0) { $0 + $1.bytes }
        )
    }

    // MARK: Sort orders (stable — path breaks ties for deterministic output)

    private static func bytesDescThenPath(_ a: StorageEntry, _ b: StorageEntry) -> Bool {
        if a.bytes != b.bytes { return a.bytes > b.bytes }
        return a.path < b.path
    }

    private static func oldestThenPath(_ a: StorageEntry, _ b: StorageEntry) -> Bool {
        let ma = a.modified ?? .distantPast, mb = b.modified ?? .distantPast
        if ma != mb { return ma < mb }
        return a.path < b.path
    }

    // MARK: Traversal

    /// Recursively collects leaf file nodes as ``StorageEntry`` rows, descending only into walked
    /// directories (an `isUnexplored` folder's empty `children` is a construction artifact).
    private static func collectLeaves(_ nodes: [FileNode], into out: inout [StorageEntry]) {
        for node in nodes {
            // Skip symlinks: the walk resolves a link's size/content to its target, so counting a
            // link AND its in-tree target would double the reported usage (and list every big file
            // twice). A symlink occupies no real space of its own. Mirrors DuplicateFinder.
            if node.isSymbolicLink == true { continue }
            // And skip a subtree this walk also reached by a shorter route. Same hazard, and the
            // line above could not see it: a folder the root links in from outside is SUBSTITUTED
            // for the real folder, so it arrives with the real path and `isSymbolicLink == false`.
            // Measured 2026-09-08 — `~/Documents` reached twice under a `~` scan put 10.5 GB of
            // phantom usage into this total. See `FileNode.isCoveredElsewhere`.
            if node.isCoveredElsewhere == true { continue }
            if node.isDirectory {
                if node.isUnexplored == true { continue }
                collectLeaves(node.children ?? [], into: &out)
            } else {
                out.append(StorageEntry(
                    path: node.id,
                    name: node.name,
                    bytes: node.fileSize ?? 0,
                    modified: node.modificationDate
                ))
            }
        }
    }

    /// The recursive rolled-up byte size of one node: a leaf's own size, or the sum of every leaf
    /// beneath a directory (skipping unexplored subtrees).
    static func rolledUpBytes(_ node: FileNode) -> Int {
        // A symlink reclaims no real space (its size/content is its target's); don't roll it up.
        if node.isSymbolicLink == true { return 0 }
        // Nor does a subtree already rolled up under its shorter route — see `collectLeaves`.
        if node.isCoveredElsewhere == true { return 0 }
        if node.isDirectory {
            if node.isUnexplored == true { return 0 }
            return (node.children ?? []).reduce(0) { $0 + rolledUpBytes($1) }
        }
        return node.fileSize ?? 0
    }

    /// Builds the treemap: one area per top-level folder, a synthetic "Files" bucket for loose
    /// top-level files, sorted largest-first, with everything past `buckets` folded into "Other".
    private static func buildTreemap(tree: [FileNode], buckets: Int) -> [TreemapNode] {
        var nodes: [TreemapNode] = []
        var looseFileBytes = 0
        for node in tree {
            if node.isSymbolicLink == true { continue }   // no phantom tile / double-count for a link
            if node.isDirectory {
                let bytes = rolledUpBytes(node)
                if bytes > 0 {
                    nodes.append(TreemapNode(name: node.name, path: node.id, bytes: bytes))
                }
            } else {
                looseFileBytes += node.fileSize ?? 0
            }
        }
        if looseFileBytes > 0 {
            nodes.append(TreemapNode(name: "Files", path: "", bytes: looseFileBytes))
        }

        nodes.sort { a, b in
            if a.bytes != b.bytes { return a.bytes > b.bytes }
            return a.name < b.name
        }

        guard buckets > 0, nodes.count > buckets else { return nodes }
        let kept = Array(nodes.prefix(buckets))
        let otherBytes = nodes.dropFirst(buckets).reduce(0) { $0 + $1.bytes }
        return otherBytes > 0 ? kept + [TreemapNode(name: "Other", path: "", bytes: otherBytes)] : kept
    }
}
