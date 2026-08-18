import Foundation
import CryptoKit

// MARK: - Result model

/// How the copies in a duplicate group are related. Shape (and the UI glyph derived from it)
/// encodes the relationship, so the right resolution reads without color: identical copies can
/// be collapsed to one, overlapping folders want an additive merge, name-only groups are a
/// warning not a redundancy, versions want "keep the newest".
public enum DuplicateMatchType: Sendable, Equatable, Hashable {
    /// Byte-for-byte identical content (files) or identical recursive trees (folders).
    case identical
    /// Folders that share most of their content but each holds some unique items.
    /// `sharedFraction` is the average shared-content ratio across the redundant copies (0...1).
    case overlapping(sharedFraction: Double)
    /// Same name, genuinely different contents — likely two unrelated things. Never auto-removed.
    case nameOnly
    /// File names that reduce to one stem (`Report`, `Report (1)`, `Report-final`) but drifted.
    case versions
    /// Documents whose *text* is identical although their bytes are not — one document downloaded
    /// twice from a provider that re-stamps each copy. See ``ContentFingerprint``.
    ///
    /// **A strictly weaker claim than `identical`, and it carries its own rules because of that.**
    /// The digest proves the extracted text matches, which is not the same as proving the documents
    /// match: measured over the real tree, 9 of 212 such groups turned out to be a signed copy
    /// beside its unsigned original, a redacted copy beside the full one, or a resume revision whose
    /// edit was purely visual. So the group is never in the "Apply recommended" batch — the user
    /// looks at each one — while still being resolvable per group once they have.
    case sameText

    /// A stable key for filtering/sorting that ignores the associated value.
    public var kind: Kind {
        switch self {
        case .identical: return .identical
        case .overlapping: return .overlapping
        case .nameOnly: return .nameOnly
        case .versions: return .versions
        case .sameText: return .sameText
        }
    }

    public enum Kind: String, Sendable, CaseIterable, Hashable {
        case identical, overlapping, nameOnly, versions, sameText
    }
}

/// One copy within a duplicate group.
public struct DuplicateCopy: Identifiable, Sendable, Equatable, Hashable {
    /// Absolute filesystem path — the copy's identity.
    public let id: String
    public var path: String { id }
    public let name: String
    public let isDirectory: Bool
    /// Total bytes (recursive for folders).
    public let size: Int
    /// Recursive count of enclosed items for folders; 1 for a file.
    public let itemCount: Int
    public let modificationDate: Date?
    /// Number of content items in this copy that are NOT present in the group's keeper.
    /// 0 for a fully redundant copy; > 0 for an overlapping copy that would need a merge.
    public let uniqueItemCount: Int
    /// Depth of the path below the scan root (fewer = closer to root = more canonical).
    public let depth: Int
    /// Whether this is the recommended copy to keep.
    public let isRecommendedKeeper: Bool
    /// True when the scan could NOT content-verify this copy: its hash (or, for a folder, some
    /// descendant's) was skipped — too large, cloud-only, unreadable. Lets the UI say the group's
    /// content claim rests on less than full verification. Defaulted so existing construction
    /// sites are unaffected.
    public let contentUnverified: Bool

    /// True when this copy lives inside a folder another group is KEEPING, so no recommendation may
    /// offer to remove it — not the current one, and not one the user re-aims by picking a
    /// different keeper. Without this the invariant lasted exactly as long as the default keeper:
    /// `choosingKeeper` relabels copies purely by id, so moving the keeper elsewhere put the kept
    /// folder's own file straight back on the removal list.
    public let isProtectedFromRemoval: Bool

    /// A non-keeper copy that holds nothing the keeper lacks — safe to remove outright.
    public var isFullyRedundant: Bool { !isRecommendedKeeper && uniqueItemCount == 0 }

    public init(
        id: String,
        name: String,
        isDirectory: Bool,
        size: Int,
        itemCount: Int,
        modificationDate: Date?,
        uniqueItemCount: Int,
        depth: Int,
        isRecommendedKeeper: Bool,
        contentUnverified: Bool = false,
        isProtectedFromRemoval: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.itemCount = itemCount
        self.modificationDate = modificationDate
        self.uniqueItemCount = uniqueItemCount
        self.depth = depth
        self.isRecommendedKeeper = isRecommendedKeeper
        self.contentUnverified = contentUnverified
        self.isProtectedFromRemoval = isProtectedFromRemoval
    }
}

