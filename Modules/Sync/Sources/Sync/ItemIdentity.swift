//
//  ItemIdentity.swift
//  SyncCloud
//

import CryptoKit
import Foundation

/// Enough of an item's on-disk state to tell later whether it is still the item an operation
/// produced — for folders as well as files.
///
/// The existing snapshot for this job, `FileSyncManager.fileSizeSnapshot`, is an `Int?` whose nil
/// means four different things: it is a directory, it is missing, it could not be statted, or the
/// size is unreadable. Its call sites then guard with `if let expected = …`, so **nil skips the
/// check rather than falling back to a different one** — which is how undo of a copied FOLDER
/// came to have no drift guard at all. The type below has no value that can be silently skipped:
/// "I could not tell" is a case you have to handle, not an absence.
public enum ItemIdentity: Equatable, Sendable {
    /// A regular file. `modified` is nil only when the filesystem did not report one.
    case file(size: Int, modified: Date?)
    /// A directory, SHALLOWLY: `childCount` is its number of immediate children — see `compare`
    /// for exactly what this can and cannot notice. A caller whose wrong answer destroys data
    /// records `.directoryTree` instead, via `deepSnapshot`.
    case directory(modified: Date?, childCount: Int)
    /// A directory described by its RECURSIVE content: `contentDigest` is a SHA-256 over every
    /// descendant's (relative path, kind, size, modification date), so an edit at ANY depth —
    /// including a same-count, same-parent-date rewrite three levels down — changes the identity.
    /// `.directory` cannot see that case, and for the copy-undo "cannot see" meant "trashes the
    /// only instance of the edit"; this case is what that guard records. Produced only by
    /// `deepSnapshot`, and `drift` re-reads at the same depth it was recorded at.
    case directoryTree(contentDigest: String)
    /// A symbolic link, described by its OWN size and date, not its target's.
    ///
    /// Spelled out rather than folded into `.file` because `attributesOfItem` does not follow
    /// links — measured: a symlink pointing at a directory reports type `NSFileTypeSymbolicLink`
    /// and size 98, the link's own bytes. Folded in, a symlinked folder would arrive as an
    /// ordinary small file, quietly skipping the child-count check while looking like it had one,
    /// and a link swapped for a same-size file would read as unchanged.
    case symlink(size: Int, modified: Date?)
    /// Nothing is at the path.
    case absent
    /// Something is at the path but its state could not be read — an unstatable file, or a
    /// directory that could not be listed. Never treat this as "unchanged".
    case indeterminate
}

/// The answer to "is this still the item I recorded?" — with an explicit third value, because the
/// question genuinely has one and collapsing it into either yes or no is the defect this exists
/// to prevent.
public enum DriftVerdict: Equatable, Sendable {
    case unchanged
    case changed
    /// One side could not be read, so nothing can be concluded. A caller acting destructively must
    /// treat this as a refusal, not as `unchanged`.
    case indeterminate
}

public extension ItemIdentity {

