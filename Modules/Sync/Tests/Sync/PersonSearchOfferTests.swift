import Testing
import Foundation
@testable import Sync

/// When ⌘F's query names somebody.
@Suite struct PersonSearchOfferTests {

    private static var registry: PersonRegistry {
        PersonRegistry(people: [
            Person(id: "abhishek", displayName: "Abhishek", fullNames: ["Abhishek Girish"]),
            Person(id: "aditi", displayName: "Aditi", fullNames: ["Aditi Abhishek"]),
            Person(id: "shweta", displayName: "Shweta", fullNames: ["Shweta Dani"]),
            Person(id: "girish", displayName: "Girish", fullNames: ["Girish Krishnamurthy"],
                   aliases: ["Dad"]),
            Person(id: "muktha", displayName: "Muktha", fullNames: ["Muktha Girish"],
                   aliases: ["Mom"]),
        ])
    }

    private func offer(_ q: String) -> Person? {
        PersonSearchOffer.person(matching: q, registry: Self.registry)
    }

    @Test func aNameOffersThatPerson() {
        #expect(offer("aditi")?.id == "aditi")
        #expect(offer("  Aditi  ")?.id == "aditi", "the query is trimmed before it is matched")
        #expect(offer("dani")?.id == "shweta", "a unique surname names her too")
        #expect(offer("mom")?.id == "muktha", "an alias is a name")
    }

    @Test func aPhraseSpendsItsSharedWordOnTheRightPerson() {
        // The trap this household's names set: `abhishek` is his first name and three other
        // people's surname. Phrase-first means the full name resolves to the daughter alone.
        #expect(offer("aditi abhishek")?.id == "aditi")
        #expect(offer("muktha girish")?.id == "muktha")
    }

    @Test func aQueryNamingTwoPeopleOffersNobody() {
        // Not a person scope. Picking one of two arbitrarily is exactly the over-attribution the
        // registry refuses to do, arriving through a search field instead.
        #expect(offer("aditi shweta") == nil)
        #expect(offer("shweta muktha") == nil)
        // Both halves are real names in this roster — a fixture naming somebody absent would
        // resolve to one person and pass for the wrong reason, which is how the first cut of this
        // test read ("aditi divit", with no Divit in the registry).
        #expect(offer("aditi")?.id == "aditi")
        #expect(offer("shweta")?.id == "shweta")
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
        // is why "Shweta R Dani" does not make `R` a name. An earlier cut duplicated both rules
        // here and neither could fail a mutation, because the tokenizer was already doing the work.
        #expect(offer("a") == nil)
        #expect(offer("R") == nil)
        #expect(offer("  Aditi  ")?.id == "aditi")
    }

    @Test func aBareSharedWordStillOffersThePersonItNames() {
        // Deliberately NOT excluded. `girish` is Dad's first name and also two other people's
        // surname, but it resolves to exactly one person, so typing your father's name has to
        // offer him. What a shared word cannot do is attribute a FILE on its own — a different
        // question, answered in `PersonFiles`, where the same word gave 204 false rows.
        #expect(offer("girish")?.id == "girish")
        #expect(offer("abhishek")?.id == "abhishek")
    }
}
