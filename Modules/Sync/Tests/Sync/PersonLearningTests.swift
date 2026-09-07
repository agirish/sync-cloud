import Foundation
import Testing
@testable import Sync

/// The learning loop: name forms discovered from filed documents, and the identifiers that give a
/// nameless scan an owner.
@Suite struct PersonLearningTests {

    static let household = PersonRegistry(people: [
        Person(id: "father", displayName: "Father", fullNames: ["Father Elder"]),
        Person(id: "daughter", displayName: "Daughter", fullNames: ["Daughter Father"]),
        // Deliberately WITHOUT "Granny Elder" — she is the person the sweep has something to learn
        // about, and the fixture mirrors the state Uncle's record was actually in.
        Person(id: "granny", displayName: "Granny", aliases: ["Mom"]),
    ])

    static func profile() -> FolderProfile {
        var folders: [String: FolderProfileEntry] = [:]
        for (path, person) in [("Family/Granny", "Granny"), ("Immigration/Passport/Granny", "Granny"),
                               ("School/Daughter", "Daughter"), ("Finance/Father", "Father")] {
            folders[path] = FolderProfileEntry(path: path, role: .personBucket, naming: nil,
                                               anchors: [], acceptsNewFiles: nil, fileCount: 3,
                                               subfolderCount: 0, axes: ["person": person])
        }
        return FolderProfile(profileId: "t", root: "~", folders: folders,
                             personTokens: ["granny", "daughter", "father"])
    }

    // MARK: - What it learns

    /// **The case this exists for**, and the one that produced Uncle's full name by hand: her
    /// documents keep saying a form her record does not have.
    @Test func aRecurringNameFormIsSuggested() throws {
        let files = ["Family/Granny": ["Granny Elder - Old.pdf", "Granny Elder - 2015.pdf"],
                     "Immigration/Passport/Granny": ["Granny Elder passport.pdf"]]
        let found = PersonNameLearning.suggestions(registry: Self.household, profile: Self.profile(),
                                                   fileNames: files)
        let s = try #require(found.first)
        #expect(s.personId == "granny")
        #expect(s.form == "Granny Elder", "offered in the tree's own spelling")
        #expect(s.occurrences == 3)
        // Stable across runs — the evidence shown must not depend on dictionary order.
        #expect(s.exampleFile == "Granny Elder - 2015.pdf")
    }

