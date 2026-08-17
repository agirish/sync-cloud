import Testing
@testable import Sync

/// What a `people.json` listing one id twice does to the roster.
///
/// The visible symptom was the Settings list drawing the first record twice — `ForEach` keys on
/// `Person.id`, so a repeated id is a repeated view identity. But the roster had **four** answers
/// to "which record is this id", and the list was only the one you could see:
///
/// | reader | answer, before |
/// |---|---|
/// | `PeopleList`'s `ForEach` | the FIRST record, drawn twice |
/// | `PeopleStore.person(id:)` | the FIRST record |
/// | `PeopleList.allFacts` | the LAST record |
/// | `PersonRegistry.strong` (tokens) | the LAST record |
/// | `PersonRegistry.phrases` | BOTH records |
/// | `PersonRegistry.given` | **neither — the claim was dropped** |
///
/// So one row could show the first record's name above the last record's facts. The fix is a
/// single door: `PersonRegistry.init(people:)` reduces to one record per id before it builds
/// anything, so every reader below inherits the same answer.
@Suite struct PersonRegistryDuplicateIdTests {

    private static func person(_ id: String, _ display: String,
                               fullNames: [String] = [], aliases: [String] = [],
                               relationship: String? = nil) -> Person {
        Person(id: id, displayName: display, relationship: relationship,
               fullNames: fullNames, aliases: aliases)
    }

    // MARK: The rule

    @Test func aRepeatedIdCollapsesToOneRecord() {
        let registry = PersonRegistry(people: [
            Self.person("girish", "Girish One", fullNames: ["Girish One"]),
            Self.person("muktha", "Muktha", fullNames: ["Muktha Girish"]),
            Self.person("girish", "Girish Two", fullNames: ["Girish Two"]),
        ])
        // The premise: without this the whole suite proves nothing, because a roster that never
        // held a duplicate cannot show one being resolved.
        #expect(registry.people.count == 2, "the duplicate was not collapsed")
        #expect(registry.people.map(\.id) == ["girish", "muktha"],
                "the surviving record moved: the first occurrence's position is what orders the roster")
    }

    @Test func theLastRecordWins() {
        let registry = PersonRegistry(people: [
            Self.person("girish", "Girish One", relationship: "self"),
            Self.person("girish", "Girish Two", relationship: "father"),
        ])
        let kept = try? #require(registry.people.first)
        // Named fields rather than record equality, so a future field cannot pass this by being
        // equal on both sides. Display and relationship differ between the two, deliberately.
        #expect(kept?.displayName == "Girish Two", "the FIRST record won, or the two were merged")
        #expect(kept?.relationship == "father")
    }

    @Test func theWinnerIsARecordAndNotAMergeOfBoth() {
        let registry = PersonRegistry(people: [
            Self.person("girish", "Girish One", fullNames: ["Girish One"], aliases: ["Gigi"]),
            Self.person("girish", "Girish Two", fullNames: ["Girish Two"]),
        ])
        let kept = try? #require(registry.people.first)
        #expect(kept?.fullNames == ["Girish Two"])
        #expect(kept?.aliases.isEmpty == true,
                "the loser's aliases came across — this is a pick, not a merge")
        // And the dropped record's names are really gone from matching, which is the cost of
        // picking. Stated as a test so the trade-off is recorded rather than discovered.
        //
        // Asserted on what was UNIQUE to the loser — its alias, and its phrase — because the two
        // records share the token "girish", which still matches and should: it belongs to the
        // surviving record too. `detect(in: "Girish One")` therefore returns the person either
        // way, and would have proved nothing about the merge.
        #expect(registry.detect(in: "Scan from Gigi.pdf").isEmpty,
                "an alias only the dropped record carried still matches — something merged")
        #expect(!registry.phrases.contains { $0.display == "Girish One" },
                "the dropped record's phrase is still registered")
        #expect(registry.phrases.contains { $0.display == "Girish Two" },
                "the surviving record lost its own phrase, so the assertion above proves nothing")
    }

    @Test func anOrdinaryRosterIsUntouched() {
        let people = [Self.person("girish", "Girish", fullNames: ["Girish Rao"]),
                      Self.person("muktha", "Muktha", fullNames: ["Muktha Girish"])]
        let registry = PersonRegistry(people: people)
        #expect(registry.people.map(\.id) == people.map(\.id))
        #expect(registry.people.map(\.displayName) == people.map(\.displayName))
    }

    // MARK: The consequence nothing could have shown

    /// A person listed twice claimed their own given name twice, and `given` publishes a token
    /// only when exactly ONE id claims it — so the duplicate disabled the very matching the second
    /// entry looked like it was reinforcing.
    ///
    /// The fixture has to reach `given` specifically, and `given` publishes a token only when
    /// **more than one person owns it** and **exactly one claims it as their given name** — so a
    /// simple pair of namesakes does not exercise it at all: a token only one person owns is
    /// answered by `strong` long before `given` is consulted. (My first fixture here was that
    /// pair, and the premise assertion below is what caught it.)
    ///
    /// The shape that does reach it is this household's own: a surname that is also somebody's
    /// given name. "girish" is owned by Muktha, through "Muktha Girish", and by Girish; only
    /// Girish's display name *starts* with it, so his is the single claim that resolves it.
    @Test func aDuplicateNoLongerDisablesItsOwnGivenName() {
        let girish = Self.person("girish", "Girish Rao", fullNames: ["Girish Rao"])
        let muktha = Self.person("muktha", "Muktha Girish", fullNames: ["Muktha Girish"])

        // The premise. If this ever stops holding, the duplicate assertion below means nothing.
        let clean = PersonRegistry(people: [girish, muktha])
        #expect(clean.given["girish"] == "girish",
                "fixture: the given-name claim is not in play, so duplicating it proves nothing")
        #expect((clean.strong["girish"] ?? nil) == nil,
                "fixture: 'girish' is answered by `strong`, so `given` is never consulted")

        let duplicated = PersonRegistry(people: [girish, muktha, girish])
        #expect(duplicated.given["girish"] == "girish",
                "a repeated entry cancelled its own given-name claim")
        #expect(duplicated.detect(in: "Girish statement.pdf") == ["girish"])
    }

    @Test func aRepeatedIdKeepsItsTokensInTheStrongMap() {
        let registry = PersonRegistry(people: [
            Self.person("girish", "Girish", fullNames: ["Girish Kulkarni"]),
            Self.person("girish", "Girish", fullNames: ["Girish Kulkarni"]),
        ])
        #expect(registry.strong["kulkarni"] == "girish")
        #expect(registry.detect(in: "Kulkarni tax notice.pdf") == ["girish"])
    }

    /// The phrase list took every record, so a duplicated roster listed the same phrase twice and
    /// the matcher had two identical candidates to choose between for one person.
    @Test func aRepeatedIdIsNotPhraseMatchedTwice() {
        let registry = PersonRegistry(people: [
            Self.person("girish", "Girish", fullNames: ["Girish Kulkarni"]),
            Self.person("girish", "Girish", fullNames: ["Girish Kulkarni"]),
        ])
        #expect(registry.phrases.filter { $0.display == "Girish Kulkarni" }.count == 1,
                "the same phrase is registered twice for one person")
    }
}
