import Design
import SwiftUI
import Sync

/// The Duplicates list, sectioned by what each finding asks of you.
///
/// **88 tiles of equal weight is a wall, not a list.** His report on the grid: "still looks very
/// crowded". The tiles were correct and the count was the problem — a byte-for-byte pair that one
/// button removes and a pair of same-named folders that nothing can remove were the same size, the
/// same shape and adjacent, so the two findings that need a person were somewhere among eighty-six
/// that do not.
///
/// This is the move the rename backlog already made for the same reason (see ``RenameCategories``,
/// and the 132 near-identical rows it was built for): section by the OPERATION, each section
/// carrying its own definition. The order is ``order``'s to explain — the bulk you can clear in a
/// click leads, and everything under it needs a person.
///
enum DuplicateSections {

    struct Section: Equatable {
        let kind: DuplicateMatchType.Kind
        let groups: [DuplicateGroup]
        var reclaimableBytes: Int { groups.reduce(0) { $0 + $1.reclaimableBytes } }
    }

    /// **The one you can act on leads; everything below it needs a person.**
    ///
    /// `identical` is first because it is the only kind `isRecommendedForBatch` admits — the
    /// header's "Apply N recommended" is exactly this section, it carries the reclaim figure, and
    /// it is the reason most people open this lens. It was last, under a most-consequential-first
    /// rule borrowed from the rename backlog; his call, and the better one: a screen that opens on
    /// four findings you must think about, with the thirty-one you can clear in a click below the
    /// fold, buries its own answer.
    ///
    /// The rest keep consequence order under it — a merge writes somewhere new, a same-text match
    /// is weaker than byte identity (`DuplicateRemovalPrompt.informativeText` adds a warning
    /// sentence for that kind and no other), and versions discard older content by a stated rule.
    ///
    /// **Not `Kind.allCases`** — that order is the enum's declaration order, which is about
    /// nothing, and this order is a claim.
    static let order: [DuplicateMatchType.Kind] = [.identical, .overlapping, .sameText,
                                                   .versions]

    /// The sections, in that order, present only when they report — a section that says "0" is a
    /// row of chrome explaining an absence.
    ///
    /// Groups keep the order they arrive in (the lens sorts by reclaimable size), so sectioning
    /// re-groups the list without re-ranking it.
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
        // Not a verb phrase like its neighbours, deliberately: "versions" is the word the card's
        // own subtitle and the confirmation dialog already use, and matching them beats a
        // grammatical parallel invented here.
        case .versions: return "versions"
        case .identical: return "to remove"
        }
    }

    /// The section's tint, routed through the one place a match type's colour is decided
    /// (`DuplicateMatchStyle.color`) rather than restated here — a second copy of the palette is
    /// how a heading comes to disagree with the badges under it.
    ///
    /// The representative type exists only for that lookup: `Kind` drops the overlap fraction, and
    /// the colour does not depend on it.
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
