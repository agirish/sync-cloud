import Foundation

/// A color a card can take: one of a fixed few, each drawn by the panel in a shade tuned for
/// light and for dark. A fixed set and not a color picker, so no choice can make a card's title
/// hard to read.
public enum VaultTint: String, CaseIterable, Codable, Sendable {
    case blue, teal, green, olive, clay, rose, plum, violet

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// What was chosen for a group or a card: a tint, or to have none.
public enum VaultCardColor: Hashable, Sendable {
    case tint(VaultTint)
    /// No color: the card is drawn in the window's own hue, as every card was before colors.
    case plain

    /// How it is stored: the tint's name, or "plain".
    public var key: String {
        switch self {
        case .tint(let tint): return tint.rawValue
        case .plain: return "plain"
        }
    }

    public init?(key: String) {
        if key == "plain" {
            self = .plain
        } else if let tint = VaultTint(rawValue: key) {
            self = .tint(tint)
        } else {
            return nil
        }
    }
}

/// Which card is drawn in which color, so a kind can be found by its tint.
///
/// A card follows its group's color unless it was given one of its own: the cards are packed into
/// columns, which scatters a group's kinds, and one color per group ties them back together. Color
/// says which kind and nothing else; whose an ID is and whether it has run out have their own marks.
///
/// Kept in UserDefaults beside the groups: the names of groups, kinds and colors, never an ID.
public struct VaultColors: Equatable, Sendable {
    /// Whether cards are colored at all. Off draws every card as before colors.
    public var isOn = true
    /// A group's color, where it is not the app's.
    public var groups: [VaultGroups.ID: VaultCardColor] = [:]
    /// A card's own color, by ``VaultCardID/key``. A card without one follows its group.
    public var cards: [String: VaultCardColor] = [:]

    public init(isOn: Bool = true, groups: [VaultGroups.ID: VaultCardColor] = [:], cards: [String: VaultCardColor] = [:]) {
        self.isOn = isOn
        self.groups = groups
        self.cards = cards
    }

    /// The colors the app's groups start with.
    public static let appGroups: [VaultGroups.ID: VaultTint] = [
        "travel": .blue, "legal": .violet, "health": .rose, "home": .green, "contact": .clay,
    ]

    /// What a group is set to: the choice made for it, else the app's, else none.
    public func color(ofGroup id: VaultGroups.ID) -> VaultCardColor {
        groups[id] ?? Self.appGroups[id].map(VaultCardColor.tint) ?? .plain
    }

    /// The color chosen for this card alone, if one was.
    public func own(_ card: VaultCardID) -> VaultCardColor? { cards[card.key] }

    /// The tint a group's chip is drawn in; nil for none, and for every group while colors are off.
    public func tint(ofGroup id: VaultGroups.ID) -> VaultTint? {
        guard isOn, case .tint(let tint) = color(ofGroup: id) else { return nil }
        return tint
    }

    /// The tint a card is drawn in: its own, else its group's. Nil draws it in the window's hue:
    /// colors are off, or it (or its group) was set to none.
    public func tint(of card: VaultCardID, kinds: VaultKinds, groups: VaultGroups) -> VaultTint? {
        guard isOn else { return nil }
        let color = own(card) ?? kinds.group(of: card, in: groups).map(color(ofGroup:)) ?? .plain
        guard case .tint(let tint) = color else { return nil }
        return tint
    }

    /// Lets go of the colors of kinds the household no longer keeps, so a kind made later under
    /// another name does not come up already colored.
    public mutating func prune(keeping kinds: VaultKinds) {
        cards = cards.filter { key, _ in VaultCardID(key: key).map(kinds.exists) ?? false }
    }

    // MARK: UserDefaults

    static let offKey = "vaultCardColorsOff"
    static let groupsKey = "vaultGroupColors"
    static let cardsKey = "vaultCardColors"

    /// The saved colors over the app's. A color this build does not know is as if never chosen.
    public static func load(from defaults: UserDefaults) -> VaultColors {
        func read(_ key: String) -> [String: VaultCardColor] {
            (defaults.dictionary(forKey: key) as? [String: String] ?? [:]).compactMapValues(VaultCardColor.init(key:))
        }
        return VaultColors(isOn: !defaults.bool(forKey: offKey),
                           groups: read(groupsKey).filter { appGroups[$0.key] != nil },
                           cards: read(cardsKey).filter { VaultCardID(key: $0.key) != nil })
    }

    /// Saves what differs from the app's, so a default changed in a later build reaches a
    /// household that never chose otherwise.
    public func save(to defaults: UserDefaults) {
        if isOn { defaults.removeObject(forKey: Self.offKey) } else { defaults.set(true, forKey: Self.offKey) }
        let groups = self.groups.filter { Self.appGroups[$0.key].map(VaultCardColor.tint) != $0.value }.mapValues(\.key)
        let cards = self.cards.mapValues(\.key)
        if groups.isEmpty { defaults.removeObject(forKey: Self.groupsKey) } else { defaults.set(groups, forKey: Self.groupsKey) }
        if cards.isEmpty { defaults.removeObject(forKey: Self.cardsKey) } else { defaults.set(cards, forKey: Self.cardsKey) }
    }
}

/// The Color choice for one card: two separate questions, the card's own color and its group's.
///
/// A card follows its group until it is given a color of its own; the group's color then still
/// reaches the group's other cards. Showing the two apart is what says which one a pick changes.
public struct VaultColorChoice: Equatable, Sendable {
    public var card: VaultCardID
    /// The card's name: "Passports".
    public var title: String
    /// The color chosen for this card alone; nil follows its group.
    public var own: VaultCardColor?
    /// The group the card is listed under; nil for a card with none, which has only its own color.
    public var group: VaultGroups.ID?
    public var groupName: String?
    /// What the group is set to.
    public var groupColor: VaultCardColor?
    /// The group's other cards that follow it, by name: what a change to the group also recolors.
    public var others: [String]
    /// Card colors as a whole (Customize Groups).
    public var isOn: Bool

    public init(card: VaultCardID, title: String, own: VaultCardColor?, group: VaultGroups.ID?, groupName: String?,
                groupColor: VaultCardColor?, others: [String], isOn: Bool) {
        self.card = card
        self.title = title
        self.own = own
        self.group = group
        self.groupName = groupName
        self.groupColor = groupColor
        self.others = others
        self.isOn = isOn
    }

    /// Under the group's colors, who a change reaches: this card when it follows the group, and
    /// the group's other cards that do.
    public var reach: String {
        let names = (own == nil ? [title] : []) + others
        let list = ListFormatter.localizedString(byJoining: names)
        switch (own == nil, names.isEmpty) {
        case (_, true): return "\(title) has its own color, and no other card is in this group."
        case (true, _): return "Colors \(list)."
        case (false, _): return "Colors \(list). \(title) has its own."
        }
    }
}
