import Foundation
import CryptoKit

// MARK: - Result model

/// How the copies in a duplicate group are related, and so how to resolve them: identical copies
/// collapse to one, overlapping folders want an additive merge, versions want "keep the newest".
/// The UI glyph encodes it by shape, so it reads without color.
public enum DuplicateMatchType: Sendable, Equatable, Hashable {
    /// Byte-for-byte identical content (files) or identical recursive trees (folders).
    case identical
    /// Folders that share most of their content but each holds some unique items.
    /// `sharedFraction` is the average shared-content ratio across the redundant copies (0...1).
    case overlapping(sharedFraction: Double)
    /// File names that reduce to one stem (`Report`, `Report (1)`, `Report-final`) but drifted.
    case versions
    /// Documents whose text is identical although their bytes are not, such as one document
    /// downloaded twice from a provider that re-stamps each copy. See ``ContentFingerprint``.
    ///
    /// Weaker than `identical`: matching text can still be a signed copy beside the unsigned one, a
    /// redacted copy beside the full one, or a purely visual edit. So it is never in the "Apply
    /// recommended" batch; the user resolves each group by hand.
    case sameText

    /// A stable key for filtering/sorting that ignores the associated value.
    public var kind: Kind {
        switch self {
        case .identical: return .identical
        case .overlapping: return .overlapping
        case .versions: return .versions
        case .sameText: return .sameText
        }
    }

    public enum Kind: String, Sendable, CaseIterable, Hashable {
        case identical, overlapping, versions, sameText
    }
}

/// What the duplicate scan measured about one folder copy's contents, per entry: the baseline a
/// destructive action re-walks against before trashing that copy (or trusting it as the keeper).
///
/// Per entry, not an aggregate count and size: an aggregate can't see a same-length rewrite, and
/// any convention mismatch with the re-walk (`.DS_Store`, a link's own bytes) would refuse every
/// folder or mask a real loss. Size and mtime per relative path, as `MergeFileSnapshot` gives the
/// merge path's trash step. It carries its own `ignoredNames` so the re-walk skips exactly what the
/// scan skipped.
public struct FolderContentSnapshot: Sendable, Equatable, Hashable {
    /// One directory entry as the scan's walk saw it.
    public enum Entry: Sendable, Equatable, Hashable {
        /// A regular file: byte size and modification date from the walk. Either changing, or the
        /// entry changing kind, is drift. Same blind spots as the file-level check
        /// (`copyDriftedInPlace`): a same-length rewrite within the volume's mtime granularity
        /// (1–2 s on FAT and some SMB), one by an mtime-preserving writer (`touch -r`,
        /// `rsync --times`), and xattr or tag edits, which move only ctime.
        case file(size: Int, modificationDate: Date?)
        /// A symbolic link, with the size and mtime the walk resolved from its target. A retarget
        /// is caught only if those readings move; the target path isn't recorded. An untouched link
        /// always compares equal, since both walks resolve it the same way.
        case symlink(size: Int, modificationDate: Date?)
        /// A subdirectory: presence only. Its contents are entries of their own, and its stat
        /// would only re-detect their changes or refuse on metadata they don't cover.
        case directory
    }

    /// Relative path under the folder copy's root → what the scan saw there.
    ///
    /// Keys compare by canonical equivalence, so NFC/NFD sibling names (possible on SMB/NFS
    /// mounts) collapse to one key, last-wins. Both walks collapse identically, so the comparison
    /// stays consistent, but a change to the collapsed-away sibling is invisible to the drift gate.
    /// Fixing that would mean abandoning `String` keys for a case only such mounts produce.
    public let entries: [String: Entry]
    /// The names the scan's traversal skipped (subtrees included); a re-walk must skip the same.
    public let ignoredNames: Set<String>

    public init(entries: [String: Entry], ignoredNames: Set<String>) {
        self.entries = entries
        self.ignoredNames = ignoredNames
    }

    /// Builds a snapshot from an already-walked tree with ``DuplicateFinder``'s conventions:
    /// ignored names skipped with their subtrees, symlinks recorded but never descended (even
    /// directory links), and the walk's own sizes and mtimes.
    ///
    /// nil when any subtree was not fully walked (`isUnexplored`): a partial walk is no baseline,
    /// and a nil snapshot refuses the destructive action. That refusal says "couldn't be fully
    /// checked", not "changed", since a rescan would reproduce it.
    public init?(walkedChildren: [FileNode], ignoredNames: Set<String>) {
        var out: [String: Entry] = [:]
        guard Self.collect(walkedChildren, prefix: "", ignoredNames: ignoredNames, into: &out) else { return nil }
        self.entries = out
        self.ignoredNames = ignoredNames
    }

    private static func collect(_ nodes: [FileNode], prefix: String,
                                ignoredNames: Set<String>, into out: inout [String: Entry]) -> Bool {
        for n in nodes {
            if ignoredNames.contains(n.name) { continue }
            let rel = prefix.isEmpty ? n.name : prefix + "/" + n.name
            if n.isSymbolicLink == true {
                out[rel] = .symlink(size: n.fileSize ?? 0, modificationDate: n.modificationDate)
                continue
            }
            // A folder reached twice under one root is recorded like a link and not descended: its
            // contents belong to the shorter route.
            if n.isCoveredElsewhere == true {
                out[rel] = .symlink(size: n.fileSize ?? 0, modificationDate: n.modificationDate)
                continue
            }
            if n.isDirectory {
                guard n.isUnexplored != true else { return false }
                out[rel] = .directory
                guard collect(n.children ?? [], prefix: rel, ignoredNames: ignoredNames, into: &out) else { return false }
            } else {
                out[rel] = .file(size: n.fileSize ?? 0, modificationDate: n.modificationDate)
            }
        }
        return true
    }
}

