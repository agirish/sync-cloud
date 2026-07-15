import Foundation

// MARK: - Result models

/// One rounded area in the Storage Lens treemap — a top-level folder (or the synthetic "Files"
/// bucket for loose top-level files, or the folded "Other" tail). `bytes` is the recursive
/// rolled-up size of every leaf file beneath it.
public struct TreemapNode: Sendable, Equatable, Hashable {
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
public struct StorageEntry: Identifiable, Sendable, Equatable, Hashable {
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
public struct StorageLensReport: Sendable, Equatable {
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

    public init(
        treemap: [TreemapNode],
        largest: [StorageEntry],
        stale: [StorageEntry],
        reclaimCandidates: [StorageEntry],
        totalBytes: Int
    ) {
        self.treemap = treemap
        self.largest = largest
        self.stale = stale
        self.reclaimCandidates = reclaimCandidates
        self.totalBytes = totalBytes
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
        //    staleness can't be judged without a date.
        let staleCutoff = now.addingTimeInterval(-Double(options.staleThresholdDays) * 86_400)
        let stale = Array(
            leaves
                .filter { entry in
                    guard let m = entry.modified else { return false }
                    return m < staleCutoff
                }
                .sorted(by: oldestThenPath)
                .prefix(options.topN)
        )

        // 5. Reclaim candidates: BOTH large AND long-untouched — the rows worth making online-only.
        let reclaimCutoff = now.addingTimeInterval(-Double(options.reclaimStaleDays) * 86_400)
        let reclaimCandidates = Array(
            leaves
                .filter { entry in
                    guard let m = entry.modified else { return false }
                    return entry.bytes >= options.minReclaimBytes && m < reclaimCutoff
                }
                .sorted(by: bytesDescThenPath)
                .prefix(options.topN)
        )

        return StorageLensReport(
            treemap: treemap,
            largest: largest,
            stale: stale,
            reclaimCandidates: reclaimCandidates,
            totalBytes: totalBytes
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
