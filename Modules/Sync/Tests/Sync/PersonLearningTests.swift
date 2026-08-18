import Foundation
import Testing
@testable import Sync

/// The learning loop: name forms discovered from filed documents, and the identifiers that give a
/// nameless scan an owner.
@Suite struct PersonLearningTests {

    static let household = PersonRegistry(people: [
        Person(id: "abhishek", displayName: "Abhishek", fullNames: ["Abhishek Girish"]),
        Person(id: "aditi", displayName: "Aditi", fullNames: ["Aditi Abhishek"]),
        // Deliberately WITHOUT "Muktha Girish" — she is the person the sweep has something to learn
        // about, and the fixture mirrors the state Anuraag's record was actually in.
        Person(id: "muktha", displayName: "Muktha", aliases: ["Mom"]),
    ])

    static func profile() -> FolderProfile {
        var folders: [String: FolderProfileEntry] = [:]
        for (path, person) in [("Family/Muktha", "Muktha"), ("Immigration/Passport/Muktha", "Muktha"),
                               ("School/Aditi", "Aditi"), ("Finance/Abhishek", "Abhishek")] {
            folders[path] = FolderProfileEntry(path: path, role: .personBucket, naming: nil,
                                               anchors: [], acceptsNewFiles: nil, fileCount: 3,
                                               subfolderCount: 0, axes: ["person": person])
        }
        return FolderProfile(profileId: "t", root: "~", folders: folders,
                             personTokens: ["muktha", "aditi", "abhishek"])
    }

    // MARK: - What it learns

    /// **The case this exists for**, and the one that produced Anuraag's full name by hand: her
    /// documents keep saying a form her record does not have.
    @Test func aRecurringNameFormIsSuggested() throws {
        let files = ["Family/Muktha": ["Muktha Girish - Old.pdf", "Muktha Girish - 2015.pdf"],
                     "Immigration/Passport/Muktha": ["Muktha Girish passport.pdf"]]
        let found = PersonNameLearning.suggestions(registry: Self.household, profile: Self.profile(),
                                                   fileNames: files)
        let s = try #require(found.first)
        #expect(s.personId == "muktha")
        #expect(s.form == "Muktha Girish", "offered in the tree's own spelling")
        #expect(s.occurrences == 3)
        // Stable across runs — the evidence shown must not depend on dictionary order.
        #expect(s.exampleFile == "Muktha Girish - 2015.pdf")
    }

