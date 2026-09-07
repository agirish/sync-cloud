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
            Self.person("elder", "Elder One", fullNames: ["Elder One"]),
            Self.person("granny", "Granny", fullNames: ["Granny Elder"]),
            Self.person("elder", "Elder Two", fullNames: ["Elder Two"]),
        ])
        // The premise: without this the whole suite proves nothing, because a roster that never
        // held a duplicate cannot show one being resolved.
        #expect(registry.people.count == 2, "the duplicate was not collapsed")
        #expect(registry.people.map(\.id) == ["elder", "granny"],
                "the surviving record moved: the first occurrence's position is what orders the roster")
    }

    @Test func theLastRecordWins() {
        let registry = PersonRegistry(people: [
            Self.person("elder", "Elder One", relationship: "self"),
            Self.person("elder", "Elder Two", relationship: "father"),
        ])
        let kept = try? #require(registry.people.first)
        // Named fields rather than record equality, so a future field cannot pass this by being
        // equal on both sides. Display and relationship differ between the two, deliberately.
        #expect(kept?.displayName == "Elder Two", "the FIRST record won, or the two were merged")
        #expect(kept?.relationship == "father")
    }

    @Test func theWinnerIsARecordAndNotAMergeOfBoth() {
        let registry = PersonRegistry(people: [
            Self.person("elder", "Elder One", fullNames: ["Elder One"], aliases: ["Gigi"]),
            Self.person("elder", "Elder Two", fullNames: ["Elder Two"]),
        ])
        let kept = try? #require(registry.people.first)
        #expect(kept?.fullNames == ["Elder Two"])
        #expect(kept?.aliases.isEmpty == true,
                "the loser's aliases came across — this is a pick, not a merge")
        // And the dropped record's names are really gone from matching, which is the cost of
        // picking. Stated as a test so the trade-off is recorded rather than discovered.
        //
        // Asserted on what was UNIQUE to the loser — its alias, and its phrase — because the two
        // records share the token "elder", which still matches and should: it belongs to the
        // surviving record too. `detect(in: "Elder One")` therefore returns the person either
        // way, and would have proved nothing about the merge.
        #expect(registry.detect(in: "Scan from Gigi.pdf").isEmpty,
                "an alias only the dropped record carried still matches — something merged")
        #expect(!registry.phrases.contains { $0.display == "Elder One" },
                "the dropped record's phrase is still registered")
        #expect(registry.phrases.contains { $0.display == "Elder Two" },
                "the surviving record lost its own phrase, so the assertion above proves nothing")
    }

    @Test func anOrdinaryRosterIsUntouched() {
        let people = [Self.person("elder", "Elder", fullNames: ["Elder Rao"]),
                      Self.person("granny", "Granny", fullNames: ["Granny Elder"])]
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
    /// given name. "elder" is owned by Granny, through "Granny Elder", and by Elder; only
    /// Elder's display name *starts* with it, so his is the single claim that resolves it.
    @Test func aDuplicateNoLongerDisablesItsOwnGivenName() {
        let elder = Self.person("elder", "Elder Rao", fullNames: ["Elder Rao"])
        let granny = Self.person("granny", "Granny Elder", fullNames: ["Granny Elder"])

        // The premise. If this ever stops holding, the duplicate assertion below means nothing.
        let clean = PersonRegistry(people: [elder, granny])
        #expect(clean.given["elder"] == "elder",
                "fixture: the given-name claim is not in play, so duplicating it proves nothing")
        #expect((clean.strong["elder"] ?? nil) == nil,
                "fixture: 'elder' is answered by `strong`, so `given` is never consulted")

        let duplicated = PersonRegistry(people: [elder, granny, elder])
        #expect(duplicated.given["elder"] == "elder",
                "a repeated entry cancelled its own given-name claim")
        #expect(duplicated.detect(in: "Elder statement.pdf") == ["elder"])
    }

    @Test func aRepeatedIdKeepsItsTokensInTheStrongMap() {
        let registry = PersonRegistry(people: [
            Self.person("elder", "Elder", fullNames: ["Elder Kulkarni"]),
            Self.person("elder", "Elder", fullNames: ["Elder Kulkarni"]),
        ])
        #expect(registry.strong["kulkarni"] == "elder")
        #expect(registry.detect(in: "Kulkarni tax notice.pdf") == ["elder"])
    }

    /// The phrase list took every record, so a duplicated roster listed the same phrase twice and
    /// the matcher had two identical candidates to choose between for one person.
    @Test func aRepeatedIdIsNotPhraseMatchedTwice() {
        let registry = PersonRegistry(people: [
            Self.person("elder", "Elder", fullNames: ["Elder Kulkarni"]),
            Self.person("elder", "Elder", fullNames: ["Elder Kulkarni"]),
        ])
        #expect(registry.phrases.filter { $0.display == "Elder Kulkarni" }.count == 1,
                "the same phrase is registered twice for one person")
    }
}
