import Foundation
import Testing
import Sync
@testable import Settings

/// **The diagnostic that explains the engine, checked against the engine.**
///
/// `PeopleTester.swift` was 136 lines with no assertion anywhere: the surface is reachable only
/// from `SettingsView` and an env-gated render probe, so its rules were shipped on inspection. That
/// matters more here than in most views, because a diagnostic that disagrees with the thing it
/// describes is worse than no diagnostic — it teaches the user a rule the app does not have.
///
/// One line in `consequence` had already been through that: counting `matches` rather than distinct
/// people made `Mom - Muktha Girish Passport.pdf` report "2 people are named, so no folder is
/// refused", while `detect` returns one person and the cross-person veto does fire.
@Suite struct PeopleTesterTests {

    static func household() -> [Person] {
        [Person(id: "abhishek", displayName: "Abhishek", relationship: "me",
                fullNames: ["Abhishek Girish"]),
         Person(id: "aditi", displayName: "Aditi", relationship: "daughter",
                fullNames: ["Aditi Abhishek"]),
         Person(id: "muktha", displayName: "Muktha", relationship: "mother",
                fullNames: ["Muktha Girish"], aliases: ["Mom"])]
    }

    /// Facts with `folders` under this person's name, so `folderCount` is what drives the sentence.
    static func facts(_ id: String, folders: Int) -> PersonFilingFacts {
        let registry = PersonRegistry(people: household())
        let person = registry.people.first { $0.id == id }!
        let paths = (0..<folders).map { "Family/\(person.displayName)/F\($0)" }
        var entries: [String: FolderProfileEntry] = [:]
        for path in paths {
            entries[path] = FolderProfileEntry(path: path, role: .personBucket, naming: nil,
                                               anchors: [], acceptsNewFiles: nil, fileCount: 1,
                                               subfolderCount: 0,
                                               axes: ["person": person.displayName])
        }
        let profile = FolderProfile(profileId: "t", root: "~", folders: entries,
                                    personTokens: Set(registry.people.map { $0.displayName.lowercased() }))
        return PersonFilingFacts.make(for: person, registry: registry, profile: profile,
                                      memory: FilingMemory(profileId: "t", salt: "s", folders: [:]))
    }

