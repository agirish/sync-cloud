import Events
import EventsTestSupport
import Foundation
import Testing
@testable import Sync

/// Pins ``FilingProfileStore/writeProfile(_:in:builtBy:now:)``, the only path that writes a folder
/// profile. A partial or clobbering write would be worse than no profile, so each guarantee has its
/// own test: never overwrite, amend the index without re-pointing it, write atomically, and roll
/// back a half-landed write. The never-overwrite guard is tested in both directions, since a
/// happy-path test alone passes with the guard deleted.
@Suite struct FilingProfileWriteTests {

    private static func scratch() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fpw-\(UUID().uuidString)")
    }

    /// What the in-app survey can produce: paths and counts, no `naming`, `anchors` or axes. Unlike
    /// the hand-built fixture in every visible field, so "unchanged" and "changed to this" can't be
    /// confused.
    private static func nameOnly(id: String = "father",
                                 root: String = "~/Documents",
                                 builtBy: String? = nil) -> FolderProfile {
        FolderProfile(
            profileId: id, root: root,
            folders: [
                "Finance": FolderProfileEntry(path: "Finance", role: .container, naming: nil,
                                              anchors: [], acceptsNewFiles: nil, fileCount: 0,
                                              subfolderCount: 2, axes: [:]),
                "Finance/Receipts": FolderProfileEntry(path: "Finance/Receipts", role: nil,
                                                       naming: nil, anchors: [],
                                                       acceptsNewFiles: nil, fileCount: 9,
                                                       subfolderCount: 0, axes: [:]),
                "Finance/TODO": FolderProfileEntry(path: "Finance/TODO", role: .inbox, naming: nil,
                                                   anchors: [], acceptsNewFiles: false,
                                                   fileCount: 4, subfolderCount: 0, axes: [:])
            ],
            personTokens: [], personAliases: [:], builtBy: builtBy)
    }

    // MARK: - Direction one: it writes where there is nothing

    /// Paths are written with bare slashes. `JSONEncoder` escapes `/` by default, which decodes the
    /// same but stops the file diffing against the Python builder's output. Asserted on the bytes,
    /// since a decoder round trip passes either way; the positive check keeps a writer that emits
    /// no nested paths from passing.
    @Test func pathKeysAreWrittenWithBareSlashesSoTheFileDiffs() throws {
        let root = Self.scratch()
        let dir = root.appendingPathComponent("profiles")
        defer { try? FileManager.default.removeItem(at: root) }

        let written = try FilingProfileStore.writeProfile(Self.nameOnly(), in: dir)
        let text = try #require(String(data: try Data(contentsOf: written), encoding: .utf8))

        #expect(text.contains("Finance/Receipts"),
                "the nested path is not in the file at all, so this scan would be vacuous")
        #expect(!text.contains("\\/"),
                "a path is escaped as Finance\\/Receipts, so this profile does not diff against the Python builder's output")
    }

    /// The write lands, creates its directory, and reads back through `profile(id:in:)`, which
    /// would refuse JSON that didn't match the offline builder's schema or shape.
    @Test func writesAProfileWhereThereIsNoneAndReadsBackThroughTheOrdinaryPath() throws {
        let root = Self.scratch()
        let dir = root.appendingPathComponent("nested/profiles")   // does not exist yet
        defer { try? FileManager.default.removeItem(at: root) }

        let written = try FilingProfileStore.writeProfile(Self.nameOnly(), in: dir,
                                                          now: Date(timeIntervalSince1970: 1_754_000_000))
        #expect(written == FilingProfileStore.profileURL(id: "father", in: dir))

        let read = try #require(FilingProfileStore.profile(id: "father", in: dir))
        // Every field, including the empty person axis. Not an identity round trip: the store stamps
        // `builtBy`, which marks the profile as the app's own, so reading back the bare input would
        // mean provenance was dropped.
        #expect(read == Self.nameOnly(builtBy: read.builtBy))
        #expect(read.provenance == .derived)
        #expect(read.folders.count == 3)
        #expect(read.folders["Finance/Receipts"]?.fileCount == 9)
        #expect(!read.acceptsNewFiles("Finance/TODO"))
        #expect(read.acceptsNewFiles("Finance/Receipts"))

        // The header the schema probe reads, and the provenance a person opening the file needs.
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: written))
                                    as? [String: Any])
        #expect(object["schemaVersion"] as? Int == FilingProfileStore.currentSchema)
        #expect(object["builtBy"] as? String == "SyncCloud — in-app folder survey")
        // The instant is injected, so the stamp names 2025 whenever this runs; a wall-clock stamp
        // would name the current year.
        #expect((object["generated"] as? String)?.hasPrefix("2025-") == true,
                "the stamp came from the wall clock, not the injected instant: \(object["generated"] ?? "nil")")
        #expect(object["folders"] is [Any], "folders is an ARRAY on disk — the decoder keys it by path")
        #expect(object["axes"] == nil, "a name-only survey claims no person axis at all")
    }

    /// A person axis survives the round trip, aliases included: the pairing that makes `Family/Mom`
    /// and `Granny` one person.
    @Test func thePersonAxisRoundTrips() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = FolderProfile(profileId: "father", root: "~/Documents",
                                    folders: Self.nameOnly().folders,
                                    personTokens: ["father", "mother", "mom", "granny"],
                                    personAliases: ["mom": "granny"])
        try FilingProfileStore.writeProfile(profile, in: dir)

        let read = try #require(FilingProfileStore.profile(id: "father", in: dir))
        #expect(read.personTokens == ["father", "mother", "mom", "granny"])
        #expect(read.personAliases["mom"] == "granny")
        #expect(read == FolderProfile(profileId: profile.profileId, root: profile.root,
                                      folders: profile.folders, personTokens: profile.personTokens,
                                      personAliases: profile.personAliases, builtBy: read.builtBy))
        #expect(read.provenance == .derived)
    }

    /// With no index, the write creates one and names itself active. A fresh machine has no
    /// `profiles.json`, and a profile nothing points at is never read.
    @Test func withNoIndexTheNewProfileBecomesTheActiveOne() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FilingProfileStore.activeProfileId(in: dir) == nil)

        try FilingProfileStore.writeProfile(Self.nameOnly(id: "fresh"), in: dir)

        #expect(FilingProfileStore.activeProfileId(in: dir) == "fresh")
        #expect(FilingProfileStore.active(in: dir)?.profile.profileId == "fresh")
    }

    // MARK: - Direction two: it refuses where there is something

    /// A name-only profile never lands on a hand-built one, which would quietly degrade To File and
    /// Renames. The write is refused with `profileExists` and the existing file stays
    /// byte-identical. The two profiles differ in every field, so a permissive guard can't pass. The
    /// index check is a control only: the guard runs before the index is read.
    @Test func refusesOverAnExistingProfileAndLeavesItByteIdentical() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FilingProfileStoreTests.makeProfiles(dir, profile: FilingProfileStoreTests.profileJSON,
                                                 memory: nil)
        let url = FilingProfileStore.profileURL(id: "father", in: dir)
        let before = try Data(contentsOf: url)
        let indexBefore = try Data(contentsOf: FilingProfileStore.indexURL(in: dir))

        #expect(throws: FilingProfileStore.WriteRefusal.profileExists(id: "father")) {
            try FilingProfileStore.writeProfile(Self.nameOnly(), in: dir)
        }

        #expect(try Data(contentsOf: url) == before, "the hand-built profile's bytes moved")
        #expect(try Data(contentsOf: FilingProfileStore.indexURL(in: dir)) == indexBefore)

        // What reads back is still the hand-built profile: its anchors and person axis, none of the
        // survey's folders.
        let read = try #require(FilingProfileStore.profile(id: "father", in: dir))
        #expect(read.folders["Finance/US/Income Tax/2023"]?.anchors == ["income", "tax"])
        #expect(read.folders["Finance/Receipts"] == nil)
        #expect(read.personAliases["mom"] == "granny")
    }

    /// An id that cannot name a directory is refused before anything is written, rather than
    /// interpolated into a path and landing somewhere surprising.
    @Test func refusesAnIdThatCannotNameADirectory() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        for bad in ["", "../escape", "a/b", ".", ".."] {
            #expect(throws: FilingProfileStore.WriteRefusal.invalidProfileId(bad)) {
                try FilingProfileStore.writeProfile(Self.nameOnly(id: bad), in: dir)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: dir.path), "nothing may be created at all")
    }

    /// A `profiles.json` this build can't read refuses the whole write, profile included, so a
    /// retry after the index is fixed isn't blocked by a half-landed profile. The exact refusal is
    /// expected, string and all ("schema 99, not 1" is what a caller prints), since any stray I/O
    /// error would satisfy `(any Error).self`.
    @Test func anUnreadableIndexRefusesTheWholeWrite() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let index = FilingProfileStore.indexURL(in: dir)
        try #"{"schemaVersion":99,"profiles":[{"profileId":"other"}]}"#
            .write(to: index, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: index)
        // A foreign schema reads as "nothing active", exactly when this would otherwise write, so
        // the refusal needs its own guard.
        #expect(FilingProfileStore.activeProfileId(in: dir) == nil)

        #expect(throws: FilingProfileStore.WriteRefusal.indexUnreadable("schema 99, not 1")) {
            try FilingProfileStore.writeProfile(Self.nameOnly(), in: dir)
        }
        #expect(try Data(contentsOf: index) == before)
        #expect(FilingProfileStore.profile(id: "father", in: dir) == nil,
                "no profile may be left behind by a refused write")
    }

    // MARK: - The index is amended, never re-pointed

    /// An active profile is never re-aimed. Writing a second profile succeeds, having no file of its
    /// own to overwrite, but `profiles.json` keeps naming the first, byte for byte.
    @Test func anActiveProfileIsNeverRePointed() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FilingProfileStoreTests.makeProfiles(dir, profile: FilingProfileStoreTests.profileJSON,
                                                 memory: nil)
        let index = FilingProfileStore.indexURL(in: dir)
        let before = try Data(contentsOf: index)

        try FilingProfileStore.writeProfile(Self.nameOnly(id: "second", root: "~/Work"), in: dir)

        #expect(try Data(contentsOf: index) == before, "profiles.json was rewritten")
        #expect(FilingProfileStore.activeProfileId(in: dir) == "father")
        // The second profile is on disk and readable: writes are additive, keyed by id.
        #expect(FilingProfileStore.profile(id: "second", in: dir)?.root == "~/Work")
        #expect(FilingProfileStore.active(in: dir)?.profile.profileId == "father")
    }

    /// When nothing is active the index is amended, not replaced: an existing entry survives, and
    /// so does a field this build doesn't know.
    @Test func anIndexWithNothingActiveIsAmendedRatherThanReplaced() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"""
        {"schemaVersion":1,"generatedBy":"the offline builder",
         "profiles":[{"profileId":"archive","root":"~/Archive","displayName":"Archive"}]}
        """#.write(to: FilingProfileStore.indexURL(in: dir), atomically: true, encoding: .utf8)
        #expect(FilingProfileStore.activeProfileId(in: dir) == nil)

        try FilingProfileStore.writeProfile(Self.nameOnly(id: "fresh"), in: dir)

        #expect(FilingProfileStore.activeProfileId(in: dir) == "fresh")
        let object = try #require(try JSONSerialization
            .jsonObject(with: Data(contentsOf: FilingProfileStore.indexURL(in: dir))) as? [String: Any])
        #expect(object["generatedBy"] as? String == "the offline builder", "an unknown key was dropped")
        let profiles = try #require(object["profiles"] as? [[String: Any]])
        #expect(profiles.count == 2)
        #expect(profiles.contains { $0["displayName"] as? String == "Archive" },
                "the existing entry was replaced rather than kept")
        let fresh = try #require(profiles.first { $0["profileId"] as? String == "fresh" })
        #expect(fresh["root"] as? String == "~/Documents")
        #expect(fresh["displayName"] == nil, "a folder walk does not know the person's name")
    }

    // MARK: - Atomicity

    /// The file on disk is only ever a whole profile. Atomicity can't be seen in a finished write,
    /// so this pins its visible side effect: `.atomic` renames an auxiliary file onto the path,
    /// replacing a symlink there, while a plain write follows the link and creates its target.
    /// Dropping `.atomic` must fail this.
    @Test func theProfileIsWrittenAtomically() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("father"),
                                                withIntermediateDirectories: true)
        let url = FilingProfileStore.profileURL(id: "father", in: dir)
        let target = dir.appendingPathComponent("father/somewhere-else.json")
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target.path)
        // A dangling link is not an existing profile, so the never-overwrite guard doesn't fire and
        // this measures atomicity, not refusal.
        #expect(!FileManager.default.fileExists(atPath: url.path))

        try FilingProfileStore.writeProfile(Self.nameOnly(), in: dir)

        let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        #expect(type == .typeRegular, "the write followed a symlink — it was not atomic")
        #expect(!FileManager.default.fileExists(atPath: target.path),
                "the link's target was created, so the bytes went through the link")
        #expect(FilingProfileStore.profile(id: "father", in: dir) != nil)
    }

    // MARK: - An index this cannot fully read is refused, not amended

    /// Writes `json` as `profiles.json` in a fresh directory and returns it with the original bytes,
    /// so a test can assert the file didn't change.
    private static func withIndex(_ json: String) throws -> (dir: URL, before: Data) {
        let dir = scratch()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = Data(json.utf8)
        try data.write(to: FilingProfileStore.indexURL(in: dir))
        return (dir, data)
    }

    /// An index the strict reader rejects is refused, not re-pointed. `activeProfileId(in:)` uses
    /// `JSONDecoder`, which reads a type mismatch as "nothing active", while the amendment's
    /// `JSONSerialization` accepts it; between them a quoted `schemaVersion`, an ordinary hand-edit
    /// slip, would aim the index away from the hand-built profile. Each shape here splits the two
    /// readers; each must refuse and leave `profiles.json` byte-identical.
    @Test(arguments: [
        #"{"schemaVersion": "1", "activeProfileId": "hand-built", "profiles": []}"#,
        #"{"schemaVersion": 1, "activeProfileId": 123, "profiles": []}"#,
        // `true` bridges to NSNumber and satisfies `as? Int` as 1, while `JSONDecoder` rejects it.
        #"{"schemaVersion": true, "activeProfileId": "hand-built", "profiles": []}"#,
    ])
    func anIndexTheStrictReaderRejectsIsRefusedRatherThanRePointed(json: String) throws {
        let (dir, before) = try Self.withIndex(json)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: FilingProfileStore.WriteRefusal.self) {
            try FilingProfileStore.writeProfile(Self.nameOnly(), in: dir)
        }
        #expect(try Data(contentsOf: FilingProfileStore.indexURL(in: dir)) == before,
                "profiles.json was rewritten — an index this cannot read is still the user's")
        #expect(!FileManager.default.fileExists(
            atPath: FilingProfileStore.profileURL(id: "father", in: dir).path),
                "the profile landed even though the index was refused")
    }

    /// A `profiles` list this can't read is refused rather than emptied: read as an empty array, the
    /// rewrite would drop every profile the index named, the clobber
    /// ``FilingProfileStore/WriteRefusal/indexUnreadable`` exists to prevent.
    @Test(arguments: [
        #"{"schemaVersion": 1, "profiles": {"hand-built": {"root": "~/Documents"}}}"#,
        #"{"schemaVersion": 1, "profiles": ["hand-built"]}"#,
    ])
    func aProfilesListThisCannotReadIsRefusedRatherThanEmptied(json: String) throws {
        let (dir, before) = try Self.withIndex(json)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: FilingProfileStore.WriteRefusal.self) {
            try FilingProfileStore.writeProfile(Self.nameOnly(), in: dir)
        }
        #expect(try Data(contentsOf: FilingProfileStore.indexURL(in: dir)) == before,
                "the user's profile list was replaced by a one-element array")
    }

    /// An index symlinked somewhere unreadable is refused, not replaced. `fileExists` follows the
    /// link and answers false for a missing target (say, an unmounted volume), so the atomic write
    /// would replace the link with a one-profile index, orphaning everything the real one names.
    /// `attributesOfItem` sees the link itself.
    @Test func anIndexSymlinkedToSomethingUnreadableIsRefused() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let index = FilingProfileStore.indexURL(in: dir)
        try FileManager.default.createSymbolicLink(
            atPath: index.path, withDestinationPath: dir.appendingPathComponent("unmounted.json").path)

        #expect(throws: FilingProfileStore.WriteRefusal.self) {
            try FilingProfileStore.writeProfile(Self.nameOnly(), in: dir)
        }
        let type = try FileManager.default.attributesOfItem(atPath: index.path)[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink, "the symlink was replaced by a freshly composed index")
        #expect(!FileManager.default.fileExists(
            atPath: FilingProfileStore.profileURL(id: "father", in: dir).path),
                "the profile landed even though the index was refused")
    }

    /// An index naming a profile that isn't on disk is re-pointed: "active" asks the filesystem, not
    /// the name. Otherwise a hand-edit as small as a trailing space would make every read load
    /// nothing while the writer refused to re-point forever. The empty id is the same question: it
    /// collapses in `appendingPathComponent` to `profiles/folder-profile.json`, which can exist.
    @Test(arguments: ["father ", "", "never-surveyed"])
    func anIndexNamingAProfileThatIsNotThereIsRePointed(id: String) throws {
        let (dir, _) = try Self.withIndex(#"{"schemaVersion": 1, "activeProfileId": "\#(id)"}"#)
        defer { try? FileManager.default.removeItem(at: dir) }

        try FilingProfileStore.writeProfile(Self.nameOnly(), in: dir)
        #expect(FilingProfileStore.activeProfileId(in: dir) == "father",
                "the index still names a profile that does not exist, so nothing can load")
        #expect(FilingProfileStore.active(in: dir)?.profile.profileId == "father")
    }

    /// The other half: an id naming a profile that is there is left alone. Without it, the test
    /// above would pass if the write path re-pointed unconditionally.
    @Test func anIndexNamingAProfileThatIsThereIsLeftAlone() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FilingProfileStoreTests.makeProfiles(dir, profile: FilingProfileStoreTests.profileJSON,
                                                 memory: nil)
        let before = try Data(contentsOf: FilingProfileStore.indexURL(in: dir))

        try FilingProfileStore.writeProfile(Self.nameOnly(id: "second", root: "~/Work"), in: dir)

        #expect(try Data(contentsOf: FilingProfileStore.indexURL(in: dir)) == before)
        #expect(FilingProfileStore.activeProfileId(in: dir) == "father")
    }

    /// Control for the refusals above: a readable index with nothing active really is amended, or
    /// they would pass with the write path removed.
    @Test func anIndexItUnderstandsIsStillAmendedInPlace() throws {
        let (dir, _) = try Self.withIndex(
            #"{"schemaVersion": 1, "profiles": [{"profileId": "older", "root": "~/Other"}], "note": "kept"}"#)
        defer { try? FileManager.default.removeItem(at: dir) }

        try FilingProfileStore.writeProfile(Self.nameOnly(), in: dir)

        let data = try Data(contentsOf: FilingProfileStore.indexURL(in: dir))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["activeProfileId"] as? String == "father")
        #expect(object["note"] as? String == "kept", "an unrelated field was dropped")
        let listed = try #require(object["profiles"] as? [[String: Any]])
        #expect(listed.compactMap { $0["profileId"] as? String }.sorted() == ["father", "older"],
                "the profile the index already named was not preserved")
    }

    /// An index that already lists this profile gains no second entry. It can list a profile whose
    /// `folder-profile.json` isn't on disk, the very state that allows this write; a duplicate would
    /// leave readers two records with no rule for which wins. The existing entry survives intact,
    /// keeping a `displayName` a folder walk can't know.
    @Test func anIndexThatAlreadyListsTheProfileDoesNotGainASecondEntry() throws {
        let (dir, _) = try Self.withIndex(#"""
        {"schemaVersion": 1,
         "profiles": [{"profileId": "father", "root": "~/Old", "displayName": "Hand built"}]}
        """#)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Listed but not on disk, and nothing active, so the write reaches the amendment.
        #expect(FilingProfileStore.activeProfileId(in: dir) == nil)

        try FilingProfileStore.writeProfile(Self.nameOnly(), in: dir)

        let object = try #require(try JSONSerialization
            .jsonObject(with: Data(contentsOf: FilingProfileStore.indexURL(in: dir)))
            as? [String: Any])
        #expect(object["activeProfileId"] as? String == "father",
                "the index was not pointed at the profile just written")
        let profiles = try #require(object["profiles"] as? [[String: Any]])
        #expect(profiles.count == 1, "the index gained a duplicate entry for father")
        #expect(profiles.first?["displayName"] as? String == "Hand built",
                "the entry already listed was replaced rather than left alone")
        #expect(profiles.first?["root"] as? String == "~/Old")
    }

    /// A field written as `null` is absent, not unreadable. `JSONSerialization` returns `NSNull`, a
    /// non-nil value every shape check would object to, but a null says nothing, and an index that
    /// says nothing is exactly the one to amend. Each shape must land the profile and amend the
    /// index, not merely not throw.
    @Test(arguments: [
        #"{"schemaVersion": null, "profiles": []}"#,
        #"{"schemaVersion": 1, "activeProfileId": null, "profiles": []}"#,
        #"{"schemaVersion": 1, "profiles": null}"#,
    ])
    func aNullFieldInTheIndexIsAmendedRatherThanRefused(json: String) throws {
        let (dir, _) = try Self.withIndex(json)
        defer { try? FileManager.default.removeItem(at: dir) }

        try FilingProfileStore.writeProfile(Self.nameOnly(), in: dir)

        #expect(FilingProfileStore.profile(id: "father", in: dir) != nil,
                "the profile was not written")
        #expect(FilingProfileStore.activeProfileId(in: dir) == "father")
        let object = try #require(try JSONSerialization
            .jsonObject(with: Data(contentsOf: FilingProfileStore.indexURL(in: dir)))
            as? [String: Any])
        let profiles = try #require(object["profiles"] as? [[String: Any]])
        #expect(profiles.compactMap { $0["profileId"] as? String } == ["father"],
                "the amended index does not list the profile it now names")
    }

    // MARK: - The bytes are a function of the profile, not of this launch

    /// The same entries in two dictionaries that iterate differently. Iteration order depends on
    /// capacity and the per-launch hash seed, not insertion order, so the capacity is raised until
    /// the two really differ; otherwise the test compares a value with itself.
    private static func laidOutDifferently(_ entries: [FolderProfileEntry])
        -> (a: [String: FolderProfileEntry], b: [String: FolderProfileEntry]) {
        func made(_ capacity: Int) -> [String: FolderProfileEntry] {
            var d = [String: FolderProfileEntry](minimumCapacity: capacity)
            for e in entries { d[e.path] = e }
            return d
        }
        let a = made(entries.count)
        for capacity in [16, 64, 256, 1_024, 4_096, 16_384] {
            let b = made(capacity)
            if Array(b.keys) != Array(a.keys) { return (a, b) }
        }
        return (a, made(16_384))
    }

    /// The same trick for the person axis, which is a `Set` and walks its buckets the same way.
    private static func laidOutDifferently(_ tokens: [String]) -> (a: Set<String>, b: Set<String>) {
        func made(_ capacity: Int) -> Set<String> {
            var s = Set<String>(minimumCapacity: capacity)
            for t in tokens { s.insert(t) }
            return s
        }
        let a = made(tokens.count)
        for capacity in [16, 64, 256, 1_024, 4_096, 16_384] {
            let b = made(capacity)
            if Array(b) != Array(a) { return (a, b) }
        }
        return (a, made(16_384))
    }

    private static let deterministicFolders = [
        "Work", "Photos", "Finance", "Finance/TODO", "Health/Daughter", "Travel", "Health",
        "Finance/Receipts"
    ].map {
        FolderProfileEntry(path: $0, role: nil, naming: nil, anchors: [], acceptsNewFiles: nil,
                           fileCount: 1, subfolderCount: 0, axes: [:])
    }

    private static let deterministicPeople = ["mother", "father", "daughter", "granny", "elder"]

    private static func writeDeterministic(folders: [String: FolderProfileEntry],
                                           people: Set<String>) throws -> Data {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = FolderProfile(profileId: "father", root: "~/Documents", folders: folders,
                                    personTokens: people,
                                    personAliases: ["mom": "granny", "dad": "elder"])
        return try Data(contentsOf: FilingProfileStore.writeProfile(
            profile, in: dir, now: Date(timeIntervalSince1970: 1_754_000_000)))
    }

    /// The same logical profile writes the same bytes, however its containers are laid out. The
    /// file's hash feeds `fingerprint(id:in:)`, which keys `FilingVerdictCache`, so a
    /// re-serialisation would void every cached verdict and re-bill a paid pass. Determinism across
    /// launches is what matters; two containers built to iterate differently are the closest one
    /// process gets. The canonical-order test below covers the rest.
    @Test func theSameProfileFromDifferentlyLaidOutContainersWritesTheSameBytes() throws {
        let folders = Self.laidOutDifferently(Self.deterministicFolders)
        let people = Self.laidOutDifferently(Self.deterministicPeople)
        #expect(Array(folders.a.keys) != Array(folders.b.keys),
                "the two folder dictionaries iterate identically, so this compares a value with itself")
        #expect(Array(people.a) != Array(people.b),
                "the two person sets iterate identically, so this compares a value with itself")

        let first = try Self.writeDeterministic(folders: folders.a, people: people.a)
        let second = try Self.writeDeterministic(folders: folders.b, people: people.b)

        #expect(first == second, "the same profile wrote different bytes from a different layout")
        #expect(!first.isEmpty)
    }

    /// The output is in canonical order, which makes it a function of the content, not the layout.
    /// Three orderings, each its own regression: `folders` sorted by path, the person axis's
    /// `values` sorted, and every object's keys sorted (`.sortedKeys`). Key order survives no parse,
    /// so it is read off the raw bytes.
    @Test func theProfileIsWrittenInCanonicalOrder() throws {
        let folders = Self.laidOutDifferently(Self.deterministicFolders)
        let bytes = try Self.writeDeterministic(folders: folders.a,
                                                people: Set(Self.deterministicPeople))
        let text = try #require(String(data: bytes, encoding: .utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])

        let entries = try #require(object["folders"] as? [[String: Any]])
        #expect(entries.compactMap { $0["path"] as? String }
                == ["Finance", "Finance/Receipts", "Finance/TODO", "Health", "Health/Daughter",
                    "Photos", "Travel", "Work"],
                "the folders array is in the dictionary's bucket order, not sorted by path")

        let axes = try #require(object["axes"] as? [String: Any])
        let person = try #require(axes["person"] as? [String: Any])
        #expect(person["values"] as? [String]
                == ["daughter", "elder", "father", "granny", "mother"],
                "the person axis is in the set's bucket order, not sorted")

        // `.sortedKeys`, read as first-occurrence offsets: each key appears once at the top level,
        // before any nested object could repeat it (`axes` sorts first).
        let top = ["axes", "builtBy", "folderCount", "folders", "generated", "note", "portable",
                   "profileId", "root", "schemaVersion"]
        let offsets = top.map { key in
            text.range(of: "\"\(key)\":")
                .map { text.distance(from: text.startIndex, to: $0.lowerBound) }
        }
        #expect(offsets.allSatisfy { $0 != nil }, "a top-level key is missing: \(top) vs \(offsets)")
        #expect(offsets == offsets.sorted { ($0 ?? 0) < ($1 ?? 0) },
                "the object's keys are not in sorted order — .sortedKeys was dropped: \(offsets)")
    }

    // MARK: - A half-landed write leaves nothing behind

    /// The profile is removed when the index write fails. It lands first, so a failed index write
    /// would leave a profile nothing points at, and every retry would refuse it with
    /// `profileExists`: a permanent block on a fresh machine. Tested through
    /// ``FilingProfileStore/land(_:at:index:at:writeIndex:)`` with an index URL in a missing
    /// directory, because a broken index reached through `writeProfile` is refused at the read and
    /// never reaches the rollback.
    @Test func aFailedIndexWriteRollsTheProfileBackAndLeavesTheTreeRetryable() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = FilingProfileStore.profileURL(id: "father", in: dir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let bytes = Data(#"{"profileId":"father"}"#.utf8)
        let unwritable = dir.appendingPathComponent("no-such-dir/profiles.json")

        #expect(throws: (any Error).self) {
            try FilingProfileStore.land(bytes, at: url, index: Data("{}".utf8), at: unwritable)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path),
                "the profile survived a failed index write — every retry now refuses to overwrite it")

        // The other direction, so the rollback can't pass by always deleting: with a writable index
        // the profile stays, and with no index to write there is nothing to undo.
        let good = dir.appendingPathComponent("profiles.json")
        try FilingProfileStore.land(bytes, at: url, index: Data("{}".utf8), at: good)
        #expect(FileManager.default.fileExists(atPath: url.path))
        try FileManager.default.removeItem(at: url)
        try FilingProfileStore.land(bytes, at: url, index: nil, at: unwritable)
        #expect(FileManager.default.fileExists(atPath: url.path),
                "a write with no index to land must not roll itself back")
    }

    /// The rollback removes only what this call wrote. The never-overwrite guard proved the path
    /// free at check time, not at removal, so a profile another writer lands in the gap must
    /// survive. The injected index write runs in exactly that gap, making the race deterministic.
    @Test func theRollbackLeavesAProfileItDidNotWrite() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = FilingProfileStore.profileURL(id: "father", in: dir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let theirs = Data(#"{"profileId":"someone-else"}"#.utf8)

        #expect(throws: (any Error).self) {
            try FilingProfileStore.land(Data(#"{"profileId":"mine"}"#.utf8), at: url,
                                        index: Data("{}".utf8),
                                        at: dir.appendingPathComponent("profiles.json")) { _, _ in
                // Stand in for the concurrent writer, then fail the index write.
                try theirs.write(to: url)
                throw CocoaError(.fileWriteUnknown)
            }
        }
        #expect(FileManager.default.fileExists(atPath: url.path),
                "the rollback deleted a profile this call did not write")
        #expect(try Data(contentsOf: url) == theirs, "someone else's profile was modified")
    }

    // MARK: - …and the line that reports it says which of the three happened

    /// The most recent line `log` captured containing `fragment`. A capture, not the shared buffer,
    /// so other suites logging past the line can't push it out.
    @MainActor
    private static func loggedLine(_ log: LogCapture, containing fragment: String) async -> String? {
        await log.entries.last { $0.message.contains(fragment) }?.message
    }

    /// A profile id unique to one run: `Logger.shared` is process-wide and suites run in parallel,
    /// so a line matched on anything less could be another test's.
    private static func rollbackId() -> String { "rb-\(UUID().uuidString.prefix(8))" }

    /// The rollback's log line says which of three things happened: removed, left in place because
    /// another writer's bytes are there, or already gone. The last is common when the index write
    /// fails because the directory went away (an unmount, a rename), and must not claim a profile
    /// sits at an empty path. Each case also asserts the two sentences it must not be.
    @MainActor
    @Test func theRollbackLineSaysWhichOfTheThreeOutcomesHappened() async throws {
        let log = LogCapture()
        let removed = " — the profile just written was removed again"
        let left = "was left in place"
        let gone = "nothing is at"

        // 1. Removed by us: the ordinary rollback.
        let mine = Self.rollbackId()
        let mineDir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: mineDir) }
        let mineURL = FilingProfileStore.profileURL(id: mine, in: mineDir)
        try FileManager.default.createDirectory(at: mineURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try FilingProfileStore.land(Data(#"{"profileId":"mine"}"#.utf8), at: mineURL,
                                        index: Data("{}".utf8),
                                        at: mineDir.appendingPathComponent("profiles.json")) { _, _ in
                throw CocoaError(.fileWriteUnknown)
            }
        }
        var line = try #require(await Self.loggedLine(log, containing: mine),
                                "the rollback wrote no line at all")
        #expect(line.contains(removed), "the line does not say the profile went away: \(line)")
        #expect(!line.contains(left), "a removed profile is reported as left in place: \(line)")
        #expect(!line.contains(gone), "a profile this call removed is reported as merely absent: \(line)")

        // 2. Left in place because it is not ours: another writer landed in the gap.
        let theirs = Self.rollbackId()
        let theirsDir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: theirsDir) }
        let theirsURL = FilingProfileStore.profileURL(id: theirs, in: theirsDir)
        try FileManager.default.createDirectory(at: theirsURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try FilingProfileStore.land(Data(#"{"profileId":"mine"}"#.utf8), at: theirsURL,
                                        index: Data("{}".utf8),
                                        at: theirsDir.appendingPathComponent("profiles.json")) { _, _ in
                try Data(#"{"profileId":"someone-else"}"#.utf8).write(to: theirsURL)
                throw CocoaError(.fileWriteUnknown)
            }
        }
        line = try #require(await Self.loggedLine(log, containing: theirs),
                            "the rollback wrote no line for a profile it refused to remove")
        #expect(line.contains(left), "the line does not say the profile is still there: \(line)")
        #expect(!line.contains(removed), "a profile this call left alone is reported as removed: \(line)")
        #expect(!line.contains(gone), "a profile still on disk is reported as absent: \(line)")
        #expect(FileManager.default.fileExists(atPath: theirsURL.path),
                "the fixture's own premise failed — the profile was removed after all")

        // 3. Already gone: the index write fails because its directory went away, and the profile
        // went with it. Reported as (2), it would promise a refusal that can't happen.
        let vanished = Self.rollbackId()
        let vanishedDir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: vanishedDir) }
        let vanishedURL = FilingProfileStore.profileURL(id: vanished, in: vanishedDir)
        try FileManager.default.createDirectory(at: vanishedURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try FilingProfileStore.land(Data(#"{"profileId":"mine"}"#.utf8), at: vanishedURL,
                                        index: Data("{}".utf8),
                                        at: vanishedDir.appendingPathComponent("profiles.json")) { _, _ in
                // The profile's directory goes, as on an unmount or a rename, which is why the
                // index write fails.
                try FileManager.default.removeItem(at: vanishedURL.deletingLastPathComponent())
                throw CocoaError(.fileWriteUnknown)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: vanishedURL.path),
                "the fixture's own premise failed — the profile is still on disk")
        line = try #require(await Self.loggedLine(log, containing: vanished),
                            "a profile that vanished under the write was reported by nothing")
        #expect(line.contains(gone), "the line does not say the profile is already gone: \(line)")
        #expect(!line.contains(left),
                "the line still claims a profile sits at a path holding nothing, and predicts a refusal that cannot happen: \(line)")
        #expect(!line.contains(removed),
                "the line credits this rollback with a removal it did not make: \(line)")
    }

    /// The other direction, so the comparison can't pass by never removing: when the bytes on disk
    /// are this call's, they go.
    @Test func theRollbackRemovesTheProfileItDidWrite() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = FilingProfileStore.profileURL(id: "father", in: dir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        #expect(throws: (any Error).self) {
            try FilingProfileStore.land(Data(#"{"profileId":"mine"}"#.utf8), at: url,
                                        index: Data("{}".utf8),
                                        at: dir.appendingPathComponent("profiles.json")) { _, _ in
                throw CocoaError(.fileWriteUnknown)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - The file says what it is

    /// Every stored field of an entry reaches the file. `ProfileDocument.EntryBox` hand-mirrors
    /// ``FolderProfileEntry`` because the JSON is a contract with the Python builder, so a new field
    /// forgotten there is silently dropped from every write. `Mirror` lists the stored properties
    /// and each must appear as a key. The entry is fully populated so omit-when-nil fields can't
    /// hide.
    @Test func theEncoderWritesEveryFieldAnEntryStores() throws {
        let full = FolderProfileEntry(path: "Finance", role: .container, naming: "ordinal-month",
                                      anchors: ["tax"], acceptsNewFiles: false,
                                      noIntakeReason: "outbound-pack", fileCount: 3,
                                      subfolderCount: 4, axes: ["year": "2024"])
        // The fixture must be full, or a field added later with a nil default would be reported as
        // a missing key, blaming the encoder for the fixture.
        let children = Mirror(reflecting: full).children
        #expect(children.count == 9, "FolderProfileEntry gained or lost a field — update this fixture")
        for child in children {
            #expect(!Self.isNilValue(child.value), "fixture leaves \(child.label ?? "?") nil, so it proves nothing about that field")
        }

        let profile = FolderProfile(profileId: "father", root: "~/Documents",
                                    folders: ["Finance": full], personTokens: [], personAliases: [:])
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FilingProfileStore.writeProfile(profile, in: dir)

        let data = try Data(contentsOf: FilingProfileStore.profileURL(id: "father", in: dir))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(object["folders"] as? [[String: Any]])
        let written = Set(try #require(entries.first).keys)

        let stored = Set(children.compactMap(\.label))
        #expect(stored.subtracting(written).isEmpty,
                "FolderProfileEntry stores \(stored.subtracting(written).sorted()) that the profile encoder never writes")

        // Presence isn't enough: writing `[]` for `anchors` or `0` for `fileCount` keeps every key
        // and loses the data, so the entry is read back and compared whole.
        let read = try #require(FilingProfileStore.profile(id: "father", in: dir))
        #expect(read.folders["Finance"] == full, "a field was written but with the wrong value")
    }

    /// Mirror hands back `Any`; an `Optional.none` inside it is not `nil` at that type.
    private static func isNilValue(_ value: Any) -> Bool {
        let mirror = Mirror(reflecting: value)
        return mirror.displayStyle == .optional && mirror.children.isEmpty
    }

    /// The `note` the file carries must describe what the survey produces: it derives `anchors` and
    /// `axes`, so the note must not say they are left empty or that filing falls back to folder
    /// names. A person auditing a bad suggestion reads this header to judge the artifact.
    @Test func theEmbeddedNoteDescribesWhatTheSurveyActuallyDerives() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FilingProfileStore.writeProfile(Self.nameOnly(), in: dir)

        let data = try Data(contentsOf: FilingProfileStore.profileURL(id: "father", in: dir))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let note = try #require(object["note"] as? String)
        #expect(!note.contains("left empty rather than guessed"),
                "the note still claims the survey derives no anchors or axes")
        #expect(!note.lowercased().contains("falls back to folder names"),
                "the note still tells its reader filing ignores what the survey derived")
        #expect(note.contains("DERIVED"),
                "the note should say plainly that anchors and axes are derived, not merely omit the old claim")
        #expect(note.contains("`naming` is the exception"),
                "the one field genuinely abstained from should still be called out")
    }
}
