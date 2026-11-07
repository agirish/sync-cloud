import Foundation
import Testing
@testable import Sync

/// Who wrote a profile, and what the app may therefore do with it. A profile the app derived from
/// a walk is re-derivable in seconds, so replacing it costs nothing. A hand-built one also records
/// judgements a walk can't see (`naming`, `folderSemantics`, the `outbound-pack` refusals), so
/// replacing it with a derived profile degrades To File and the rename pass while every suite stays
/// green. Every test here keeps those two cases apart.
@Suite struct FolderProfileProvenanceTests {

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
        let dir = try makeCanonicalTempRoot(prefix: "provenance")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try FilingProfileStore.writeProfile(Self.profile("fresh"), in: dir)

        let read = try #require(FilingProfileStore.profile(id: "fresh", in: dir))
        #expect(read.provenance == .derived)
        #expect(read.builtBy?.hasPrefix(FolderProfile.derivedBuiltByPrefix) == true,
                "the header the store stamps must be the one provenance recognises")
    }

    /// A profile the app did not stamp is hand-built:
    /// - one with no `builtBy` at all, the safe default: the only profiles without the header
    ///   predate the app writing any, and those are the hand-built ones;
    /// - somebody else's builder;
    /// - a hand-edited header, which costs the file its provenance, never its contents. Reading it
    ///   as hand-built is the cautious answer (it stops being replaceable), and it keeps its folders.
    @Test(arguments: [
        (#"{"schemaVersion": 1, "profileId": "old", "root": "~/Documents", "folders": []}"#, "old", 0, true),
        (#"{"schemaVersion": 1, "profileId": "py", "root": "~/Documents", "builtBy": "build_profile.py", "folders": []}"#, "py", 0, false),
        (#"{"schemaVersion": 1, "profileId": "odd", "root": "~/Documents", "builtBy": 42, "folders": [{"path": "Finance", "fileCount": 3, "subfolderCount": 0, "anchors": [], "axes": {}}]}"#,
         "odd", 1, true),
    ])
    func aProfileTheAppDidNotStampReadsAsHandBuilt(json: String, id: String, folderCount: Int, builtByIsNil: Bool) throws {
        let dir = try makeCanonicalTempRoot(prefix: "provenance")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.writeRaw(json, id: id, in: dir)

        let read = try #require(FilingProfileStore.profile(id: id, in: dir))
        #expect((read.builtBy == nil) == builtByIsNil)
        #expect(read.provenance == .handBuilt)
        #expect(read.folders.count == folderCount, "a bad header took the folders with it")
    }

    // MARK: - What may be re-pointed

    @Test func nothingActiveMeansTheNewProfileTakesOver() throws {
        let dir = try makeCanonicalTempRoot(prefix: "provenance")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try FilingProfileStore.writeProfile(Self.profile("first"), in: dir)
        #expect(FilingProfileStore.activeProfileId(in: dir) == "first")
    }

    /// The app may supersede its own previous derivation. Otherwise a survey writes a correct
    /// profile under a fresh id and nothing reads it, because `profiles.json` still names the old
    /// one, and no message says so.
    @Test func aDerivedProfileMayBeSuperseded() throws {
        let dir = try makeCanonicalTempRoot(prefix: "provenance")
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
        let dir = try makeCanonicalTempRoot(prefix: "provenance")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.writeRaw(#"{"schemaVersion": 1, "profileId": "father", "root": "~/Documents", "folders": []}"#,
                          id: "father", in: dir)
        try Self.writeIndex(active: "father", in: dir)

        _ = try FilingProfileStore.writeProfile(Self.profile("derived"), in: dir)

        #expect(FilingProfileStore.activeProfileId(in: dir) == "father",
                "a derived profile took over from a hand-built one")
        #expect(FilingProfileStore.profile(id: "derived", in: dir) != nil,
                "the derived profile should still be written — it is refused the pointer, not the disk")
    }

    /// An active profile this build can't read is not one it may decide it owns. Refusing leaves
    /// the user where they were; the alternative treats an unparseable file as the app's own and
    /// points everything away from it.
    @Test func anUnreadableActiveProfileIsNotSuperseded() throws {
        let dir = try makeCanonicalTempRoot(prefix: "provenance")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.writeRaw("{ not json at all", id: "broken", in: dir)
        try Self.writeIndex(active: "broken", in: dir)

        _ = try FilingProfileStore.writeProfile(Self.profile("derived"), in: dir)
        #expect(FilingProfileStore.activeProfileId(in: dir) == "broken")
    }

    /// An active id naming a profile that isn't on disk at all is superseded. `indexForAmending`
    /// normalises a dangling id to "nothing active": re-pointing away from a name that resolves to
    /// no file can't lose anything, and otherwise a hand-edit as small as a trailing space would
    /// leave the bootstrap dead while reporting success. So provenance only decides the case where
    /// the file is there: hand-built (refuse), derived (replace), or unreadable (refuse, above).
    @Test func anActiveIdWithNoProfileBehindItIsSuperseded() throws {
        let dir = try makeCanonicalTempRoot(prefix: "provenance")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.writeIndex(active: "ghost", in: dir)

        _ = try FilingProfileStore.writeProfile(Self.profile("derived"), in: dir)
        #expect(FilingProfileStore.activeProfileId(in: dir) == "derived",
                "a dangling pointer left the app with no profile it could reach")
    }

    /// The path guard still holds: an id already on disk is refused outright. Provenance decides
    /// what may be re-pointed, never what may be overwritten; a profile is always written under a
    /// fresh id, so this refusal is what stops one being clobbered in place.
    @Test func writingOverAnExistingIdIsStillRefused() throws {
        let dir = try makeCanonicalTempRoot(prefix: "provenance")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try FilingProfileStore.writeProfile(Self.profile("same"), in: dir)

        #expect(throws: FilingProfileStore.WriteRefusal.profileExists(id: "same")) {
            _ = try FilingProfileStore.writeProfile(Self.profile("same"), in: dir)
        }
    }
}
