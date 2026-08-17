//
//  ItemIdentity.swift
//  SyncCloud
//

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
    /// A directory. `childCount` is its number of immediate children — see `compare` for exactly
    /// what this can and cannot notice.
    case directory(modified: Date?, childCount: Int)
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
    /// Costs one `attributesOfItem` for a file, plus one shallow directory listing for a folder.
    /// That is the same order of cost as the size snapshot it replaces, and cheap enough to take
    /// at registration time (where it already is) and again at undo time.
    static func snapshot(at url: URL, fileManager fm: FileManaging) -> ItemIdentity {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else {
            // attributesOfItem throws for both "not there" and "there but unreadable", and those
            // must not collapse: absent is a fact, unreadable is an unknown.
            return fm.fileExists(atPath: url.path) ? .indeterminate : .absent
        }

        if (attrs[.type] as? FileAttributeType) == .typeDirectory {
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

    /// Compares a recorded identity against what is on disk now.
    ///
    /// **What this notices.** For a file: any size change, and any modification-date change —
    /// including a same-length rewrite, which a size-only comparison misses and which is exactly
    /// how an edited copy gets trashed by an undo. `attributesOfItem` already returns the date in
    /// the same call the size comes from, so the stronger check costs nothing.
    ///
    /// **What this does not notice.** For a directory it compares the folder's own modification
    /// date and its immediate child count. That covers a child being added, removed or replaced —
    /// the reported hazard, where files land in a copied folder between the copy and the undo. It
    /// does NOT cover an edit made deep inside an untouched subtree, which leaves both values
    /// identical. Detecting that means walking the tree, and the honest position is that this
    /// answers `.unchanged` for a case it did not really check. A caller that needs more must say
    /// so; a caller that needs *any* guard is currently getting none.
    static func compare(recorded: ItemIdentity, current: ItemIdentity) -> DriftVerdict {
        if recorded == .indeterminate || current == .indeterminate { return .indeterminate }
        return recorded == current ? .unchanged : .changed
    }

    /// `compare(recorded: self, current: snapshot(at:))` — the form a guard reads best in.
    func drift(at url: URL, fileManager fm: FileManaging) -> DriftVerdict {
        ItemIdentity.compare(recorded: self, current: ItemIdentity.snapshot(at: url, fileManager: fm))
    }
}
