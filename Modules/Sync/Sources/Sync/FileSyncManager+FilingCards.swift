import Foundation

/// A card's place in To File's list when it left it: where it goes back on Undo.
public struct FilingCardPosition: Sendable, Equatable {
    public let index: Int
    public let suggestion: FilingSuggestion
    public init(index: Int, suggestion: FilingSuggestion) { self.index = index; self.suggestion = suggestion }
}

extension FileSyncManager {
    /// Where each of `ids` stands in the list now, for putting it back later.
    public func filingCardPositions(_ ids: Set<String>) -> [FilingCardPosition] {
        filingSuggestions.enumerated().compactMap { i, s in ids.contains(s.id) ? FilingCardPosition(index: i, suggestion: s) : nil }
    }

    /// Puts cards back where they stood, skipping any the list already shows: an Undo of a filing,
    /// a Set Aside or a Move to Trash. Front to back, so each lands at its old index.
    public func restoreFilingCards(_ cards: [FilingCardPosition]) {
        let shown = Set(filingSuggestions.map(\.id))
        for card in cards.sorted(by: { $0.index < $1.index }) where !shown.contains(card.suggestion.id) {
            filingSuggestions.insert(card.suggestion, at: min(card.index, filingSuggestions.count))
        }
    }
}
