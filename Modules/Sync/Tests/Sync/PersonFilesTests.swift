import Testing
import Foundation
@testable import Sync

/// "All of Aditi's files" — the folder and filename channels, and the discipline that keeps the
/// second one from claiming half the household.
///
/// **Measured against the real corpus before these fixtures were written.** Attributing on any
/// name match at all gave Dad 204 files "elsewhere" against 3 in his own folders, because `girish`
/// is his first name, his wife's surname and both sons' surname. Requiring a phrase or a token
/// unique to him takes that to 10, and Abhishek — whose unique set is *empty*, since his first
/// name is three other people's surname — from 290 to 111. That is the same discipline that took
/// the router's over-attribution from 36 to 0, and it is the reason these fixtures exist.
@Suite struct PersonFilesTests {

    // MARK: Fixtures — a household whose names overlap the way the real one does

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

    private static func entry(_ path: String, person: String? = nil) -> FolderProfileEntry {
        FolderProfileEntry(path: path, role: nil, naming: nil, anchors: [], acceptsNewFiles: true,
                           fileCount: 1, subfolderCount: 0,
                           axes: person.map { ["person": $0] } ?? [:])
    }

    private static func profile(_ folders: [(String, String?)]) -> FolderProfile {
        var map: [String: FolderProfileEntry] = [:]
        for (path, person) in folders { map[path] = entry(path, person: person) }
        return FolderProfile(profileId: "t", root: "/root", folders: map, personTokens: [])
    }

    private static func corpus(_ paths: [String]) -> FilingCorpus {
        FilingCorpus(profileId: "t", salt: "s",
                     documents: Dictionary(uniqueKeysWithValues: paths.map {
                         ($0, FilingCorpusDocument(size: 1, modified: 0, anchors: [], idHashes: []))
                     }))
    }

    // MARK: The resolver that did not exist