/// One copy within a duplicate group.
public struct DuplicateCopy: Identifiable, Sendable, Equatable, Hashable {
    /// Absolute filesystem path: the copy's identity.
    public let id: String
    public var path: String { id }
    public let name: String
    public let isDirectory: Bool
    /// Total bytes (recursive for folders).
    public let size: Int
    /// Recursive count of enclosed items for folders; 1 for a file.
    public let itemCount: Int
    public let modificationDate: Date?
    /// Number of content items in this copy that are not in the group's keeper. 0 for a fully
    /// redundant copy; > 0 for an overlapping copy that would need a merge.
    public let uniqueItemCount: Int
    /// Depth of the path below the scan root (fewer = closer to root = more canonical).
    public let depth: Int
    /// Whether this is the recommended copy to keep.
    public let isRecommendedKeeper: Bool
    /// True when the scan couldn't content-verify this copy: its hash (or a descendant's) was
    /// skipped as cloud-only or unreadable, so the UI can say the group's claim is not fully
    /// verified.
    public let contentUnverified: Bool

    /// True when this copy lives inside a folder another group is keeping, so no recommendation may
    /// offer to remove it, even after the user picks a different keeper (`choosingKeeper`
    /// relabels by id alone and would put it back on the removal list).
    public let isProtectedFromRemoval: Bool

    /// The scan's per-entry baseline for a folder copy (nil for files and hand-built copies).
    /// Every destructive path re-walks against it before trashing, and nil refuses: without a
    /// baseline the folder can't be shown to still be what was grouped. Session-only, never saved.
    public let contentSnapshot: FolderContentSnapshot?

    /// A non-keeper copy that holds nothing the keeper lacks: safe to remove outright.
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
        isProtectedFromRemoval: Bool = false,
        contentSnapshot: FolderContentSnapshot? = nil
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
        self.contentSnapshot = contentSnapshot
    }
}

