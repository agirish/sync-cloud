import Foundation

/// Whether a pane-search query names somebody, and is therefore worth offering as a person scope.
///
/// **The find stays a find.** This only ever *adds* an offer beneath the field; the substring search
/// underneath is untouched, runs on every query including this one, and is what ⇧↩ keeps. A query
/// that names nobody produces `nil` and the field behaves exactly as it did before this existed —
/// which is the property that makes the offer safe to put on a control people already use.
public enum PersonSearchOffer {

    /// The one person this query names, or `nil`.
    ///
    /// **Exactly one, or nothing.** A query that resolves to two people is not a person scope —
    /// "girish krishnamurthy muktha" names a couple, and picking one of them arbitrarily is the
    /// over-attribution this household's names invite. The matcher already refuses to guess: it is
    /// phrase-first and longest-wins, so "Aditi Abhishek" resolves to Aditi alone and spends the
    /// surname doing it.
    ///
    /// A bare shared word is *not* excluded here, and that is deliberate. `girish` resolves to one
    /// person — Dad, whose first name it is — so the offer appears and is correct; what the shared
    /// word cannot do is *attribute a file* on its own, which is a different question answered in
    /// ``PersonFiles``. Refusing the offer too would mean typing your father's name and being told
    /// nothing.
    ///
    /// **One rule, and it is the only one this type owns.** A first cut also trimmed the query and
    /// refused anything under two characters; mutation-testing showed neither guard could fail a
    /// test, because `PersonRegistry.words` already tokenizes — it discards whitespace and skips
    /// words shorter than two characters, which is why "Shweta R Dani" does not make `R` a name.
    /// Two owners for one rule is how they drift apart, so these defer to the tokenizer and this
    /// keeps the part that is genuinely its own: how many people a query may name.
    public static func person(matching query: String, registry: PersonRegistry) -> Person? {
        let ids = registry.detect(in: query)
        guard ids.count == 1, let id = ids.first else { return nil }
        return registry.people.first { $0.id == id }
    }
}