/// A cluster of duplicate/related items surfaced by ``DuplicateFinder``.
public struct DuplicateGroup: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let matchType: DuplicateMatchType
    /// The common display name (e.g. "Folder 1"). For versions it's the shared stem.
    public let name: String
    public let isDirectory: Bool
    /// The copies, keeper first, then by ascending depth and path.
    public let copies: [DuplicateCopy]
    /// Bytes recoverable by applying the recommended resolution.
    public let reclaimableBytes: Int

    public init(
        id: UUID = UUID(),
        matchType: DuplicateMatchType,
        name: String,
        isDirectory: Bool,
        copies: [DuplicateCopy],
        reclaimableBytes: Int
    ) {
        self.id = id
        self.matchType = matchType
        self.name = name
        self.isDirectory = isDirectory
        self.copies = copies
        self.reclaimableBytes = reclaimableBytes
    }

    /// A stable identity for this cluster across scans — the sorted copy paths. Lets a
    /// "Keep separate" choice persist so the same group isn't re-flagged next scan.
    public var ignoreKey: String {
        copies.map { $0.id }.sorted().joined(separator: "\n")
    }

    /// The recommended copy to keep.
    public var keeper: DuplicateCopy {
        copies.first(where: { $0.isRecommendedKeeper }) ?? copies[0]
    }

    /// The copies the recommendation would remove or merge away.
    public var redundantCopies: [DuplicateCopy] {
        copies.filter { !$0.isRecommendedKeeper }
    }

    /// True when the recommendation removes copies without any merge — the per-group one-click
    /// case (identical dedup, or keep-newest for versions).
    public var isFullyResolvableByRemoval: Bool {
        switch matchType {
        case .identical, .versions, .sameText: return true
        case .overlapping, .nameOnly: return false
        }
    }

    /// True when this group is safe to include in the blind "Apply recommended" batch. Only
    /// byte-identical duplicates qualify: versions discard genuinely *different* older content and
    /// version-matching is heuristic (bursts, numbered series), so they require a per-group look —
    /// and a `sameText` group proves only that two documents *read* the same, which the measured
    /// signed-copy and redacted-copy cases show is not the same as being the same document.
    public var isRecommendedForBatch: Bool {
        if case .identical = matchType { return true }
        return false
    }

    /// Absolute paths the recommended removal would trash (fully-redundant / older copies).
    public var recommendedRemovalPaths: [String] {
        switch matchType {
        case .identical, .versions, .sameText:
            // Protected copies are filtered here, at the ONE place a recommendation becomes a list
            // of paths to trash, so re-aiming the keeper cannot smuggle one back in.
            return redundantCopies.filter { !$0.isProtectedFromRemoval }.map { $0.path }
        case .overlapping, .nameOnly:
            return []
        }
    }

    /// Whether the user may pick a different keeper — whatever `isFullyResolvableByRemoval` admits,
    /// which is identical, versions **and same-text** (`DuplicateFinderSameTextTests` pins that
    /// last one deliberately). Overlapping and name-only groups are the exclusions: changing an
    /// overlapping keeper would re-shuffle which items are "unique", which needs the content hashes
    /// we don't retain after a scan, and a name-only group is not known to hold one document at all.
    /// Read off `isFullyResolvableByRemoval` rather than restated — the list was spelled out here
    /// and stopped matching when same-text arrived, and restating it in the fix reproduced the same
    /// drift by forgetting name-only.
    public var allowsKeeperChoice: Bool { isFullyResolvableByRemoval }

    /// Returns this group with a different keeper chosen (no-op unless `allowsKeeperChoice` and the
    /// id names a non-keeper copy). Reorders keeper-first and recomputes reclaimable bytes; keeps
    /// the same `id` so list/expansion identity is stable.
    public func choosingKeeper(_ copyID: DuplicateCopy.ID) -> DuplicateGroup {
        guard allowsKeeperChoice,
              copyID != keeper.id,
              copies.contains(where: { $0.id == copyID }) else { return self }
        let relabelled = copies.map { Self.relabel($0, isKeeper: $0.id == copyID) }
        let newKeeper = relabelled.first { $0.id == copyID }!
        let rest = relabelled.filter { $0.id != copyID }.sorted { ($0.depth, $0.id) < ($1.depth, $1.id) }
        // Protected copies are excluded, for the same reason `recommendedRemovalPaths` excludes
        // them: re-aiming the keeper is exactly what puts a protected copy on the redundant side,
        // and counting bytes that will never be trashed makes the card promise a reclaim the
        // "Move to Trash" it sits beside cannot deliver.
        let reclaim = rest.filter { !$0.isProtectedFromRemoval }.reduce(0) { $0 + $1.size }
        return DuplicateGroup(id: id, matchType: matchType, name: name, isDirectory: isDirectory,
                              copies: [newKeeper] + rest, reclaimableBytes: reclaim)
    }

    /// Returns this group with the copy at `path` removed and its figures recomputed, or nil when
    /// fewer than two copies remain (the cluster is no longer a duplicate). Keeps the same `id` so
    /// list/expansion identity is stable. Used when a single copy is resolved out-of-band — trashed
    /// from the Compare duplicate review — so the Duplicates list updates without a full rescan.
    ///
    /// The Compare flow only ever trashes a *redundant* copy (the keeper stays on the left), but if
    /// the keeper is the one removed we promote the shallowest survivor so the group keeps a keeper.
    public func removingRedundantCopy(atPath path: String) -> DuplicateGroup? {
        guard let removed = copies.first(where: { $0.id == path }) else { return self }
        var remaining = copies.filter { $0.id != path }
        guard remaining.count >= 2 else { return nil }

        if removed.isRecommendedKeeper, !remaining.contains(where: { $0.isRecommendedKeeper }) {
            let newKeeperID = remaining.min { ($0.depth, $0.id) < ($1.depth, $1.id) }!.id
            remaining = remaining.map { Self.relabel($0, isKeeper: $0.id == newKeeperID) }
        }
        let keeperFirst = remaining.sorted {
            (($0.isRecommendedKeeper ? 0 : 1), $0.depth, $0.id) < (($1.isRecommendedKeeper ? 0 : 1), $1.depth, $1.id)
        }
        return DuplicateGroup(
            id: id, matchType: matchType, name: name, isDirectory: isDirectory,
            copies: keeperFirst,
            reclaimableBytes: Self.reclaim(after: removed, matchType: matchType,
                                           remaining: keeperFirst, priorReclaim: reclaimableBytes))
    }

    /// A copy of `c` with its keeper flag set — the single relabelling used by
    /// ``choosingKeeper(_:)`` and ``removingRedundantCopy(atPath:)``.
    private static func relabel(_ c: DuplicateCopy, isKeeper: Bool) -> DuplicateCopy {
        DuplicateCopy(id: c.id, name: c.name, isDirectory: c.isDirectory, size: c.size,
                      itemCount: c.itemCount, modificationDate: c.modificationDate,
                      uniqueItemCount: c.uniqueItemCount, depth: c.depth,
                      isRecommendedKeeper: isKeeper, contentUnverified: c.contentUnverified,
                      isProtectedFromRemoval: c.isProtectedFromRemoval)
    }

    /// Recomputes reclaimable bytes after one copy is removed, per the finder's own rules: identical
    /// and versions groups reclaim the full size of every remaining redundant copy; an overlapping
    /// group reclaims each redundant copy's *shared* bytes, so it drops by the removed copy's share
    /// (its per-copy fraction isn't retained, so the group's average shared fraction stands in);
    /// name-only groups reclaim nothing.
    private static func reclaim(after removed: DuplicateCopy, matchType: DuplicateMatchType,
                                remaining: [DuplicateCopy], priorReclaim: Int) -> Int {
        switch matchType {
        case .identical, .versions, .sameText:
            return remaining.filter { !$0.isRecommendedKeeper && !$0.isProtectedFromRemoval }
                .reduce(0) { $0 + $1.size }
        case .overlapping(let fraction):
            return max(0, priorReclaim - Int(Double(removed.size) * fraction))
        case .nameOnly:
            return 0
        }
    }
}

// MARK: - Options

public struct DuplicateFinderOptions: Sendable {
    /// Files smaller than this are ignored for standalone file grouping (they still count toward
    /// folder signatures). Keeps trivially tiny files out of the results.
    public var minFileSize: Int
    /// Folder overlap at or above this fraction is reported as "overlapping"; below it, a
    /// same-name/different-content pair is reported as "name only".
    public var overlapThreshold: Double
    /// Names skipped entirely (their subtrees don't count toward signatures either).
    public var ignoredNames: Set<String>
    /// Whether to surface drifted same-stem files as version groups.
    public var detectVersions: Bool
    /// Whether to read documents and group those whose *text* matches although their bytes do not
    /// — the re-stamped-download case. Costs one PDF parse per document on a COLD scan and nothing
    /// on a rescan, because the digests are cached by the same (path, mtime, size) key the content
    /// hashes use.
    ///
    /// **~5.5 minutes for this tree's 10,569 PDFs, not the 46 s this once said.** That figure was
    /// measured with six parses running at a time, which is the arrangement
    /// ``PDFKitSerialAccess`` exists to forbid — PDFKit's text extraction is not thread-safe, and
    /// the fast number was buying a digest that changed between runs. The honest cost of a stable
    /// fingerprint is one parse at a time.
    public var detectSameText: Bool