/// A cluster of duplicate/related items surfaced by ``DuplicateFinder``.
public struct DuplicateGroup: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let matchType: DuplicateMatchType
    /// The common display name (e.g. "Folder 1"). For versions it's the shared stem.
    public let name: String
    public let isDirectory: Bool
    /// The copies as the finder built them: keeper first, then by ascending depth and path.
    ///
    /// **That order doesn't survive a keeper re-pick**, which leaves the array as it was. Find the
    /// keeper by `isRecommendedKeeper`, as `keeper`, `redundantCopies` and
    /// `recommendedRemovalPaths` do, never by `copies[0]`.
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

    /// A stable identity for this cluster across scans (the sorted copy paths), so a "Keep
    /// separate" choice persists and the group isn't re-flagged next scan.
    public var ignoreKey: String {
        copies.map { $0.id }.sorted().joined(separator: "\n")
    }

    /// The recommended copy to keep.
    ///
    /// The `??` covers a broken invariant only: every production route keeps exactly one copy
    /// flagged, but `init` is public and takes any array. `copies[0]` still traps on an empty
    /// group, which no finder builds; a group with no copies is not a group.
    public var keeper: DuplicateCopy {
        copies.first(where: { $0.isRecommendedKeeper }) ?? copies[0]
    }

    /// The copies the recommendation would remove or merge away.
    ///
    /// **Excludes whatever ``keeper`` names, and every flagged copy.** This list drives "Move to
    /// Trash", so it must never include the copy meant to survive, even with no copy flagged or
    /// two. Both conditions together can only remove fewer copies, the right direction for a trash.
    public var redundantCopies: [DuplicateCopy] {
        // Not via `keeper`, so an empty group stays empty instead of trapping. The id test also
        // covers two copies at one path, one flagged and one not, which a folder linked in from
        // outside can produce (`~/Documents` twice in a `~` scan).
        let keeperID = copies.first(where: { $0.isRecommendedKeeper })?.id ?? copies.first?.id
        // Both conditions: the id test alone would make a second flagged copy redundant.
        return copies.filter { !$0.isRecommendedKeeper && $0.id != keeperID }
    }

    /// True when the recommendation removes copies without any merge: the per-group one-click
    /// case (identical dedup, or keep-newest for versions).
    public var isFullyResolvableByRemoval: Bool {
        switch matchType {
        case .identical, .versions, .sameText: return true
        case .overlapping: return false
        }
    }

    /// True when this group is safe for the blind "Apply recommended" batch. Only byte-identical
    /// duplicates qualify: versions discard different older content on a heuristic match, and
    /// `sameText` proves only that two documents read the same.
    public var isRecommendedForBatch: Bool {
        if case .identical = matchType { return true }
        return false
    }

    /// Absolute paths the recommended removal would trash (fully-redundant / older copies).
    public var recommendedRemovalPaths: [String] {
        switch matchType {
        case .identical, .versions, .sameText:
            // Protected copies are filtered here, the one place a recommendation becomes paths to
            // trash, so re-aiming the keeper can't put one back.
            return redundantCopies.filter { !$0.isProtectedFromRemoval }.map { $0.path }
        case .overlapping:
            return []
        }
    }

    /// Whether the user may pick a different keeper: whatever `isFullyResolvableByRemoval` admits
    /// (identical, versions and same-text, which `DuplicateFinderSameTextTests` pins). Not
    /// overlapping: a new keeper would change which items are unique, which needs hashes a scan
    /// doesn't keep. Read off `isFullyResolvableByRemoval`, not restated, so the lists can't drift.
    public var allowsKeeperChoice: Bool { isFullyResolvableByRemoval }

    /// Returns this group with a different keeper chosen (no-op unless `allowsKeeperChoice` and the
    /// id names a non-keeper copy). Recomputes reclaimable bytes; keeps the same `id` so
    /// list/expansion identity is stable.
    ///
    /// The copies keep their order, so the row the user clicked stays under the pointer. Nothing
    /// needs keeper-first order: ``keeper`` and ``redundantCopies`` read the flag.
    public func choosingKeeper(_ copyID: DuplicateCopy.ID) -> DuplicateGroup {
        guard allowsKeeperChoice,
              copyID != keeper.id,
              copies.contains(where: { $0.id == copyID }) else { return self }
        let relabelled = copies.map { Self.relabel($0, isKeeper: $0.id == copyID) }
        // Protected copies are excluded, as in `recommendedRemovalPaths`: they are never trashed,
        // so counting them would promise a reclaim "Move to Trash" can't deliver.
        let reclaim = relabelled
            .filter { !$0.isRecommendedKeeper && !$0.isProtectedFromRemoval }
            .reduce(0) { $0 + $1.size }
        return DuplicateGroup(id: id, matchType: matchType, name: name, isDirectory: isDirectory,
                              copies: relabelled, reclaimableBytes: reclaim)
    }

    /// Returns this group with the copy at `path` removed and its figures recomputed, or nil when
    /// fewer than two copies remain. Keeps the same `id`. Used when one copy is trashed from the
    /// Compare duplicate review, so the Duplicates list updates without a rescan. If the keeper is
    /// removed, the shallowest survivor is promoted so the group keeps one.
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

    /// A copy of `c` with its keeper flag set, for ``choosingKeeper(_:)`` and
    /// ``removingRedundantCopy(atPath:)``.
    private static func relabel(_ c: DuplicateCopy, isKeeper: Bool) -> DuplicateCopy {
        DuplicateCopy(id: c.id, name: c.name, isDirectory: c.isDirectory, size: c.size,
                      itemCount: c.itemCount, modificationDate: c.modificationDate,
                      uniqueItemCount: c.uniqueItemCount, depth: c.depth,
                      isRecommendedKeeper: isKeeper, contentUnverified: c.contentUnverified,
                      isProtectedFromRemoval: c.isProtectedFromRemoval,
                      contentSnapshot: c.contentSnapshot)
    }

    /// Recomputes reclaimable bytes after one copy is removed, per the finder's rules: identical,
    /// versions and same-text groups reclaim every remaining unprotected redundant copy's full size;
    /// an overlapping group drops by the removed copy's shared bytes, estimated with the group's
    /// average shared fraction since per-copy fractions aren't kept.
    private static func reclaim(after removed: DuplicateCopy, matchType: DuplicateMatchType,
                                remaining: [DuplicateCopy], priorReclaim: Int) -> Int {
        switch matchType {
        case .identical, .versions, .sameText:
            return remaining.filter { !$0.isRecommendedKeeper && !$0.isProtectedFromRemoval }
                .reduce(0) { $0 + $1.size }
        case .overlapping(let fraction):
            return max(0, priorReclaim - Int(Double(removed.size) * fraction))
        }
    }
}

// MARK: - Options

public struct DuplicateFinderOptions: Sendable {
    /// Files smaller than this are ignored for standalone file grouping (they still count toward
    /// folder signatures). Keeps trivially tiny files out of the results.
    public var minFileSize: Int
    /// A folder joins an overlapping group when it shares at least this much with the keeper,
    /// measured both ways (`mutualFraction`). A group with no members left is not reported.
    public var overlapThreshold: Double
    /// Names skipped entirely (their subtrees don't count toward signatures either).
    public var ignoredNames: Set<String>
    /// Whether to surface drifted same-stem files as version groups.
    public var detectVersions: Bool
    /// Whether to read documents and group those whose text matches although their bytes don't
    /// (the re-stamped download). Costs one PDF parse per document on a cold scan and nothing on a
    /// rescan, since digests are cached under the content hashes' key. Parses run one at a time
    /// (``PDFKitSerialAccess``): PDFKit's text extraction is not thread-safe, so ~10k PDFs take
    /// minutes.
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

    /// `ItemIdentity.deepIdentityIgnoredNames` deliberately doesn't reuse this set. This is a
    /// discovery filter, so it may skip tooling trees (`.git`, `.build`, `node_modules`), leaving
    /// the folder's identity unknown (see `collect`). The copy-undo's identity walk guards against
    /// destruction, where a false skip lets ⌘Z trash the only copy of an edit, so it skips only OS
    /// noise. Change each set on its own merits.
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

/// Finds duplicate and related items within a single provider tree. Pure and deterministic:
/// grouping runs over an already-walked ``FileNode`` tree plus a map of content hashes, so it is
/// testable without a disk. Stateless statics, like ``FileDiffEngine``.
public enum DuplicateFinder {

