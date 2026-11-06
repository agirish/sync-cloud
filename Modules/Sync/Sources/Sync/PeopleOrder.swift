import Foundation

/// The order a roster is shown in when nobody has arranged it by hand.
///
/// By relationship, not by name: the list answers "whose document is this", so the reader's own
/// record comes first, then the people closest to them. Tiers: yourself, spouse, children,
/// parents, siblings, everyone else. Within a tier names are alphabetical, so two children don't
/// reshuffle between launches.
///
/// Only a default: once the user moves a row, `PeopleStore.orderIsCustom` is set and the file's
/// order wins. A relationship this can't place (friend, in-law, colleague, none) lands last.
public enum PeopleOrder {

    /// The tiers, in the order they are listed. `rawValue` is the sort key.
    public enum Tier: Int, CaseIterable, Sendable, Comparable {
        case yourself, spouse, children, parents, siblings, others

        public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    /// The words a relationship can use for each tier. Lowercase, one word each: a relationship is
    /// tokenised on the roster's own splitter before it is looked up, so "My wife" and "wife" both
    /// place, and case never matters.
    static let vocabulary: [Tier: Set<String>] = [
        .yourself: ["me", "self", "myself", "primary", "owner", "i"],
        .spouse: ["wife", "husband", "spouse", "partner", "fiancé", "fiancée", "fiance", "fiancee"],
        .children: ["son", "daughter", "child", "kid", "kids", "children"],
        .parents: ["mother", "father", "mom", "mum", "dad", "parent", "amma", "appa", "mama", "papa"],
        .siblings: ["brother", "sister", "sibling", "bro", "sis"],
    ]

    /// Words that take a relationship out of the tier its other words would place it in.
    /// "mother-in-law" says `mother` but is not the user's parent, so anything qualified is
    /// everyone else. One-word forms ("grandmother", "stepson") match no tier word and need no entry.
    static let qualifiers: Set<String> = ["law", "step", "grand", "half", "ex", "former", "late"]

    /// Where a relationship lands. `nil` and the unplaceable both land last.
    public static func tier(of relationship: String?) -> Tier {
        guard let relationship else { return .others }
        let words = Set(PersonRegistry.words(relationship))
        guard words.isDisjoint(with: qualifiers) else { return .others }
        for tier in Tier.allCases where tier != .others {
            if !words.isDisjoint(with: vocabulary[tier] ?? []) { return tier }
        }
        return .others
    }

    /// The roster in default order: by tier, then by display name within a tier.
    public static func arranged(_ people: [Person]) -> [Person] {
        people.sorted { a, b in
            let ta = tier(of: a.relationship), tb = tier(of: b.relationship)
            if ta != tb { return ta < tb }
            return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }
    }
}