    static func factsById(_ pairs: [(String, Int)]) -> [String: PersonFilingFacts] {
        Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, facts($0.0, folders: $0.1)) })
    }

    // MARK: - The tester agrees with the engine

    /// **The documented defect, as a test.** "Mom" and "Muktha Girish" both name one person, so
    /// `explain` returns two matches and `detect` returns one id. Counting rows here made the panel
    /// announce that no folder is refused — about a filename for which the veto fires.
    ///
    /// Asserted against `detect` rather than against the sentence alone, so the two cannot drift:
    /// the count in the words has to be the count the engine acts on.
    @Test func aPersonMatchedTwiceIsStillOnePerson() throws {
        let registry = PersonRegistry(people: Self.household())
        let stem = PeopleTester.stem(of: "Mom - Muktha Girish Passport.pdf")

        let report = registry.explain(in: stem)
        try #require(report.matches.count > 1,
                     "this filename no longer produces two matches for one person — the fixture has stopped reproducing the case")
        #expect(registry.detect(in: stem).count == 1)

        let said = PeopleTester.consequence(of: stem, registry: registry,
                                            factsById: Self.factsById([("muktha", 3)]))
        #expect(said?.contains("people are named") != true,
                "the tester reported multiple people for a filename the engine attributes to one — the panel contradicts the veto it exists to explain: \(said ?? "nil")")
        #expect(said == "Prefers their 3 folders.")
    }

    /// …and the count it does print is the number of DISTINCT people, not of matches. Three
    /// household members in one filename is an ordinary scanned document, and "Two people are
    /// named" about three of them is simply wrong.
    @Test func severalPeopleAreCountedNotAssumedToBeTwo() {
        let registry = PersonRegistry(people: Self.household())
        let stem = PeopleTester.stem(of: "Abhishek Girish Aditi Abhishek Muktha Girish - scan.pdf")
        let ids = registry.detect(in: stem)
        let said = PeopleTester.consequence(of: stem, registry: registry, factsById: [:])
        #expect(said == "\(ids.count) people are named, so no folder is refused on anyone's behalf.")
        #expect(ids.count >= 2, "the fixture no longer names more than one person")
    }

    // MARK: - What identifying them decides

    /// A person with a record but no folders changes nothing, and the sentence says so rather than
    /// promising a preference the engine cannot act on.
    @Test func aPersonWithNoFoldersIsToldTheyChangeNothing() {
        let registry = PersonRegistry(people: Self.household())
        let said = PeopleTester.consequence(of: PeopleTester.stem(of: "Aditi Abhishek - OCI.pdf"),
                                            registry: registry,
                                            factsById: Self.factsById([("aditi", 0)]))
        #expect(said == "Aditi has no folders recorded yet, so this changes nothing.")
    }

    /// The two halves of the consequence, which are what make the panel worth reading: the folders
    /// preferred, and the folders refused on somebody else's behalf. With nobody else holding
    /// folders there is nothing to refuse, and claiming otherwise would describe a veto that cannot
    /// fire.
    @Test func theRefusalHalfAppearsOnlyWhenThereIsSomeoneToRefuse() {
        let registry = PersonRegistry(people: Self.household())
        let stem = PeopleTester.stem(of: "Aditi Abhishek - OCI.pdf")

        let alone = PeopleTester.consequence(of: stem, registry: registry,
                                             factsById: Self.factsById([("aditi", 2)]))
        #expect(alone == "Prefers their 2 folders.")

        // Somebody else with folders of their own, and the sentence gains its second half.
        let withOthers = PeopleTester.consequence(of: stem, registry: registry,
                                                  factsById: Self.factsById([("aditi", 2), ("muktha", 4)]))
        #expect(withOthers == "Prefers their 2 folders; refuses the other person's.")

        // …and pluralises on the count of people, not of folders.
        let twoOthers = PeopleTester.consequence(
            of: stem, registry: registry,
            factsById: Self.factsById([("aditi", 2), ("muktha", 4), ("abhishek", 9)]))
        #expect(twoOthers == "Prefers their 2 folders; refuses the other 2 people's.")

        // A person on the roster with no folders is not somebody to refuse — there is nothing of
        // theirs to keep this document out of.
        let othersButEmpty = PeopleTester.consequence(
            of: stem, registry: registry,
            factsById: Self.factsById([("aditi", 2), ("muktha", 0)]))
        #expect(othersButEmpty == "Prefers their 2 folders.")
    }

    /// One folder is "their 1 folder", not "their 1 folders".
    @Test func aSingleFolderIsSingular() {
        let registry = PersonRegistry(people: Self.household())
        #expect(PeopleTester.consequence(of: PeopleTester.stem(of: "Aditi Abhishek.pdf"),
                                         registry: registry,
                                         factsById: Self.factsById([("aditi", 1)]))
                == "Prefers their 1 folder.")
    }

    /// A filename naming nobody has no consequence to report — the panel says "names nobody"
    /// instead, which is a different line.
    @Test func aFilenameNamingNobodyHasNoConsequence() {
        #expect(PeopleTester.consequence(of: PeopleTester.stem(of: "Utility Bill.pdf"),
                                         registry: PersonRegistry(people: Self.household()),
                                         factsById: Self.factsById([("aditi", 2)])) == nil)
    }

    // MARK: - The question the engine is actually asked

    /// **The extension is stripped before anything is matched**, because that is what the veto
    /// matches on. Testing the raw string would answer a question the engine never asks — and an
    /// extension that happens to be somebody's name is not a hypothetical: the panel is where a
    /// user goes to find out why a file went somewhere odd.
    @Test func theExtensionIsNotPartOfTheName() {
        #expect(PeopleTester.stem(of: "Aditi Abhishek - OCI.pdf") == "Aditi Abhishek - OCI")
        #expect(PeopleTester.stem(of: "no-extension") == "no-extension")
        #expect(PeopleTester.stem(of: "Scan.2026.01.pdf") == "Scan.2026.01")
    }

    // MARK: - What the rows say

    /// A phrase match and a token match are described differently, because *which* one fired is the
    /// counter-intuitive part the panel exists to show.
    @Test func aPhraseMatchAndATokenMatchReadDifferently() {
        let registry = PersonRegistry(people: Self.household())
        let phrase = PersonMatch(personId: "aditi", form: "Aditi Abhishek",
                                 words: ["aditi", "abhishek"], isPhrase: true)
        let token = PersonMatch(personId: "aditi", form: "aditi", words: ["aditi"], isPhrase: false)
        #expect(PeopleTester.line(for: phrase, registry: registry)
                == "Aditi — matched the full name “Aditi Abhishek”")
        #expect(PeopleTester.line(for: token, registry: registry) == "Aditi — matched “aditi”")
        #expect(PeopleTester.line(for: phrase, registry: registry)
                != PeopleTester.line(for: token, registry: registry),
                "a phrase and a token read identically — the row no longer shows which rule fired")
    }

    /// The absorbed line, which is the whole reason full names are worth entering: "Abhishek" in
    /// "Aditi Abhishek" does not name Abhishek.
    @Test func anAbsorbedWordSaysWhoItWouldHaveNamed() {
        let registry = PersonRegistry(people: Self.household())
        let absorbed = AbsorbedWord(word: "abhishek", wouldHaveNamed: "abhishek",
                                    absorbedInto: "Aditi Abhishek", absorbedFor: "aditi")
        #expect(PeopleTester.absorbedLine(absorbed, registry: registry)
                == "“abhishek” would have named Abhishek on its own — “Aditi Abhishek” claimed it first.")
    }

    /// An id the roster does not answer to falls back to the id rather than drawing a blank — the
    /// panel is a diagnostic, so an unresolvable id is information.
    @Test func anUnknownIdIsShownRatherThanDroppped() {
        #expect(PeopleTester.displayName("ghost", in: PersonRegistry(people: Self.household()))
                == "ghost")
    }
}