    /// Prefix of the per-path placeholder signature for files the scan couldn't hash (unreadable,
    /// cloud-only) or didn't need to (no same-size twin, or ends unlike any twin's). A unique value
    /// keeps folder signatures computable and can never falsely match, but it must never count as
    /// evidence that contents differ either.
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
        /// Whether this node is, or holds, an entry skipped as a tooling tree (`.git`,
        /// `node_modules`, …): content that exists but nothing here has looked at.
        var holdsUnseenContent: Bool = false
        /// Whether this node is, or holds, a package (`.key`, `.pages`, `.photoslibrary`, …).
        var holdsPackage: Bool = false
    }

    /// Groups duplicate/related items in the given tree.
    /// - Parameters:
    ///   - tree: The walked children of the scan root (top-level nodes).
    ///   - fileHashes: Map of absolute file path → SHA-256 hex. Files absent from the map are
    ///     treated as "identity unknown" and never asserted identical.
    ///   - options: Tuning.
    ///   - textFingerprints: Map of absolute file path → ``ContentFingerprint`` digest, for the
    ///     documents that produced one. Absent is never evidence either way.
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
        // The walked node for every directory that could become a folder copy, so the folder
        // passes can record a ``FolderContentSnapshot`` on each copy. Built lazily per emitted copy:
        // a rollup in `collect` would hold every entry once per ancestor level. The index skips
        // what `collect` skips, so anything absent here was never a candidate.
        var dirNodesByPath: [String: FileNode] = [:]
        func indexDirs(_ nodes: [FileNode]) {
            for n in nodes where n.isDirectory {
                if options.ignoredNames.contains(n.name) || n.isSymbolicLink == true
                    || n.isCoveredElsewhere == true { continue }
                dirNodesByPath[n.id] = n
                indexDirs(n.children ?? [])
            }
        }
        indexDirs(tree)
        let snapshotForDir: (String) -> FolderContentSnapshot? = { path in
            guard let node = dirNodesByPath[path] else { return nil }
            return FolderContentSnapshot(walkedChildren: node.children ?? [],
                                         ignoredNames: options.ignoredNames)
        }
        // Hard-linked files (link count > 1) leave candidacy entirely, before any pass: trashing
        // one link frees nothing, "identical" links aren't a duplicate pair, and a versions group
        // must not judge an inode against itself. Dropped here so every pass is covered. Unknown
        // link counts stay in: over-reporting a duplicate beats hiding one.
        if !multiLinkPaths.isEmpty {
            files.removeAll { multiLinkPaths.contains($0.path) }
        }

        var groups: [DuplicateGroup] = []
        // Paths already covered by an ancestor duplicate group, so files inside a redundant folder
        // copy aren't reported again.
        var coveredRoots: Set<String> = []
        // File paths already placed in a group (identical wins over versions).
        var groupedFilePaths: Set<String> = []
        // The keeper of every identical-folder group. `coveredRoots` holds only redundant copies,
        // so without this a file pass could recommend removing a file inside a kept folder (see
        // `protectingFolderKeepers`).
        var folderKeeperRoots: Set<String> = []

        // The keeper of every identical-file group: the same-text pass may use one as an anchor
        // and must never offer to remove it.
        var identicalFileKeepers: Set<String> = []

        groups += identicalFolderGroups(dirs, options: options, snapshotForDir: snapshotForDir,
                                        coveredRoots: &coveredRoots, keeperRoots: &folderKeeperRoots)
        groups += overlappingFolderGroups(dirs, options: options, snapshotForDir: snapshotForDir,
                                               coveredRoots: &coveredRoots)
        groups += identicalFileGroups(files, options: options, coveredRoots: coveredRoots, keeperRoots: folderKeeperRoots, groupedFilePaths: &groupedFilePaths, keepers: &identicalFileKeepers)
        // Before versions: a second download (`DE429D-2.pdf` beside `DE429D.pdf`) shares a stem,
        // and the versions pass would call it an older version when the text says it never changed.
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
    ///
    /// A package is one item. Its contents roll up into its size, hashes and signature, so two
    /// identical decks still match, but nothing inside is ever a candidate (`insidePackage`), or
    /// Apply recommended could trash an image shared by two Keynote decks, or a Photos original.
    private static func collect(
        _ node: FileNode,
        depth: Int,
        fileHashes: [String: String],
        options: DuplicateFinderOptions,
        files: inout [NodeInfo],
        dirs: inout [NodeInfo],
        insidePackage: Bool = false
    ) -> NodeInfo? {
        // Skipped is not absent. OS noise (`.DS_Store`, `Thumbs.db`) is dropped. Other skipped
        // names (`.git`, `node_modules`) are content: dropped, a clone would match a ZIP of its
        // working tree and could be trashed. So they reach the parent as an entry of unknown
        // identity, like a directory link: nothing inside is hashed (`flattenFiles(_:skipping:)`),
        // the parent can't be identical, and `holdsUnseenContent` keeps it out of overlapping.
        if options.ignoredNames.contains(node.name) {
            if ItemIdentity.deepIdentityIgnoredNames.contains(node.name) { return nil }
            return NodeInfo(
                path: node.id, name: node.name, isDirectory: node.isDirectory,
                size: 0, itemCount: 0, modificationDate: node.modificationDate,
                depth: depth, signature: nil, contentHashes: [], holdsUnseenContent: true
            )
        }
        // A symlink is never a candidate: it hashes like its target, and trashing the target would
        // leave a dangling link as the "kept" copy. It still occupies a name, so it folds into the
        // parent's signature: a file link as a "symlink:"-tagged hash, so a folder holding a link
        // never matches one holding the real file; a directory link unhashed, making its parent
        // non-groupable. Not added to the buckets or walked. Size and itemCount 0; the parent
        // counts it as one entry.
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
        // A subtree also reached by a shorter route is not a copy of anything: it is the same
        // entry arriving twice (`FileNode.isCoveredElsewhere`), and the symlink test can't see it.
        // As a candidate, a `~` scan would offer to Trash `~/Documents` as a copy of itself. So it
        // is treated like a symlink: one entry, never a candidate, never walked into.
        if node.isCoveredElsewhere == true {
            return NodeInfo(
                path: node.id, name: node.name, isDirectory: node.isDirectory,
                size: 0, itemCount: 0, modificationDate: node.modificationDate,
                depth: depth, signature: nil, contentHashes: []
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
            if !insidePackage { files.append(info) }
            return info
        }

        // Directory: roll up children first.
        var childInfos: [NodeInfo] = []
        let isPackage = node.isPackage
        for child in node.children ?? [] {
            if let ci = collect(child, depth: depth + 1, fileHashes: fileHashes, options: options,
                                files: &files, dirs: &dirs, insidePackage: insidePackage || isPackage) {
                childInfos.append(ci)
            }
        }

        let size = childInfos.reduce(0) { $0 + $1.size }
        // A skipped tooling tree isn't counted, so the figure is what the walk saw. (Any child
        // still carrying an ignored name is one; OS noise never comes back.)
        let itemCount = childInfos.reduce(0) {
            options.ignoredNames.contains($1.name) ? $0 : $0 + 1 + ($1.isDirectory ? $1.itemCount : 0)
        }
        var contentHashes = Set<String>()
        for ci in childInfos { contentHashes.formUnion(ci.contentHashes) }

        // Structural signature: sorted child (name, sig) pairs, hashed to keep it bounded. nil if
        // any descendant's identity is unknown (an unhashed file, an unwalked directory), so the
        // tree is never asserted identical.
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
            contentHashes: contentHashes,
            // A folder the walk didn't read holds unseen content, like a skipped `.git`, so it is
            // never folded away.
            holdsUnseenContent: node.isUnexplored == true || childInfos.contains(where: \.holdsUnseenContent),
            holdsPackage: isPackage || childInfos.contains(where: \.holdsPackage)
        )
        if !insidePackage { dirs.append(info) }
        return info
    }

