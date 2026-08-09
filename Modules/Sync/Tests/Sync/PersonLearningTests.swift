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

    /// With no memory there is nothing to learn from, and attribution is exactly what it was.
    @Test func withNoMemoryTheIndexIsEmpty() {
        let identity = PersonIdentityIndex.make(registry: Self.household, profile: Self.profile(),
                                                memory: nil)
        #expect(identity.isEmpty)
        #expect(identity.count(for: "muktha") == 0)
    }
}
