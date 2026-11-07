import Design
import SwiftUI
import Sync

/// The Duplicates list, sectioned by what each finding asks of you.
///
/// Tiles of equal weight make a wall: a byte-for-byte pair one button removes would sit beside a
/// pair of same-named folders nothing can remove, at the same size and shape. So, as
/// ``RenameCategories`` does for renames, the list is sectioned by the operation, each section
/// carrying its own definition. ``order`` explains the order.
///
enum DuplicateSections {

    struct Section: Equatable {
        let kind: DuplicateMatchType.Kind
        let groups: [DuplicateGroup]
        var reclaimableBytes: Int { groups.reduce(0) { $0 + $1.reclaimableBytes } }
    }

    /// The one you can act on leads; everything below it needs a person.
    ///
    /// `identical` is first because it is the only kind `isRecommendedForBatch` admits: the
    /// header's "Apply N recommended" is exactly this section, it carries the reclaim figure, and
    /// it is why most people open this lens. A screen that opened on the findings you must think
    /// about would bury it.
    ///
    /// The rest keep consequence order: a merge writes somewhere new, a same-text match is weaker
    /// than byte identity (`DuplicateRemovalPrompt.informativeText` warns for that kind alone), and
    /// versions discard older content by a stated rule. Not `Kind.allCases`, whose declaration
    /// order means nothing.
    static let order: [DuplicateMatchType.Kind] = [.identical, .overlapping, .sameText,
                                                   .versions]

    /// The sections, in that order, present only when they have groups: a section that says "0" is
    /// chrome explaining an absence. Groups keep the order they arrive in (the lens sorts by
    /// reclaimable size), so sectioning regroups the list without re-ranking it.
    static func sections(_ groups: [DuplicateGroup]) -> [Section] {
        var buckets: [DuplicateMatchType.Kind: [DuplicateGroup]] = [:]
        for group in groups { buckets[group.matchType.kind, default: []].append(group) }
        return order.compactMap { kind in
            guard let members = buckets[kind], !members.isEmpty else { return nil }
            return Section(kind: kind, groups: members)
        }
    }

    /// The pill's word — what the section asks for. `identical` is the one kind that wears no
    /// badge on its cards (`DuplicateMatchStyle.badgeLabel` returns nil for it), so this is the
    /// only place its section is named.
    static func label(_ kind: DuplicateMatchType.Kind) -> String {
        switch kind {
        case .overlapping: return "to merge"
        case .sameText: return "to check"
        // Not a verb phrase like its neighbours: "versions" is the word the card's subtitle and the
        // confirmation dialog already use.
        case .versions: return "versions"
        case .identical: return "to remove"
        }
    }

    /// The section's tint, from the one place a match type's colour is decided
    /// (`DuplicateMatchStyle.color`), so a heading can't disagree with the badges under it. The
    /// representative type exists only for that lookup: `Kind` drops the overlap fraction, and the
    /// colour doesn't depend on it.
    static func tint(_ kind: DuplicateMatchType.Kind) -> Color {
        DuplicateMatchStyle.color(representative(kind))
    }

    static func representative(_ kind: DuplicateMatchType.Kind) -> DuplicateMatchType {
        switch kind {
        case .identical: return .identical
        case .sameText: return .sameText
        case .versions: return .versions
        case .overlapping: return .overlapping(sharedFraction: 1)
        }
    }

    /// The section's one line: what this kind of finding is, and what resolving it does.
    static func definition(_ kind: DuplicateMatchType.Kind) -> String {
        switch kind {
        case .overlapping:
            return "Folders sharing most of their contents. Merging copies the unique items into the keeper, then trashes the rest."
        case .sameText:
            return "Read the same, but the bytes differ — a signed or re-saved copy looks identical. Open both before removing."
        case .versions:
            return "A numbered or dated series. The newest is kept; the older ones go to the Trash."
        case .identical:
            return "Byte-for-byte copies. The only kind “Apply recommended” touches."
        }
    }
}
