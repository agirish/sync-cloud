//
//  ItemIdentity.swift
//  SyncCloud
//

import CryptoKit
import Foundation

/// Enough of an item's on-disk state to tell later whether it is still the item an operation
/// produced, for folders as well as files. Unlike an optional size, it has no value a guard can
/// silently skip with `if let`: "absent" and "couldn't tell" are cases the caller must handle.
public enum ItemIdentity: Equatable, Sendable {
    /// A regular file. `modified` is nil only when the filesystem did not report one.
    case file(size: Int, modified: Date?)
    /// A directory, shallowly: `childNames` digests its immediate children's names, OS noise
    /// (`deepIdentityIgnoredNames`) left out, and `fileNumber` is its own `st_ino` (nil where the
    /// file system reports none). `compare` says what this can't notice; a caller whose wrong answer
    /// destroys data records `.directoryTree` instead. Not the folder's date or raw child count:
    /// Finder's `.DS_Store` moves both when the user merely opens it.
    case directory(childNames: String, fileNumber: UInt64?)
    /// A directory by its recursive content: `contentDigest` is a SHA-256 over every descendant's
    /// relative path, kind, size and modification date, so an edit at any depth changes it, which
    /// `.directory` misses and the copy-undo must not. Produced only by `deepSnapshot`; `drift`
    /// re-reads at the same depth.
    case directoryTree(contentDigest: String)
    /// `.directoryTree` plus the folder's own file number (`st_ino`), for folders content can't
    /// tell apart: every merge-emptied source folder has the same digest, so a stranger empty folder
    /// trashed under the freed name would match. The number survives a move into the Trash and a
    /// `.DS_Store` write. Produced only by `deepSnapshotWithFileNumber`; `drift` re-reads it so.
    case directoryTreeAndFileNumber(contentDigest: String, fileNumber: UInt64)
    /// A directory whose contents couldn't be read (an unreadable descendant, a cloud folder that
    /// didn't answer), known by its own file number alone. Enough to ask whether the folder in the
    /// Trash under this name is the one an operation put there: the number survives the move, and a
    /// stranger has another. Produced only by `deepSnapshotOrFileNumber`; `drift` re-reads the
    /// number.
    case directoryFileNumber(UInt64)
    /// A symbolic link, by its own size and date, not its target's (`attributesOfItem` doesn't
    /// follow links). Its own case, or a link to a folder would read as a small file and a link
    /// swapped for a same-size file as unchanged.
    case symlink(size: Int, modified: Date?)
    /// Nothing is at the path.
    case absent
    /// Something is at the path but its state couldn't be read: an unstatable file, or a directory
    /// that couldn't be listed. **Never treat this as "unchanged".**
    case indeterminate
}

/// The answer to "is this still the item I recorded?", with an explicit third value: "couldn't
/// tell" must never collapse into yes or no.
public enum DriftVerdict: Equatable, Sendable {
    case unchanged
    case changed
    /// One side couldn't be read, so nothing can be concluded. **A caller acting destructively must
    /// treat this as a refusal**, not as `unchanged`.
    case indeterminate
}

public extension ItemIdentity {