    // MARK: Identical folders

    private static func identicalFolderGroups(
        _ dirs: [NodeInfo],
        options: DuplicateFinderOptions,
        snapshotForDir: (String) -> FolderContentSnapshot?,
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
        // Every folder that holds a keeper chosen so far, so "does this member hold one?" is one
        // lookup.
        var keeperAncestors = Set<String>()
        func recordAncestors(of path: String) {
            var current = (path as NSString).deletingLastPathComponent
            while !current.isEmpty, current != "/", keeperAncestors.insert(current).inserted {
                current = (current as NSString).deletingLastPathComponent
            }
        }
        keeperRoots.forEach(recordAncestors)
        for var members in candidates {
            members = members.filter { !isCovered($0.path, by: coveredRoots) }
            guard members.count >= 2 else { continue }

            // **A folder an earlier group keeps, or one that holds it, is never a copy to remove
            // here.** Otherwise one group could keep `P/Sub` and trash `Q/Sub` while another kept
            // `Q` and trashed `P`, and one Apply recommended would trash every copy. Such a member
            // may still be the keeper, marked protected so a re-pick can't put it on the removal
            // list; with nothing removable left there is no group.
            let protectedPaths = Set(members.filter { m in
                isCovered(m.path, by: keeperRoots) || keeperAncestors.contains(m.path)
            }.map(\.path))
            let ordered: [NodeInfo]
            if protectedPaths.isEmpty {
                ordered = orderKeeperFirst(members, keeperIndex: chooseKeeper(members))
            } else {
                let protected = members.filter { protectedPaths.contains($0.path) }
                let keeper = protected[chooseKeeper(protected)]
                let removable = members.filter { !protectedPaths.contains($0.path) }
                guard !removable.isEmpty else { continue }
                // A second protected member has nowhere safe to sit, so it leaves the group, as in
                // `protectingFolderKeepers`.
                ordered = [keeper] + removable.sorted { ($0.depth, $0.path) < ($1.depth, $1.path) }
            }
            let keeper = ordered[0]
            let copies = ordered.enumerated().map { idx, info in
                makeCopy(info, keeper: keeper, isKeeper: idx == 0, protectedPaths: protectedPaths,
                         contentSnapshot: snapshotForDir(info.path))
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
            // Not in `coveredRoots`, which would also hide inner folder pairs from the passes
            // below. The file passes consult it to leave the kept folder alone.
            keeperRoots.insert(keeper.path)
            recordAncestors(of: keeper.path)
        }
        return groups
    }

    // MARK: Overlapping folders

    private static func overlappingFolderGroups(
        _ dirs: [NodeInfo],
        options: DuplicateFinderOptions,
        snapshotForDir: (String) -> FolderContentSnapshot?,
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
            // A folder nested inside a same-named folder is part of its content, not a copy.
            // Grouped, a merge would copy files into the keeper and then trash a piece of it: data
            // loss. Keep only the outermost members.
            let members = outermost(allMembers)
            guard members.count >= 2 else { continue }
            // Drop groups that are actually identical (already handled): keep only those with at
            // least two distinct signatures.
            let distinctSignatures = Set(members.map { $0.signature ?? UUID().uuidString })
            guard distinctSignatures.count >= 2 else { continue }

            let keeperIdx = chooseKeeper(members)
            let ordered = orderKeeperFirst(members, keeperIndex: keeperIdx)
            let keeper = ordered[0]

            // Each folder joins on its own merits, and the group is what is left: one average over
            // all same-named folders would let unrelated subsets sink a real twin.
            // **A copy holding content the walk skipped is never folded away**: folding trashes
            // the rest of the copy, which would include a `.git` nobody compared. Nor a package or
            // a folder holding one: the file-by-file merge would fold one document's insides into
            // another's (`FileOperations.isMergeableFolder`).
            let folded = ordered.dropFirst().filter {
                !$0.holdsUnseenContent && !$0.holdsPackage
                    && mutualFraction(of: $0, against: keeper) >= options.overlapThreshold
            }
            let kept = [keeper] + folded
            // One-sided, because what a fold-in frees is the folded copy's own redundant bytes.
            let fractions = folded.map { sharedFraction(of: $0, against: keeper) }
            let mutual = folded.map { mutualFraction(of: $0, against: keeper) }
            let avgMutual = mutual.isEmpty ? 0 : mutual.reduce(0, +) / Double(mutual.count)

            // Snapshots here too: the Compare review gates its trash on the recorded baseline for
            // every directory group kind.
            let copies = kept.enumerated().map { idx, info in
                makeCopy(info, keeper: keeper, isKeeper: idx == 0,
                         contentSnapshot: snapshotForDir(info.path))
            }

            // Something survived the per-copy gate, so there is a group. `avgMutual` is only the
            // figure the card reports.
            if !folded.isEmpty {
                // Reclaimable ≈ the shared (redundant) bytes of each folded-in copy.
                let reclaimable = zip(folded, fractions)
                    .reduce(0) { $0 + Int(Double($1.0.size) * $1.1) }
                groups.append(DuplicateGroup(
                    matchType: .overlapping(sharedFraction: avgMutual),
                    name: name,
                    isDirectory: true,
                    copies: copies,
                    reclaimableBytes: reclaimable
                ))
                // Resolve overlaps at the folder level — don't also re-report their shared inner
                // files as standalone identical-file duplicates.
                for c in copies { coveredRoots.insert(c.path) }
            }
            // With nothing left after the gate, nothing is reported: in an organised tree a shared
            // name (`2020`, `Archive`, `Payslips`) is not evidence of duplication. Nothing real is
            // lost, since only a reported group writes `coveredRoots`, so files filed in two such
            // folders are still reported as identical-file groups.
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
            // Every member is marked grouped, not just the surviving copies: a protected file
            // dropped from this group is still accounted for, and must not reappear in a versions
            // group.
            for m in members { groupedFilePaths.insert(m.path) }
            keepers.insert(keeper.path)
        }
        return groups
    }

