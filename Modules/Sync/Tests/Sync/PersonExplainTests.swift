import Foundation
import Testing
@testable import Sync

/// The explanation the People section shows, the roster-level overview, and the record of what the
/// cross-person rule refused.
@Suite struct PersonExplainTests {

    static let household = PersonRegistry(people: [
        Person(id: "abhishek", displayName: "Abhishek", fullNames: ["Abhishek Girish"]),
        Person(id: "aditi", displayName: "Aditi", fullNames: ["Aditi Abhishek"]),
        Person(id: "muktha", displayName: "Muktha", fullNames: ["Muktha Girish"],
               aliases: ["Mom", "Mother"]),
    ])

    // MARK: - explain

    /// **What the matcher answers, stated rather than derived.**
    ///
    /// This asserted that `detect` agrees with `explain` — over a spread of inputs, with a comment
    /// explaining that they cannot disagree because `detect` IS `Set(explain(...).map(\.personId))`.
    /// It compared the model to itself: every one of those cases passes with any matching rule
    /// whatsoever, including one that names nobody at all. The shapes were well chosen; only the
    /// assertion was empty, so they are kept and given real answers.
    ///
    /// Each line is a rule the file's prose claims elsewhere: a longer phrase consumes the words
    /// inside it (`Aditi Abhishek` is Aditi, not Aditi-and-her-father), an alias resolves to the
    /// person, a bare given name matching two people still resolves to whoever claims it as a
    /// first name, and text naming nobody names nobody.
    @Test func theMatcherAnswersEachShapeAsTheRulesSay() {
        let cases: [(String, Set<String>)] = [
            ("Aditi Abhishek - OCI", ["aditi"]),
            ("Mom - passport", ["muktha"]),
            ("Muktha Girish", ["muktha"]),
            ("Abhishek", ["abhishek"]),
            ("Scan 2026-08-02", []),
            ("", []),
            ("Abhishek Girish and Muktha Girish", ["abhishek", "muktha"]),
        ]
        for (text, expected) in cases {
            #expect(Self.household.detect(in: text) == expected,
                    "“\(text)” → \(Self.household.detect(in: text).sorted())")
        }
    }

    /// And the seam the test above used to assert: `explain` reports exactly what `detect` answers.
    /// Worth one line, since the People section shows the explanation and the veto acts on the set —
    /// but it is a wiring check, not the matcher's coverage, which is what the case table above is.
    @Test func explainReportsTheSamePeopleDetectAnswers() {
        let text = "Abhishek Girish and Mom"
        #expect(Set(Self.household.explain(in: text).matches.map(\.personId))
                == Self.household.detect(in: text))
    }

    /// The form is reported **as the roster spells it**, not as the tokenizer sees it — the point
    /// is to quote the user's own entry back to them.
    @Test func theMatchedFormIsQuotedAsWritten() throws {
        let report = Self.household.explain(in: "aditi abhishek - oci card")
        let match = try #require(report.matches.first)
        #expect(match.personId == "aditi")
        #expect(match.form == "Aditi Abhishek")
        #expect(match.isPhrase)

        let alias = try #require(Self.household.explain(in: "mom - passport").matches.first)
        #expect(alias.form == "Mom", "the alias was reported lowercased")
        #expect(!alias.isPhrase)
    }

    /// **The explanation that makes phrase matching make sense**: the word that was spent, and who
    /// it would otherwise have named. Without this the tester says "Aditi" and the user is left to
    /// wonder why her father's name in the same filename did nothing.
    @Test func anAbsorbedWordNamesWhoItWouldHaveMatched() throws {
        let report = Self.household.explain(in: "Aditi Abhishek - OCI Card")
        let absorbed = try #require(report.absorbed.first)
        #expect(absorbed.word == "abhishek")
        #expect(absorbed.wouldHaveNamed == "abhishek")
        #expect(absorbed.absorbedInto == "Aditi Abhishek")
        #expect(report.absorbed.count == 1)
    }

    /// A phrase that consumes only its own person's words absorbs nothing — the report must not
    /// invent an explanation where there is none to give.
    @Test func aPhraseThatStealsNothingReportsNothingAbsorbed() {
        let report = Self.household.explain(in: "Muktha Girish - Resume")
        #expect(report.matches.map(\.personId) == ["muktha"])
        // "girish" belongs to Abhishek's full name too, but on its own it names nobody in this
        // roster — it is neither a strong token nor anyone's given name — so nothing was taken.
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

    /// **A person the tree files for who is not on the roster is the actionable gap.** Documents
    /// naming them are attributed to nobody and their folders get no protection, and nothing else
    /// in the app would ever mention it.
    @Test func aPersonWithFoldersButNoRecordIsReported() throws {
        let profile = Self.profile([("Family/Ravi", "Ravi"),
                                    ("Immigration/Passport/Ravi", "Ravi"),
                                    ("Family/Aditi", "Aditi")])
        let memory = FilingMemory(profileId: "t", salt: "s", folders: [
            "Family/Ravi": FilingMemoryEntry(docs: 7, anchors: [], idHashes: []),
            "Family/Aditi": FilingMemoryEntry(docs: 3, anchors: [], idHashes: []),
        ])
        let overview = PeopleOverview.make(registry: Self.household, profile: profile, memory: memory)

        let ravi = try #require(overview.unclaimed.first)
        #expect(ravi.name == "Ravi", "the offer must propose the spelling the tree uses")
        #expect(ravi.folders == 2)
        #expect(ravi.documents == 7)
        #expect(ravi.exampleFolder == "Family/Ravi", "the shallowest folder is the recognisable one")
        #expect(overview.claimedFolders == 1)
        #expect(overview.claimedDocuments == 3)
    }

    /// A complete roster reports no gap — the state that lets the section say so plainly instead of
    /// showing an empty space.
    @Test func aCompleteRosterHasNoUnclaimedPeople() {
        let profile = Self.profile([("Family/Aditi", "Aditi"), ("Family/Mom", "Mom")])
        let overview = PeopleOverview.make(registry: Self.household, profile: profile, memory: nil)
        #expect(overview.unclaimed.isEmpty)
        // `Family/Mom` counts as claimed through the alias, which is the whole point of resolving
        // the axis through the registry rather than by string equality.
        #expect(overview.claimedFolders == 2)
    }

    /// Someone on the roster with no folders is named, so the section can say their record is
    /// currently inert rather than leaving them looking identical to everyone else.
    @Test func aPersonWithNoFoldersIsNamed() {
        let profile = Self.profile([("Family/Aditi", "Aditi")])
        let overview = PeopleOverview.make(registry: Self.household, profile: profile, memory: nil)
        #expect(Set(overview.peopleWithNoFolders) == ["abhishek", "muktha"])
    }

    // MARK: - Areas

    /// The areas are the top level of each folder's path, busiest first — what a person's record
    /// is *about*, which a folder count cannot say.
    @Test func areasGroupFoldersByTheTopOfTheirPath() throws {
        let profile = Self.profile([("Family/Aditi", "Aditi"),
                                    ("Family/Aditi/Events", "Aditi"),
                                    ("School/Aditi", "Aditi")])
        let memory = FilingMemory(profileId: "t", salt: "s", folders: [
            "School/Aditi": FilingMemoryEntry(docs: 40, anchors: [], idHashes: []),
            "Family/Aditi": FilingMemoryEntry(docs: 2, anchors: [], idHashes: []),
        ])
        let aditi = try #require(Self.household.people.first { $0.id == "aditi" })
        let facts = PersonFilingFacts.make(for: aditi, registry: Self.household,
                                           profile: profile, memory: memory)
        // School leads on documents despite Family holding more folders — busiest, not biggest.
        #expect(facts.areas.map(\.name) == ["School", "Family"])
        #expect(facts.areas.first?.documents == 40)
        #expect(facts.areas.last?.folders == 2)
    }

    // MARK: - What the veto prevented

    @MainActor
    @Test func theVetoLogCountsAndRemembersPerPerson() {
        let suite = "veto-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = PersonVetoLog(userDefaults: defaults)

        log.record(PersonVetoEvent(namedPerson: "aditi", proposedPerson: "divit",
                                   fileName: "Aditi OCI.pdf", destination: "Immigration/OCI/Divit",
                                   at: Date(timeIntervalSince1970: 1_000)))
        log.record(PersonVetoEvent(namedPerson: "aditi", proposedPerson: "divit",
                                   fileName: "Aditi Passport.pdf", destination: "Passport/Divit",
                                   at: Date(timeIntervalSince1970: 2_000)))

        #expect(log.count(namedPerson: "aditi") == 2)
        #expect(log.count(namedPerson: "divit") == 0)
        // Newest first, so "last" means the most recent refusal rather than the first ever.
        #expect(log.mostRecent(namedPerson: "aditi")?.fileName == "Aditi Passport.pdf")
        // A relaunch reads the same history.
        #expect(PersonVetoLog(userDefaults: defaults).count(namedPerson: "aditi") == 2)
    }

    /// Capped, because this is an illustration and not a filing diary.
    @MainActor
    @Test func theVetoLogForgetsTheOldest() {
        // Cleaned up like every sibling in this file: a UUID-named suite with no teardown leaves a
        // plist in the shared `~/Library/Preferences` on every run, for as long as the suite exists.
        let name = "veto-cap-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let log = PersonVetoLog(userDefaults: defaults)
        for i in 0..<(PersonVetoLog.capacity + 10) {
            log.record(PersonVetoEvent(namedPerson: "aditi", proposedPerson: "divit",
                                       fileName: "\(i).pdf", destination: "d",
                                       at: Date(timeIntervalSince1970: Double(i))))
        }
        #expect(log.events.count == PersonVetoLog.capacity)
        #expect(log.events.first?.fileName == "\(PersonVetoLog.capacity + 9).pdf")
    }
}