    public init(
        minFileSize: Int = 4 * 1024,
        overlapThreshold: Double = 0.7,
        ignoredNames: Set<String> = DuplicateFinderOptions.defaultIgnoredNames,
        detectVersions: Bool = true,
        detectSameText: Bool = true
    ) {
        self.minFileSize = minFileSize
        self.overlapThreshold = overlapThreshold
        self.ignoredNames = ignoredNames
        self.detectVersions = detectVersions
        self.detectSameText = detectSameText
    }

    public static let defaultIgnoredNames: Set<String> = [
        ".DS_Store", ".git", ".build", "node_modules", ".Trashes", "Thumbs.db", ".localized"
    ]

    /// UserDefaults keys the Settings UI binds to (shared so the app builds the same options).
    public enum DefaultsKey {
        public static let minFileSize = "tidyMinFileSize"
        public static let overlapThreshold = "tidyOverlapThreshold"
        public static let detectVersions = "tidyDetectVersions"
        public static let detectSameText = "tidyDetectSameText"
    }

    /// Builds options from persisted settings, falling back to the code defaults for any unset key.
    public static func fromDefaults(_ defaults: UserDefaults = .standard) -> DuplicateFinderOptions {
        var options = DuplicateFinderOptions()
        if defaults.object(forKey: DefaultsKey.minFileSize) != nil {
            options.minFileSize = defaults.integer(forKey: DefaultsKey.minFileSize)
        }
        if defaults.object(forKey: DefaultsKey.overlapThreshold) != nil {
            options.overlapThreshold = defaults.double(forKey: DefaultsKey.overlapThreshold)
        }
        if defaults.object(forKey: DefaultsKey.detectVersions) != nil {
            options.detectVersions = defaults.bool(forKey: DefaultsKey.detectVersions)
        }
        if defaults.object(forKey: DefaultsKey.detectSameText) != nil {
            options.detectSameText = defaults.bool(forKey: DefaultsKey.detectSameText)
        }
        return options
    }

    /// Version-group stems this common are too generic to be useful; suppressed to cut noise.
    static let genericVersionStems: Set<String> = [
        "index", "readme", "untitled", "document", "image", "img", "photo", "screenshot",
        "scan", "new", "temp", "test", "note", "notes", "file"
    ]
}

// MARK: - Engine

/// Finds duplicate and related items *within a single provider tree*. Pure and deterministic:
/// grouping runs over an already-walked ``FileNode`` tree plus a map of file content hashes, so
/// the logic is fully testable without disk. Mirrors ``FileDiffEngine`` (stateless statics).
public enum DuplicateFinder {

    /// Prefix of the per-path placeholder signature the scan assigns to files it could NOT hash
    /// (over the size cap, unreadable, cloud-only). Placeholders keep folder signatures computable
    /// — a unique value can never falsely MATCH — but they are not content identity: they must
    /// never count as evidence that two files' contents DIFFER either.
    public static let unknownSignaturePrefix = "u:"

    /// Builds the placeholder signature for a file whose content identity is unknown.
    public static func unknownSignature(forPath path: String) -> String {
        unknownSignaturePrefix + path
    }

    /// Whether a signature is an unknown-content placeholder rather than a real content hash.
    public static func isUnknownSignature(_ signature: String) -> Bool {
        signature.hasPrefix(unknownSignaturePrefix)
    }

    // Internal per-node rollup computed bottom-up from the tree.
    struct NodeInfo {
        let path: String
        let name: String
        let isDirectory: Bool
        let size: Int
        let itemCount: Int
        let modificationDate: Date?
        let depth: Int
        /// Structural content signature (folders) or content hash (files). nil = identity unknown.
        let signature: String?
        /// Set of descendant file content hashes (folders); the file's own hash (files).
        let contentHashes: Set<String>
    }