    /// Reads the item at `url`.
    ///
    /// **A folder identity is not the same order of cost as the size snapshot it replaces, and a
    /// caller taking one per item in a batch has to account for that.** Measured on this machine:
    /// `attributesOfItem` on a directory is ~138 µs, a shallow listing of a 2,000-entry directory
    /// is ~4.4 ms — about 32× — and it scales with the entry count while the stat does not. For a
    /// file the cost is unchanged: one `attributesOfItem`, with the modification date riding along
    /// in the same call as the size.
    ///
    /// That lands at registration time rather than undo time — the registration sites snapshot
    /// every item up front — so a batch of many large folders pays a listing each. The MOVE
    /// registrations take that shallow listing synchronously on the main actor;
    /// `registerCopyUndo` pays a RECURSIVE one, via `deepSnapshot`, and pays it in a detached
    /// walk precisely because recursive-on-main froze the UI for the length of the tree (see its
    /// own cost note). Taking folder identities lazily, or off the main actor, is a decision for
    /// the call site; this type does not make it.
    static func snapshot(at url: URL, fileManager fm: FileManaging) -> ItemIdentity {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else {
            // attributesOfItem throws for both "not there" and "there but unreadable", and those
            // must not collapse: absent is a fact, unreadable is an unknown.
            return fm.fileExists(atPath: url.path) ? .indeterminate : .absent
        }

        let type = attrs[.type] as? FileAttributeType

        // Before the directory test, because attributesOfItem does NOT follow links: a symlink to
        // a directory reports as a link, not as the directory it points at.
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
                // A shallow listing cannot be partial, so the second case is unreachable here
                // today; it is spelled out rather than defaulted so that if this ever lists
                // recursively, the choice has to be made again deliberately.
                return .directory(modified: attrs[.modificationDate] as? Date,
                                  childCount: listing.urls.count)
            }
        }

        let size = (attrs[.size] as? NSNumber)?.intValue ?? (attrs[.size] as? Int)
        guard let size else { return .indeterminate }
        return .file(size: size, modified: attrs[.modificationDate] as? Date)
    }

    /// Reads the item at `url`, describing a directory by its RECURSIVE content rather than by its
    /// own date and immediate child count. For anything that is not a directory this is exactly
    /// `snapshot`; for a directory it answers `.directoryTree` — or `.indeterminate` the moment
    /// any part of the tree could not be read, because a partial walk cannot prove a tree is still
    /// what it was.
    ///
    /// **Cost.** One recursive walk, stat-only — no file's bytes are ever read. The duplicates
    /// path already accepts exactly this trade (`folderDriftedInPlace`: "one recursive walk per
    /// folder copy, at the moment of a destructive click — the alternative is trashing the last
    /// copy of 1,200 photos to save it"), and both moments this runs at are the same shape: at
    /// copy-undo REGISTRATION the copy has just finished, so the tree's metadata is warm, and at
    /// undo/redo VERIFICATION the user has just clicked something destructive.
    ///
    /// **What goes into the digest.** One line per descendant, holding its relative path, its
    /// kind, and for files and symlinks its size and modification date (millisecond precision —
    /// APFS keeps more, and a whole millisecond cannot be lost to Double rounding). Directory
    /// entries carry path and kind only: their membership IS their content here, their dates
    /// would re-state changes the children's own lines already carry, and a directory date that
    /// moves with no line moving is exactly the perturbation the move-redo had to design around.
    ///
    /// **Symlinks are described as themselves, never followed** — `attributesOfItem` does not
    /// traverse, and the enumerator does not descend into a linked directory — so a dangling link
    /// does not fail the walk, and a link swapped for another target changes the identity (its
    /// own size and date move). Same convention `snapshot` states for the top-level item.
    ///
    /// **What Finder and tooling scribble inside the copy is not part of its identity.** The walk
    /// skips every entry carrying a `DuplicateFinderOptions.defaultIgnoredNames` component — the
    /// named entry AND its whole subtree — which is the convention the duplicates gate already
    /// walks under, adopted for the same lesson: counting `.DS_Store` "refused every folder ever
    /// opened in Finder, forever". Digested here, the first Finder visit to a copied folder would
    /// change its recorded identity and ⌘Z would refuse an untouched copy for as long as the undo
    /// lived. An ignored entry is skipped BEFORE it is statted, so an unstatable `.DS_Store`
    /// cannot refuse either. The deliberate residual: the listing's OUTCOME is decided before any
    /// name is filtered, so a descendant that cannot be descended into still answers
    /// `.indeterminate` even when it sits inside an ignored subtree — recorded at registration,
    /// that is a permanent refusal for that item. Refusal is the safe direction, and it is stated
    /// here rather than silent.
    ///
    /// **The digest is a function of the tree, not of the walk.** APFS promises no enumeration
    /// order, so the lines are sorted by the UTF-8 bytes of the relative path's precomposed form
    /// before hashing — deterministic across enumeration orders, volumes, and the two moments
    /// (registration and verification) whose answers must be comparable. Precomposed because APFS
    /// and HFS+ lookups are normalization-insensitive, so one on-disk name must not hash two ways
    /// depending on which spelling the enumerator reports — the rule, and why it lives behind a
    /// named seam, is at `canonicalDigestSpelling(ofRelativePath:)`.
    /// The one spelling `deepSnapshot` digests a descendant's relative path under, whatever form
    /// the walk reported it in. APFS and HFS+ lookups are normalization-insensitive but APFS
    /// storage is normalization-preserving, so one logical name can genuinely sit on disk in
    /// either Unicode form (a POSIX or SMB writer stores precomposed bytes; Foundation's path
    /// APIs write decomposed) — and the digest must not hash it two ways.
    ///
    /// A named seam rather than an inline call so the rule is PINNABLE: through `listing(of:)`
    /// every current pipeline happens to hand `deepSnapshot` the DECOMPOSED form regardless of
    /// what is on disk — `URL(fileURLWithPath:)` and `appendingPathComponent` both convert
    /// through the file-system representation, which decomposes (measured 2026-08-21, both
    /// directions probed) — so no fixture reachable through `deepSnapshot`'s public face can
    /// vary the spelling, and deleting this precomposition passed every end-to-end test. That
    /// pipeline normalization is incidental and undocumented, which is exactly why the rule
    /// stays and why `DeepFolderIdentityTests` asserts it here, at the seam, where a fixture can
    /// reach it.
    internal static func canonicalDigestSpelling(ofRelativePath rel: String) -> String {
        rel.precomposedStringWithCanonicalMapping
    }

    static func deepSnapshot(at url: URL, fileManager fm: FileManaging) -> ItemIdentity {
        let shallow = snapshot(at: url, fileManager: fm)
        guard case .directory = shallow else { return shallow }

        // `options: []` is the recursive walk. `.listedWithUnreadableDescendants` is a real but
        // PARTIAL answer, and partial proves nothing about the part that was withheld — the same
        // refusal `folderDriftedInPlace` makes of it, and the safe direction: `.indeterminate`
        // REFUSES the undo rather than authorising it.
        let listing = fm.listing(of: url, options: [])
        guard listing.outcome == .listed else { return .indeterminate }

        let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
        var lines: [String] = []
        lines.reserveCapacity(listing.urls.count)
        for child in listing.urls {
            let rel = child.path.hasPrefix(prefix)
                ? String(child.path.dropFirst(prefix.count)) : child.path
            // The ignored-names skip, per the doc above: a component match covers both the named
            // entry itself and everything below it, and it runs before the stat so an ignored
            // entry can neither shift the digest nor refuse the walk.
            if rel.split(separator: "/").contains(
                where: { DuplicateFinderOptions.defaultIgnoredNames.contains(String($0)) }) {
                continue
            }
            // An entry the walk just listed but cannot stat means the tree is being modified (or
            // withheld) under our feet — nothing can be concluded, so nothing may be destroyed.
            guard let attrs = try? fm.attributesOfItem(atPath: child.path) else { return .indeterminate }
            let canonicalRel = canonicalDigestSpelling(ofRelativePath: rel)
            let type = attrs[.type] as? FileAttributeType
            if type == .typeDirectory {
                lines.append("\(canonicalRel)\u{0}d")
                continue
            }
            let kind = type == .typeSymbolicLink ? "l" : "f"
            guard let size = (attrs[.size] as? NSNumber)?.intValue ?? (attrs[.size] as? Int) else {
                return .indeterminate
            }
            let millis = (attrs[.modificationDate] as? Date)
                .map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? "-"
            lines.append("\(canonicalRel)\u{0}\(kind)\u{0}\(size)\u{0}\(millis)")
        }
        // Byte order of the canonical form, not Swift's `<`: String comparison is defined over
        // canonical equivalence, which is deterministic but harder to reason about than bytes,
        // and the property this buys is that two walks of one tree serialize identically.
        lines.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        // The scheme marker means a rule change makes old and new digests DIFFER (a refusal)
        // rather than collide — same practice as `ContentFingerprint.scheme`. "tree-2": tree-1
        // digested every entry; the ignored-names skip above changed what serializes.
        let canonical = "tree-2\n" + lines.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return .directoryTree(contentDigest: digest.map { String(format: "%02x", $0) }.joined())
    }

    /// Compares a recorded identity against what is on disk now.
    ///
    /// **What this notices.** For a file: any size change, and any modification-date change —
    /// including a same-length rewrite, which a size-only comparison misses and which is exactly
    /// how an edited copy gets trashed by an undo. `attributesOfItem` already returns the date in
    /// the same call the size comes from, so the stronger check costs nothing.
    ///
    /// **What a SHALLOW directory identity does not notice.** `.directory` compares the folder's
    /// own modification date and its immediate child count. That covers a child being added,
    /// removed or replaced — but NOT an edit made deep inside an untouched subtree, which leaves
    /// both values identical, so for that pairing this answers `.unchanged` for a case it did not
    /// really check. `.directoryTree` exists for the caller that cannot afford that: its digest
    /// covers every descendant, so the deep edit IS checked. Which depth a guard gets is decided
    /// where the identity is RECORDED — the copy-undo records deep because its wrong answer
    /// trashes the only instance of an edit; the move paths record shallow deliberately, and say
    /// why at their registration sites in `FileSyncManager+Undo.swift`.
    ///
    /// A recorded depth is also re-read at that depth (`drift` dispatches on the recorded case),
    /// so the two sides of this comparison always describe the same question; a deep recording
    /// compared against a path that is no longer a directory at all is an ordinary `.changed`.
    static func compare(recorded: ItemIdentity, current: ItemIdentity) -> DriftVerdict {
        if recorded == .indeterminate || current == .indeterminate { return .indeterminate }
        return recorded == current ? .unchanged : .changed
    }

    /// `compare(recorded: self, current: <re-read>)` — the form a guard reads best in. The
    /// re-read happens at the depth the recording was taken at: a `.directoryTree` is compared
    /// against a fresh `deepSnapshot`, everything else against a fresh `snapshot`, so a guard
    /// cannot accidentally hold a deep recording to a shallow answer (which would read `.changed`
    /// for every untouched folder — a guard that refuses everything is not a guard).
    func drift(at url: URL, fileManager fm: FileManaging) -> DriftVerdict {
        let current: ItemIdentity
        if case .directoryTree = self {
            current = ItemIdentity.deepSnapshot(at: url, fileManager: fm)
        } else {
            current = ItemIdentity.snapshot(at: url, fileManager: fm)
        }
        return ItemIdentity.compare(recorded: self, current: current)
    }
}