    // MARK: Same text, different bytes

    /// Documents whose ``ContentFingerprint`` digest matches although their bytes don't: the
    /// re-stamped download, the compressed re-save, the same statement filed under two names.
    ///
    /// It only adds what the byte hash lacked, via `groupedFilePaths`: two members sharing a known
    /// hash were already grouped by `identicalFileGroups` (same size floor, same `coveredRoots`),
    /// leaving at most that group's keeper, so no "distinct signatures" guard is needed.
    ///
    /// An identical group's keeper may anchor a group here, never be offered for removal by it.
    /// Excluding it would delete groups where a document was downloaded twice and also copied; with
    /// disjoint removal sets, one batch can't undo the other's promise.
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
        // Sorted by digest so the order doesn't ride on dictionary iteration. Visible only where
        // the final sort ties, and only across launches (Swift seeds its hasher per process), so
        // no single-process test can catch it.
        for digest in buckets.keys.sorted() {
            let members = buckets[digest]!
            guard members.count >= 2 else { continue }
            let protectedPaths = Set(members.map { $0.path }.filter {
                identicalKeepers.contains($0) || isCovered($0, by: folderKeeperRoots)
            })
            // Keeper from the protected subset when there is one, as in `protectingFolderKeepers`:
            // the choice is a location heuristic the user can re-aim, so anchoring on a copy
            // another group keeps costs nothing.
            let pool = protectedPaths.isEmpty ? members : members.filter { protectedPaths.contains($0.path) }
            let keeper = pool[chooseKeeper(pool)]
            // A second protected member can be neither keeper nor removable, so it leaves the
            // group, as in `protectingFolderKeepers`. It stays marked as grouped below.
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
            // Every member, protected ones included, as above, so versions can't pick one up again.
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
            guard let (stem, ext, markers) = versionStemAndMarkers(f.name) else { continue }
            // A download counter is not evidence of versions. A browser appends " (1)" when the
            // name exists, and `invoice.pdf`, `invoice (1).pdf` can be different months' bills that
            // "Keep newest, Trash older" would trash. A re-download of the same document is caught
            // upstream (identical or same-text), so a counter name never joins by name, even beside
            // or alongside a deliberate marker (`statement (1) copy.xlsx`). Dropped before
            // clustering: left in, it would still count as a marker and as drift evidence, and
            // could split or sink a cluster.
            guard !markers.contains(0) else { continue }
            guard !DuplicateFinderOptions.genericVersionStems.contains(stem) else { continue }
            buckets["\(stem)\u{0}\(ext)", default: []].append(f)
        }