    /// **One file is an anecdote.** A single occurrence is not a naming habit, and suggesting from
    /// it would surface every typo in the tree.
    @Test func aFormUsedOnceIsNotSuggested() {
        let files = ["Family/Muktha": ["Muktha Girish - Old.pdf"]]
        #expect(PersonNameLearning.suggestions(registry: Self.household, profile: Self.profile(),
                                               fileNames: files).isEmpty)
    }

    /// **The noise this shape exists to refuse**, all of it taken from the real tree. Every one of
    /// these recurs, and none is a name: the words around the person are document vocabulary, and
    /// a rule that keyed on recurrence alone would offer all of them.
    @Test func documentVocabularyIsNeverMistakenForAName() {
        let files = ["Family/Muktha": ["Bio Pages MUKTHA.pdf", "Bio Pages MUKTHA copy.pdf"],
                     "School/Aditi": ["Aditi OCI.pdf", "Aditi OCI 2.pdf",
                                      "Aditi Annual Update.pdf", "Aditi Annual Update 2.pdf"],
                     "Finance/Abhishek": ["Credit Report Abhishek.pdf",
                                          "Credit Report Abhishek 2.pdf",
                                          "Abhishek Global Entry.pdf", "Abhishek Global Entry 2.pdf"]]
        let found = PersonNameLearning.suggestions(registry: Self.household, profile: Self.profile(),
                                                   fileNames: files)
        #expect(found.isEmpty, "offered document words as names: \(found.map(\.form))")
    }

    /// A form the person already has is not news.
    @Test func aKnownFormIsNotSuggested() {
        let files = ["School/Aditi": ["Aditi Abhishek - report.pdf", "Aditi Abhishek - card.pdf"]]
        #expect(PersonNameLearning.suggestions(registry: Self.household, profile: Self.profile(),
                                               fileNames: files).isEmpty)
    }

    /// **A run must start with one of THEIR words.** Without that, a document in Aditi's folder
    /// naming her father offers "Abhishek …" as a name for *her*.
    @Test func aRunNotStartingWithTheirNameIsNotTheirs() {
        let files = ["School/Aditi": ["Report for Abhishek Girish.pdf",
                                      "Letter for Abhishek Girish.pdf"]]
        let found = PersonNameLearning.suggestions(registry: Self.household, profile: Self.profile(),
                                                   fileNames: files)
        #expect(found.isEmpty, "attributed her father's name to Aditi: \(found.map(\.form))")
    }

    /// **The lead-word guard on its own.** "Abhishek Muktha" is nobody's recorded form, so the
    /// already-claimed check cannot refuse it — only the rule that a form must lead with what the
    /// household calls *this* person can. Without it, `abhishek` reaching Aditi through her own
    /// full name hands her a run that starts with her father's name.
    @Test func aRunLeadingWithAWordFromTheirFullNameIsNotTheirs() {
        let files = ["School/Aditi": ["Abhishek Muktha - deed.pdf", "Abhishek Muktha - deed 2.pdf"]]
        let found = PersonNameLearning.suggestions(registry: Self.household, profile: Self.profile(),
                                                   fileNames: files)
        #expect(found.isEmpty, "led with her father's name and was offered to Aditi: \(found.map(\.form))")
    }

    /// **The already-claimed guard on its own.** Two people share a given name — which is ordinary
    /// in a family — so a run in the second's folder can lead with *his* word and still be the
    /// first's whole name. Only knowing the form is already somebody's refuses it.
    @Test func aFormThatIsAlreadySomebodyElsesIsNotOfferedToANamesake() {
        // The nephew is "Girish Rao" — a distinct display name, so his folder's axis RESOLVES.
        // The first draft gave both people the bare name "Girish", which made the axis value
        // ambiguous, so the folder was skipped before any guard ran and the test passed proving
        // nothing.
        let twoGirishes = PersonRegistry(people: [
            Person(id: "girish", displayName: "Girish", fullNames: ["Girish Krishnamurthy"]),
            Person(id: "girish-rao", displayName: "Girish Rao"),
        ])
        var folders: [String: FolderProfileEntry] = [:]
        folders["Family/Girish Rao"] = FolderProfileEntry(path: "Family/Girish Rao",
                                                          role: .personBucket, naming: nil,
                                                          anchors: [], acceptsNewFiles: nil,
                                                          fileCount: 2, subfolderCount: 0,
                                                          axes: ["person": "Girish Rao"])
        let profile = FolderProfile(profileId: "t", root: "~", folders: folders,
                                    personTokens: ["girish", "rao"])
        // Non-vacuity: the fixture must actually reach the rule. A run made of his own words IS
        // offered, which proves the folder was read and the guards were consulted.
        let reachable = PersonNameLearning.suggestions(
            registry: twoGirishes, profile: profile,
            fileNames: ["Family/Girish Rao": ["Girish Rao Krishnamurthy - a.pdf",
                                              "Girish Rao Krishnamurthy - b.pdf"]])
        #expect(!reachable.isEmpty, "the fixture never reached the rule — it proves nothing")

        let files = ["Family/Girish Rao": ["Girish Krishnamurthy - letter.pdf",
                                           "Girish Krishnamurthy - letter 2.pdf"]]
        let found = PersonNameLearning.suggestions(registry: twoGirishes, profile: profile,
                                                   fileNames: files)
        #expect(found.isEmpty, "offered one Girish the other's whole name: \(found.map(\.form))")
    }

    /// A rejected suggestion never comes back.
    @Test func aDismissedFormStaysDismissed() throws {
        let files = ["Family/Muktha": ["Muktha Girish - Old.pdf", "Muktha Girish - New.pdf"]]
        let found = PersonNameLearning.suggestions(registry: Self.household, profile: Self.profile(),
                                                   fileNames: files)
        let s = try #require(found.first)
        #expect(PersonNameLearning.suggestions(registry: Self.household, profile: Self.profile(),
                                               fileNames: files, dismissed: [s.id]).isEmpty)
    }

    /// Only the folders that are somebody's are read — a document in a shared folder teaches
    /// nothing about whose name is whose.
    @Test func filesOutsideAPersonsFoldersAreIgnored() {
        let files = ["Home/Utilities": ["Muktha Girish - bill.pdf", "Muktha Girish - bill 2.pdf"]]
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
    /// but the passport number on it has only ever been filed into Muktha's folder.
    @Test func anIdentifierAttributesANamelessScan() {
        let memory = Self.memory(["Immigration/Passport/Muktha": ["z1234567"],
                                  "School/Aditi": ["a9876543"]])
        let identity = PersonIdentityIndex.make(registry: Self.household, profile: Self.profile(),
                                                memory: memory)
        #expect(identity.count(for: "muktha") == 1)
        let named = Self.household.attribute(fileName: "Scan 2026-08-02.pdf",
                                             pageSample: "passport no z1234567 republic of india",
                                             identity: identity)
        #expect(named == ["muktha"])
    }

    /// **An identifier never overrides a name.** It is the strongest evidence in a document nobody
    /// labelled, and the most surprising to be filed by — so it is consulted last.
    @Test func aNameOutranksAnIdentifier() {
        let memory = Self.memory(["Immigration/Passport/Muktha": ["z1234567"]])
        let identity = PersonIdentityIndex.make(registry: Self.household, profile: Self.profile(),
                                                memory: memory)
        // The filename says Aditi; the page carries Muktha's number.
        let byName = Self.household.attribute(fileName: "Aditi Abhishek - form.pdf",
                                              pageSample: "sponsor passport z1234567",
                                              identity: identity)
        #expect(byName == ["aditi"])
    }

    /// **An identifier two people share is nobody's.** A household account number would otherwise
    /// file every joint statement into whichever of them sorted first.
    @Test func anIdentifierTwoPeopleShareIsDropped() {
        let memory = Self.memory(["Family/Muktha": ["j5550000"], "School/Aditi": ["j5550000"]])
        let identity = PersonIdentityIndex.make(registry: Self.household, profile: Self.profile(),
                                                memory: memory)
        #expect(identity.isEmpty)
        #expect(Self.household.attribute(fileName: "Scan.pdf", pageSample: "account j5550000",
                                         identity: identity).isEmpty)
    }

    // MARK: - Un-learning a misfile

    /// **The whole point of the correction, and why it has to act before the single-owner filter.**
    ///
    /// Muktha's passport number is in her folder eleven times and, once the scan is misfiled, in
    /// Aditi's once. Two claimants, so the index drops it: the number that identified her best now
    /// identifies nobody, and pressing "not Aditi's" changed nothing at all — the index is rebuilt
    /// from the tree as surveyed and took no tags.
    ///
    /// Withdrawing Aditi's claim hands the identifier back to Muktha rather than merely blanking
    /// it, which is what a correction ought to buy.
    @Test func rejectingAMisfileHandsTheIdentifierBackToItsRealOwner() {
        let memory = Self.memory(["Immigration/Passport/Muktha": ["z1234567"],
                                  "School/Aditi": ["z1234567"]])
        let profile = Self.profile()

        // Before: two claimants, so nobody owns it.
        let confused = PersonIdentityIndex.make(registry: Self.household, profile: profile,
                                                memory: memory)
        #expect(confused.isEmpty, "the fixture must reproduce the silenced identifier")

        let corpus = FilingCorpus(profileId: "t", salt: "s", documents: [
            "School/Aditi/Scan 2026-08-02.pdf": FilingCorpusDocument(
                size: 100, modified: 1, anchors: [],
                idHashes: [FilingMemory.hash("z1234567", salt: "s")]),
        ])
        let tags = [PersonTag(personId: "aditi", key: .path("School/Aditi/Scan 2026-08-02.pdf"),
                              verdict: .rejected, recordedPath: "School/Aditi/Scan 2026-08-02.pdf")]
        let withdrawn = PersonIdentityIndex.rejectedIdentifiers(tags: tags, corpus: corpus, salt: "s")

        let repaired = PersonIdentityIndex.make(registry: Self.household, profile: profile,
                                                memory: memory, rejectedIdentifiers: withdrawn)
        #expect(repaired.count(for: "muktha") == 1, "the identifier was not handed back")
        #expect(repaired.count(for: "aditi") == 0)
        #expect(Self.household.attribute(fileName: "Scan.pdf", pageSample: "passport no z1234567",
                                         identity: repaired) == ["muktha"])
    }

    /// And the plain direction: an identifier the index gave to the wrong person alone stops being
    /// theirs, rather than being handed to somebody the tree never claimed it for.
    @Test func rejectingAnIdentifierNobodyElseClaimsLeavesItUnowned() {
        let memory = Self.memory(["School/Aditi": ["z1234567"]])
        let corpus = FilingCorpus(profileId: "t", salt: "s", documents: [
            "School/Aditi/Scan.pdf": FilingCorpusDocument(
                size: 100, modified: 1, anchors: [],
                idHashes: [FilingMemory.hash("z1234567", salt: "s")]),
        ])
        let tags = [PersonTag(personId: "aditi", key: .path("School/Aditi/Scan.pdf"),
                              verdict: .rejected, recordedPath: "School/Aditi/Scan.pdf")]
        let index = PersonIdentityIndex.make(
            registry: Self.household, profile: Self.profile(), memory: memory,
            rejectedIdentifiers: PersonIdentityIndex.rejectedIdentifiers(
                tags: tags, corpus: corpus, salt: "s"))
        #expect(index.isEmpty)
    }

    /// **A confirmation is not a claim.** "Yes, this is Muktha's" on a joint statement must not
    /// hand her a household account number the tree never gave her alone.
    @Test func aConfirmationWithdrawsNothing() {
        let corpus = FilingCorpus(profileId: "t", salt: "s", documents: [
            "Family/Muktha/Statement.pdf": FilingCorpusDocument(
                size: 100, modified: 1, anchors: [],
                idHashes: [FilingMemory.hash("j5550000", salt: "s")]),
        ])
        let tags = [PersonTag(personId: "muktha", key: .path("Family/Muktha/Statement.pdf"),
                              verdict: .confirmed, recordedPath: "Family/Muktha/Statement.pdf")]
        #expect(PersonIdentityIndex.rejectedIdentifiers(tags: tags, corpus: corpus, salt: "s").isEmpty)
    }

    /// A corpus salted differently from the memory hashes nothing in common, so translating a
    /// rejection through it would withdraw a claim at random. It withdraws none instead.
    @Test func aCorpusWithTheWrongSaltWithdrawsNothing() {
        let corpus = FilingCorpus(profileId: "t", salt: "OTHER", documents: [
            "School/Aditi/Scan.pdf": FilingCorpusDocument(
                size: 100, modified: 1, anchors: [],
                idHashes: [FilingMemory.hash("z1234567", salt: "OTHER")]),
        ])
        let tags = [PersonTag(personId: "aditi", key: .path("School/Aditi/Scan.pdf"),
                              verdict: .rejected, recordedPath: "School/Aditi/Scan.pdf")]
        #expect(PersonIdentityIndex.rejectedIdentifiers(tags: tags, corpus: corpus, salt: "s").isEmpty)
    }

    /// A fingerprint-keyed rejection reaches the corpus through the path it was recorded at — the
    /// corpus has no fingerprints, so without that a durable verdict would translate to nothing.
    @Test func aFingerprintKeyedRejectionStillFindsItsDocument() {
        let corpus = FilingCorpus(profileId: "t", salt: "s", documents: [
            "School/Aditi/Scan.pdf": FilingCorpusDocument(
                size: 100, modified: 1, anchors: [],
                idHashes: [FilingMemory.hash("z1234567", salt: "s")]),
        ])
        let tags = [PersonTag(personId: "aditi", key: .fingerprint("fp-1"),
                              verdict: .rejected, recordedPath: "School/Aditi/Scan.pdf")]
        let out = PersonIdentityIndex.rejectedIdentifiers(tags: tags, corpus: corpus, salt: "s")
        #expect(out["aditi"] == [FilingMemory.hash("z1234567", salt: "s")])
    }

    /// With no memory there is nothing to learn from, and attribution is exactly what it was.
    @Test func withNoMemoryTheIndexIsEmpty() {
        let identity = PersonIdentityIndex.make(registry: Self.household, profile: Self.profile(),
                                                memory: nil)
        #expect(identity.isEmpty)
        #expect(identity.count(for: "muktha") == 0)
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
        #expect(PersonNameLearning.spelledWords("Muktha Girish - CV") == ["Muktha", "Girish", "CV"])
    }

    /// And plain ASCII is unchanged, so this alignment moved nothing that already worked.
    @Test func anASCIINameSplitsExactlyAsBefore() {
        #expect(PersonNameLearning.spelledWords("Shweta R Dani 2015.pdf")
                == ["Shweta", "R", "Dani", "2015", "pdf"])
    }
}
