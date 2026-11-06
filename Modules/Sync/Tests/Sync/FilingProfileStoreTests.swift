import Foundation
import Testing
@testable import Sync

@Suite struct FilingProfileStoreTests {

    static func makeProfiles(_ dir: URL, id: String = "father",
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

    /// The on-disk shape, as the Python builder writes it, including the two-element token arrays
    /// and the axis aliases: decoding is the only contract between the builder and this module.
    static let profileJSON = """
    {"profileId":"father","root":"~/Documents",
     "axes":{"person":{"values":["Father","Mother"],"aliases":{"Mom":"Granny"}}},
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
    {"schemaVersion":1,"profileId":"father","salt":"abc123","idfFolderBase":2096,
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
        #expect(loaded.profile.profileId == "father")
        #expect(loaded.profile.folders.count == 3)
        #expect(loaded.memory?.folders.count == 1)
        #expect(loaded.memory?.salt == "abc123")

        let year = try #require(loaded.profile.folders["Finance/US/Income Tax/2023"])
        #expect(year.role == .yearBucket)
        #expect(year.yearKey == "2023")
        #expect(year.anchors == ["income", "tax"])
        // Aliases are the same person under two names: `Family/Mom` is Immigration's `Granny`.
        #expect(loaded.profile.personTokens.isSuperset(of: ["father", "mother", "mom", "granny"]))
        // The pairing survives decode too; without it nothing downstream can tell they are one
        // person.
        #expect(loaded.profile.personAliases["mom"] == "granny")

        let entry = try #require(loaded.memory?.folders["Finance/US/Income Tax/2023"])
        #expect(entry.docs == 12)
        #expect(entry.anchors.first == FilingMemoryToken(token: "turbotax", weight: 4.2))
        #expect(entry.idHashes.first?.token == "3437e15c04d360ef")
    }

    /// A year inside a descriptive name. `IRS Docs - 2024` sits beside the bare-year folders with no
    /// `year` axis, so without the name fallback it lands in another family and is never compared
    /// with the years it belongs to.
    @Test func aYearInTheNameIsFoundWhenTheAxisIsMissing() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.makeProfiles(dir, profile: Self.profileJSON, memory: nil)
        let p = try #require(FilingProfileStore.profile(id: "father", in: dir))
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
        let p = try #require(FilingProfileStore.profile(id: "father", in: dir))
        #expect(!p.acceptsNewFiles("Documents/TODO"))               // flagged in the profile
        #expect(!p.acceptsNewFiles("Health/TODO/Dental"))           // never surveyed, path rule
        #expect(!p.acceptsNewFiles("Work/EDD - TODO"))              // component, not suffix
        #expect(p.acceptsNewFiles("Finance/US/Income Tax/2023"))
    }

    /// A missing memory is ordinary, not a fault: the profile alone still routes.
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
        #expect(FilingProfileStore.profile(id: "father", in: dir) == nil)
        #expect(FilingProfileStore.activeProfileId(in: dir) == "father")
    }

    /// A future schema is refused, not half-read: decoded field by field, a new shape would become
    /// a mostly empty value that gets used, a silent wrong answer.
    @Test func aForeignSchemaIsRefusedRatherThanHalfRead() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let future = Self.memoryJSON.replacingOccurrences(of: "\"schemaVersion\":1",
                                                          with: "\"schemaVersion\":99")
        try Self.makeProfiles(dir, profile: Self.profileJSON, memory: future)
        #expect(FilingProfileStore.memory(id: "father", in: dir) == nil)
        // Control: the same file at the current schema still reads.
        try Self.makeProfiles(dir, profile: Self.profileJSON, memory: Self.memoryJSON)
        #expect(FilingProfileStore.memory(id: "father", in: dir) != nil)
    }

    /// `people.json` is read when present and supplies the full names, which a survey of folder
    /// names can't know and which make "Daughter Father" attributable to one person.
    @Test func aPeopleFileIsReadAndSuppliesTheFullNames() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.makeProfiles(dir, profile: Self.profileJSON, memory: nil)
        try """
        {"schemaVersion":1,"people":[
          {"id":"father","displayName":"Father","relationship":"me",
           "fullNames":["Father Elder"]},
          {"id":"daughter","displayName":"Daughter","relationship":"daughter",
           "fullNames":["Daughter Father"]},
          {"id":"granny","displayName":"Granny","relationship":"mother",
           "fullNames":["Granny Elder"],"aliases":["Mom","Mother"]}]}
        """.write(to: dir.appendingPathComponent("father/people.json"),
                  atomically: true, encoding: .utf8)

        let loaded = try #require(FilingProfileStore.active(in: dir))
        #expect(loaded.registry.source == .file)
        #expect(loaded.registry.people.count == 3)
        #expect(loaded.registry.people.first?.relationship == "me")
        #expect(loaded.registry.detect(in: "Daughter Father - OCI.pdf") == ["daughter"])
        #expect(loaded.registry.detect(in: "Mom - passport.pdf") == ["granny"])
    }

    /// With no `people.json` the registry is seeded from the profile's own axis, so aliases work on
    /// a tree that has only been surveyed.
    @Test func withNoPeopleFileTheRegistryIsSeededFromTheProfile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.makeProfiles(dir, profile: Self.profileJSON, memory: nil)

        let loaded = try #require(FilingProfileStore.active(in: dir))
        #expect(loaded.registry.source == .profileAxis)
        #expect(Set(loaded.registry.people.map(\.id)) == ["father", "mother", "granny"])
        #expect(loaded.registry.detect(in: "Mom - passport.pdf") == ["granny"])
    }

    /// The fingerprint moves when the roster does: it is mixed into every verdict cache key, and a
    /// changed roster changes the shortlist every file is asked about.
    @Test func theFingerprintMovesWhenThePeopleFileChanges() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.makeProfiles(dir, profile: Self.profileJSON, memory: nil)
        let before = FilingProfileStore.fingerprint(id: "father", in: dir)
        try #"{"schemaVersion":1,"people":[{"id":"daughter","displayName":"Daughter"}]}"#
            .write(to: dir.appendingPathComponent("father/people.json"),
                   atomically: true, encoding: .utf8)
        #expect(FilingProfileStore.fingerprint(id: "father", in: dir) != before)
    }

    /// A people.json that exists but can't be read makes the fingerprint unavailable, not
    /// different. A digest without it could never recur once the file is fixed, so every paid
    /// verdict recorded under it would be unreachable (see `PeopleStore.savedRevision`).
    @Test func anUnreadablePeopleFileMakesTheFingerprintUnavailable() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fps-\(UUID().uuidString)")
        let fm = FileManager.default
        let people = dir.appendingPathComponent("father/people.json")
        defer {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: people.path)
            try? fm.removeItem(at: dir)
        }
        try Self.makeProfiles(dir, profile: Self.profileJSON, memory: nil)
        try #"{"schemaVersion":1,"people":[{"id":"daughter","displayName":"Daughter"}]}"#
            .write(to: people, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: people.path)

        #expect(FilingProfileStore.fingerprint(id: "father", in: dir) == nil,
                "an unreadable component minted a digest instead of declaring it unavailable")
    }

    /// A genuinely absent people.json stays an ordinary state: the other artifacts still digest.
    @Test func anAbsentPeopleFileStillYieldsAFingerprint() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.makeProfiles(dir, profile: Self.profileJSON, memory: nil)

        let digest = FilingProfileStore.fingerprint(id: "father", in: dir)
        #expect(digest != nil, "an absent optional component made the fingerprint unavailable")
        #expect(digest != "", "the present artifacts were not digested")
    }

    /// The hash format is the contract with the builder. A change wouldn't fail, it would silently
    /// stop every identifier matching, so it is pinned against an independently computed literal:
    /// `sha256("abc123" + "1892")[0..<16]`.
    @Test func theIdentifierHashMatchesTheBuilder() {
        #expect(FilingMemory.hash("1892", salt: "abc123") == "3437e15c04d360ef")
        #expect(FilingMemory.hash("kaiser", salt: "s") == "3529b1a559fe505a")
    }
}

/// Decodes the artifacts on this machine, the only check that the Swift decoder agrees with the
/// Python generator on real data. Skipped visibly where they don't exist, rather than passing
/// vacuously.
@Suite(.enabled(if: FilingProfileStore.defaultDirectory().map {
    FileManager.default.fileExists(atPath: $0.appendingPathComponent("profiles.json").path)
} ?? false, "no filing profile on this machine"))
struct RealFilingProfileTests {

    /// Measures the registry against the token rule on the real corpus, where each filed document's
    /// folder is the right answer. False vetoes (refusing the document's own folder) must not rise.
    /// The number held is over-attribution: `Granny Elder - Resume.pdf` names one person, but the
    /// token rule reads two because `elder` is her surname and his given name (36 of 1,375 here).
    /// Each such file can slip into the wrong person's folder, unseen. Skipped where the corpus is
    /// absent; prints both numbers so a regression reads as a number.
    @Test func theRegistryRefusesFewerCorrectFoldersThanTheTokenRule() throws {
        let dir = try #require(FilingProfileStore.defaultDirectory())
        let loaded = try #require(FilingProfileStore.active(in: dir))
        let corpusURL = dir.appendingPathComponent("\(loaded.profile.profileId)/filing-corpus.json")
        try #require(FileManager.default.fileExists(atPath: corpusURL.path),
                     "no filing corpus on this machine")
        // Only the keys (the paths) are needed; the values are of mixed shape, so the file is read as
        // opaque JSON.
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
        // The point of the registry: a document naming one person must not be read as naming two.
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

        // The two artifacts are snapshots that can be taken at different times, so the memory may
        // name folders the profile has never seen. That must degrade, not break: the path rule still
        // answers and the router has no axes for them. A large divergence means different trees.
        let unknown = memory.folders.keys.filter { loaded.profile.folders[$0] == nil }
        let drift = Double(unknown.count) / Double(memory.folders.count)
        #expect(drift < 0.05, "memory and profile disagree on \(unknown.count) folders — re-survey")
        for folder in unknown {
            // An unknown folder must still get an answer, and the path rule decides it.
            #expect(loaded.profile.acceptsNewFiles(folder) != FolderProfile.isInboxPath(folder))
        }

        // No inbox may carry filing memory into a destination list.
        let index = FilingRouter.makeIndex(destinations: Array(loaded.profile.folders.keys),
                                           profile: loaded.profile, memory: memory)
        #expect(!index.destinations.contains { $0.lowercased().contains("todo") })
        #expect(index.destinations.count > 1000)
    }
}

/// A profile's identity is the folder it was loaded from (`profiles/<activeProfileId>/`), not the
/// `profileId` field inside it, which decodes to `"default"` when absent and goes stale on a folder
/// rename. Built from the field, roster edits would be written where nothing reads them, and the
/// fingerprint would hash an empty folder, keying every cached verdict against artifacts not in
/// use.
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
        // Premise: the field really did decode to something else.
        #expect(loaded.profile.profileId == "default",
                "the fixture stopped reproducing the split")
        #expect(loaded.id == "work",
                "the id every store is built from is still the field inside the file")
    }

    /// When they agree, the ordinary case, nothing changes.
    @Test func anAgreeingProfileLoadsUnderItsOwnId() throws {
        let dir = try makeProfiles(activeId: "father", folderId: "father")
        defer { try? FileManager.default.removeItem(at: dir) }
        let loaded = try #require(FilingProfileStore.active(in: dir))
        #expect(loaded.id == "father")
        #expect(loaded.profile.profileId == "father")
    }

    /// The fingerprint follows the same id, so a cached verdict is keyed against the artifacts
    /// actually in use rather than an empty directory that happens to share a name.
    @Test func theFingerprintOfTheLoadedIdIsNotEmpty() throws {
        let dir = try makeProfiles(activeId: "work", folderId: nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        let loaded = try #require(FilingProfileStore.active(in: dir))
        #expect(FilingProfileStore.fingerprint(id: loaded.id, in: dir)?.isEmpty == false)
        #expect(FilingProfileStore.fingerprint(id: loaded.profile.profileId, in: dir) == "",
                "the fixture stopped showing why the wrong id is wrong")
    }
}