        var groups: [DuplicateGroup] = []
        for bucket in buckets.values where bucket.count >= 2 {
            // A shared stem alone is weak evidence: unrelated same-named files live in different
            // folders (/2019/IMG_0001.jpg, /2023/IMG_0001.jpg), and a "versions" group would trash
            // a unique one. So require a stripped marker (" (1)", "copy", "-v2", "final", …) on at
            // least one member, or every member in the same folder.
            //
            // A marker vouches only for its own name and the members beside it: "IMG_0001 copy.jpg"
            // says nothing about a same-stem file elsewhere. So cross-folder members join only on
            // their own marker or by sharing a bearer's parent.
            //
            // Markers in several folders are independent events, so each marker folder with
            // same-stem company forms its own group, pairing each copy with its own original. Only
            // lone bearers pool across folders, on their own names' evidence; unmarked files never
            // join that pool.
            let sameParent = Set(bucket.map { ($0.path as NSString).deletingLastPathComponent }).count == 1
            let memberClusters: [[NodeInfo]]
            if sameParent {
                memberClusters = [bucket]   // same-stem siblings
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
                    // Grouped once, not filtered per parent.
                    let byParent = Dictionary(grouping: bucket) {
                        ($0.path as NSString).deletingLastPathComponent
                    }
                    for parent in markerParents.sorted() {
                        let inParent = byParent[parent] ?? []
                        // A cluster that can't prove drift (fewer than two real hashes) would die
                        // at the guard below, so its bearers fall through to the cross-folder pool,
                        // where another bearer may prove it. Unmarked companions never follow.
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
                // Only proven drift: at least two distinct real contents. Placeholder and missing
                // signatures are not evidence of difference, so unknown-hash members may ride along
                // in a group real hashes justify but never stand one up. Files inside a kept folder
                // may anchor but are never offered for removal (`protectingFolderKeepers`), applied
                // first so the evidence is read off the members that remain.
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
                // Every member, not just the surviving copies, as the identical pass does.
                for m in members { groupedFilePaths.insert(m.path) }
            }
        }
        return groups
    }

    // MARK: Folder-keeper protection

    /// A file group's members reordered so that a file inside an identical-folder group's keeper is
    /// never one of the copies recommended for removal. nil when fewer than two members survive.
    ///
    /// One "Apply recommended" acts on every group at once, and `coveredRoots` holds only redundant
    /// copies, so without this one batch could trash F2 and hollow out the kept F1 too. Protected
    /// files still anchor groups, so a third copy elsewhere stays removable, but only as the
    /// keeper. A second protected member has nowhere safe to sit and leaves the group.
    private static func protectingFolderKeepers(
        _ members: [NodeInfo],
        keeperRoots: Set<String>,
        chooseKeeperIn: ([NodeInfo]) -> Int,
        keeperMayBePickedFromProtected: Bool
    ) -> [NodeInfo]? {
        guard members.count >= 2 else { return nil }
        guard !keeperRoots.isEmpty else {
            // The common case: no identical-folder groups at all.
            return orderKeeperFirst(members, keeperIndex: chooseKeeperIn(members))
        }
        let protected = members.filter { isCovered($0.path, by: keeperRoots) }
        guard !protected.isEmpty else {
            return orderKeeperFirst(members, keeperIndex: chooseKeeperIn(members))
        }
        // Which file anchors depends on what the keeper choice means. For identical copies it is
        // a location heuristic the user can change, so preferring a protected file is free. For
        // versions the card promises "Keep newest", and the newest protected file could be years
        // older, so the keeper is picked over all members and protection only shrinks the
        // removable side.
        let keeper = keeperMayBePickedFromProtected
            ? protected[chooseKeeperIn(protected)]
            : members[chooseKeeperIn(members)]
        let removable = members.filter { $0.path != keeper.path && !isCovered($0.path, by: keeperRoots) }
        guard !removable.isEmpty else { return nil }
        // Keeper first, then (depth, path), as `DuplicateGroup.copies` documents.
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

    /// The location penalty for a versions keeper: only true archive, backup and trash segments,
    /// unlike ``archiveSegments``, which only picks a home among identical bytes. Versions differ
    /// and the non-keepers are trashed, and the newest revision may well sit in Downloads or tmp;
    /// penalizing those would trash the only copy of new content. Backups stay penalized, since a
    /// backup tool's mtime rewrite can make a stale copy look newest.
    private static let versionsStaleLocationSegments: Set<String> = [
        "archive", "archives", "old", "backup", "backups", "trash", ".trash"
    ]

    private static func versionsStaleLocationPenalty(_ path: String) -> Int {
        let segs = path.split(separator: "/").map { $0.lowercased() }
        return segs.reduce(0) { $0 + (versionsStaleLocationSegments.contains($1) ? 1 : 0) }
    }

    /// Picks the versions keeper: least stale location first (``versionsStaleLocationSegments``),
    /// then the most recently modified, then the shallowest path. Internal so tests can pin it.
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
    ///   - protectedRoots: Directories whose contents may not be removed (an identical-folder
    ///     group's keeper). Tested by containment.
    ///   - protectedPaths: Exact paths that may not be removed (an identical-file group's keeper).
    ///     Separate because `isInsideDirectory` matches proper ancestors only, so a file path in
    ///     `protectedRoots` would silently protect nothing.
    private static func makeCopy(_ info: NodeInfo, keeper: NodeInfo, isKeeper: Bool,
                                 protectedRoots: Set<String> = [],
                                 protectedPaths: Set<String> = [],
                                 contentSnapshot: FolderContentSnapshot? = nil) -> DuplicateCopy {
        let unique = isKeeper ? 0 : info.contentHashes.subtracting(keeper.contentHashes).count
        // Unverified: a file whose hash is missing or a placeholder, or a folder with no full
        // signature or with a placeholder descendant (computable, but not verified).
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
                || protectedPaths.contains(info.path),
            contentSnapshot: contentSnapshot
        )
    }

