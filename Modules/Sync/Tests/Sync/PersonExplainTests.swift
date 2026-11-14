import Foundation
import Testing
@testable import Sync

/// The explanation the People section shows, the roster-level overview, and the record of what the
/// cross-person rule refused.
@Suite struct PersonExplainTests {

    static let household = PersonRegistry(people: [
        Person(id: "father", displayName: "Father", fullNames: ["Father Elder"]),
        Person(id: "daughter", displayName: "Daughter", fullNames: ["Daughter Father"]),
        Person(id: "granny", displayName: "Granny", fullNames: ["Granny Elder"],
               aliases: ["Mom", "Mother"]),
    ])

    // MARK: - explain

    /// What the matcher answers, stated rather than derived from `explain`, which would compare the
    /// model to itself. Each case is a rule: a longer phrase consumes the words inside it
    /// (`Daughter Father` is Daughter, not Daughter and her father), an alias resolves to the
    /// person, a given name shared by two people resolves to whoever claims it as a first name, and
    /// text naming nobody names nobody.
    @Test func theMatcherAnswersEachShapeAsTheRulesSay() {
        let cases: [(String, Set<String>)] = [
            ("Daughter Father - OCI", ["daughter"]),
            ("Mom - passport", ["granny"]),
            ("Granny Elder", ["granny"]),
            ("Father", ["father"]),
            ("Scan 2026-08-02", []),
            ("", []),
            ("Father Elder and Granny Elder", ["father", "granny"]),
        ]
        for (text, expected) in cases {
            #expect(Self.household.detect(in: text) == expected,
                    "“\(text)” → \(Self.household.detect(in: text).sorted())")
        }
    }

    /// `explain` reports exactly what `detect` answers, since the People section shows the one and
    /// the veto acts on the other. A wiring check; the case table above is the matcher's coverage.
    @Test func explainReportsTheSamePeopleDetectAnswers() {
        let text = "Father Elder and Mom"
        #expect(Set(Self.household.explain(in: text).matches.map(\.personId))
                == Self.household.detect(in: text))
    }

    /// The form is reported as the roster spells it, not as the tokenizer sees it, so the user's own
    /// entry is quoted back to them.
    @Test func theMatchedFormIsQuotedAsWritten() throws {
        let report = Self.household.explain(in: "daughter father - oci card")
        let match = try #require(report.matches.first)
        #expect(match.personId == "daughter")
        #expect(match.form == "Daughter Father")
        #expect(match.isPhrase)

        let alias = try #require(Self.household.explain(in: "mom - passport").matches.first)
        #expect(alias.form == "Mom", "the alias was reported lowercased")
        #expect(!alias.isPhrase)
    }

    /// The report names the word a phrase spent and who it would otherwise have named. Without it
    /// the tester says "Daughter" and the user can't tell why her father's name did nothing.
    @Test func anAbsorbedWordNamesWhoItWouldHaveMatched() throws {
        let report = Self.household.explain(in: "Daughter Father - OCI Card")
        let absorbed = try #require(report.absorbed.first)
        #expect(absorbed.word == "father")
        #expect(absorbed.wouldHaveNamed == "father")
        #expect(absorbed.absorbedInto == "Daughter Father")
        #expect(report.absorbed.count == 1)
    }

    /// A phrase that consumes only its own person's words absorbs nothing: the report must not
    /// invent an explanation.
    @Test func aPhraseThatStealsNothingReportsNothingAbsorbed() {
        let report = Self.household.explain(in: "Granny Elder - Resume")
        #expect(report.matches.map(\.personId) == ["granny"])
        // "elder" belongs to Father's full name too, but on its own it names nobody in this
        // roster (neither a strong token nor anyone's given name), so nothing was taken.
        #expect(report.absorbed.isEmpty)
    }

    // MARK: - The roster against the tree

    static func profile(_ pairs: [(String, String)]) -> FolderProfile {
        var folders: [String: FolderProfileEntry] = [:]
        for (path, person) in pairs {
            folders[path] = FolderProfileEntry(path: path, role: .personBucket, naming: nil,
                                               anchors: [], acceptsNewFiles: nil, fileCount: 1,
                                               subfolderCount: 0, axes: ["person": person])
        }
        return FolderProfile(profileId: "t", root: "~", folders: folders, personTokens: [])
    }

    /// A person the tree files for who isn't on the roster is the actionable gap: documents naming
    /// them are attributed to nobody, their folders get no protection, and nothing else says so.
    @Test func aPersonWithFoldersButNoRecordIsReported() throws {
        let profile = Self.profile([("Family/Ravi", "Ravi"),
                                    ("Immigration/Passport/Ravi", "Ravi"),
                                    ("Family/Daughter", "Daughter")])
        let memory = FilingMemory(profileId: "t", salt: "s", folders: [
            "Family/Ravi": FilingMemoryEntry(docs: 7, anchors: [], idHashes: []),
            "Family/Daughter": FilingMemoryEntry(docs: 3, anchors: [], idHashes: []),
        ])
        let overview = PeopleOverview.make(registry: Self.household, profile: profile, memory: memory)

        let ravi = try #require(overview.unclaimed.first)
        #expect(ravi.name == "Ravi", "the offer must propose the spelling the tree uses")
        #expect(ravi.folders == 2)
        #expect(ravi.exampleFolder == "Family/Ravi", "the shallowest folder is the recognisable one")
        #expect(overview.claimedFolders == 1)
        #expect(overview.claimedDocuments == 3)
    }

    /// A complete roster reports no gap, so the section can say so plainly instead of showing an
    /// empty space.
    @Test func aCompleteRosterHasNoUnclaimedPeople() {
        let profile = Self.profile([("Family/Daughter", "Daughter"), ("Family/Mom", "Mom")])
        let overview = PeopleOverview.make(registry: Self.household, profile: profile, memory: nil)
        #expect(overview.unclaimed.isEmpty)
        // `Family/Mom` counts as claimed through the alias: the axis resolves through the registry,
        // not by string equality.
        #expect(overview.claimedFolders == 2)
    }

    /// Someone on the roster with no folders is named, so the section can say their record is
    /// currently inert rather than leaving them looking identical to everyone else.
    @Test func aPersonWithNoFoldersIsNamed() {
        let profile = Self.profile([("Family/Daughter", "Daughter")])
        let overview = PeopleOverview.make(registry: Self.household, profile: profile, memory: nil)
        #expect(Set(overview.peopleWithNoFolders) == ["father", "granny"])
    }

    // MARK: - Areas

    /// The areas are the top level of each folder's path, busiest first: what a person's record is
    /// about, which a folder count can't say.
    @Test func areasGroupFoldersByTheTopOfTheirPath() throws {
        let profile = Self.profile([("Family/Daughter", "Daughter"),
                                    ("Family/Daughter/Events", "Daughter"),
                                    ("School/Daughter", "Daughter")])
        let memory = FilingMemory(profileId: "t", salt: "s", folders: [
            "School/Daughter": FilingMemoryEntry(docs: 40, anchors: [], idHashes: []),
            "Family/Daughter": FilingMemoryEntry(docs: 2, anchors: [], idHashes: []),
        ])
        let daughter = try #require(Self.household.people.first { $0.id == "daughter" })
        let facts = PersonFilingFacts.make(for: daughter, registry: Self.household,
                                           profile: profile, memory: memory)
        // School leads on documents though Family holds more folders: busiest, not biggest.
        #expect(facts.areas.map(\.name) == ["School", "Family"])
        #expect(facts.areas.first?.documents == 40)
        #expect(facts.areas.last?.folders == 2)
    }
}
