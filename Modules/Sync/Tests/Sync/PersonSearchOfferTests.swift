import Testing
import Foundation
@testable import Sync

/// When ⌘F's query names somebody.
@Suite struct PersonSearchOfferTests {

    private static var registry: PersonRegistry {
        PersonRegistry(people: [
            Person(id: "father", displayName: "Father", fullNames: ["Father Elder"]),
            Person(id: "daughter", displayName: "Daughter", fullNames: ["Daughter Father"]),
            Person(id: "mother", displayName: "Mother", fullNames: ["Mother Maiden"]),
            Person(id: "elder", displayName: "Elder", fullNames: ["Elder Forebear"],
                   aliases: ["Dad"]),
            Person(id: "granny", displayName: "Granny", fullNames: ["Granny Elder"],
                   aliases: ["Mom"]),
        ])
    }

    private func offer(_ q: String) -> Person? {
        PersonSearchOffer.person(matching: q, registry: Self.registry)
    }

    @Test func aNameOffersThatPerson() {
        #expect(offer("daughter")?.id == "daughter")
        #expect(offer("  Daughter  ")?.id == "daughter", "the query is trimmed before it is matched")
        #expect(offer("maiden")?.id == "mother", "a unique surname names her too")
        #expect(offer("mom")?.id == "granny", "an alias is a name")
    }

    @Test func aPhraseSpendsItsSharedWordOnTheRightPerson() {
        // The trap this household's names set: `father` is his first name and three other
        // people's surname. Phrase-first means the full name resolves to the daughter alone.
        #expect(offer("daughter father")?.id == "daughter")
        #expect(offer("granny elder")?.id == "granny")
    }

    @Test func aQueryNamingTwoPeopleOffersNobody() {
        // Not a person scope. Picking one of two arbitrarily is exactly the over-attribution the
        // registry refuses to do, arriving through a search field instead.
        #expect(offer("daughter mother") == nil)
        #expect(offer("mother granny") == nil)
        // Both halves are real names in this roster — a fixture naming somebody absent would
        // resolve to one person and pass for the wrong reason, which is how the first cut of this
        // test read ("daughter son", with no Son in the registry).
        #expect(offer("daughter")?.id == "daughter")
        #expect(offer("mother")?.id == "mother")
    }

    @Test func aQueryNamingNobodyLeavesTheFindAlone() {
        // The property that makes this safe on a control people already use: no offer, and the
        // substring search underneath is untouched.
        #expect(offer("invoice") == nil)
        #expect(offer("2024") == nil)
        #expect(offer("") == nil)
        #expect(offer("   ") == nil)
    }

    @Test func theTokenizerOwnsWhitespaceAndSingleCharacters() {
        // Asserted as behaviour of the whole, not as a guard in `PersonSearchOffer` — it has none.
        // `PersonRegistry.words` discards whitespace and skips words under two characters, which
        // is why "Mother I Maiden" does not make `R` a name. An earlier cut duplicated both rules
        // here and neither could fail a mutation, because the tokenizer was already doing the work.
        #expect(offer("a") == nil)
        #expect(offer("R") == nil)
        #expect(offer("  Daughter  ")?.id == "daughter")
    }

    @Test func aBareSharedWordStillOffersThePersonItNames() {
        // Deliberately NOT excluded. `elder` is Dad's first name and also two other people's
        // surname, but it resolves to exactly one person, so typing your father's name has to
        // offer him. What a shared word cannot do is attribute a FILE on its own — a different
        // question, answered in `PersonFiles`, where the same word gave 204 false rows.
        #expect(offer("elder")?.id == "elder")
        #expect(offer("father")?.id == "father")
    }
}