    /// Reads the item at `url`. A file costs one `attributesOfItem`; **a folder costs a listing**,
    /// about 30× a stat for 2,000 entries and growing with the count, paid per item at undo
    /// registration. Move registrations list shallowly on the main actor; `registerCopyUndo` walks
    /// deep in a detached task, since a deep walk on main freezes the UI. Where to pay is the call
    /// site's decision.
    ///
    /// **A folder whose contents aren't on this Mac asks its cloud app**, possibly on the main
    /// actor. `listing(of:)` waits at most the dataless reads' deadline, once, and an unanswered
    /// folder is `.indeterminate`, so the undo refuses rather than vouching for it.
    static func snapshot(at url: URL, fileManager fm: FileManaging) -> ItemIdentity {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else {
            // attributesOfItem throws both for "not there" and "there but unreadable", which must
            // stay apart: absent is a fact, unreadable an unknown.
            return fm.fileExists(atPath: url.path) ? .indeterminate : .absent
        }

        let type = attrs[.type] as? FileAttributeType

        // Before the directory test, because attributesOfItem doesn't follow links: a symlink to a
        // directory reports as a link.
        if type == .typeSymbolicLink {
            guard let size = (attrs[.size] as? NSNumber)?.intValue ?? (attrs[.size] as? Int) else {
                return .indeterminate
            }
            return .symlink(size: size, modified: attrs[.modificationDate] as? Date)
        }

        if type == .typeDirectory {
            let listing = fm.listing(of: url)
            switch listing.outcome {
            case .unreadable:
                return .indeterminate
            case .listed, .listedWithUnreadableDescendants:
                // A shallow listing can't be partial, so the second case is unreachable; spelled
                // out, not defaulted, so a recursive listing here forces the choice again.
                return .directory(childNames: childNamesDigest(listing.urls),
                                  fileNumber: fileNumber(in: attrs))
            }
        }

        let size = (attrs[.size] as? NSNumber)?.intValue ?? (attrs[.size] as? Int)
        guard let size else { return .indeterminate }
        return .file(size: size, modified: attrs[.modificationDate] as? Date)
    }

    /// The one spelling `deepSnapshot` digests a descendant's relative path under, whatever form the
    /// walk reported. APFS lookups ignore normalization but storage preserves it, so one name can sit
    /// on disk in either form, and the digest must not hash it two ways.
    ///
    /// A named seam so `DeepFolderIdentityTests` can pin it: today's path APIs happen to hand
    /// `deepSnapshot` the decomposed form whatever is on disk, so no end-to-end fixture can vary the
    /// spelling. That is incidental, which is why the rule stays.
    internal static func canonicalDigestSpelling(ofRelativePath rel: String) -> String {
        rel.precomposedStringWithCanonicalMapping
    }

    /// The names `deepSnapshot` leaves out of a tree's identity, OS noise only: `.DS_Store`,
    /// `.localized`, `Thumbs.db` and `.Trashes`, which the OS writes on its own schedule. Digesting
    /// them would manufacture drift, and drift here means a refused ⌘Z.
    ///
    /// Matched by component name at any depth, so a user's own `.Trashes` folder inside a copy is
    /// invisible too, an accepted trade: a copied volume root puts the real one at depth 1.
    ///
    /// **Deliberately not `DuplicateFinderOptions.defaultIgnoredNames`**, which also skips `.git`,
    /// `.build` and `node_modules`. That is a discovery filter, where a false skip misses a
    /// duplicate; this guards destruction, where a false skip lets ⌘Z trash the only copy of an
    /// edit made inside one. Argue any addition to either set on its own merits.
    static let deepIdentityIgnoredNames: Set<String> = [
        ".DS_Store", ".localized", "Thumbs.db", ".Trashes"
    ]

    /// Reads the item at `url`, describing a directory by its recursive content (`.directoryTree`).
    /// Anything else is exactly `snapshot`. **`.indeterminate` as soon as any part of the tree can't
    /// be read**: a partial walk can't prove a tree unchanged.
    ///
    /// One recursive, stat-only walk, the trade `folderDriftedInPlace` accepts too: it runs at
    /// copy-undo registration, when the tree is warm, and at undo or redo after a destructive click.
    ///
    /// The digest has one line per descendant: relative path and kind, plus size and modification
    /// date (whole milliseconds, safe from `Double` rounding) for files and symlinks. Folders carry
    /// path and kind only, since their dates move with no real change. Symlinks are described, never
    /// followed, so a dangling link doesn't fail the walk.
    ///
    /// Entries under a `deepIdentityIgnoredNames` component are skipped before they are statted, so
    /// an unstatable `.DS_Store` can't refuse either. But the listing's outcome is decided first: an
    /// unreadable descendant inside an ignored subtree still answers `.indeterminate`, a permanent
    /// refusal if recorded, reported once per batch
    /// (`FileSyncManager.logIndeterminateRegistrations`).
    ///
    /// Lines are sorted by the bytes of the precomposed path
    /// (`canonicalDigestSpelling(ofRelativePath:)`), so the digest depends on the tree, not on
    /// enumeration order or the name's Unicode form.
    static func deepSnapshot(at url: URL, fileManager fm: FileManaging) -> ItemIdentity {
        deepSnapshotDetailingFailure(at: url, fileManager: fm).identity
    }