    /// Groups duplicate/related items in the given tree.
    /// - Parameters:
    ///   - tree: The walked children of the scan root (top-level nodes).
    ///   - fileHashes: Map of absolute file path → SHA-256 hex. Files absent from the map are
    ///     treated as "identity unknown" and never asserted identical.
    ///   - options: Tuning.
    ///   - textFingerprints: Map of absolute file path → ``ContentFingerprint`` digest, for the
    ///     documents that produced one. Absent means "this document did not say enough to be
    ///     identified by what it says" and is never evidence either way.
    /// - Returns: Groups sorted by reclaimable bytes (desc), then name.
    public static func findGroups(
        tree: [FileNode],
        fileHashes: [String: String],
        options: DuplicateFinderOptions = .init(),
        multiLinkPaths: Set<String> = [],
        textFingerprints: [String: String] = [:]
    ) -> [DuplicateGroup] {
        var files: [NodeInfo] = []
        var dirs: [NodeInfo] = []
        for node in tree {
            _ = collect(node, depth: 0, fileHashes: fileHashes, options: options, files: &files, dirs: &dirs)
        }
        // Hard-linked files (link count > 1) leave duplicate candidacy ENTIRELY, before any
        // pass: a directory entry is not the bytes, so every offer the single-path copy model
        // could make about one is a lie — trashing one link frees nothing (a sibling entry, in
        // or out of the scan, keeps the blocks), "identical" links aren't a duplicate pair, and
        // a versions group must not adjudicate history between an inode and itself. One drop
        // here protects the identical AND versions passes alike; a per-pass collapse protected
        // one and un-claimed the links for the other. Unknown link counts (no stat) stay in:
        // over-reporting a duplicate beats hiding one.
        if !multiLinkPaths.isEmpty {
            files.removeAll { multiLinkPaths.contains($0.path) }
        }

        var groups: [DuplicateGroup] = []
        // Paths already fully accounted for by an ancestor duplicate group (so we don't also
        // report every file inside a redundant folder copy as its own duplicate).
        var coveredRoots: Set<String> = []
        // File paths already placed in a group (identical wins over versions).
        var groupedFilePaths: Set<String> = []
        // The KEEPER side of every identical-folder group. `coveredRoots` deliberately holds only
        // the redundant copies, so without this the file passes below could recommend removing a
        // file from inside a folder the very same batch is keeping — see `protectingFolderKeepers`.
        var folderKeeperRoots: Set<String> = []

        // The KEEPER side of every identical-FILE group, for the same reason `folderKeeperRoots`
        // exists one line up: the same-text pass below is allowed to reach back for one of these
        // as an anchor, and must never offer to remove it.
        var identicalFileKeepers: Set<String> = []

        groups += identicalFolderGroups(dirs, options: options, coveredRoots: &coveredRoots, keeperRoots: &folderKeeperRoots)
        groups += overlappingAndNameOnlyGroups(dirs, options: options, coveredRoots: &coveredRoots)
        groups += identicalFileGroups(files, options: options, coveredRoots: coveredRoots, keeperRoots: folderKeeperRoots, groupedFilePaths: &groupedFilePaths, keepers: &identicalFileKeepers)
        // BEFORE versions, deliberately. A provider's second download often lands beside the first
        // under a name the version stemmer reduces to the same stem — `DE429D.pdf` next to
        // `DE429D-2.pdf`. Left to the versions pass those become "keep newest, trash older", which
        // is a story about a document that changed; the fingerprint knows it did not change at all.
        if options.detectSameText, !textFingerprints.isEmpty {
            groups += sameTextFileGroups(files, fingerprints: textFingerprints, options: options,
                                         coveredRoots: coveredRoots, folderKeeperRoots: folderKeeperRoots,
                                         identicalKeepers: identicalFileKeepers,
                                         groupedFilePaths: &groupedFilePaths)
        }
        if options.detectVersions {
            groups += versionGroups(files, options: options, coveredRoots: coveredRoots, keeperRoots: folderKeeperRoots, groupedFilePaths: &groupedFilePaths)
        }

        return groups.sorted { lhs, rhs in
            if lhs.reclaimableBytes != rhs.reclaimableBytes { return lhs.reclaimableBytes > rhs.reclaimableBytes }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: Traversal

    /// Rolls up a node bottom-up, appending files/dirs to the collectors. Returns the node's info
    /// (or nil if it was skipped as an ignored name).
    private static func collect(
        _ node: FileNode,
        depth: Int,
        fileHashes: [String: String],
        options: DuplicateFinderOptions,
        files: inout [NodeInfo],
        dirs: inout [NodeInfo]
    ) -> NodeInfo? {
        if options.ignoredNames.contains(node.name) { return nil }
        // A symlink must never be a duplicate CANDIDATE: the walk resolves its size/content to its
        // target, so a link and its in-tree target would hash identically and group as "copies,"
        // and trashing the real target would leave a dangling link as the "kept" copy. But it still
        // occupies a name in its parent, so it MUST contribute to the parent's structural signature
        // — otherwise a folder containing a symlink would look identical to one without it and the
        // two would be offered as duplicate folders. So return an info the parent folds into its
        // signature (a file link carries a "symlink:"-TAGGED target hash so it can never collide
        // with a REAL file of the same name+hash — otherwise a folder holding a symlink would look
        // identical to one holding the real file and the two would be offered as duplicate folders,
        // trashing the real copy; a directory link is left unhashed, conservatively making its
        // parent non-groupable) WITHOUT adding it to the file/dir buckets, and without walking a
        // linked directory's contents. Size 0 + itemCount 0: a symlink reclaims no space and adds no
        // nested items (the parent still counts it as one entry via its own `+ 1`).
        if node.isSymbolicLink == true {
            let signature = node.isDirectory ? nil : fileHashes[node.id].map { "symlink:" + $0 }
            return NodeInfo(
                path: node.id,
                name: node.name,
                isDirectory: node.isDirectory,
                size: 0,
                itemCount: 0,
                modificationDate: node.modificationDate,
                depth: depth,
                signature: signature,
                contentHashes: []
            )
        }

        if !node.isDirectory {
            let hash = fileHashes[node.id]
            let info = NodeInfo(
                path: node.id,
                name: node.name,
                isDirectory: false,
                size: node.fileSize ?? 0,
                itemCount: 1,
                modificationDate: node.modificationDate,
                depth: depth,
                signature: hash,
                contentHashes: hash.map { [$0] } ?? []
            )
            files.append(info)
            return info
        }

        // Directory: roll up children first.
        var childInfos: [NodeInfo] = []
        for child in node.children ?? [] {
            if let ci = collect(child, depth: depth + 1, fileHashes: fileHashes, options: options, files: &files, dirs: &dirs) {
                childInfos.append(ci)
            }
        }

        let size = childInfos.reduce(0) { $0 + $1.size }
        let itemCount = childInfos.reduce(0) { $0 + 1 + ($1.isDirectory ? $1.itemCount : 0) }
        var contentHashes = Set<String>()
        for ci in childInfos { contentHashes.formUnion(ci.contentHashes) }

        // Structural signature: canonical serialization of sorted child (name, sig) pairs, hashed
        // to keep it bounded. nil if any descendant's identity is unknown (an unhashed file, or a
        // directory whose children weren't walked) — then we can't assert this tree is identical.
        var signature: String? = nil
        if node.isUnexplored != true {
            let parts = childInfos.map { ci -> String? in ci.signature.map { "\(ci.name)\u{0}\($0)" } }
            if !parts.contains(where: { $0 == nil }) {
                let joined = parts.compactMap { $0 }.sorted().joined(separator: "\u{1}")
                signature = stableHash("D:" + joined)
            }
        }

        let info = NodeInfo(
            path: node.id,
            name: node.name,
            isDirectory: true,
            size: size,
            itemCount: itemCount,
            modificationDate: node.modificationDate,
            depth: depth,
            signature: signature,
            contentHashes: contentHashes
        )
        dirs.append(info)
        return info
    }

    // MARK: Identical folders

    private static func identicalFolderGroups(
        _ dirs: [NodeInfo],
        options: DuplicateFinderOptions,
        coveredRoots: inout Set<String>,
        keeperRoots: inout Set<String>
    ) -> [DuplicateGroup] {
        var buckets: [String: [NodeInfo]] = [:]
        for d in dirs {
            guard let sig = d.signature, !d.contentHashes.isEmpty else { continue }
            buckets[sig, default: []].append(d)
        }

        // Emit shallower/larger folders first so an outer identical pair claims its subtree before
        // any inner pair is considered.
        let candidates = buckets.values
            .filter { $0.count >= 2 }
            .sorted { a, b in
                let ad = a.first?.depth ?? 0, bd = b.first?.depth ?? 0
                if ad != bd { return ad < bd }                       // shallower first
                return (a.first?.size ?? 0) > (b.first?.size ?? 0)   // larger first
            }

        var groups: [DuplicateGroup] = []
        for var members in candidates {
            members = members.filter { !isCovered($0.path, by: coveredRoots) }
            guard members.count >= 2 else { continue }

            let keeperIdx = chooseKeeper(members)
            let ordered = orderKeeperFirst(members, keeperIndex: keeperIdx)
            let keeper = ordered[0]
            let copies = ordered.enumerated().map { idx, info in
                makeCopy(info, keeper: keeper, isKeeper: idx == 0)
            }
            let reclaimable = copies.dropFirst().reduce(0) { $0 + $1.size }
            groups.append(DuplicateGroup(
                matchType: .identical,
                name: keeper.name,
                isDirectory: true,
                copies: copies,
                reclaimableBytes: reclaimable
            ))
            for c in copies.dropFirst() { coveredRoots.insert(c.path) }
            // Recorded separately from `coveredRoots`: covering the keeper would also hide inner
            // folder pairs from the passes below, which is a wider change than this invariant
            // needs. The file passes consult it to keep their hands off the kept folder.
            keeperRoots.insert(keeper.path)
        }
        return groups
    }

    // MARK: Overlapping / name-only folders

    private static func overlappingAndNameOnlyGroups(
        _ dirs: [NodeInfo],
        options: DuplicateFinderOptions,
        coveredRoots: inout Set<String>
    ) -> [DuplicateGroup] {
        // Candidates: non-covered folders with known content, bucketed by name.
        var byName: [String: [NodeInfo]] = [:]
        for d in dirs {
            guard !d.contentHashes.isEmpty, !isCovered(d.path, by: coveredRoots) else { continue }
            byName[d.name, default: []].append(d)
        }

        var groups: [DuplicateGroup] = []
        for (name, allMembers) in byName {
            // A folder nested inside another same-named folder is already *part of* that folder's
            // content, not a separate copy. Grouping the pair would let a merge copy files into
            // the keeper and then trash a piece of it (the nested copy) — data loss. Keep only the
            // outermost members.
            let members = outermost(allMembers)
            guard members.count >= 2 else { continue }
            // Drop groups that are actually identical (already handled): keep only those with at
            // least two distinct signatures.
            let distinctSignatures = Set(members.map { $0.signature ?? UUID().uuidString })
            guard distinctSignatures.count >= 2 else { continue }

            let keeperIdx = chooseKeeper(members)
            let ordered = orderKeeperFirst(members, keeperIndex: keeperIdx)
            let keeper = ordered[0]

            // Average shared-content fraction of the redundant copies against the keeper.
            let fractions = ordered.dropFirst().map { sharedFraction(of: $0, against: keeper) }
            let avgShared = fractions.isEmpty ? 0 : fractions.reduce(0, +) / Double(fractions.count)

            let copies = ordered.enumerated().map { idx, info in
                makeCopy(info, keeper: keeper, isKeeper: idx == 0)
            }

            if avgShared >= options.overlapThreshold {
                // Reclaimable ≈ the shared (redundant) bytes of each folded-in copy.
                let reclaimable = zip(ordered.dropFirst(), fractions)
                    .reduce(0) { $0 + Int(Double($1.0.size) * $1.1) }
                groups.append(DuplicateGroup(
                    matchType: .overlapping(sharedFraction: avgShared),
                    name: name,
                    isDirectory: true,
                    copies: copies,
                    reclaimableBytes: reclaimable
                ))
                // Resolve overlaps at the folder level — don't also re-report their shared inner
                // files as standalone identical-file duplicates.
                for c in copies { coveredRoots.insert(c.path) }
            } else {
                groups.append(DuplicateGroup(
                    matchType: .nameOnly,
                    name: name,
                    isDirectory: true,
                    copies: copies,
                    reclaimableBytes: 0
                ))
            }
        }
        return groups
    }

    // MARK: Identical files

    private static func identicalFileGroups(
        _ files: [NodeInfo],
        options: DuplicateFinderOptions,
        coveredRoots: Set<String>,
        keeperRoots: Set<String>,
        groupedFilePaths: inout Set<String>,
        keepers: inout Set<String>
    ) -> [DuplicateGroup] {
        var buckets: [String: [NodeInfo]] = [:]
        for f in files {
            guard let hash = f.signature, f.size >= options.minFileSize else { continue }
            guard !isCovered(f.path, by: coveredRoots) else { continue }
            buckets[hash, default: []].append(f)
        }

        var groups: [DuplicateGroup] = []
        for members in buckets.values where members.count >= 2 {
            guard let ordered = protectingFolderKeepers(members, keeperRoots: keeperRoots, chooseKeeperIn: chooseKeeper,
                                                        keeperMayBePickedFromProtected: true) else { continue }
            let keeper = ordered[0]
            let copies = ordered.enumerated().map { idx, info in
                makeCopy(info, keeper: keeper, isKeeper: idx == 0, protectedRoots: keeperRoots)
            }
            let reclaimable = copies.dropFirst().reduce(0) { $0 + $1.size }
            groups.append(DuplicateGroup(
                matchType: .identical,
                name: keeper.name,
                isDirectory: false,
                copies: copies,
                reclaimableBytes: reclaimable
            ))
            // EVERY member of the bucket is marked grouped, not just the copies that survived
            // protection: a protected file dropped from this group is still accounted for by it,
            // and leaving it unmarked let it reappear in a versions group the identical pass had
            // always suppressed.
            for m in members { groupedFilePaths.insert(m.path) }
            keepers.insert(keeper.path)
        }
        return groups
    }

    // MARK: Same text, different bytes

    /// Documents whose ``ContentFingerprint`` digest matches although their bytes do not — the
    /// re-stamped download, the compressed re-save, the same statement filed under two names.
    ///
    /// **The pass only ever adds information the byte hash did not have**, and it gets that from
    /// `groupedFilePaths` rather than from a guard of its own. A first draft carried an explicit
    /// "at least two distinct content signatures" check, and mutation testing could not kill it:
    /// it is unreachable by construction. `identicalFileGroups` buckets by content hash under the
    /// same size floor and the same `coveredRoots`, so any two members here that share a KNOWN
    /// hash were already grouped and marked — leaving at most that group's keeper behind — while
    /// members with no hash are distinct by definition. An inert guard reads as a safety net that
    /// is holding something; this comment is what it was actually worth.
    ///
    /// **It reaches back for an identical group's keeper, and only as an anchor.** Measured on the
    /// real tree, 14 of the 253 groups this finds contain a byte-identical sub-pair — one document
    /// downloaded twice *and* copied once — and in every one of those 14 the remaining members are
    /// a single file. Excluding everything the identical pass touched would therefore not weaken
    /// those 14 groups, it would delete them. So an identical group's keeper may anchor a group
    /// here (it is the copy that pass promised to keep), while never being offered for removal by
    /// it: two groups, disjoint removal sets, no way for one batch to undo the other's promise.
    private static func sameTextFileGroups(
        _ files: [NodeInfo],
        fingerprints: [String: String],
        options: DuplicateFinderOptions,
        coveredRoots: Set<String>,
        folderKeeperRoots: Set<String>,
        identicalKeepers: Set<String>,
        groupedFilePaths: inout Set<String>
    ) -> [DuplicateGroup] {
        var buckets: [String: [NodeInfo]] = [:]
        for f in files {
            guard f.size >= options.minFileSize else { continue }
            guard !isCovered(f.path, by: coveredRoots) else { continue }
            guard !groupedFilePaths.contains(f.path) || identicalKeepers.contains(f.path) else { continue }
            guard let digest = fingerprints[f.path] else { continue }
            buckets[digest, default: []].append(f)
        }

        var groups: [DuplicateGroup] = []
        // Sorted by digest so the emitted order does not ride on dictionary iteration. It is
        // observable only where the final sort ties (two groups with equal reclaimable bytes and
        // equal names) and only ACROSS launches, because Swift seeds its hasher per process — so
        // no single-process test can kill this line, and none pretends to.
        for digest in buckets.keys.sorted() {
            let members = buckets[digest]!
            guard members.count >= 2 else { continue }
            let protectedPaths = Set(members.map { $0.path }.filter {
                identicalKeepers.contains($0) || isCovered($0, by: folderKeeperRoots)
            })
            // Keeper: preferred from the protected subset when there is one. Same argument as
            // `protectingFolderKeepers` makes for identical files — the keeper choice is a location
            // heuristic carrying no promise, and the user can re-aim it — so anchoring on the copy
            // another group already promised to keep costs nothing and keeps this group actionable.
            let pool = protectedPaths.isEmpty ? members : members.filter { protectedPaths.contains($0.path) }
            let keeper = pool[chooseKeeper(pool)]
            // A SECOND protected member leaves the group rather than appearing in it: it can be
            // neither the keeper (taken) nor removable, so it has nowhere safe to sit — the same
            // call `protectingFolderKeepers` makes, for the same reason. It stays marked as grouped
            // below, so nothing downstream picks it up again.
            let removable = members.filter { $0.path != keeper.path && !protectedPaths.contains($0.path) }
            guard !removable.isEmpty else { continue }

            let ordered = [keeper] + removable.sorted { ($0.depth, $0.path) < ($1.depth, $1.path) }
            let copies = ordered.enumerated().map { idx, info in
                makeCopy(info, keeper: keeper, isKeeper: idx == 0, protectedPaths: protectedPaths)
            }
            groups.append(DuplicateGroup(
                matchType: .sameText,
                name: keeper.name,
                isDirectory: false,
                copies: copies,
                reclaimableBytes: copies.dropFirst().reduce(0) { $0 + $1.size }
            ))
            // Every member, protected ones included — the rule the two passes above follow, so a
            // file this group accounted for can never be picked up again by versions.
            for m in members { groupedFilePaths.insert(m.path) }
        }
        return groups
    }

    // MARK: Versions

    private static func versionGroups(
        _ files: [NodeInfo],
        options: DuplicateFinderOptions,
        coveredRoots: Set<String>,
        keeperRoots: Set<String>,
        groupedFilePaths: inout Set<String>
    ) -> [DuplicateGroup] {
        var buckets: [String: [NodeInfo]] = [:]
        for f in files {
            guard f.size >= options.minFileSize else { continue }
            guard !isCovered(f.path, by: coveredRoots), !groupedFilePaths.contains(f.path) else { continue }
            guard let (stem, ext) = versionStem(f.name) else { continue }
            guard !DuplicateFinderOptions.genericVersionStems.contains(stem) else { continue }
            buckets["\(stem)\u{0}\(ext)", default: []].append(f)
        }

        var groups: [DuplicateGroup] = []
        for bucket in buckets.values where bucket.count >= 2 {
            // A shared stem alone is weak evidence: unrelated same-named files routinely live in
            // different folders (/2019/IMG_0001.jpg vs /2023/IMG_0001.jpg, ClientA/invoice.pdf vs
            // ClientB/invoice.pdf) and must NOT form a "versions" group — its recommendation would
            // trash a unique file. Require a real version signal: at least one member whose name
            // carried a stripped marker (" (1)", "copy", "-v2", "final", …), or every member in the
            // SAME folder (same-stem siblings that differ only by case/whitespace normalization).
            //
            // A marker vouches ONLY for its own name and for the members sharing its parent
            // directory — "IMG_0001 copy.jpg" is evidence someone duplicated the IMG_0001.jpg
            // NEXT TO IT, not that a same-stem file in a different folder is a version of either.
            // Licensing the whole cross-folder stem bucket off one marker would group
            // /2023/IMG_0001.jpg + "/2023/IMG_0001 copy.jpg" + /2019/IMG_0001.jpg and recommend
            // trashing the unrelated 2019 photo. So cross-folder members join only on their OWN
            // marker (or by sharing a marker-bearer's parent); the rest of the bucket is dropped.
            //
            // And a parent's vouching stops at ONE duplication site: markers in more than one
            // folder are independent events (ClientA duplicated its report; ClientB its own),
            // not one document's history. Pooling every marker folder's plain siblings made the
            // newest file anywhere the keeper and recommended trashing another folder's unmarked
            // original. With multiple marker parents, each marker folder that has same-stem
            // company forms its OWN group (round-5 same-parent semantics, per folder) — pairing
            // every copy with ITS original, never another folder's. Only LONE bearers (no
            // same-stem sibling beside them) still pool cross-folder: their marker names carry
            // their own evidence (the save-as-into-Downloads case), and unmarked files never
            // ride along with that pool.
            let sameParent = Set(bucket.map { ($0.path as NSString).deletingLastPathComponent }).count == 1
            let memberClusters: [[NodeInfo]]
            if sameParent {
                memberClusters = [bucket]   // same-stem siblings: the round-4 same-parent path, unchanged
            } else {
                let markerBearers = bucket.filter { hasVersionMarker($0.name) }
                let markerParents = Set(markerBearers.map { ($0.path as NSString).deletingLastPathComponent })
                guard !markerParents.isEmpty else { continue }
                if markerParents.count == 1 {
                    memberClusters = [bucket.filter {
                        hasVersionMarker($0.name)
                            || markerParents.contains(($0.path as NSString).deletingLastPathComponent)
                    }]
                } else {
                    var clusters: [[NodeInfo]] = []
                    var loneBearerPool: [NodeInfo] = []
                    // Grouped ONCE. This filtered the whole bucket per parent and recomputed
                    // `deletingLastPathComponent` inside the closure every time — n×m string work
                    // where one pass suffices, on a loop that runs per name-bucket.
                    let byParent = Dictionary(grouping: bucket) {
                        ($0.path as NSString).deletingLastPathComponent
                    }
                    for parent in markerParents.sorted() {
                        let inParent = byParent[parent] ?? []
                        // A cluster that cannot PROVE drift (fewer than two real hashes — its
                        // companions are too large or cloud-only to hash) will die at the guard
                        // below; its bearers then fall through to the cross-folder pool instead
                        // of silently vanishing — a marked name still carries its own evidence,
                        // and a lone bearer elsewhere may prove the drift the home folder
                        // couldn't. Unmarked companions never follow them into the pool.
                        let provableDrift = Set(inParent.compactMap { $0.signature }
                            .filter { !isUnknownSignature($0) }).count >= 2
                        if inParent.count >= 2 && provableDrift {
                            clusters.append(inParent)
                        } else {
                            loneBearerPool.append(contentsOf: inParent.filter { hasVersionMarker($0.name) })
                        }
                    }
                    if loneBearerPool.count >= 2 { clusters.append(loneBearerPool) }
                    memberClusters = clusters
                }
            }
            for members in memberClusters {
                guard members.count >= 2 else { continue }
                // Only PROVEN drift: at least two distinct REAL contents (identical bytes were
                // already grouped). Placeholder ("u:" unknown) and missing signatures are not
                // evidence of difference — two byte-identical files that were merely too large
                // (or cloud-only) to hash must not be claimed as drifted versions. Unknown-hash
                // members may ride along in a group that real hashes justify, but can never
                // stand one up by themselves.
                // Files inside a kept folder can anchor a version group but are never offered for
                // removal by it (see `protectingFolderKeepers`) — applied before the drift check
                // below so the evidence is read off the members that actually remain.
                guard let ordered = protectingFolderKeepers(members, keeperRoots: keeperRoots, chooseKeeperIn: newestIndex,
                                                            keeperMayBePickedFromProtected: false) else { continue }
                let realHashes = Set(ordered.compactMap { $0.signature }.filter { !isUnknownSignature($0) })
                guard realHashes.count >= 2 else { continue }

                let keeper = ordered[0]
                let copies = ordered.enumerated().map { idx, info in
                    makeCopy(info, keeper: keeper, isKeeper: idx == 0, protectedRoots: keeperRoots)
                }
                let reclaimable = copies.dropFirst().reduce(0) { $0 + $1.size }
                let (stem, ext) = versionStem(keeper.name) ?? (keeper.name, "")
                groups.append(DuplicateGroup(
                    matchType: .versions,
                    name: ext.isEmpty ? stem : "\(stem).\(ext)",
                    isDirectory: false,
                    copies: copies,
                    reclaimableBytes: reclaimable
                ))
                // Every member, not just the copies that survived protection — the same rule the
                // identical pass follows. A protected file dropped from this group is still
                // accounted for by it, and nothing downstream should be able to pick it up again.
                for m in members { groupedFilePaths.insert(m.path) }
            }
        }
        return groups
    }

    // MARK: Folder-keeper protection

    /// A file group's members reordered so that anything living inside an identical-folder group's
    /// KEEPER is the group's own keeper — never one of the copies it recommends removing. Returns
    /// nil when fewer than two members survive, i.e. there is no group left to report.
    ///
    /// A folder group tells the user "F1 is kept, F2 is redundant", and one "Apply recommended"
    /// acts on every group at once. Nothing stopped a file group from independently recommending
    /// `F1/a.txt` — content of the folder being kept — because `coveredRoots` only ever received
    /// the REDUNDANT copies. A single batch would then trash F2 *and* hollow out F1, so the folder
    /// the app had just called an intact copy no longer matched the one the user verified. The
    /// mirror direction (a keeper inside a redundant copy) was already guarded; this is the same
    /// invariant approached from the other side.
    ///
    /// Protected files still ANCHOR groups — that is how a third copy elsewhere stays discoverable
    /// and removable — but only as the keeper. A second protected member has nowhere safe to sit,
    /// so it leaves the group instead of becoming a removal recommendation.
    private static func protectingFolderKeepers(
        _ members: [NodeInfo],
        keeperRoots: Set<String>,
        chooseKeeperIn: ([NodeInfo]) -> Int,
        keeperMayBePickedFromProtected: Bool
    ) -> [NodeInfo]? {
        guard members.count >= 2 else { return nil }
        guard !keeperRoots.isEmpty else {
            // The overwhelmingly common case (no identical-folder groups at all): the group is
            // exactly what it always was.
            return orderKeeperFirst(members, keeperIndex: chooseKeeperIn(members))
        }
        let protected = members.filter { isCovered($0.path, by: keeperRoots) }
        guard !protected.isEmpty else {
            return orderKeeperFirst(members, keeperIndex: chooseKeeperIn(members))
        }
        // WHICH file anchors the group depends on what the pass's keeper choice MEANS.
        //
        // For identical copies it is a location heuristic ("least archive-like"), with no promise
        // attached and a user-facing control to change it — so preferring a protected file is free,
        // and it is what keeps a third copy elsewhere both visible and removable.
        //
        // For versions the keeper is the NEWEST, and the card says so in as many words ("Keep
        // newest, Trash older"). Choosing the newest of the protected SUBSET quietly makes that
        // false — it can be years older than the newest member — so the keeper stays whatever the
        // pass picked over all members, and protection only removes the protected files from the
        // removable side.
        let keeper = keeperMayBePickedFromProtected
            ? protected[chooseKeeperIn(protected)]
            : members[chooseKeeperIn(members)]
        let removable = members.filter { $0.path != keeper.path && !isCovered($0.path, by: keeperRoots) }
        guard !removable.isEmpty else { return nil }
        // Keeper first, then the pass's usual (depth, path) ordering for the rest — the ordering
        // `DuplicateGroup.copies` documents.
        return [keeper] + removable.sorted { ($0.depth, $0.path) < ($1.depth, $1.path) }
    }

    // MARK: Recommendation

    /// Picks the keeper: least "archive-like" location, then most-complete content, then
    /// shallowest path, then most recently modified, then lexicographically first path (stable).
    static func chooseKeeper(_ infos: [NodeInfo]) -> Int {
        var best = 0
        for i in 1..<infos.count {
            if preferAsKeeper(infos[i], over: infos[best]) { best = i }
        }
        return best
    }

    private static func preferAsKeeper(_ a: NodeInfo, over b: NodeInfo) -> Bool {
        let pa = archivePenalty(a.path), pb = archivePenalty(b.path)
        if pa != pb { return pa < pb }
        if a.contentHashes.count != b.contentHashes.count { return a.contentHashes.count > b.contentHashes.count }
        if a.depth != b.depth { return a.depth < b.depth }
        let da = a.modificationDate ?? .distantPast, db = b.modificationDate ?? .distantPast
        if da != db { return da > db }
        return a.path.localizedStandardCompare(b.path) == .orderedAscending
    }

    private static let archiveSegments: Set<String> = [
        "archive", "archives", "old", "backup", "backups", "tmp", "temp",
        "trash", ".trash", "downloads", "cache", "caches"
    ]

    private static func archivePenalty(_ path: String) -> Int {
        let segs = path.split(separator: "/").map { $0.lowercased() }
        return segs.reduce(0) { $0 + (archiveSegments.contains($1) ? 1 : 0) }
    }

    /// The location penalty for a VERSIONS keeper. Unlike ``archiveSegments`` (used for
    /// identical groups, where every copy holds the same bytes and the penalty only picks the
    /// canonical HOME), this list holds only true archive/backup/trash segments. Versions
    /// groups' copies hold DIFFERENT bytes and the recommendation trashes the non-keepers — a
    /// just-downloaded newest revision legitimately sits in Downloads (or tmp/cache), and
    /// penalizing those transient locations recommended keeping the STALE Documents copy and
    /// trashing the only copy of the new content. Archive/backup stay penalized: there a
    /// backup tool's mtime rewrite really does crown the wrong copy.
    private static let versionsStaleLocationSegments: Set<String> = [
        "archive", "archives", "old", "backup", "backups", "trash", ".trash"
    ]

    private static func versionsStaleLocationPenalty(_ path: String) -> Int {
        let segs = path.split(separator: "/").map { $0.lowercased() }
        return segs.reduce(0) { $0 + (versionsStaleLocationSegments.contains($1) ? 1 : 0) }
    }

    /// Picks the versions keeper: least "stale" location first (archive/backup/trash only — a
    /// backup copy must not be recommended as the one to keep even when its mtime is newest,
    /// e.g. because a backup tool rewrote it; but a Downloads/tmp copy may well BE the newest
    /// revision), then the most recently modified, then the shallowest path.
    /// Internal (not private) so tests can pin the keeper choice directly.
    static func newestIndex(_ infos: [NodeInfo]) -> Int {
        var best = 0
        for i in 1..<infos.count {
            let pi = versionsStaleLocationPenalty(infos[i].path)
            let pb = versionsStaleLocationPenalty(infos[best].path)
            if pi != pb {
                if pi < pb { best = i }
                continue
            }
            let di = infos[i].modificationDate ?? .distantPast
            let db = infos[best].modificationDate ?? .distantPast
            if di > db || (di == db && infos[i].depth < infos[best].depth) { best = i }
        }
        return best
    }

    // MARK: Helpers

    /// - Parameters:
    ///   - protectedRoots: DIRECTORIES whose contents may not be removed (an identical-folder
    ///     group's keeper). Tested by containment.
    ///   - protectedPaths: EXACT paths that may not be removed (an identical-file group's keeper).
    ///     A separate parameter because `isInsideDirectory` matches proper ancestors only, so a
    ///     file path handed to `protectedRoots` would protect nothing — silently.
    private static func makeCopy(_ info: NodeInfo, keeper: NodeInfo, isKeeper: Bool,
                                 protectedRoots: Set<String> = [],
                                 protectedPaths: Set<String> = []) -> DuplicateCopy {
        let unique = isKeeper ? 0 : info.contentHashes.subtracting(keeper.contentHashes).count
        // Unverified content: a file whose hash is missing or an unknown-content placeholder, or
        // a folder without a full structural signature (some descendant wasn't walked) or with an
        // unknown-content descendant (placeholders make the signature computable and unique, but
        // the folder's contents still weren't fully verified).
        let unverified: Bool
        if info.isDirectory {
            unverified = info.signature == nil || info.contentHashes.contains(where: isUnknownSignature)
        } else {
            unverified = info.signature.map(isUnknownSignature) ?? true
        }
        return DuplicateCopy(
            id: info.path,
            name: info.name,
            isDirectory: info.isDirectory,
            size: info.size,
            itemCount: info.isDirectory ? info.itemCount : 1,
            modificationDate: info.modificationDate,
            uniqueItemCount: unique,
            depth: info.depth,
            isRecommendedKeeper: isKeeper,
            contentUnverified: unverified,
            isProtectedFromRemoval: isCovered(info.path, by: protectedRoots)
                || protectedPaths.contains(info.path)
        )
    }

    private static func orderKeeperFirst(_ infos: [NodeInfo], keeperIndex: Int) -> [NodeInfo] {
        var rest = infos
        let keeper = rest.remove(at: keeperIndex)
        rest.sort { ($0.depth, $0.path) < ($1.depth, $1.path) }
        return [keeper] + rest
    }

    private static func sharedFraction(of copy: NodeInfo, against keeper: NodeInfo) -> Double {
        guard !copy.contentHashes.isEmpty else { return 0 }
        let shared = copy.contentHashes.intersection(keeper.contentHashes).count
        return Double(shared) / Double(copy.contentHashes.count)
    }

    private static func isCovered(_ path: String, by roots: Set<String>) -> Bool {
        path.isInsideDirectory(anyOf: roots)
    }

    /// Keeps only the members not nested inside another member (drops ancestor/descendant dupes).
    private static func outermost(_ infos: [NodeInfo]) -> [NodeInfo] {
        // **`paths` alone, not `paths.subtracting([$0.path])`.** Rebuilding the whole Set once per
        // member is O(n²) copying plus n allocations, and it bought nothing: `isInsideDirectory`
        // only matches at a "/" boundary, so a path can never be INSIDE itself. Called per
        // name-bucket, and a common folder name (`img`, `assets`, `.git`) buckets large.
        let paths = Set(infos.map { $0.path })
        return infos.filter { !$0.path.isInsideDirectory(anyOf: paths) }
    }

    static func stableHash(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The trailing copy/version markers, compiled ONCE.
    ///
    /// `range(of:options:.regularExpression)` compiles its pattern on every call, and this ran four
    /// of them inside a `while changed` loop — then `hasVersionMarker` called the whole thing again
    /// from scratch. Measured over 20,000 names: **11.4 µs each as written against 4.0 µs
    /// pre-compiled, 2.9x.** Called for every file above the size floor, then three more times per
    /// bucket.
    ///
    /// `try!` because these are four literals in this file: a failure here is a typo in the line
    /// above it, not a runtime condition, and the alternative is an optional that every caller
    /// would have to pretend could be nil.
    private static let versionMarkerPatterns: [NSRegularExpression] = [
        #"\s*\(\d+\)$"#,            // " (1)"
        #"[ _-]copy(\s*\d+)?$"#,    // " copy", "-copy 2"
        #"[ _-]v\d+$"#,             // "-v2", "_v3"
        #"[ _-](final|draft|latest|new|old|revised|edit|edited)$"#
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// Reduces a filename to its version stem + extension, stripping trailing copy/version markers.
    /// Returns nil for an empty stem. Case-normalized for grouping.
    static func versionStem(_ name: String) -> (stem: String, ext: String)? {
        let ns = name as NSString
        let ext = ns.pathExtension.lowercased()
        var stem = (ns.deletingPathExtension as String).lowercased()

        var changed = true
        while changed {
            changed = false
            for r in versionMarkerPatterns {
                let range = NSRange(stem.startIndex..., in: stem)
                if let match = r.firstMatch(in: stem, options: [], range: range),
                   let found = Range(match.range, in: stem) {
                    stem.removeSubrange(found)
                    changed = true
                }
            }
        }
        stem = stem.trimmingCharacters(in: .whitespaces)
        guard !stem.isEmpty else { return nil }
        return (stem, ext)
    }

    /// True when ``versionStem(_:)`` actually stripped a version/copy marker from the name — i.e.
    /// the name itself carries evidence of being a version ("report copy.pdf", "deck-final.key"),
    /// as opposed to merely sharing a stem with another file. Case/whitespace normalization alone
    /// does not count as a marker.
    static func hasVersionMarker(_ name: String) -> Bool {
        guard let (stem, _) = versionStem(name) else { return false }
        let plain = ((name as NSString).deletingPathExtension as String)
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
        return stem != plain
    }
}
