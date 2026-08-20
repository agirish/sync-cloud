import Foundation
import Testing
@testable import Sync

/// Who wrote a profile, and what the app is therefore allowed to do with it.
///
/// **The asymmetry is the whole subject.** A profile the app derived from a walk is re-derivable in
/// seconds, so replacing it costs nothing. A hand-built one also records judgements a walk cannot
/// see — `naming`, `folderSemantics`, the `outbound-pack` refusals — so replacing *that* with a
/// derived profile degrades To File and the rename pass while every suite stays green. Every test
/// here is about keeping those two cases apart.
@Suite struct FolderProfileProvenanceTests {

    private static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func profile(_ id: String) -> FolderProfile {
        FolderProfile(profileId: id, root: "~/Documents",
                      folders: ["Finance": FolderProfileEntry(path: "Finance", role: nil, naming: nil, anchors: [], acceptsNewFiles: nil, fileCount: 3, subfolderCount: 0, axes: [:])],
                      personTokens: [])
    }

    /// Writes a profile file directly, so a test can stage a header this build would not write.
    private static func writeRaw(_ json: String, id: String, in directory: URL) throws {
        let dir = directory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent("folder-profile.json"),
                       atomically: true, encoding: .utf8)
    }

    private static func writeIndex(active: String?, in directory: URL) throws {
        let body = active.map { "{\"schemaVersion\": 1, \"activeProfileId\": \"\($0)\"}" }
            ?? "{\"schemaVersion\": 1}"
        try body.write(to: directory.appendingPathComponent("profiles.json"),
                       atomically: true, encoding: .utf8)
    }

    // MARK: - Reading provenance off the file

    /// A profile the app wrote reads as its own work.
    @Test func aProfileTheAppWroteReadsAsDerived() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try FilingProfileStore.writeProfile(Self.profile("fresh"), in: dir)

        let read = try #require(FilingProfileStore.profile(id: "fresh", in: dir))
        #expect(read.provenance == .derived)
        #expect(read.builtBy?.hasPrefix(FolderProfile.derivedBuiltByPrefix) == true,
                "the header the store stamps must be the one provenance recognises")
    }

    /// **A profile with no `builtBy` at all is hand-built**, and that is the safe default by
    /// construction: the only profiles without the header are the ones written before the app could
    /// write any, which are exactly the hand-built ones.
    @Test func aProfileWithNoHeaderReadsAsHandBuilt() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.writeRaw(#"{"schemaVersion": 1, "profileId": "old", "root": "~/Documents", "folders": []}"#,
                          id: "old", in: dir)

        let read = try #require(FilingProfileStore.profile(id: "old", in: dir))
        #expect(read.builtBy == nil)
        #expect(read.provenance == .handBuilt)
    }

    /// Somebody else's builder is hand-built too.
    @Test func aForeignBuilderReadsAsHandBuilt() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.writeRaw(#"{"schemaVersion": 1, "profileId": "py", "root": "~/Documents", "builtBy": "build_profile.py", "folders": []}"#,
                          id: "py", in: dir)

        let read = try #require(FilingProfileStore.profile(id: "py", in: dir))
        #expect(read.provenance == .handBuilt)
    }

    /// A hand-edited header costs the file its provenance, never its contents.
    ///
    /// Reading it as hand-built is the cautious answer — the file simply stops being replaceable —
    /// and it must not take the 3,013 folders with it.
    @Test func aMistypedHeaderCostsProvenanceAndNothingElse() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.writeRaw(#"{"schemaVersion": 1, "profileId": "odd", "root": "~/Documents", "builtBy": 42, "folders": [{"path": "Finance", "fileCount": 3, "subfolderCount": 0, "anchors": [], "axes": {}}]}"#,
                          id: "odd", in: dir)

        let read = try #require(FilingProfileStore.profile(id: "odd", in: dir))
        #expect(read.provenance == .handBuilt)
        #expect(read.folders.count == 1, "a bad header took the folders with it")
    }

    // MARK: - What may be re-pointed

    @Test func nothingActiveMeansTheNewProfileTakesOver() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try FilingProfileStore.writeProfile(Self.profile("first"), in: dir)
        #expect(FilingProfileStore.activeProfileId(in: dir) == "first")
    }

    /// The app may supersede its own previous derivation.
    ///
    /// **This is the case the old rule got wrong**, and it did not fail loudly: a survey ran to
    /// completion, wrote a correct profile under a fresh id, and then nothing read it — because
    /// `profiles.json` still named the old one and no message said so.
    @Test func aDerivedProfileMayBeSuperseded() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try FilingProfileStore.writeProfile(Self.profile("run-1"), in: dir)
        #expect(FilingProfileStore.activeProfileId(in: dir) == "run-1")

        _ = try FilingProfileStore.writeProfile(Self.profile("run-2"), in: dir)
        #expect(FilingProfileStore.activeProfileId(in: dir) == "run-2",
                "the app refused to replace its own derivation — the new survey is on disk and unread")

        // The superseded one is kept, never deleted: it is the only copy of what was in effect.
        #expect(FilingProfileStore.profile(id: "run-1", in: dir) != nil)
    }

    /// A hand-built profile is never re-pointed away from.
    @Test func aHandBuiltProfileIsNeverSuperseded() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.writeRaw(#"{"schemaVersion": 1, "profileId": "abhishek", "root": "~/Documents", "folders": []}"#,
                          id: "abhishek", in: dir)
        try Self.writeIndex(active: "abhishek", in: dir)

        _ = try FilingProfileStore.writeProfile(Self.profile("derived"), in: dir)

        #expect(FilingProfileStore.activeProfileId(in: dir) == "abhishek",
                "a derived profile took over from a hand-built one")
        #expect(FilingProfileStore.profile(id: "derived", in: dir) != nil,
                "the derived profile should still be written — it is refused the pointer, not the disk")
    }

    /// An active profile this build cannot read is not one it may decide it owns.
    ///
    /// The same principle as an absent header: refusing leaves the user where they were, and the
    /// alternative is deciding that an unparseable file is the app's own and aiming everything away
    /// from it.
    @Test func anUnreadableActiveProfileIsNotSuperseded() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.writeRaw("{ not json at all", id: "broken", in: dir)
        try Self.writeIndex(active: "broken", in: dir)

        _ = try FilingProfileStore.writeProfile(Self.profile("derived"), in: dir)
        #expect(FilingProfileStore.activeProfileId(in: dir) == "broken")
    }

    /// An active id naming a profile that is not on disk at all **is** superseded.
    ///
    /// **The opposite of what I first asserted here, and the existing rule is the better one.**
    /// `indexForAmending` already normalises a dangling id to "nothing active", with its reason
    /// written down: re-pointing away from a name that resolves to no file cannot lose anything,
    /// while re-pointing away from one that resolves is exactly what must never happen. A hand-edit
    /// as small as a trailing space would otherwise leave the bootstrap permanently dead while
    /// reporting success.
    ///
    /// So provenance never sees this case — it is settled one layer down. What provenance decides
    /// is the case where the file *is* there: readable and hand-built (refuse), readable and derived
    /// (replace), or present and unreadable (refuse, above).
    @Test func anActiveIdWithNoProfileBehindItIsSuperseded() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.writeIndex(active: "ghost", in: dir)

        _ = try FilingProfileStore.writeProfile(Self.profile("derived"), in: dir)
        #expect(FilingProfileStore.activeProfileId(in: dir) == "derived",
                "a dangling pointer left the app with no profile it could reach")
    }

    /// The path guard is unchanged: an id already on disk is refused outright.
    ///
    /// Provenance decides what may be *re-pointed*, never what may be *overwritten* — a profile is
    /// always written under a fresh id, so this refusal is what stops one being clobbered in place.
    @Test func writingOverAnExistingIdIsStillRefused() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try FilingProfileStore.writeProfile(Self.profile("same"), in: dir)

        #expect(throws: FilingProfileStore.WriteRefusal.profileExists(id: "same")) {
            _ = try FilingProfileStore.writeProfile(Self.profile("same"), in: dir)
        }
    }
}
