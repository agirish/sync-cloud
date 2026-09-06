import Foundation

/// The order a roster is shown in when nobody has arranged it by hand.
///
/// **By relationship, not by name.** An alphabetical list put a daughter first and the person
/// whose Mac this is fifth, which is the wrong way round for a list that exists to answer "whose
/// document is this": the reader's own record is the one they check first, then the people
/// closest to them. The tiers are the ones asked for, in that order — yourself, spouse, children,
/// parents, siblings, then everyone else — and inside a tier the names are alphabetical so two
/// children do not reshuffle between launches.
///
/// **Only until somebody moves a row.** `PeopleStore.orderIsCustom` records that the user has
/// arranged the list themselves, and from then on the file's order is the order; this rule is the
/// default, not a constraint. A relationship this cannot place — a friend, an in-law, a colleague,
/// nothing at all — lands in the last tier, which is also where a work profile's roster would sit
/// entirely, and that is fine: the rule costs nothing there and the user can still arrange it.
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

    /// Words that take a relationship OUT of the tier its other words would place it in.
    ///
    /// "mother-in-law" says `mother`, and is not a parent; "step son" says `son`. The tiers are the
    /// user's own household — parents are *their* parents — so anything qualified is everyone else.
    /// A single-word qualification ("grandmother", "stepson") never matches a tier word in the
    /// first place and needs no entry here.
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
