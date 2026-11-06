import Testing
import Foundation
@testable import Sync

/// "All of Daughter's files": the folder and filename channels, and the rule that keeps the
/// filename channel from claiming half the household. A name attributes only as a phrase or a token
/// unique to one person. On the real corpus, where one word is a first name to one person and a
/// surname to three others, any match at all files hundreds of documents under the wrong person.
@Suite struct PersonFilesTests {

    // MARK: Fixtures — a household whose names overlap the way the real one does

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
        // `Immigration/OCI/Mother/Daughter` is Daughter's folder inside her mother's. Its contents
        // must not go to Mother just because her folder is also an ancestor.
        let p = Self.profile([("Immigration", nil),
                              ("Immigration/OCI", nil),
                              ("Immigration/OCI/Mother", "Mother"),
                              ("Immigration/OCI/Mother/Daughter", "Daughter")])
        #expect(PersonFiles.person(forPath: "Immigration/OCI/Mother/Daughter", profile: p,
                                   registry: Self.registry) == "daughter")
        #expect(PersonFiles.person(forPath: "Immigration/OCI/Mother", profile: p,
                                   registry: Self.registry) == "mother")
        // A document three levels below the axis still resolves: the point of the walk.
        #expect(PersonFiles.person(forPath: "Immigration/OCI/Mother/Daughter/Scans/2024", profile: p,
                                   registry: Self.registry) == "daughter")
        // And a folder under no one's returns nobody rather than the nearest guess.
        #expect(PersonFiles.person(forPath: "Immigration/OCI", profile: p,
                                   registry: Self.registry) == nil)
    }

    // MARK: The two channels

    @Test func ownFoldersAreGroupedAndTheRestIsTheInterestingPart() throws {
        let p = Self.profile([("Family", nil), ("Family/Daughter", "Daughter"),
                              ("Family/Daughter/School", "Daughter"), ("Shared", nil)])
        let c = Self.corpus(["Family/Daughter/a.pdf", "Family/Daughter/School/b.pdf",
                             "Family/Daughter/School/c.pdf", "Shared/Daughter - passport.pdf",
                             "Shared/unrelated.pdf"])
        let set = try PersonFiles.gather(personId: "daughter", corpus: c, profile: p, registry: Self.registry)

        #expect(set.folderCount == 2)
        // Largest folder first: the reading order matches "where most of it is".
        #expect(set.ownFolders.first?.folder == "Family/Daughter/School")
        #expect(set.total == 4)
        // The payoff row: theirs by name, filed outside their folders.
        #expect(set.elsewhere.map(\.path) == ["Shared/Daughter - passport.pdf"])
        #expect(set.elsewhere.first?.evidence == .namedInFile)
    }

    @Test func aFileInsideHerOwnFolderIsNotAlsoAMisfiling() throws {
        // `Family/Daughter/Daughter - passport.pdf` matches her name and sits in her folder. Counted
        // in both channels, a correctly filed document would land on the candidate-misfilings list.
        let p = Self.profile([("Family", nil), ("Family/Daughter", "Daughter")])
        let c = Self.corpus(["Family/Daughter/Daughter - passport.pdf"])
        let set = try PersonFiles.gather(personId: "daughter", corpus: c, profile: p, registry: Self.registry)
        #expect(set.elsewhere.isEmpty)
        #expect(set.ownFolders.first?.files.count == 1)
    }

    @Test func foldersAreOrderedBySizeThenByNameForStability() throws {
        // The comparator looks like a swapped-operands bug but isn't, so it is pinned before anyone
        // "fixes" it. Equal counts are needed, or the name comparison never runs.
        let p = Self.profile([("F", nil), ("F/Beta", "Daughter"), ("F/Alpha", "Daughter"),
                              ("F/Big", "Daughter")])
        let c = Self.corpus(["F/Big/1.pdf", "F/Big/2.pdf", "F/Beta/1.pdf", "F/Alpha/1.pdf"])
        let set = try PersonFiles.gather(personId: "daughter", corpus: c, profile: p,
                                     registry: Self.registry)
        #expect(set.ownFolders.map(\.folder) == ["F/Big", "F/Alpha", "F/Beta"],
                "largest first, then ties by name — got \(set.ownFolders.map(\.folder))")
    }

    // MARK: The discipline — a shared word never attributes on its own

    @Test func aSharedSurnameDoesNotMakeAFileDads() throws {
        // `Granny Elder - CV.pdf` is Mum's; `elder` is her surname. A bare shared token must not
        // claim it, and the phrase must claim it for her.
        let p = Self.profile([("Family", nil), ("Family/Granny", "Granny")])
        let c = Self.corpus(["Shared/Granny Elder - CV.pdf"])
        let dad = try PersonFiles.gather(personId: "elder", corpus: c, profile: p, registry: Self.registry)
        #expect(dad.elsewhere.isEmpty, "a shared surname attributed the file to Dad")
        let mum = try PersonFiles.gather(personId: "granny", corpus: c, profile: p, registry: Self.registry)
        #expect(mum.elsewhere.map(\.path) == ["Shared/Granny Elder - CV.pdf"],
                "the phrase did not claim it for the person it names — the guard above proves nothing")
    }

    @Test func aBareSharedWordAttributesToNobody() throws {
        // The strength gate itself. In `Granny Elder - CV.pdf` the phrase matcher consumes the
        // surname first, so the gate is never asked; it decides only when a shared word appears
        // with no phrase around it, like `Elder - 2021`. Must fail if the gate accepts every match.
        let p = Self.profile([("Shared", nil)])
        let c = Self.corpus(["Shared/Elder - 2021 travel.pdf"])
        let dad = try PersonFiles.gather(personId: "elder", corpus: c, profile: p, registry: Self.registry)
        #expect(dad.elsewhere.isEmpty,
                "a bare shared word attributed the file — `elder` is also two other people's surname")
        // The same word inside his full name does attribute, or the rule above is just "never".
        let named = Self.corpus(["Shared/Elder Forebear - 2021 travel.pdf"])
        let byPhrase = try PersonFiles.gather(personId: "elder", corpus: named, profile: p,
                                          registry: Self.registry)
        #expect(byPhrase.elsewhere.count == 1)
    }

    @Test func aPhraseSpendsTheSharedWordOnTheRightPerson() throws {
        // "Daughter Father" is hers, and the surname is consumed doing it, so it isn't also her
        // father's. Both directions, since a rule that attributed to neither would pass one half.
        let p = Self.profile([("Shared", nil)])
        let c = Self.corpus(["Shared/Daughter Father - OCI.pdf"])
        let hers = try PersonFiles.gather(personId: "daughter", corpus: c, profile: p, registry: Self.registry)
        let his = try PersonFiles.gather(personId: "father", corpus: c, profile: p, registry: Self.registry)
        #expect(hers.elsewhere.count == 1)
        #expect(his.elsewhere.isEmpty, "the surname in his daughter's full name counted for him")
    }

    @Test func aUniqueTokenAttributesOnItsOwn() throws {
        // The other half of `isStrong`: `maiden` names exactly one person, so it needs no phrase.
        // A rule that only accepted full names would miss most of what it should find.
        let p = Self.profile([("Shared", nil)])
        let c = Self.corpus(["Shared/Maiden - lease.pdf"])
        let set = try PersonFiles.gather(personId: "mother", corpus: c, profile: p, registry: Self.registry)
        #expect(set.elsewhere.count == 1)
    }

    @Test func anAliasIsAsGoodAsAName() throws {
        // "Dad - passport.pdf" is his. The alias is unique to him, so it attributes on its own.
        let p = Self.profile([("Shared", nil)])
        let c = Self.corpus(["Shared/Dad - passport.pdf"])
        let set = try PersonFiles.gather(personId: "elder", corpus: c, profile: p, registry: Self.registry)
        #expect(set.elsewhere.count == 1)
        #expect(set.elsewhere.first?.matchedForm == "Dad")
    }

    // MARK: Cancellation

    @Test func aCancelledGatherStopsInsteadOfFinishing() async throws {
        // Enough documents to cross the cancellation stride (one check per 256 documents); a
        // smaller corpus never observes the flag and legitimately runs to completion.
        let p = Self.profile([("Family", nil), ("Family/Daughter", "Daughter")])
        let c = Self.corpus((0..<600).map { "Family/Daughter/doc-\($0).pdf" })
        let registry = Self.registry
        let worker = Task.detached { () throws -> PersonFileSet in
            // Bounded wait for the cancel below, which is always issued. The pass cap turns a
            // broken cancellation flag into a "did not throw" failure rather than a hang.
            var passes = 0
            while !Task.isCancelled, passes < 5_000 {
                passes += 1
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return try PersonFiles.gather(personId: "daughter", corpus: c, profile: p,
                                          registry: registry)
        }
        worker.cancel()
        await #expect(throws: CancellationError.self,
                      "a cancelled sweep ran to completion — the stride check is not firing") {
            try await worker.value
        }
    }

    // MARK: Non-vacuity

    @Test func aPersonWithNothingGetsAnEmptyAnswerRatherThanEveryonesFiles() throws {
        let p = Self.profile([("Shared", nil)])
        let c = Self.corpus(["Shared/unrelated.pdf", "Shared/invoice.pdf"])
        let set = try PersonFiles.gather(personId: "son", corpus: c, profile: p, registry: Self.registry)
        #expect(set.total == 0)
    }
}
