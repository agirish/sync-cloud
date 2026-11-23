import Foundation

/// One card as Cards and List draw it: a kind of ID with its rows, or a Contact card.
public enum VaultCardSlot: Identifiable, Sendable {
    case ids(VaultCardID, [VaultModel.Row])
    case contact(VaultContactCard)

    /// The card's fold key, shared with ``VaultModel/folded``.
    public var id: String {
        switch self {
        case .ids(let card, _): return card.key
        case .contact(let card): return VaultModel.foldKey(card.kind)
        }
    }

    /// How many rows it holds: what the card's count says, and what packs it in a column.
    public var count: Int {
        switch self {
        case .ids(_, let rows): return rows.count
        case .contact(let card): return card.items.count
        }
    }
}

/// A group's cards, in the groups' order: what Cards and List draw under the group's heading.
public struct VaultCardGroup: Identifiable, Sendable {
    public var id: VaultGroups.ID
    public var name: String
    public var slots: [VaultCardSlot]
    /// Every row in it.
    public var count: Int { slots.reduce(0) { $0 + $1.count } }
}

/// Where the arrow keys stop in Cards and List: an ID, or a Contact row.
public enum VaultWalkStop: Equatable, Sendable {
    case id(UUID)
    case contact(String)
}

extension VaultModel {
    /// The cards on screen, group by group in the groups' order, each group's ID cards first
    /// (``VaultKinds/order(by:)``) and Contact's own three in its place. A group with none is
    /// left out. Other Finds, sorted by name, is one group with no name.
    public var cardGroups: [VaultCardGroup] {
        let shown = cards
        let contacts = contactCards
        if tab == .other && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return shown.isEmpty ? [] : [VaultCardGroup(id: "", name: "", slots: shown.map { .ids($0.card, $0.rows) })]
        }
        var out: [VaultCardGroup] = []
        for id in groups.order {
            var slots: [VaultCardSlot] = shown.filter { kinds.group(of: $0.card, in: groups) == id }.map { .ids($0.card, $0.rows) }
            if id == VaultGroups.contact { slots += contacts.map { .contact($0) } }
            if !slots.isEmpty { out.append(VaultCardGroup(id: id, name: groups.name(id), slots: slots)) }
        }
        // A card whose group is not one of the groups (a later build's) comes last, never lost.
        let placed = Set(out.flatMap { $0.slots.map(\.id) })
        let rest = shown.filter { !placed.contains($0.card.key) }
        if !rest.isEmpty { out.append(VaultCardGroup(id: "", name: VaultCategory.other.title, slots: rest.map { .ids($0.card, $0.rows) })) }
        return out
    }

    /// Where the arrow keys stop, in the order drawn: in Cards and List every row of every card
    /// on screen, a folded card's passed over in Cards; in People, the IDs as drawn.
    public var walkStops: [VaultWalkStop] {
        guard layout != .people else { return walkOrder.map(VaultWalkStop.id) }
        return cardGroups.flatMap(\.slots).flatMap { slot -> [VaultWalkStop] in
            guard showsList || !folded.contains(slot.id) else { return [] }
            switch slot {
            case .ids(_, let rows): return rows.map { .id($0.id) }
            case .contact(let card): return card.items.map { .contact($0.id) }
            }
        }
    }

    /// Whether every card of a group on screen is folded.
    public func isFolded(group id: VaultGroups.ID) -> Bool {
        let keys = cardGroups.first { $0.id == id }?.slots.map(\.id) ?? []
        return !keys.isEmpty && keys.allSatisfy(folded.contains)
    }

    /// Folds a group's cards, or opens them when all are folded; with `all`, every card, as
    /// ⌥-click does, the way this group goes.
    public func toggleFold(group id: VaultGroups.ID, all: Bool = false) {
        let fold = !isFolded(group: id)
        if all {
            setFolded(fold ? Set(kinds.order.map(\.key)).union(Self.contactFoldKeys) : [])
        } else {
            let keys = Set(cardGroups.first { $0.id == id }?.slots.map(\.id) ?? [])
            setFolded(fold ? folded.union(keys) : folded.subtracting(keys))
        }
    }
}