    @Test func theNearestPersonFolderWins() {
        // `Immigration/OCI/Shweta/Aditi` is Aditi's folder inside her mother's. Attributing its
        // contents to Shweta because her folder is also an ancestor is exactly the over-attribution
        // the registry work removed, arriving by a different route.
        let p = Self.profile([("Immigration", nil),
                              ("Immigration/OCI", nil),
                              ("Immigration/OCI/Shweta", "Shweta"),
                              ("Immigration/OCI/Shweta/Aditi", "Aditi")])
        #expect(PersonFiles.person(forPath: "Immigration/OCI/Shweta/Aditi", profile: p,
                                   registry: Self.registry) == "aditi")
        #expect(PersonFiles.person(forPath: "Immigration/OCI/Shweta", profile: p,
                                   registry: Self.registry) == "shweta")
        // A document three levels below the axis still resolves — the whole point of the walk.
        #expect(PersonFiles.person(forPath: "Immigration/OCI/Shweta/Aditi/Scans/2024", profile: p,
                                   registry: Self.registry) == "aditi")
        // And a folder under no one's returns nobody rather than the nearest guess.
        #expect(PersonFiles.person(forPath: "Immigration/OCI", profile: p,
                                   registry: Self.registry) == nil)
    }

    // MARK: The two channels

    @Test func herFoldersAreGroupedAndTheRestIsTheInterestingPart() {
        let p = Self.profile([("Family", nil), ("Family/Aditi", "Aditi"),
                              ("Family/Aditi/School", "Aditi"), ("Shared", nil)])
        let c = Self.corpus(["Family/Aditi/a.pdf", "Family/Aditi/School/b.pdf",
                             "Family/Aditi/School/c.pdf", "Shared/Aditi - passport.pdf",
                             "Shared/unrelated.pdf"])
        let set = PersonFiles.gather(personId: "aditi", corpus: c, profile: p, registry: Self.registry)

        #expect(set.folderCount == 2)
        // Largest folder first: the reading order matches "where most of it is".
        #expect(set.herFolders.first?.folder == "Family/Aditi/School")
        #expect(set.total == 4)
        // The payoff row: hers by name, filed somewhere that is not hers.
        #expect(set.elsewhere.map(\.path) == ["Shared/Aditi - passport.pdf"])
        #expect(set.elsewhere.first?.evidence == .namedInFile)
    }

    @Test func aFileInsideHerOwnFolderIsNotAlsoAMisfiling() {
        // `Family/Aditi/Aditi - passport.pdf` matches her name AND sits in her folder. Counting it
        // in both channels would put a correctly-filed document on the candidate-misfilings list,
        // which is the one list that has to stay worth reading.
        let p = Self.profile([("Family", nil), ("Family/Aditi", "Aditi")])
        let c = Self.corpus(["Family/Aditi/Aditi - passport.pdf"])
        let set = PersonFiles.gather(personId: "aditi", corpus: c, profile: p, registry: Self.registry)
        #expect(set.elsewhere.isEmpty)
        #expect(set.herFolders.first?.files.count == 1)
    }

    @Test func foldersAreOrderedBySizeThenByNameForStability() {
        // The ordering had no test at all, and the expression implementing it looked like the
        // classic swapped-operands bug (it was not — but a sort nobody asserts is a sort nobody
        // can safely rewrite). Equal counts are the half that was invisible: without a tie the
        // name comparison never runs.
        let p = Self.profile([("F", nil), ("F/Beta", "Aditi"), ("F/Alpha", "Aditi"),
                              ("F/Big", "Aditi")])
        let c = Self.corpus(["F/Big/1.pdf", "F/Big/2.pdf", "F/Beta/1.pdf", "F/Alpha/1.pdf"])
        let set = PersonFiles.gather(personId: "aditi", corpus: c, profile: p,
                                     registry: Self.registry)
        #expect(set.herFolders.map(\.folder) == ["F/Big", "F/Alpha", "F/Beta"],
                "largest first, then ties by name — got \(set.herFolders.map(\.folder))")
    }

    // MARK: The discipline — a shared word never attributes on its own

    @Test func aSharedSurnameDoesNotMakeAFileDads() {
        // **The 204-to-10 case.** `Muktha Girish - CV.pdf` is Mum's; `girish` is her surname. A
        // bare shared token must not claim it — and the phrase must claim it for HER.
        let p = Self.profile([("Family", nil), ("Family/Muktha", "Muktha")])
        let c = Self.corpus(["Shared/Muktha Girish - CV.pdf"])
        let dad = PersonFiles.gather(personId: "girish", corpus: c, profile: p, registry: Self.registry)
        #expect(dad.elsewhere.isEmpty, "a shared surname attributed the file to Dad")
        let mum = PersonFiles.gather(personId: "muktha", corpus: c, profile: p, registry: Self.registry)
        #expect(mum.elsewhere.map(\.path) == ["Shared/Muktha Girish - CV.pdf"],
                "the phrase did not claim it for the person it names — the guard above proves nothing")
    }

    @Test func aBareSharedWordAttributesToNobody() {
        // **The rule the corpus is named for, and the one my first fixtures did not reach.**
        // `Muktha Girish - CV.pdf` is caught a step earlier — the phrase matcher consumes the
        // surname into her full name, so Dad never matches at all and the strength gate is never
        // asked. The gate only speaks when a shared word appears with NO phrase around it, which
        // is what most of the real corpus's 204 false rows looked like: `Girish - 2021`, a folder
        // and a year.
        //
        // Mutation-checked: with the gate accepting every match, this is the test that fails.
        let p = Self.profile([("Shared", nil)])
        let c = Self.corpus(["Shared/Girish - 2021 travel.pdf"])
        let dad = PersonFiles.gather(personId: "girish", corpus: c, profile: p, registry: Self.registry)
        #expect(dad.elsewhere.isEmpty,
                "a bare shared word attributed the file — `girish` is also two other people's surname")
        // The same word inside HIS full name does attribute, or the rule above is just "never".
        let named = Self.corpus(["Shared/Girish Krishnamurthy - 2021 travel.pdf"])
        let byPhrase = PersonFiles.gather(personId: "girish", corpus: named, profile: p,
                                          registry: Self.registry)
        #expect(byPhrase.elsewhere.count == 1)
    }

    @Test func aPhraseSpendsTheSharedWordOnTheRightPerson() {
        // "Aditi Abhishek" is hers, and the surname is consumed doing it, so it is not also her
        // father's. Both directions, because a rule that attributed to neither would pass one half.
        let p = Self.profile([("Shared", nil)])
        let c = Self.corpus(["Shared/Aditi Abhishek - OCI.pdf"])
        let hers = PersonFiles.gather(personId: "aditi", corpus: c, profile: p, registry: Self.registry)
        let his = PersonFiles.gather(personId: "abhishek", corpus: c, profile: p, registry: Self.registry)
        #expect(hers.elsewhere.count == 1)
        #expect(his.elsewhere.isEmpty, "the surname in his daughter's full name counted for him")
    }

    @Test func aUniqueTokenAttributesOnItsOwn() {
        // The other half of `isStrong`. `dani` names exactly one person, so it does not need a
        // phrase — without this the rule would only ever accept full names and the feature would
        // miss most of what it should find.
        let p = Self.profile([("Shared", nil)])
        let c = Self.corpus(["Shared/Dani - lease.pdf"])
        let set = PersonFiles.gather(personId: "shweta", corpus: c, profile: p, registry: Self.registry)
        #expect(set.elsewhere.count == 1)
    }

    @Test func anAliasIsAsGoodAsAName() {
        // "Dad - passport.pdf" is his. The alias is unique to him, so it attributes on its own.
        let p = Self.profile([("Shared", nil)])
        let c = Self.corpus(["Shared/Dad - passport.pdf"])
        let set = PersonFiles.gather(personId: "girish", corpus: c, profile: p, registry: Self.registry)
        #expect(set.elsewhere.count == 1)
        #expect(set.elsewhere.first?.matchedForm == "Dad")
    }

    // MARK: Non-vacuity

    @Test func aPersonWithNothingGetsAnEmptyAnswerRatherThanEveryonesFiles() {
        let p = Self.profile([("Shared", nil)])
        let c = Self.corpus(["Shared/unrelated.pdf", "Shared/invoice.pdf"])
        let set = PersonFiles.gather(personId: "divit", corpus: c, profile: p, registry: Self.registry)
        #expect(set.total == 0)
    }
}
