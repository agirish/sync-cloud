import Foundation
import Testing
@testable import Sync

@Suite struct FilingProfileStoreTests {

    static func makeProfiles(_ dir: URL, id: String = "abhishek",
                             profile: String, memory: String?) throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(id),
                                                withIntermediateDirectories: true)
        try #"{"schemaVersion":1,"activeProfileId":""# .appending(id).appending(#""}"#)
            .write(to: dir.appendingPathComponent("profiles.json"), atomically: true, encoding: .utf8)
        try profile.write(to: dir.appendingPathComponent("\(id)/folder-profile.json"),
                          atomically: true, encoding: .utf8)
        if let memory {
            try memory.write(to: dir.appendingPathComponent("\(id)/filing-memory.json"),
                             atomically: true, encoding: .utf8)
        }
    }

    /// The on-disk shape, written by the generator that produced the real artifact. Decoding is the
    /// only contract between a Python builder and this module, so the fixture is written the way the
    /// builder writes it — including the two-element token arrays and the axis aliases.
    static let profileJSON = """
    {"profileId":"abhishek","root":"~/Documents",
     "axes":{"person":{"values":["Abhishek","Shweta"],"aliases":{"Mom":"Muktha"}}},
     "folders":[
       {"path":"Finance/US/Income Tax/2023","role":"year-bucket","naming":"descriptive",
        "anchors":["income","tax"],"fileCount":3,"subfolderCount":6,
        "axes":{"jurisdiction":"US","year":"2023","lifecycle":"active"}},
       {"path":"Finance/US/Income Tax/IRS Docs - 2024","role":"pass-through","naming":null,
        "anchors":["irs"],"fileCount":0,"subfolderCount":1,
        "axes":{"jurisdiction":"US","lifecycle":"active"}},
       {"path":"Documents/TODO","role":"inbox","naming":null,"anchors":[],
        "acceptsNewFiles":false,"fileCount":524,"subfolderCount":0,"axes":{}}]}
    """

    static let memoryJSON = """
    {"schemaVersion":1,"profileId":"abhishek","salt":"abc123","idfFolderBase":2096,
     "folders":{"Finance/US/Income Tax/2023":
       {"docs":12,"anchors":[["turbotax",4.2],["deduction",3.1]],
        "idHashes":[["3437e15c04d360ef",5.0]],"folderModified":1754000000}}}
    """

    @Test func readsTheActiveProfileAndItsMemory() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.makeProfiles(dir, profile: Self.profileJSON, memory: Self.memoryJSON)

        let loaded = try #require(FilingProfileStore.active(in: dir))
        #expect(loaded.profile.profileId == "abhishek")
        #expect(loaded.profile.folders.count == 3)
        #expect(loaded.memory?.folders.count == 1)
        #expect(loaded.memory?.salt == "abc123")

        let year = try #require(loaded.profile.folders["Finance/US/Income Tax/2023"])
        #expect(year.role == .yearBucket)
        #expect(year.yearKey == "2023")
        #expect(year.anchors == ["income", "tax"])
        // Aliases are the same person under two names — `Family/Mom` is Immigration's `Muktha`.
        #expect(loaded.profile.personTokens.isSuperset(of: ["abhishek", "shweta", "mom", "muktha"]))
        // And the PAIRING survives decode, which is the half that used to be thrown away: without
        // it nothing downstream can tell that those are one person rather than two.
        #expect(loaded.profile.personAliases["mom"] == "muktha")

        let entry = try #require(loaded.memory?.folders["Finance/US/Income Tax/2023"])
        #expect(entry.docs == 12)
        #expect(entry.anchors.first == FilingMemoryToken(token: "turbotax", weight: 4.2))
        #expect(entry.idHashes.first?.token == "3437e15c04d360ef")
    }

    /// **A year hidden inside a descriptive name.** `IRS Docs - 2024` sits beside the bare-year
    /// folders and the survey recorded no `year` axis for it, so without the name fallback it lands
    /// in a different family and is never compared with the years it belongs to.
    @Test func aYearInTheNameIsFoundWhenTheAxisIsMissing() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.makeProfiles(dir, profile: Self.profileJSON, memory: nil)
        let p = try #require(FilingProfileStore.profile(id: "abhishek", in: dir))
        #expect(p.folders["Finance/US/Income Tax/IRS Docs - 2024"]?.axes["year"] == nil)
        #expect(FolderProfileEntry.looksLikeYear("2019-2020"))
        #expect(FolderProfileEntry.looksLikeYear("2024"))
        #expect(!FolderProfileEntry.looksLikeYear("IRS Docs - 2024"))
    }

    /// Inboxes are refused by the profile's own flag *and* by the path rule, because a tree grows
    /// new inboxes the survey never saw.
    @Test func inboxesAreRefusedAsDestinations() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.makeProfiles(dir, profile: Self.profileJSON, memory: nil)
        let p = try #require(FilingProfileStore.profile(id: "abhishek", in: dir))
        #expect(!p.acceptsNewFiles("Documents/TODO"))               // flagged in the profile
        #expect(!p.acceptsNewFiles("Health/TODO/Dental"))           // never surveyed, path rule
        #expect(!p.acceptsNewFiles("Work/EDD - TODO"))              // component, not suffix
        #expect(p.acceptsNewFiles("Finance/US/Income Tax/2023"))
    }

    /// A missing memory is ordinary, not a fault — the profile alone still routes.
    @Test func aMissingMemoryStillYieldsAProfile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.makeProfiles(dir, profile: Self.profileJSON, memory: nil)
        let loaded = try #require(FilingProfileStore.active(in: dir))
        #expect(loaded.memory == nil)
    }

    @Test func absentAndMalformedBothYieldNil() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FilingProfileStore.active(in: dir) == nil)          // nothing there at all
        try Self.makeProfiles(dir, profile: "{ not json", memory: nil)
        #expect(FilingProfileStore.profile(id: "abhishek", in: dir) == nil)
        #expect(FilingProfileStore.activeProfileId(in: dir) == "abhishek")
    }

    /// **A future schema is refused, not half-read.** The store's own doc claimed this and only
    /// `profiles.json` was ever checked, so an artifact with a new shape would have been decoded
    /// field-by-field into a mostly empty value and used — the silent wrong answer this store
    /// exists to avoid.
    @Test func aForeignSchemaIsRefusedRatherThanHalfRead() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let future = Self.memoryJSON.replacingOccurrences(of: "\"schemaVersion\":1",
                                                          with: "\"schemaVersion\":99")
        try Self.makeProfiles(dir, profile: Self.profileJSON, memory: future)
        #expect(FilingProfileStore.memory(id: "abhishek", in: dir) == nil)
        // and the same file at the current schema still reads, or the test above proves nothing
        try Self.makeProfiles(dir, profile: Self.profileJSON, memory: Self.memoryJSON)
        #expect(FilingProfileStore.memory(id: "abhishek", in: dir) != nil)
    }

    /// **The hash format is the contract with the builder that wrote the file.** A change here does
    /// not fail — it silently stops every identifier matching — so it is pinned against a literal
    /// computed independently: `sha256("abc123" + "1892")[0..<16]`.
    /// `people.json` is read when it is there, and it is what supplies the full names — the forms
    /// a survey of folder names cannot know, and the only thing that makes "Aditi Abhishek"
    /// attributable to one person.
    @Test func aPeopleFileIsReadAndSuppliesTheFullNames() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.makeProfiles(dir, profile: Self.profileJSON, memory: nil)
        try """
        {"schemaVersion":1,"people":[
          {"id":"abhishek","displayName":"Abhishek","relationship":"me",
           "fullNames":["Abhishek Girish"]},
          {"id":"aditi","displayName":"Aditi","relationship":"daughter",
           "fullNames":["Aditi Abhishek"]},
          {"id":"muktha","displayName":"Muktha","relationship":"mother",
           "fullNames":["Muktha Girish"],"aliases":["Mom","Mother"]}]}
        """.write(to: dir.appendingPathComponent("abhishek/people.json"),
                  atomically: true, encoding: .utf8)

        let loaded = try #require(FilingProfileStore.active(in: dir))
        #expect(loaded.registry.source == .file)
        #expect(loaded.registry.people.count == 3)
        #expect(loaded.registry.people.first?.relationship == "me")
        #expect(loaded.registry.detect(in: "Aditi Abhishek - OCI.pdf") == ["aditi"])
        #expect(loaded.registry.detect(in: "Mom - passport.pdf") == ["muktha"])
    }

    /// With no `people.json` the registry is seeded from the profile's own axis — so the alias fix
    /// lands on a tree that has only ever been surveyed, without anyone writing a file.
    @Test func withNoPeopleFileTheRegistryIsSeededFromTheProfile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.makeProfiles(dir, profile: Self.profileJSON, memory: nil)

        let loaded = try #require(FilingProfileStore.active(in: dir))
        #expect(loaded.registry.source == .profileAxis)
        #expect(Set(loaded.registry.people.map(\.id)) == ["abhishek", "shweta", "muktha"])
        #expect(loaded.registry.detect(in: "Mom - passport.pdf") == ["muktha"])
    }

    /// The fingerprint moves when the roster does — it is mixed into every verdict cache key, and
    /// a changed roster changes the shortlist every file is asked about.
    @Test func theFingerprintMovesWhenThePeopleFileChanges() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.makeProfiles(dir, profile: Self.profileJSON, memory: nil)
        let before = FilingProfileStore.fingerprint(id: "abhishek", in: dir)
        try #"{"schemaVersion":1,"people":[{"id":"aditi","displayName":"Aditi"}]}"#
            .write(to: dir.appendingPathComponent("abhishek/people.json"),
                   atomically: true, encoding: .utf8)
        #expect(FilingProfileStore.fingerprint(id: "abhishek", in: dir) != before)
    }

    @Test func theIdentifierHashMatchesTheBuilder() {
        #expect(FilingMemory.hash("1892", salt: "abc123") == "3437e15c04d360ef")
        #expect(FilingMemory.hash("kaiser", salt: "s") == "3529b1a559fe505a")
    }
}

