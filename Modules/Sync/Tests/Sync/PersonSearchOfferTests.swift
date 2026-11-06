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
        // `father` is his first name and three other people's surname. Phrase-first means the
        // full name resolves to the daughter alone.
        #expect(offer("daughter father")?.id == "daughter")
        #expect(offer("granny elder")?.id == "granny")
    }

    @Test func aQueryNamingTwoPeopleOffersNobody() {
        // Not a person scope: picking one of two arbitrarily is the over-attribution the registry
        // refuses everywhere else.
        #expect(offer("daughter mother") == nil)
        #expect(offer("mother granny") == nil)
        // Both halves are real names in this roster: a name missing from it would leave one person
        // and pass for the wrong reason.
        #expect(offer("daughter")?.id == "daughter")
        #expect(offer("mother")?.id == "mother")
    }

    @Test func aQueryNamingNobodyLeavesTheFindAlone() {
        // What makes this safe on a control people already use: no offer, and the substring
        // search underneath is untouched.
        #expect(offer("invoice") == nil)
        #expect(offer("2024") == nil)
        #expect(offer("") == nil)
        #expect(offer("   ") == nil)
    }

    @Test func theTokenizerOwnsWhitespaceAndSingleCharacters() {
        // Behaviour of the whole: `PersonSearchOffer` has no guard of its own.
        // `PersonRegistry.words` discards whitespace and skips words under two characters, which
        // is why the `I` in "Mother I Maiden" is never a name.
        #expect(offer("a") == nil)
        #expect(offer("R") == nil)
        #expect(offer("  Daughter  ")?.id == "daughter")
    }

    @Test func aBareSharedWordStillOffersThePersonItNames() {
        // Deliberately not excluded: `elder` is two other people's surname but resolves to exactly
        // one person, so typing your father's name offers him. A shared word can't attribute a
        // file on its own, but that is `PersonFiles`'s question.
        #expect(offer("elder")?.id == "elder")
        #expect(offer("father")?.id == "father")
    }
}
