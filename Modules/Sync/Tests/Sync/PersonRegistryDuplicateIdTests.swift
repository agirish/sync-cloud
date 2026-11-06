import Testing
@testable import Sync

/// What a `people.json` listing one id twice does to the roster. Each reader (the Settings list's
/// `ForEach`, `PeopleStore.person(id:)`, the facts, and the registry's `strong`, `phrases` and
/// `given` maps) could otherwise pick a different record, or none, so one row could show one
/// record's name above another's facts. `PersonRegistry.init(people:)` reduces to one record per
/// id before building anything, so every reader gets the same answer.
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
        // The premise: the duplicate really was collapsed.
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
        // Named fields rather than record equality, so a future field can't pass this by being
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
        // The dropped record's names are gone from matching: the cost of picking, recorded as a
        // test. Asserted on what was unique to the loser, its alias and phrase, because the shared
        // token "elder" rightly still matches through the survivor.
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

    /// A person listed twice must not claim their given name twice: `given` publishes a token only
    /// when exactly one id claims it, so a duplicate would disable its own matching. `given` is
    /// consulted only for a token more than one person owns (others are answered by `strong`), so
    /// the fixture uses a surname that is also a given name: "elder" belongs to Granny and to
    /// Elder, and only Elder's display name starts with it.
    @Test func aDuplicateNoLongerDisablesItsOwnGivenName() {
        let elder = Self.person("elder", "Elder Rao", fullNames: ["Elder Rao"])
        let granny = Self.person("granny", "Granny Elder", fullNames: ["Granny Elder"])

        // The premise: the fixture reaches `given`.
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

    /// A duplicated roster lists each phrase once, so the matcher never has two identical
    /// candidates for one person.
    @Test func aRepeatedIdIsNotPhraseMatchedTwice() {
        let registry = PersonRegistry(people: [
            Self.person("elder", "Elder", fullNames: ["Elder Kulkarni"]),
            Self.person("elder", "Elder", fullNames: ["Elder Kulkarni"]),
        ])
        #expect(registry.phrases.filter { $0.display == "Elder Kulkarni" }.count == 1,
                "the same phrase is registered twice for one person")
    }
}