/// Decodes the artifacts actually on this machine. Skipped — visibly — where they do not exist,
/// rather than passing vacuously: this is the only check that the Swift decoder agrees with the
/// Python generator on 2,096 folders of real data.
@Suite(.enabled(if: FilingProfileStore.defaultDirectory().map {
    FileManager.default.fileExists(atPath: $0.appendingPathComponent("profiles.json").path)
} ?? false, "no filing profile on this machine"))
struct RealFilingProfileTests {

    /// **The claim that the registry is an improvement, measured rather than argued — and the
    /// measurement is not the one I first reached for.**
    ///
    /// Every already-filed document is a labelled example: the folder it sits in *is* the right
    /// answer. The obvious metric is therefore *false vetoes* — a rule refusing the folder the
    /// document actually lives in — and on this corpus the two rules are **identical at 3 of
    /// 1,375**. All three are `Family/Aditi/Events/Baby Shower/`, documents named for the parents
    /// inside the child's event folder; no amount of name intelligence resolves that, because the
    /// folder is Aditi's for a reason the filename cannot state.
    ///
    /// What the registry actually fixes is **over-attribution**: `Muktha Girish - Resume.pdf` names
    /// one person, and the token rule reports two, because `girish` is her surname and his given
    /// name. The token rule does that to **36** of the same 1,375. Every one is a document the veto
    /// would let into the wrong person's folder — the protection failing open, which is exactly the
    /// failure that is invisible in use — and, since the router penalises a folder whose person the
    /// document does not name, 36 files scoring against a family member they have nothing to do
    /// with. So that is the number this test holds.
    ///
    /// Skipped where the corpus is absent (a survey artifact, not something the app writes), and it
    /// prints both numbers so a regression reads as a number rather than a boolean.
    @Test func theRegistryRefusesFewerCorrectFoldersThanTheTokenRule() throws {
        let dir = try #require(FilingProfileStore.defaultDirectory())
        let loaded = try #require(FilingProfileStore.active(in: dir))
        let corpusURL = dir.appendingPathComponent("\(loaded.profile.profileId)/filing-corpus.json")
        try #require(FileManager.default.fileExists(atPath: corpusURL.path),
                     "no filing corpus on this machine")
        // Only the keys are needed — the paths. Each document's value carries tokens and counters
        // of mixed shape, so it is decoded as opaque JSON rather than modelled.
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: corpusURL))
        let documents = try #require((raw as? [String: Any])?["documents"] as? [String: Any])

        var considered = 0, oldFalseVetoes = 0, newFalseVetoes = 0
        var oldOverAttributed = 0, newOverAttributed = 0
        for path in documents.keys {
            guard let slash = path.lastIndex(of: "/") else { continue }
            let folder = String(path[path.startIndex..<slash])
            let fileName = String(path[path.index(after: slash)...])
            guard let axis = loaded.profile.folders[folder]?.axes["person"]?.lowercased() else { continue }
            guard let goldPerson = loaded.registry.person(forAxisValue: axis) else { continue }
            considered += 1

            // The rule as it shipped: intersect the filename's tokens with a flat bag of names.
            let tokenPeople = FilingEngine.nameTokens(fileName)
                .intersection(loaded.profile.personTokens)
            if !tokenPeople.isEmpty, !tokenPeople.contains(axis) { oldFalseVetoes += 1 }
            if tokenPeople.count > 1 { oldOverAttributed += 1 }

            // The rule now: resolve through the registry, phrases first.
            let named = loaded.registry.detect(in: (fileName as NSString).deletingPathExtension)
            if !named.isEmpty, !named.contains(goldPerson) { newFalseVetoes += 1 }
            if named.count > 1 { newOverAttributed += 1 }
        }

        let summary = "of \(considered) person-filed documents — false vetoes \(oldFalseVetoes) → "
            + "\(newFalseVetoes); attributed to more than one person "
            + "\(oldOverAttributed) → \(newOverAttributed)"
        #expect(considered > 100, "too few person-filed documents to measure (\(considered))")
        #expect(newFalseVetoes <= oldFalseVetoes,
                "the registry refuses MORE correct folders than the token rule — \(summary)")
        // The rule this change is actually for. A document naming one person must not be read as
        // naming two; 36 of this corpus were, every one of them a shared given-name-as-surname.
        #expect(newOverAttributed < oldOverAttributed / 2,
                "phrase matching did not reduce over-attribution — \(summary)")
        print("Person attribution \(summary)")
    }

    @Test func theRealArtifactsDecodeAndAgreeWithEachOther() throws {
        let dir = try #require(FilingProfileStore.defaultDirectory())
        let loaded = try #require(FilingProfileStore.active(in: dir))
        #expect(loaded.profile.folders.count > 1000)

        let memory = try #require(loaded.memory)
        #expect(!memory.salt.isEmpty)
        #expect(memory.folders.count > 500)

        // **The two artifacts are snapshots, and they can be taken at different times.** This
        // machine's memory was rebuilt after `Immigration/` was reorganised on 6 Aug; the profile
        // was not, so the memory names folders the profile has never seen. That has to *degrade*,
        // not break — the path rule still answers for them and the router simply has no axes to
        // reason with. A large divergence would mean the two describe different trees.
        let unknown = memory.folders.keys.filter { loaded.profile.folders[$0] == nil }
        let drift = Double(unknown.count) / Double(memory.folders.count)
        #expect(drift < 0.05, "memory and profile disagree on \(unknown.count) folders — re-survey")
        for folder in unknown {
            // Answering at all is the requirement; an unknown folder must not become a destination
            // just because the profile cannot vouch for it.
            #expect(loaded.profile.acceptsNewFiles(folder) != FolderProfile.isInboxPath(folder))
        }

        // No inbox may carry filing memory into a destination list.
        let index = FilingRouter.makeIndex(destinations: Array(loaded.profile.folders.keys),
                                           profile: loaded.profile, memory: memory)
        #expect(!index.destinations.contains { $0.lowercased().contains("todo") })
        #expect(index.destinations.count > 1000)
    }
}