    /// `deepSnapshot`, with the folder's own file number when it answers `.directoryTree`
    /// (`.directoryTreeAndFileNumber`). With no number reported (a test double), the plain
    /// `.directoryTree`, recorded and re-read alike.
    static func deepSnapshotWithFileNumber(at url: URL, fileManager fm: FileManaging) -> ItemIdentity {
        let deep = deepSnapshot(at: url, fileManager: fm)
        guard case .directoryTree(let digest) = deep,
              let fileNumber = directoryFileNumber(at: url, fileManager: fm) else { return deep }
        return .directoryTreeAndFileNumber(contentDigest: digest, fileNumber: fileNumber)
    }

    /// `deepSnapshot`, or, when that is `.indeterminate`, the folder's own file number
    /// (`.directoryFileNumber`), which needs only a stat of the folder. Otherwise, or with no number
    /// reported (a test double), `deepSnapshot`'s answer unchanged.
    static func deepSnapshotOrFileNumber(at url: URL, fileManager fm: FileManaging) -> ItemIdentity {
        let deep = deepSnapshot(at: url, fileManager: fm)
        guard deep == .indeterminate,
              let fileNumber = directoryFileNumber(at: url, fileManager: fm) else { return deep }
        return .directoryFileNumber(fileNumber)
    }

    /// The file number (`st_ino`) of the directory at `url`, from a stat of it alone; nil when it
    /// isn't a directory or the file system reports none.
    static func directoryFileNumber(at url: URL, fileManager fm: FileManaging) -> UInt64? {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeDirectory else { return nil }
        return fileNumber(in: attrs)
    }

    /// The shallow identity's names: each immediate child's name, precomposed, OS noise left out,
    /// sorted by bytes and hashed, so listing order and a name's Unicode spelling don't move it.
    private static func childNamesDigest(_ children: [URL]) -> String {
        let names = children.map(\.lastPathComponent)
            .filter { !deepIdentityIgnoredNames.contains($0) }
            .map { canonicalDigestSpelling(ofRelativePath: $0) }
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        return HexEncoding.string(SHA256.hash(data: Data(names.joined(separator: "\u{0}").utf8)))
    }

    private static func fileNumber(in attrs: [FileAttributeKey: Any]) -> UInt64? {
        switch attrs[.systemFileNumber] {
        case let number as NSNumber: return number.uint64Value
        case let number as UInt64: return number
        case let number as Int: return UInt64(truncatingIfNeeded: number)
        default: return nil
        }
    }

