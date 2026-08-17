import Foundation
import Testing
@testable import Sync

/// Pins ``FilingProfileStore/writeProfile(_:in:builtBy:now:)`` — the first and only path that has
/// ever written a folder profile.
///
/// The store's own doc says why this needs holding down: *"Read-only, deliberately. These artifacts
/// are produced by a survey of the tree, not by the app's normal operation, and a partial rewrite
/// from a half-finished scan would be worse than no profile at all."* Each of the four guarantees
/// that let a write exist at all is a separate test here, and **the never-overwrite guard is tested
/// in both directions** — writing where there is nothing, and refusing where there is something —
/// because a happy-path test alone passes just as well with the guard deleted.
@Suite struct FilingProfileWriteTests {

    private static func scratch() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fpw-\(UUID().uuidString)")
    }

    /// What the in-app survey can produce: paths and counts, no `naming`, no `anchors`, no axes.
    /// Deliberately unlike the hand-built fixture below in every visible field, so "the file did
    /// not change" and "the file changed to this" can never be confused.
    private static func nameOnly(id: String = "abhishek",
                                 root: String = "~/Documents") -> FolderProfile {
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
            personTokens: [], personAliases: [:])
    }

    // MARK: - Direction one: it writes where there is nothing

    /// The write lands, creates its directory, and **comes back through the ordinary reader** —
    /// which is the interchangeability claim: the JSON a survey writes here is the JSON the offline
    /// Python builder writes, or `profile(id:in:)` would refuse it on schema or shape.
    @Test func writesAProfileWhereThereIsNoneAndReadsBackThroughTheOrdinaryPath() throws {
        let root = Self.scratch()
        let dir = root.appendingPathComponent("nested/profiles")   // does not exist yet
        defer { try? FileManager.default.removeItem(at: root) }

        let written = try FilingProfileStore.writeProfile(Self.nameOnly(), in: dir,
                                                          now: Date(timeIntervalSince1970: 1_754_000_000))
        #expect(written == FilingProfileStore.profileURL(id: "abhishek", in: dir))

        let read = try #require(FilingProfileStore.profile(id: "abhishek", in: dir))
        #expect(read == Self.nameOnly())            // every field, including the empty person axis
        #expect(read.folders.count == 3)
        #expect(read.folders["Finance/Receipts"]?.fileCount == 9)
        #expect(!read.acceptsNewFiles("Finance/TODO"))
        #expect(read.acceptsNewFiles("Finance/Receipts"))

        // And the header the schema probe reads, plus the provenance a human opening the file needs.
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: written))
                                    as? [String: Any])
        #expect(object["schemaVersion"] as? Int == FilingProfileStore.currentSchema)
        #expect(object["builtBy"] as? String == "SyncCloud — in-app folder survey")
        // The instant is injected, so the stamp names 2025 however long this test lives — a stamp
        // taken from the wall clock says this year instead (mechanism 5: don't race the clock).
        #expect((object["generated"] as? String)?.hasPrefix("2025-") == true,
                "the stamp came from the wall clock, not the injected instant: \(object["generated"] ?? "nil")")
        #expect(object["folders"] is [Any], "folders is an ARRAY on disk — the decoder keys it by path")
        #expect(object["axes"] == nil, "a name-only survey claims no person axis at all")
    }

    /// A person axis survives the round trip, aliases included — the pairing that makes
    /// `Family/Mom` and `Muktha` one person rather than two.
    @Test func thePersonAxisRoundTrips() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = FolderProfile(profileId: "abhishek", root: "~/Documents",
                                    folders: Self.nameOnly().folders,
                                    personTokens: ["abhishek", "shweta", "mom", "muktha"],
                                    personAliases: ["mom": "muktha"])
        try FilingProfileStore.writeProfile(profile, in: dir)

        let read = try #require(FilingProfileStore.profile(id: "abhishek", in: dir))
        #expect(read.personTokens == ["abhishek", "shweta", "mom", "muktha"])
        #expect(read.personAliases["mom"] == "muktha")
        #expect(read == profile)
    }

    /// With no index at all, the write creates one and names itself active — the bootstrap this
    /// exists for. A fresh machine has no `profiles.json`, and a profile nothing points at is a
    /// file the app will never read.
    @Test func withNoIndexTheNewProfileBecomesTheActiveOne() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FilingProfileStore.activeProfileId(in: dir) == nil)

        try FilingProfileStore.writeProfile(Self.nameOnly(id: "fresh"), in: dir)

        #expect(FilingProfileStore.activeProfileId(in: dir) == "fresh")
        #expect(FilingProfileStore.active(in: dir)?.profile.profileId == "fresh")
    }

    // MARK: - Direction two: it refuses where there is something

    /// **The refusing direction, which the happy path skips.** A hand-built profile is on disk; the
    /// survey offers a name-only one for the same id; the write is refused with a distinguishable
    /// error and the existing file is *byte-identical* afterwards.
    ///
    /// The two profiles differ in every readable field, so a permissive guard cannot pass this by
    /// writing something that happens to read the same: `ROADMAP_V4.md` — "A name-only profile must
    /// never land on top of a hand-built one — it would degrade To File and Renames with nothing
    /// failing."
    /// Note the index assertion in here is a control, not coverage: the `profileExists` guard runs
    /// before the index is ever read, so no path in a refused call can reach `profiles.json`. It is
    /// kept because it states the intent, but no amendment bug can break it — the tests that do
    /// cover the amendment are the refusal pair and the in-place amend below.
    @Test func refusesOverAnExistingProfileAndLeavesItByteIdentical() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FilingProfileStoreTests.makeProfiles(dir, profile: FilingProfileStoreTests.profileJSON,
                                                 memory: nil)
        let url = FilingProfileStore.profileURL(id: "abhishek", in: dir)
        let before = try Data(contentsOf: url)
        let indexBefore = try Data(contentsOf: FilingProfileStore.indexURL(in: dir))

        #expect(throws: FilingProfileStore.WriteRefusal.profileExists(id: "abhishek")) {
            try FilingProfileStore.writeProfile(Self.nameOnly(), in: dir)
        }

        #expect(try Data(contentsOf: url) == before, "the hand-built profile's bytes moved")
        #expect(try Data(contentsOf: FilingProfileStore.indexURL(in: dir)) == indexBefore)

        // And what reads back is still the hand-built one — the survey's three folders are not
        // there, the surveyed anchors and person axis are.
        let read = try #require(FilingProfileStore.profile(id: "abhishek", in: dir))
        #expect(read.folders["Finance/US/Income Tax/2023"]?.anchors == ["income", "tax"])
        #expect(read.folders["Finance/Receipts"] == nil)
        #expect(read.personAliases["mom"] == "muktha")
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

    /// A `profiles.json` this build cannot read is refused, **and the profile is not written
    /// either** — the whole write fails, so a retry after the index is fixed is not blocked by a
    /// half-landed profile it would then refuse to replace.
    ///
    /// The expectation names the exact refusal rather than `(any Error).self`, which is what it used
    /// to say: a scratch directory that could not be created, a `Data` write that failed, any stray
    /// I/O error at all would have satisfied the loose form while the refusal under test had stopped
    /// firing. The string is part of it — "schema 99, not 1" is the sentence a caller prints, and a
    /// refusal that named the wrong version was a real bug in this file's history (a `false`
    /// `schemaVersion` read as schema 0).
    @Test func anUnreadableIndexRefusesTheWholeWrite() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let index = FilingProfileStore.indexURL(in: dir)
        try #"{"schemaVersion":99,"profiles":[{"profileId":"other"}]}"#
            .write(to: index, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: index)
        // A foreign schema reads as "nothing active" — which is exactly when this would otherwise
        // write, so the refusal has to be its own guard.
        #expect(FilingProfileStore.activeProfileId(in: dir) == nil)

        #expect(throws: FilingProfileStore.WriteRefusal.indexUnreadable("schema 99, not 1")) {
            try FilingProfileStore.writeProfile(Self.nameOnly(), in: dir)
        }
        #expect(try Data(contentsOf: index) == before)
        #expect(FilingProfileStore.profile(id: "abhishek", in: dir) == nil,
                "no profile may be left behind by a refused write")
    }

    // MARK: - The index is amended, never re-pointed

    /// **An active profile is never re-aimed.** Writing a *second* profile succeeds — it has no
    /// file of its own to overwrite — but `profiles.json` keeps naming the first, byte for byte.
    @Test func anActiveProfileIsNeverRePointed() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FilingProfileStoreTests.makeProfiles(dir, profile: FilingProfileStoreTests.profileJSON,
                                                 memory: nil)
        let index = FilingProfileStore.indexURL(in: dir)
        let before = try Data(contentsOf: index)

        try FilingProfileStore.writeProfile(Self.nameOnly(id: "second", root: "~/Work"), in: dir)

        #expect(try Data(contentsOf: index) == before, "profiles.json was rewritten")
        #expect(FilingProfileStore.activeProfileId(in: dir) == "abhishek")
        // The second profile is on disk and readable — additive, exactly as the id keying intends.
        #expect(FilingProfileStore.profile(id: "second", in: dir)?.root == "~/Work")
        #expect(FilingProfileStore.active(in: dir)?.profile.profileId == "abhishek")
    }

    /// When nothing is active the index is **amended, not replaced**: an entry the user or the
    /// offline builder already put there survives, and so does a field this build does not know.
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

    /// **The file on disk is only ever a whole profile.** Atomicity cannot be observed by reading a
    /// finished write, so this pins the one externally visible consequence of `.atomic`: Foundation
    /// writes an auxiliary file and *renames* it onto the destination, which replaces a symlink at
    /// that path. A plain write follows the link and creates its target instead.
    ///
    /// Measured both ways before this test was written — with `.atomic` the path becomes a regular
    /// file and the link target is never created; without it, the path stays a symlink and the
    /// target appears. Dropping `.atomic` therefore fails here, which is the whole point.
    @Test func theProfileIsWrittenAtomically() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("abhishek"),
                                                withIntermediateDirectories: true)
        let url = FilingProfileStore.profileURL(id: "abhishek", in: dir)
        let target = dir.appendingPathComponent("abhishek/somewhere-else.json")
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target.path)
        // A dangling link is not an existing profile, so the never-overwrite guard does not fire
        // here and this test measures atomicity rather than refusal.
        #expect(!FileManager.default.fileExists(atPath: url.path))

        try FilingProfileStore.writeProfile(Self.nameOnly(), in: dir)

        let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        #expect(type == .typeRegular, "the write followed a symlink — it was not atomic")
        #expect(!FileManager.default.fileExists(atPath: target.path),
                "the link's target was created, so the bytes went through the link")
        #expect(FilingProfileStore.profile(id: "abhishek", in: dir) != nil)
    }

    // MARK: - An index this cannot fully read is refused, not amended

    /// Writes `json` as `profiles.json` in a fresh directory and returns both, with the original
    /// bytes, so a test can assert the file did not move.
    private static func withIndex(_ json: String) throws -> (dir: URL, before: Data) {
        let dir = scratch()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = Data(json.utf8)
        try data.write(to: FilingProfileStore.indexURL(in: dir))
        return (dir, data)
    }

    /// **The index decides one thing — whether anything is already active — and it used to be asked
    /// twice, by two parsers that disagreed.**
    ///
    /// `activeProfileId(in:)` decodes with `JSONDecoder`, which throws on a type mismatch and so
    /// reported "nothing active" for an index whose `schemaVersion` was quoted; the amendment then
    /// re-read the same bytes with `JSONSerialization`, which accepts them, found no *Int* schema to
    /// object to, and re-pointed `activeProfileId` at the new survey. A quoted number is an ordinary
    /// hand-edit slip, and the profile it aimed away from is the hand-built one.
    ///
    /// The parameters are the shapes that split the two readers. Each must refuse, and each must
    /// leave `profiles.json` byte-for-byte as it was.
    @Test(arguments: [
        #"{"schemaVersion": "1", "activeProfileId": "hand-built", "profiles": []}"#,
        #"{"schemaVersion": 1, "activeProfileId": 123, "profiles": []}"#,
        // `true` bridges to NSNumber and satisfies `as? Int` as 1, so this is the case a plain
        // "is it an Int" test waves through while `JSONDecoder` rejects it — the two-reader split
        // again, one type over.
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
            atPath: FilingProfileStore.profileURL(id: "abhishek", in: dir).path),
                "the profile landed even though the index was refused")
    }

    /// A `profiles` list this cannot read is refused rather than silently emptied.
    ///
    /// It used to be `as? [[String: Any]] ?? []`, so an object-keyed `profiles` — or a list with a
    /// string in it — became an empty array and the rewrite dropped every profile the index named.
    /// That is precisely the clobber ``FilingProfileStore/WriteRefusal/indexUnreadable`` says it
    /// exists to prevent: "it names profiles a clobber would orphan".
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

    /// **An index symlinked somewhere unreadable is refused, not replaced.**
    ///
    /// `fileExists` follows symlinks and answers *false* for one whose target is missing, so an
    /// index linked onto a volume that is not mounted read as "no index here" — and the atomic write
    /// that followed replaced the link itself with a fresh one-profile index, orphaning everything
    /// the real one named. `attributesOfItem` is the check that sees the link rather than its
    /// target.
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
            atPath: FilingProfileStore.profileURL(id: "abhishek", in: dir).path),
                "the profile landed even though the index was refused")
    }

    /// **An index naming a profile that is not on disk is not "already answered".**
    ///
    /// The write path refuses to re-point an index that already names an active profile, which is
    /// right — but it took the *name* as proof. A hand-edit as small as a trailing space makes every
    /// read load nothing (`profiles/abhishek /folder-profile.json` does not exist) while the writer
    /// saw a non-empty string and declined to re-point for ever after: the bootstrap was dead and
    /// every call still reported success. A dangling pointer is not an answer, so "active" now asks
    /// the filesystem.
    ///
    /// The empty id is the same question, which is why it is no longer special-cased: `""` is not
    /// "no profile" — an empty component collapses in `appendingPathComponent`, so it addresses
    /// `profiles/folder-profile.json`, a layout that can genuinely exist. Asking whether the file is
    /// there answers both without guessing which ids are meaningful.
    @Test(arguments: ["abhishek ", "", "never-surveyed"])
    func anIndexNamingAProfileThatIsNotThereIsRePointed(id: String) throws {
        let (dir, _) = try Self.withIndex(#"{"schemaVersion": 1, "activeProfileId": "\#(id)"}"#)
        defer { try? FileManager.default.removeItem(at: dir) }

        try FilingProfileStore.writeProfile(Self.nameOnly(), in: dir)
        #expect(FilingProfileStore.activeProfileId(in: dir) == "abhishek",
                "the index still names a profile that does not exist, so nothing can load")
        #expect(FilingProfileStore.active(in: dir)?.profile.profileId == "abhishek")
    }

    /// The other half of that rule, and the one that must not regress: an id naming a profile that
    /// IS there is left alone. Without this the test above would pass just as well if the write path
    /// re-pointed unconditionally, which is the harm the guard exists for.
    @Test func anIndexNamingAProfileThatIsThereIsLeftAlone() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FilingProfileStoreTests.makeProfiles(dir, profile: FilingProfileStoreTests.profileJSON,
                                                 memory: nil)
        let before = try Data(contentsOf: FilingProfileStore.indexURL(in: dir))

        try FilingProfileStore.writeProfile(Self.nameOnly(id: "second", root: "~/Work"), in: dir)

        #expect(try Data(contentsOf: FilingProfileStore.indexURL(in: dir)) == before)
        #expect(FilingProfileStore.activeProfileId(in: dir) == "abhishek")
    }

    /// The control for both refusals above: an index this *can* read, with nothing active, really is
    /// amended — otherwise the two tests would pass just as well with the write path removed
    /// altogether.
    @Test func anIndexItUnderstandsIsStillAmendedInPlace() throws {
        let (dir, _) = try Self.withIndex(
            #"{"schemaVersion": 1, "profiles": [{"profileId": "older", "root": "~/Other"}], "note": "kept"}"#)
        defer { try? FileManager.default.removeItem(at: dir) }

        try FilingProfileStore.writeProfile(Self.nameOnly(), in: dir)

        let data = try Data(contentsOf: FilingProfileStore.indexURL(in: dir))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["activeProfileId"] as? String == "abhishek")
        #expect(object["note"] as? String == "kept", "an unrelated field was dropped")
        let listed = try #require(object["profiles"] as? [[String: Any]])
        #expect(listed.compactMap { $0["profileId"] as? String }.sorted() == ["abhishek", "older"],
                "the profile the index already named was not preserved")
    }

    /// **An index that already lists this profile must not be given a second entry for it.**
    ///
    /// The list is amended, and the id it is being amended for can already be in it: the offline
    /// builder writes an entry per profile, and an index can name a profile whose
    /// `folder-profile.json` is not on disk — which is exactly the state that makes this write
    /// *allowed* (nothing resolvable is active, so the index may be re-pointed). Without the
    /// `contains` guard the same id is listed twice, and every reader of `profiles` then has two
    /// records for one profile with no rule for which wins.
    ///
    /// The entry already there also has to survive intact, not be replaced by the one this would
    /// have appended: it carries a `displayName` the offline builder knew and a folder walk does
    /// not.
    @Test func anIndexThatAlreadyListsTheProfileDoesNotGainASecondEntry() throws {
        let (dir, _) = try Self.withIndex(#"""
        {"schemaVersion": 1,
         "profiles": [{"profileId": "abhishek", "root": "~/Old", "displayName": "Hand built"}]}
        """#)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Listed but not on disk, and nothing named active — so the write is allowed and reaches
        // the amendment, which is the only way to this branch.
        #expect(FilingProfileStore.activeProfileId(in: dir) == nil)

        try FilingProfileStore.writeProfile(Self.nameOnly(), in: dir)

        let object = try #require(try JSONSerialization
            .jsonObject(with: Data(contentsOf: FilingProfileStore.indexURL(in: dir)))
            as? [String: Any])
        #expect(object["activeProfileId"] as? String == "abhishek",
                "the index was not pointed at the profile just written")
        let profiles = try #require(object["profiles"] as? [[String: Any]])
        #expect(profiles.count == 1, "the index gained a duplicate entry for abhishek")
        #expect(profiles.first?["displayName"] as? String == "Hand built",
                "the entry already listed was replaced rather than left alone")
        #expect(profiles.first?["root"] as? String == "~/Old")
    }

    /// **A field written as `null` is absent, not unreadable.**
    ///
    /// `JSONSerialization` hands back `NSNull` for a JSON null, so `object["schemaVersion"]` is
    /// non-nil for `"schemaVersion": null` and every "is this field a shape I understand" check
    /// sees a value to object to. Refusing there would be wrong in the one direction that matters:
    /// a null field says nothing, and an index saying nothing about its schema, its active profile
    /// or its profile list is precisely the index this write path exists to amend. A hand-edit that
    /// clears a field by nulling it rather than deleting it is ordinary, and so is a generator that
    /// spells "unset" that way.
    ///
    /// Each shape must land the profile *and* amend the index — asserted rather than just "did not
    /// throw", because a refusal is not the only way to fail this.
    @Test(arguments: [
        #"{"schemaVersion": null, "profiles": []}"#,
        #"{"schemaVersion": 1, "activeProfileId": null, "profiles": []}"#,
        #"{"schemaVersion": 1, "profiles": null}"#,
    ])
    func aNullFieldInTheIndexIsAmendedRatherThanRefused(json: String) throws {
        let (dir, _) = try Self.withIndex(json)
        defer { try? FileManager.default.removeItem(at: dir) }

        try FilingProfileStore.writeProfile(Self.nameOnly(), in: dir)

        #expect(FilingProfileStore.profile(id: "abhishek", in: dir) != nil,
                "the profile was not written")
        #expect(FilingProfileStore.activeProfileId(in: dir) == "abhishek")
        let object = try #require(try JSONSerialization
            .jsonObject(with: Data(contentsOf: FilingProfileStore.indexURL(in: dir)))
            as? [String: Any])
        let profiles = try #require(object["profiles"] as? [[String: Any]])
        #expect(profiles.compactMap { $0["profileId"] as? String } == ["abhishek"],
                "the amended index does not list the profile it now names")
    }

    // MARK: - The bytes are a function of the profile, not of this launch

    /// The same entries in two dictionaries that **iterate differently**, by construction.
    ///
    /// Swift's `Dictionary` walks its buckets, and the bucket a key lands in depends on the
    /// capacity as well as on the per-launch hash seed — so building at two capacities is an
    /// explicit difference, where building in two *insertion* orders is not one at all (the same
    /// keys at the same capacity iterate the same way whatever order they went in). The capacity is
    /// raised until the two really do differ, because a fixture whose two inputs iterate identically
    /// is comparing a value against itself.
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
        "Work", "Photos", "Finance", "Finance/TODO", "Health/Aditi", "Travel", "Health",
        "Finance/Receipts"
    ].map {
        FolderProfileEntry(path: $0, role: nil, naming: nil, anchors: [], acceptsNewFiles: nil,
                           fileCount: 1, subfolderCount: 0, axes: [:])
    }

    private static let deterministicPeople = ["shweta", "abhishek", "aditi", "muktha", "girish"]

    private static func writeDeterministic(folders: [String: FolderProfileEntry],
                                           people: Set<String>) throws -> Data {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = FolderProfile(profileId: "abhishek", root: "~/Documents", folders: folders,
                                    personTokens: people,
                                    personAliases: ["mom": "muktha", "dad": "girish"])
        return try Data(contentsOf: FilingProfileStore.writeProfile(
            profile, in: dir, now: Date(timeIntervalSince1970: 1_754_000_000)))
    }

    /// **The file is byte-identical for the same logical profile, however its containers are laid
    /// out.** `writeProfile`'s own doc says why — the sort exists so "its hash feeds
    /// `fingerprint(id:in:)`", which keys `FilingVerdictCache`. A profile that re-serialises
    /// differently for the same content invalidates every cached verdict and re-bills a paid
    /// classification pass for a tree nobody changed. Nothing asserted it.
    ///
    /// Note what this limb can and cannot see. Determinism *across launches* is the property that
    /// matters, and no in-process comparison observes it: one `Dictionary` value iterates the same
    /// way all run long, so writing it twice is guaranteed to agree whether or not anything sorts.
    /// The two containers are therefore built to iterate differently on purpose — which is
    /// as close as a single process gets to a second launch. The companion test below covers what
    /// this one cannot.
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

    /// The limb with teeth: the output is in **canonical** order, which is what makes it a function
    /// of the content rather than of the layout — and it is the only form of this claim a single
    /// process can check, since a container's iteration order does not change within a run.
    ///
    /// Three separate orderings, three separate regressions: the `folders` array is sorted by path,
    /// the person axis's `values` are sorted, and every object's keys are sorted (`.sortedKeys`).
    /// Key order survives no parse, so it is read off the raw bytes.
    @Test func theProfileIsWrittenInCanonicalOrder() throws {
        let folders = Self.laidOutDifferently(Self.deterministicFolders)
        let bytes = try Self.writeDeterministic(folders: folders.a,
                                                people: Set(Self.deterministicPeople))
        let text = try #require(String(data: bytes, encoding: .utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])

        let entries = try #require(object["folders"] as? [[String: Any]])
        #expect(entries.compactMap { $0["path"] as? String }
                == ["Finance", "Finance/Receipts", "Finance/TODO", "Health", "Health/Aditi",
                    "Photos", "Travel", "Work"],
                "the folders array is in the dictionary's bucket order, not sorted by path")

        let axes = try #require(object["axes"] as? [String: Any])
        let person = try #require(axes["person"] as? [String: Any])
        #expect(person["values"] as? [String]
                == ["abhishek", "aditi", "girish", "muktha", "shweta"],
                "the person axis is in the set's bucket order, not sorted")

        // `.sortedKeys`, read as first-occurrence offsets: each of these spellings appears exactly
        // once at the top level, and the top level is written before any nested object that could
        // repeat one (`axes` sorts first of all).
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

    /// **The profile is removed when the index write fails**, because the alternative is the one
    /// state nothing can recover from.
    ///
    /// The profile lands first and the index second. If the second throws, the old code left a
    /// profile on disk that nothing pointed at — and, worse, one that every retry refused with
    /// `profileExists`, whose contract tells the caller *"this tree already has a profile and I did
    /// not touch it"*. On a fresh machine, the only state this write path exists for, that is a
    /// permanent block.
    ///
    /// **Tested through ``FilingProfileStore/land(_:at:index:at:)`` rather than through
    /// `writeProfile`, because the obvious way in stopped working.** Leaving a directory where
    /// `profiles.json` should be used to reach the rollback: the index read returned nothing, the
    /// index was composed from scratch, the profile landed, and the write to a directory failed. Once
    /// the store learned to tell "there but unreadable" from "absent", that same fixture began
    /// failing at the *read* — so the test kept passing while exercising a refusal and the rollback
    /// lost its only coverage, silently. The failure is now induced where it actually is: an index
    /// URL inside a directory that does not exist.
    @Test func aFailedIndexWriteRollsTheProfileBackAndLeavesTheTreeRetryable() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = FilingProfileStore.profileURL(id: "abhishek", in: dir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let bytes = Data(#"{"profileId":"abhishek"}"#.utf8)
        let unwritable = dir.appendingPathComponent("no-such-dir/profiles.json")

        #expect(throws: (any Error).self) {
            try FilingProfileStore.land(bytes, at: url, index: Data("{}".utf8), at: unwritable)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path),
                "the profile survived a failed index write — every retry now refuses to overwrite it")

        // The other direction, so the rollback cannot be passing by deleting unconditionally: with
        // a writable index the profile stays, and with NO index to write there is nothing to undo.
        let good = dir.appendingPathComponent("profiles.json")
        try FilingProfileStore.land(bytes, at: url, index: Data("{}".utf8), at: good)
        #expect(FileManager.default.fileExists(atPath: url.path))
        try FileManager.default.removeItem(at: url)
        try FilingProfileStore.land(bytes, at: url, index: nil, at: unwritable)
        #expect(FileManager.default.fileExists(atPath: url.path),
                "a write with no index to land must not roll itself back")
    }

    /// The rollback removes only what **this call** wrote.
    ///
    /// The caller's never-overwrite guard proved the path was free at check time, not at removal
    /// time. If another writer lands a profile in the gap between the two writes, an unconditional
    /// delete would take it out — inverting the refusal contract from "I did not touch it" into "I
    /// deleted it". The comparison is what prevents that, and it is only reachable deterministically
    /// through the injected index write: that closure runs in exactly the gap the race occupies.
    @Test func theRollbackLeavesAProfileItDidNotWrite() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = FilingProfileStore.profileURL(id: "abhishek", in: dir)
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

    /// The other direction, so the comparison cannot be passing by never removing anything: when the
    /// bytes on disk ARE this call's, they go.
    @Test func theRollbackRemovesTheProfileItDidWrite() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = FilingProfileStore.profileURL(id: "abhishek", in: dir)
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

    /// **Every stored field of an entry reaches the file.**
    ///
    /// `ProfileDocument.EntryBox` hand-mirrors ``FolderProfileEntry`` — its own `CodingKey` enum and
    /// eight explicit `encode` calls — because the JSON is a contract with the offline Python
    /// builder and being explicit about it is the point. The cost of an explicit mirror is that
    /// nothing fails when the two drift: a field added to the entry and its decoder, and forgotten
    /// here, is silently dropped from every write, and a round-trip fixture only notices if it
    /// happens to populate that field.
    ///
    /// So the mirror is checked against the type by reflection rather than by eye. `Mirror` lists
    /// the stored properties; every one of them has to appear as a key in the written JSON. The
    /// entry is fully populated for exactly that reason — the two omit-when-nil fields would
    /// otherwise be legitimately absent and the check would pass without seeing them.
    @Test func theEncoderWritesEveryFieldAnEntryStores() throws {
        let full = FolderProfileEntry(path: "Finance", role: .container, naming: "ordinal-month",
                                      anchors: ["tax"], acceptsNewFiles: false, fileCount: 3,
                                      subfolderCount: 4, axes: ["year": "2024"])
        // The fixture has to be genuinely full, or "every stored field appears" is measured over
        // fields that are absent for a legitimate reason. A field added later with a default would
        // otherwise arrive nil and be reported as a missing key, blaming the encoder for the fixture.
        let children = Mirror(reflecting: full).children
        #expect(children.count == 8, "FolderProfileEntry gained or lost a field — update this fixture")
        for child in children {
            #expect(!Self.isNilValue(child.value), "fixture leaves \(child.label ?? "?") nil, so it proves nothing about that field")
        }

        let profile = FolderProfile(profileId: "abhishek", root: "~/Documents",
                                    folders: ["Finance": full], personTokens: [], personAliases: [:])
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FilingProfileStore.writeProfile(profile, in: dir)

        let data = try Data(contentsOf: FilingProfileStore.profileURL(id: "abhishek", in: dir))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(object["folders"] as? [[String: Any]])
        let written = Set(try #require(entries.first).keys)

        let stored = Set(children.compactMap(\.label))
        #expect(stored.subtracting(written).isEmpty,
                "FolderProfileEntry stores \(stored.subtracting(written).sorted()) that the profile encoder never writes")

        // **Presence is not enough.** An encoder writing `[]` for `anchors` or `0` for `fileCount`
        // keeps every key and loses the data, so the entry is read back and compared whole.
        let read = try #require(FilingProfileStore.profile(id: "abhishek", in: dir))
        #expect(read.folders["Finance"] == full, "a field was written but with the wrong value")
    }

    /// Mirror hands back `Any`; an `Optional.none` inside it is not `nil` at that type.
    private static func isNilValue(_ value: Any) -> Bool {
        let mirror = Mirror(reflecting: value)
        return mirror.displayStyle == .optional && mirror.children.isEmpty
    }

    /// The `note` the file carries about itself has to describe what the builder actually produced.
    ///
    /// It claimed `anchors` and `axes` were "left empty rather than guessed" and that "filing falls
    /// back to folder names" — neither true: the survey derives both, measuring 99.73% for anchors
    /// and 99.80%-100% across the axes. Quote the floor rather than the best of them — 99.87% is
    /// `axes.lifecycle` alone, and the weakest axis is `axes.person` at 99.80%. These headers exist
    /// so a person auditing a bad suggestion can trust the artifact, which is exactly the reader a
    /// false note misdirects.
    @Test func theEmbeddedNoteDescribesWhatTheSurveyActuallyDerives() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FilingProfileStore.writeProfile(Self.nameOnly(), in: dir)

        let data = try Data(contentsOf: FilingProfileStore.profileURL(id: "abhishek", in: dir))
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
