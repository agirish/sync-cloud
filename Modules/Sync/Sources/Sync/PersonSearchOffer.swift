import Foundation

/// Whether a pane-search query names somebody, and so is worth offering as a person scope.
///
/// The find stays a find: this only adds an offer beneath the field. The substring search still
/// runs on every query and keeps ↩ and ⇧↩; taking the offer is ⌘↩. A query that names nobody gives
/// `nil` and the field behaves as a plain find, which makes the offer safe on a control people
/// already use.
public enum PersonSearchOffer {

    /// The one person this query names, or `nil`.
    ///
    /// Exactly one, or nothing: a query naming two people ("elder forebear granny" names a couple)
    /// is not a person scope, and picking one would over-attribute. The matcher is phrase-first and
    /// longest-wins, so "Daughter Father" resolves to Daughter alone.
    ///
    /// A bare shared word is deliberately allowed: `elder` is Dad's first name, so the offer is
    /// right. Whether that word can attribute a file on its own is ``PersonFiles``'s question.
    ///
    /// Trimming and short words are left to `PersonRegistry.words`, which already drops whitespace
    /// and words under two characters; this type owns only how many people a query may name.
    public static func person(matching query: String, registry: PersonRegistry) -> Person? {
        let ids = registry.detect(in: query)
        guard ids.count == 1, let id = ids.first else { return nil }
        return registry.people.first { $0.id == id }
    }
}