    private static func orderKeeperFirst(_ infos: [NodeInfo], keeperIndex: Int) -> [NodeInfo] {
        var rest = infos
        let keeper = rest.remove(at: keeperIndex)
        rest.sort { ($0.depth, $0.path) < ($1.depth, $1.path) }
        return [keeper] + rest
    }

    /// How much of `copy` is already in `keeper`: the reclaim estimate, since a fold-in frees this
    /// copy's redundant bytes. One-sided, so it can't be the gate (``mutualFraction(of:against:)``).
    private static func sharedFraction(of copy: NodeInfo, against keeper: NodeInfo) -> Double {
        guard !copy.contentHashes.isEmpty else { return 0 }
        let shared = copy.contentHashes.intersection(keeper.contentHashes).count
        return Double(shared) / Double(copy.contentHashes.count)
    }

    /// How much of the two folders together is shared: the intersection over the larger side.
    ///
    /// The folder pass buckets by name, and a one-sided fraction would call a one-file folder that
    /// shares its file with a 361-item namesake "100% shared" and offer a merge. Over the larger
    /// side that scores 1/361, while real versions barely move (18 of 20 is 0.9 either way). A
    /// small subset (5 inside 10 scores 0.5) is deliberately not a folder finding; its files are
    /// still reported as identical-file duplicates.
    private static func mutualFraction(of copy: NodeInfo, against keeper: NodeInfo) -> Double {
        let larger = max(copy.contentHashes.count, keeper.contentHashes.count)
        guard larger > 0 else { return 0 }
        return Double(copy.contentHashes.intersection(keeper.contentHashes).count) / Double(larger)
    }

    private static func isCovered(_ path: String, by roots: Set<String>) -> Bool {
        path.isInsideDirectory(anyOf: roots)
    }

    /// Keeps only the members not nested inside another member (drops ancestor/descendant dupes).
    private static func outermost(_ infos: [NodeInfo]) -> [NodeInfo] {
        // `paths` alone, not minus `$0.path` (an O(n²) rebuild): `isInsideDirectory` matches only
        // at a "/" boundary, so a path is never inside itself. Buckets can be large.
        let paths = Set(infos.map { $0.path })
        return infos.filter { !$0.path.isInsideDirectory(anyOf: paths) }
    }

    static func stableHash(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return HexEncoding.string(digest)
    }

    /// The trailing copy/version markers, compiled once: `range(of:options:.regularExpression)`
    /// would compile per call, and this runs for every file above the size floor. `try!` because
    /// these are literals; a failure is a typo, not a runtime condition.
    private static let versionMarkerPatterns: [NSRegularExpression] = [
        #"\s*\(\d+\)$"#,            // " (1)"
        #"[ _-]copy(\s*\d+)?$"#,    // " copy", "-copy 2"
        #"[ _-]v\d+$"#,             // "-v2", "_v3"
        #"[ _-](final|draft|latest|new|old|revised|edit|edited)$"#
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// Reduces a filename to its version stem + extension, stripping trailing copy/version markers.
    /// Returns nil for an empty stem. Case-normalized for grouping.
    static func versionStem(_ name: String) -> (stem: String, ext: String)? {
        versionStemAndMarkers(name).map { ($0.stem, $0.ext) }
    }

    /// ``versionStem(_:)`` plus the indexes into ``versionMarkerPatterns`` of the markers it
    /// stripped (index 0 is the download counter).
    private static func versionStemAndMarkers(_ name: String)
        -> (stem: String, ext: String, markers: Set<Int>)? {
        let ns = name as NSString
        let ext = ns.pathExtension.lowercased()
        let (stripped, markers) = strippingVersionMarkers((ns.deletingPathExtension as String).lowercased())
        let stem = stripped.trimmingCharacters(in: .whitespaces)
        guard !stem.isEmpty else { return nil }
        return (stem, ext, markers)
    }

    /// `stem` with every trailing marker removed, and the indexes into ``versionMarkerPatterns``
    /// of the ones that fired (index 0 is the download counter, " (1)").
    private static func strippingVersionMarkers(_ stem: String) -> (String, Set<Int>) {
        var stem = stem
        var fired: Set<Int> = []
        var changed = true
        while changed {
            changed = false
            for (i, r) in versionMarkerPatterns.enumerated() {
                let range = NSRange(stem.startIndex..., in: stem)
                if let match = r.firstMatch(in: stem, options: [], range: range),
                   let found = Range(match.range, in: stem) {
                    stem.removeSubrange(found)
                    fired.insert(i)
                    changed = true
                }
            }
        }
        return (stem, fired)
    }

    /// True when ``versionStem(_:)`` stripped a version or copy marker, so the name itself is
    /// evidence of a version ("report copy.pdf", "deck-final.key"). Case and whitespace
    /// normalization alone don't count.
    static func hasVersionMarker(_ name: String) -> Bool {
        guard let (stem, _) = versionStem(name) else { return false }
        let plain = ((name as NSString).deletingPathExtension as String)
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
        return stem != plain
    }
}