    /// **One file is an anecdote.** A single occurrence is not a naming habit, and suggesting from
    /// it would surface every typo in the tree.
    @Test func aFormUsedOnceIsNotSuggested() {
        let files = ["Family/Granny": ["Granny Elder - Old.pdf"]]
        #expect(PersonNameLearning.suggestions(registry: Self.household, profile: Self.profile(),
                                               fileNames: files).isEmpty)
    }

    /// **The noise this shape exists to refuse**, all of it taken from the real tree. Every one of
    /// these recurs, and none is a name: the words around the person are document vocabulary, and
    /// a rule that keyed on recurrence alone would offer all of them.
    @Test func documentVocabularyIsNeverMistakenForAName() {
        let files = ["Family/Granny": ["Bio Pages GRANNY.pdf", "Bio Pages GRANNY copy.pdf"],
                     "School/Daughter": ["Daughter OCI.pdf", "Daughter OCI 2.pdf",
                                      "Daughter Annual Update.pdf", "Daughter Annual Update 2.pdf"],
                     "Finance/Father": ["Credit Report Father.pdf",
                                          "Credit Report Father 2.pdf",
                                          "Father Global Entry.pdf", "Father Global Entry 2.pdf"]]
        let found = PersonNameLearning.suggestions(registry: Self.household, profile: Self.profile(),
                                                   fileNames: files)
        #expect(found.isEmpty, "offered document words as names: \(found.map(\.form))")
    }

    /// A form the person already has is not news.
    @Test func aKnownFormIsNotSuggested() {
        let files = ["School/Daughter": ["Daughter Father - report.pdf", "Daughter Father - card.pdf"]]
        #expect(PersonNameLearning.suggestions(registry: Self.household, profile: Self.profile(),
                                               fileNames: files).isEmpty)
    }

    /// **A run must start with one of THEIR words.** Without that, a document in Daughter's folder
    /// naming her father offers "Father …" as a name for *her*.
    @Test func aRunNotStartingWithTheirNameIsNotTheirs() {
        let files = ["School/Daughter": ["Report for Father Elder.pdf",
                                      "Letter for Father Elder.pdf"]]
        let found = PersonNameLearning.suggestions(registry: Self.household, profile: Self.profile(),
                                                   fileNames: files)
        #expect(found.isEmpty, "attributed her father's name to Daughter: \(found.map(\.form))")
    }

    /// **The lead-word guard on its own.** "Father Granny" is nobody's recorded form, so the
    /// already-claimed check cannot refuse it — only the rule that a form must lead with what the
    /// household calls *this* person can. Without it, `father` reaching Daughter through her own
    /// full name hands her a run that starts with her father's name.
    @Test func aRunLeadingWithAWordFromTheirFullNameIsNotTheirs() {
        let files = ["School/Daughter": ["Father Granny - deed.pdf", "Father Granny - deed 2.pdf"]]
        let found = PersonNameLearning.suggestions(registry: Self.household, profile: Self.profile(),
                                                   fileNames: files)
        #expect(found.isEmpty, "led with her father's name and was offered to Daughter: \(found.map(\.form))")
    }

    /// **The already-claimed guard on its own.** Two people share a given name — which is ordinary
    /// in a family — so a run in the second's folder can lead with *his* word and still be the
    /// first's whole name. Only knowing the form is already somebody's refuses it.
    @Test func aFormThatIsAlreadySomebodyElsesIsNotOfferedToANamesake() {
        // The nephew is "Elder Rao" — a distinct display name, so his folder's axis RESOLVES.
        // The first draft gave both people the bare name "Elder", which made the axis value
        // ambiguous, so the folder was skipped before any guard ran and the test passed proving
        // nothing.
        let twoElders = PersonRegistry(people: [
            Person(id: "elder", displayName: "Elder", fullNames: ["Elder Forebear"]),
            Person(id: "elder-rao", displayName: "Elder Rao"),
        ])
        var folders: [String: FolderProfileEntry] = [:]
        folders["Family/Elder Rao"] = FolderProfileEntry(path: "Family/Elder Rao",
                                                          role: .personBucket, naming: nil,
                                                          anchors: [], acceptsNewFiles: nil,
                                                          fileCount: 2, subfolderCount: 0,
                                                          axes: ["person": "Elder Rao"])
        let profile = FolderProfile(profileId: "t", root: "~", folders: folders,
                                    personTokens: ["elder", "rao"])
        // Non-vacuity: the fixture must actually reach the rule. A run made of his own words IS
        // offered, which proves the folder was read and the guards were consulted.
        let reachable = PersonNameLearning.suggestions(
            registry: twoElders, profile: profile,
            fileNames: ["Family/Elder Rao": ["Elder Rao Forebear - a.pdf",
                                              "Elder Rao Forebear - b.pdf"]])
        #expect(!reachable.isEmpty, "the fixture never reached the rule — it proves nothing")

        let files = ["Family/Elder Rao": ["Elder Forebear - letter.pdf",
                                           "Elder Forebear - letter 2.pdf"]]
        let found = PersonNameLearning.suggestions(registry: twoElders, profile: profile,
                                                   fileNames: files)
        #expect(found.isEmpty, "offered one Elder the other's whole name: \(found.map(\.form))")
    }

    /// A rejected suggestion never comes back.
    @Test func aDismissedFormStaysDismissed() throws {
        let files = ["Family/Granny": ["Granny Elder - Old.pdf", "Granny Elder - New.pdf"]]
        let found = PersonNameLearning.suggestions(registry: Self.household, profile: Self.profile(),
                                                   fileNames: files)
        let s = try #require(found.first)
        #expect(PersonNameLearning.suggestions(registry: Self.household, profile: Self.profile(),
                                               fileNames: files, dismissed: [s.id]).isEmpty)
    }

    /// Only the folders that are somebody's are read — a document in a shared folder teaches
    /// nothing about whose name is whose.
    @Test func filesOutsideAPersonsFoldersAreIgnored() {
        let files = ["Home/Utilities": ["Granny Elder - bill.pdf", "Granny Elder - bill 2.pdf"]]
        #expect(PersonNameLearning.suggestions(registry: Self.household, profile: Self.profile(),
                                               fileNames: files).isEmpty)
    }

    // MARK: - Identifiers

    static func memory(_ folders: [String: [String]], salt: String = "s") -> FilingMemory {
        var entries: [String: FilingMemoryEntry] = [:]
        for (folder, ids) in folders {
            entries[folder] = FilingMemoryEntry(
                docs: 4, anchors: [],
                idHashes: ids.map { FilingMemoryToken(token: FilingMemory.hash($0, salt: salt),
                                                      weight: 3.0) })
        }
        return FilingMemory(profileId: "t", salt: salt, folders: entries)
    }

    /// **The tier that gives a scan an owner.** Its name says nothing and its text names nobody,
    /// but the passport number on it has only ever been filed into Granny's folder.
    @Test func anIdentifierAttributesANamelessScan() {
        let memory = Self.memory(["Immigration/Passport/Granny": ["z1234567"],
                                  "School/Daughter": ["a9876543"]])
        let identity = PersonIdentityIndex.make(registry: Self.household, profile: Self.profile(),
                                                memory: memory)
        #expect(identity.count(for: "granny") == 1)
        let named = Self.household.attribute(fileName: "Scan 2026-08-02.pdf",
                                             pageSample: "passport no z1234567 republic of india",
                                             identity: identity)
        #expect(named == ["granny"])
    }

    /// **An identifier never overrides a name.** It is the strongest evidence in a document nobody
    /// labelled, and the most surprising to be filed by — so it is consulted last.
    @Test func aNameOutranksAnIdentifier() {
        let memory = Self.memory(["Immigration/Passport/Granny": ["z1234567"]])
        let identity = PersonIdentityIndex.make(registry: Self.household, profile: Self.profile(),
                                                memory: memory)
        // The filename says Daughter; the page carries Granny's number.
        let byName = Self.household.attribute(fileName: "Daughter Father - form.pdf",
                                              pageSample: "sponsor passport z1234567",
                                              identity: identity)
        #expect(byName == ["daughter"])
    }

    /// **An identifier two people share is nobody's.** A household account number would otherwise
    /// file every joint statement into whichever of them sorted first.
    @Test func anIdentifierTwoPeopleShareIsDropped() {
        let memory = Self.memory(["Family/Granny": ["j5550000"], "School/Daughter": ["j5550000"]])
        let identity = PersonIdentityIndex.make(registry: Self.household, profile: Self.profile(),
                                                memory: memory)
        #expect(identity.isEmpty)
        #expect(Self.household.attribute(fileName: "Scan.pdf", pageSample: "account j5550000",
                                         identity: identity).isEmpty)
    }

    // MARK: - Un-learning a misfile

    /// **The whole point of the correction, and why it has to act before the single-owner filter.**
    ///
    /// Granny's passport number is in her folder eleven times and, once the scan is misfiled, in
    /// Daughter's once. Two claimants, so the index drops it: the number that identified her best now
    /// identifies nobody, and pressing "not Daughter's" changed nothing at all — the index is rebuilt
    /// from the tree as surveyed and took no tags.
    ///
    /// Withdrawing Daughter's claim hands the identifier back to Granny rather than merely blanking
    /// it, which is what a correction ought to buy.
    @Test func rejectingAMisfileHandsTheIdentifierBackToItsRealOwner() {
        let memory = Self.memory(["Immigration/Passport/Granny": ["z1234567"],
                                  "School/Daughter": ["z1234567"]])
        let profile = Self.profile()

        // Before: two claimants, so nobody owns it.
        let confused = PersonIdentityIndex.make(registry: Self.household, profile: profile,
                                                memory: memory)
        #expect(confused.isEmpty, "the fixture must reproduce the silenced identifier")

        let corpus = FilingCorpus(profileId: "t", salt: "s", documents: [
            "School/Daughter/Scan 2026-08-02.pdf": FilingCorpusDocument(
                size: 100, modified: 1, anchors: [],
                idHashes: [FilingMemory.hash("z1234567", salt: "s")]),
        ])
        let tags = [PersonTag(personId: "daughter", key: .path("School/Daughter/Scan 2026-08-02.pdf"),
                              verdict: .rejected, recordedPath: "School/Daughter/Scan 2026-08-02.pdf")]
        let withdrawn = PersonIdentityIndex.rejectedIdentifiers(tags: tags, corpus: corpus, salt: "s")

        let repaired = PersonIdentityIndex.make(registry: Self.household, profile: profile,
                                                memory: memory, rejectedIdentifiers: withdrawn)
        #expect(repaired.count(for: "granny") == 1, "the identifier was not handed back")
        #expect(repaired.count(for: "daughter") == 0)
        #expect(Self.household.attribute(fileName: "Scan.pdf", pageSample: "passport no z1234567",
                                         identity: repaired) == ["granny"])
    }

    /// And the plain direction: an identifier the index gave to the wrong person alone stops being
    /// theirs, rather than being handed to somebody the tree never claimed it for.
    @Test func rejectingAnIdentifierNobodyElseClaimsLeavesItUnowned() {
        let memory = Self.memory(["School/Daughter": ["z1234567"]])
        let corpus = FilingCorpus(profileId: "t", salt: "s", documents: [
            "School/Daughter/Scan.pdf": FilingCorpusDocument(
                size: 100, modified: 1, anchors: [],
                idHashes: [FilingMemory.hash("z1234567", salt: "s")]),
        ])
        let tags = [PersonTag(personId: "daughter", key: .path("School/Daughter/Scan.pdf"),
                              verdict: .rejected, recordedPath: "School/Daughter/Scan.pdf")]
        let index = PersonIdentityIndex.make(
            registry: Self.household, profile: Self.profile(), memory: memory,
            rejectedIdentifiers: PersonIdentityIndex.rejectedIdentifiers(
                tags: tags, corpus: corpus, salt: "s"))
        #expect(index.isEmpty)
    }

    /// **A confirmation is not a claim.** "Yes, this is Granny's" on a joint statement must not
    /// hand her a household account number the tree never gave her alone.
    @Test func aConfirmationWithdrawsNothing() {
        let corpus = FilingCorpus(profileId: "t", salt: "s", documents: [
            "Family/Granny/Statement.pdf": FilingCorpusDocument(
                size: 100, modified: 1, anchors: [],
                idHashes: [FilingMemory.hash("j5550000", salt: "s")]),
        ])
        let tags = [PersonTag(personId: "granny", key: .path("Family/Granny/Statement.pdf"),
                              verdict: .confirmed, recordedPath: "Family/Granny/Statement.pdf")]
        #expect(PersonIdentityIndex.rejectedIdentifiers(tags: tags, corpus: corpus, salt: "s").isEmpty)
    }

    /// A corpus salted differently from the memory hashes nothing in common, so translating a
    /// rejection through it would withdraw a claim at random. It withdraws none instead.
    @Test func aCorpusWithTheWrongSaltWithdrawsNothing() {
        let corpus = FilingCorpus(profileId: "t", salt: "OTHER", documents: [
            "School/Daughter/Scan.pdf": FilingCorpusDocument(
                size: 100, modified: 1, anchors: [],
                idHashes: [FilingMemory.hash("z1234567", salt: "OTHER")]),
        ])
        let tags = [PersonTag(personId: "daughter", key: .path("School/Daughter/Scan.pdf"),
                              verdict: .rejected, recordedPath: "School/Daughter/Scan.pdf")]
        #expect(PersonIdentityIndex.rejectedIdentifiers(tags: tags, corpus: corpus, salt: "s").isEmpty)
    }

    /// A fingerprint-keyed rejection reaches the corpus through the path it was recorded at — the
    /// corpus has no fingerprints, so without that a durable verdict would translate to nothing.
    @Test func aFingerprintKeyedRejectionStillFindsItsDocument() {
        let corpus = FilingCorpus(profileId: "t", salt: "s", documents: [
            "School/Daughter/Scan.pdf": FilingCorpusDocument(
                size: 100, modified: 1, anchors: [],
                idHashes: [FilingMemory.hash("z1234567", salt: "s")]),
        ])
        let tags = [PersonTag(personId: "daughter", key: .fingerprint("fp-1"),
                              verdict: .rejected, recordedPath: "School/Daughter/Scan.pdf")]
        let out = PersonIdentityIndex.rejectedIdentifiers(tags: tags, corpus: corpus, salt: "s")
        #expect(out["daughter"] == [FilingMemory.hash("z1234567", salt: "s")])
    }

    /// With no memory there is nothing to learn from, and attribution is exactly what it was.
    @Test func withNoMemoryTheIndexIsEmpty() {
        let identity = PersonIdentityIndex.make(registry: Self.household, profile: Self.profile(),
                                                memory: nil)
        #expect(identity.isEmpty)
        #expect(identity.count(for: "granny") == 0)
    }
}