    /// `deepSnapshot` plus, when the answer is `.indeterminate`, the descendant that made it so: the
    /// first unreadable one of a partial listing, or a child that vanished or lost its size between
    /// list and stat; nil for an unreadable root. Recording callers report it once per batch
    /// (`FileSyncManager.logIndeterminateRegistrations`), since a registration-time `.indeterminate`
    /// is a permanent refusal a later ⌘Z banner can't explain.
    static func deepSnapshotDetailingFailure(
        at url: URL, fileManager fm: FileManaging
    ) -> (identity: ItemIdentity, unreadableDescendant: URL?) {
        let shallow = snapshot(at: url, fileManager: fm)
        guard case .directory = shallow else { return (shallow, nil) }

        // `options: []` is the recursive walk. `.listedWithUnreadableDescendants` is partial and
        // proves nothing about what was withheld, so `.indeterminate`, which refuses the undo, as
        // `folderDriftedInPlace` does. A cloud folder that didn't answer is withheld this way.
        let listing = fm.listing(of: url, options: [])
        guard listing.outcome == .listed else {
            return (.indeterminate, listing.unreadableDescendants.first)
        }

        let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
        var lines: [String] = []
        lines.reserveCapacity(listing.urls.count)
        for child in listing.urls {
            let rel = child.path.hasPrefix(prefix)
                ? String(child.path.dropFirst(prefix.count)) : child.path
            // The ignored-names skip: a component match covers the entry and everything below it,
            // before the stat, so an ignored entry can neither shift the digest nor refuse the walk.
            if rel.split(separator: "/").contains(
                where: { deepIdentityIgnoredNames.contains(String($0)) }) {
                continue
            }
            // An entry just listed but unstatable means the tree is changing or withheld: nothing
            // can be concluded, so nothing may be destroyed.
            guard let attrs = try? fm.attributesOfItem(atPath: child.path) else {
                return (.indeterminate, child)
            }
            let canonicalRel = canonicalDigestSpelling(ofRelativePath: rel)
            let type = attrs[.type] as? FileAttributeType
            if type == .typeDirectory {
                lines.append("\(canonicalRel)\u{0}d")
                continue
            }
            let kind = type == .typeSymbolicLink ? "l" : "f"
            guard let size = (attrs[.size] as? NSNumber)?.intValue ?? (attrs[.size] as? Int) else {
                return (.indeterminate, child)
            }
            let millis = (attrs[.modificationDate] as? Date)
                .map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? "-"
            lines.append("\(canonicalRel)\u{0}\(kind)\u{0}\(size)\u{0}\(millis)")
        }
        // Byte order of the canonical form, not Swift's `<` (canonical equivalence), so two walks
        // of one tree plainly serialize identically.
        lines.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        // The scheme marker makes a rule change produce differing digests (a refusal) rather than
        // collisions, as `ContentFingerprint.scheme` does. Bump it whenever what is digested changes.
        let canonical = "tree-3\n" + lines.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return (.directoryTree(contentDigest: HexEncoding.string(digest)), nil)
    }

    /// Compares a recorded identity against what is on disk now. For a file it notices any size or
    /// modification-date change, so a same-length rewrite isn't trashed as untouched.
    ///
    /// **A shallow `.directory` misses a child replaced by one of the same name, and any edit inside
    /// a child**, answering `.unchanged` for what it didn't check. The depth is chosen where the
    /// identity is recorded: the copy-undo and every Trash backup (`FileSyncManager.backupIdentity`)
    /// record deep, since a wrong answer destroys an edit; moves and delete-undo restores record
    /// shallow, since the item travels rather than being destroyed (`FileSyncManager+Undo.swift`).
    /// `drift` re-reads at the recorded depth; a path no longer a directory is just `.changed`.
    static func compare(recorded: ItemIdentity, current: ItemIdentity) -> DriftVerdict {
        if recorded == .indeterminate || current == .indeterminate { return .indeterminate }
        return recorded == current ? .unchanged : .changed
    }

    /// `compare(recorded: self, current: <re-read>)`, the form a guard reads best in. Re-read the way
    /// the recording was taken (each deep case by its own deep read, everything else by `snapshot`),
    /// so a deep recording is never held to a shallow answer, which would refuse every untouched
    /// folder.
    func drift(at url: URL, fileManager fm: FileManaging) -> DriftVerdict {
        let current: ItemIdentity
        switch self {
        case .directoryTree:
            current = ItemIdentity.deepSnapshot(at: url, fileManager: fm)
        case .directoryTreeAndFileNumber:
            current = ItemIdentity.deepSnapshotWithFileNumber(at: url, fileManager: fm)
        case .directoryFileNumber:
            // The number alone, by a stat: the contents weren't readable when recorded and need
            // not be now. Not a directory, or gone, is `.changed`; a failed stat is `.indeterminate`.
            current = ItemIdentity.directoryFileNumber(at: url, fileManager: fm)
                .map(ItemIdentity.directoryFileNumber) ?? ItemIdentity.snapshot(at: url, fileManager: fm)
        default:
            current = ItemIdentity.snapshot(at: url, fileManager: fm)
        }
        return ItemIdentity.compare(recorded: self, current: current)
    }
}