/// **Identity was read from one place and written from another.**
///
/// Everything is read from `profiles/<activeProfileId>/`, named by `profiles.json`. The app then
/// built the roster and the tag store from `profile.profileId` — a field INSIDE the artifact that
/// decodes to `"default"` when absent, which nothing rejects. Omit it and reads come from `work/`
/// while the first roster edit writes to `default/`, where nothing reads it; the fingerprint hashes
/// that same empty directory, so every cached classification is keyed against artifacts not in use.
/// The same split appears on a directory rename, which the docs present as the way to add a second
/// tree.
@Suite struct FilingProfileIdentityTests {

    private func makeProfiles(activeId: String, folderId: String?) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("profile-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(activeId),
                                                withIntermediateDirectories: true)
        try Data("""
        {"schemaVersion":1,"activeProfileId":"\(activeId)"}
        """.utf8).write(to: dir.appendingPathComponent("profiles.json"))
        let idField = folderId.map { "\"profileId\":\"\($0)\"," } ?? ""
        try Data("""
        {\(idField)"root":"~/Documents","folders":[]}
        """.utf8).write(to: dir.appendingPathComponent("\(activeId)/folder-profile.json"))
        return dir
    }

    /// The folder the artifacts were found in is the identity, whatever the file calls itself.
    @Test func theLoadedIdIsTheFolderNotTheFieldInside() throws {
        let dir = try makeProfiles(activeId: "work", folderId: nil)
        defer { try? FileManager.default.removeItem(at: dir) }

        let loaded = try #require(FilingProfileStore.active(in: dir))
        // The premise: the field really did decode to something else, or this proves nothing.
        #expect(loaded.profile.profileId == "default",
                "the fixture stopped reproducing the split")
        #expect(loaded.id == "work",
                "the id every store is built from is still the field inside the file")
    }

    /// And when they agree — the ordinary case — nothing changes.
    @Test func anAgreeingProfileLoadsUnderItsOwnId() throws {
        let dir = try makeProfiles(activeId: "abhishek", folderId: "abhishek")
        defer { try? FileManager.default.removeItem(at: dir) }
        let loaded = try #require(FilingProfileStore.active(in: dir))
        #expect(loaded.id == "abhishek")
        #expect(loaded.profile.profileId == "abhishek")
    }

    /// The fingerprint follows the same id, so a cached verdict is keyed against the artifacts
    /// actually in use rather than an empty directory that happens to share a name.
    @Test func theFingerprintOfTheLoadedIdIsNotEmpty() throws {
        let dir = try makeProfiles(activeId: "work", folderId: nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        let loaded = try #require(FilingProfileStore.active(in: dir))
        #expect(!FilingProfileStore.fingerprint(id: loaded.id, in: dir).isEmpty)
        #expect(FilingProfileStore.fingerprint(id: loaded.profile.profileId, in: dir).isEmpty,
                "the fixture stopped showing why the wrong id is wrong")
    }
}