/// **The two sides of the name-learning comparison split words the same way.**
///
/// The learner cut filenames on Unicode letters and numbers; the matcher cuts ASCII-only runs. For
/// a roster holding a non-ASCII name the guard that stops one person being offered another's name
/// was comparing keys built by different splitters — it could never match, so the run was rejected.
/// Conservative, and therefore silent.
@Suite struct PersonNameTokenizerTests {

    @Test func theLearnerAndTheMatcherAgreeOnANonASCIIName() {
        let written = PersonNameLearning.spelledWords("José García - passport")
        #expect(written.map { $0.lowercased() } == PersonRegistry.words("José García - passport"),
                "two splitters: \(written) vs \(PersonRegistry.words("José García - passport"))")
    }

    /// Still the tree's own spelling, which is the whole reason the helper exists — a suggestion is
    /// offered as the filename wrote it, not lowercased by the matcher.
    @Test func theSpellingIsTheFilesOwn() {
        #expect(PersonNameLearning.spelledWords("Granny Elder - CV") == ["Granny", "Elder", "CV"])
    }

    /// And plain ASCII is unchanged, so this alignment moved nothing that already worked.
    @Test func anASCIINameSplitsExactlyAsBefore() {
        #expect(PersonNameLearning.spelledWords("Mother I Maiden 2015.pdf")
                == ["Mother", "I", "Maiden", "2015", "pdf"])
    }
}
