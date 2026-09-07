import Foundation
import Testing
@testable import Sync

/// Walking a tree and writing a profile from it.
///
/// The derivation and the write were both shipped and had nothing between them: no code path walked
/// a tree and put the two together, so a machine that never ran the out-of-repo builder had no way
/// to get a profile at all. These are the seams of that path — what it records, what it refuses, and
/// the one outcome that looks like success and is not.
@MainActor
@Suite struct FolderWalkTests {

    private static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A small tree with the shapes the builder reads: a container, an inbox, a person bucket.
    private static func tree(in root: URL) throws {
        for path in ["Finance", "Finance/Receipts", "Finance/TODO", "Family", "Family/Mother"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path),
                                                    withIntermediateDirectories: true)
        }
        try "x".write(to: root.appendingPathComponent("Finance/Receipts/2024 receipt.pdf"),
                      atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("Family/Mother/passport.pdf"),
                      atomically: true, encoding: .utf8)
    }

    private func manager(profiles: URL) -> FileSyncManager {
        let m = FileSyncManager()
        m.filingProfilesDirectory = profiles
        return m
    }

    // MARK: - The happy path

    @Test func aWalkWritesAProfileAndBecomesActive() async throws {
        let root = try Self.scratch(), profiles = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: profiles) }
        try Self.tree(in: root)

        let result = await manager(profiles: profiles).deriveFolderProfile(root: root)
        let report = try #require(try? result.get())

        #expect(report.foldersProfiled > 0, "the walk recorded no folders from a tree that has them")
        #expect(report.becameActive)
        #expect(FilingProfileStore.activeProfileId(in: profiles) == report.profileId)

        let written = try #require(FilingProfileStore.profile(id: report.profileId, in: profiles))
        #expect(written.provenance == .derived, "the app must be able to replace its own work later")
        #expect(written.folders["Finance"] != nil)
        #expect(!written.acceptsNewFiles("Finance/TODO"), "an inbox was recorded as a destination")
    }

    /// The confirmed places reach the profile, and nothing else becomes one.
    ///
    /// The mining is only 83.2% right and every point of the gap is an invention, so the vocabulary
    /// is handed in. This is the assertion that the hand-in is actually honoured.
    @Test func onlyConfirmedPlacesBecomeJurisdictions() async throws {
        let root = try Self.scratch(), profiles = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: profiles) }
        for path in ["Finance/US", "Finance/EMP", "Legal/US"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path),
                                                    withIntermediateDirectories: true)
        }

        let result = await manager(profiles: profiles).deriveFolderProfile(root: root,
                                                                          jurisdictionValues: ["US"])
        let report = try #require(try? result.get())
        #expect(report.jurisdictions == ["US"])

        let written = try #require(FilingProfileStore.profile(id: report.profileId, in: profiles))
        #expect(written.folders["Finance/US"]?.axes["jurisdiction"] == "US")
        #expect(written.folders["Finance/EMP"]?.axes["jurisdiction"] == nil,
                "an unconfirmed value became a jurisdiction — the whole error is in the guessing")
    }

    /// The root is recorded the way the hand-built profiles spell it.
    @Test func theRootIsRecordedRelativeToHome() {
        let home = NSHomeDirectory()
        #expect(FileSyncManager.recordedRoot(for: URL(fileURLWithPath: home + "/Documents"))
                == "~/Documents")
        #expect(FileSyncManager.recordedRoot(for: URL(fileURLWithPath: "/Volumes/Archive/Docs"))
                == "/Volumes/Archive/Docs", "a path outside home has no ~ to fold")
    }

    /// Every walk gets its own id, so nothing is ever written over.
    @Test func eachWalkGetsItsOwnProfileId() {
        let a = FileSyncManager.walkProfileId(now: Date(timeIntervalSince1970: 1_754_000_000))
        let b = FileSyncManager.walkProfileId(now: Date(timeIntervalSince1970: 1_754_000_060))
        #expect(a != b)
        for id in [a, b] {
            #expect(!id.contains("/"), "a profile id is interpolated into a path")
            #expect(!id.contains(" "), "a space in a directory name is a needless trap")
            #expect(!id.isEmpty)
        }
    }

    /// Two walks inside one second do not collide.
    ///
    /// The stamp is second-resolution and `writeProfile` refuses over an existing id, so without a
    /// suffix the ordinary act of pressing *Learn again* on a small tree reported "the profile could
    /// not be written".
    @Test func twoWalksInTheSameSecondBothLand() async throws {
        let root = try Self.scratch(), profiles = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: profiles) }
        try Self.tree(in: root)
        let manager = manager(profiles: profiles)
        let instant = Date(timeIntervalSince1970: 1_754_000_000)

        let first = try #require(try? (await manager.deriveFolderProfile(root: root, now: instant)).get())
        let second = try #require(try? (await manager.deriveFolderProfile(root: root, now: instant)).get())

        #expect(first.profileId != second.profileId)
        #expect(second.becameActive, "the second walk of the same second was refused")
        #expect(FilingProfileStore.profile(id: first.profileId, in: profiles) != nil)
        #expect(FilingProfileStore.profile(id: second.profileId, in: profiles) != nil)
    }

    // MARK: - What it refuses

    @Test func aWalkWithNowhereToWriteFails() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.tree(in: root)

        let result = await FileSyncManager().deriveFolderProfile(root: root)
        #expect(throws: FileSyncManager.FolderWalkFailure.noProfilesDirectory) { try result.get() }
    }

    /// An unreadable root is not "your tree has no folders".
    ///
    /// **Recording an empty profile would be worse than refusing.** It decodes perfectly, reads as a
    /// surveyed tree everywhere downstream, and answers every routing question with "no destination"
    /// — a confident wrong answer, latched, which is the failure mode this repo has hit before.
    @Test func anUnreadableRootIsRefusedRatherThanRecordedAsEmpty() async throws {
        let profiles = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: profiles) }
        let missing = URL(fileURLWithPath: "/private/tmp/does-not-exist-\(UUID().uuidString)")

        let result = await manager(profiles: profiles).deriveFolderProfile(root: missing)
        #expect(throws: FileSyncManager.FolderWalkFailure.rootUnreadable(missing.path)) {
            try result.get()
        }
        #expect(FilingProfileStore.activeProfileId(in: profiles) == nil,
                "a refused walk still moved the pointer")
    }

    /// A readable folder with nothing in it is refused too, and for its own reason.
    ///
    /// Distinct from unreadable: this one the app *could* profile, and the profile would be empty —
    /// which decodes perfectly, reads as a surveyed tree everywhere downstream, and answers every
    /// routing question with a confident "no destination" while telling the user their tree was
    /// learned.
    @Test func anEmptyFolderIsRefusedRatherThanProfiledAsNothing() async throws {
        let root = try Self.scratch(), profiles = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: profiles) }

        let result = await manager(profiles: profiles).deriveFolderProfile(root: root)
        #expect(throws: FileSyncManager.FolderWalkFailure.nothingToLearn(root.path)) { try result.get() }
        #expect(FilingProfileStore.activeProfileId(in: profiles) == nil)
    }

    /// The root's own entry is always there, so it cannot stand for a learned tree.
    ///
    /// The reason `nothingToLearn` counts entries below the root rather than asking `isEmpty`: a
    /// walk of a folder with nothing in it still produces a one-folder profile.
    @Test func anEmptyTreeStillProducesTheRootEntry() {
        let built = FolderSurveyBuilder.build(tree: [], root: "~/x", profileId: "p", registry: nil)
        #expect(built.folders.keys.sorted() == [FolderSurveyBuilder.rootEntryPath],
                "a guard written as folders.isEmpty would be a branch that never runs")
    }

    /// A file handed in where a folder was expected.
    @Test func aFileIsNotAFolderToLearn() async throws {
        let root = try Self.scratch(), profiles = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: profiles) }
        let file = root.appendingPathComponent("note.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let result = await manager(profiles: profiles).deriveFolderProfile(root: file)
        #expect(throws: FileSyncManager.FolderWalkFailure.rootUnreadable(file.path)) { try result.get() }
    }

    // MARK: - The outcome that looks like success

    /// A walk on a machine with a hand-built profile succeeds, lands on disk, and is **not** used.
    ///
    /// **This is the one worth reporting rather than swallowing.** The store refuses to re-point
    /// away from a profile it did not write — correctly, since a hand-built one records judgements a
    /// walk cannot see — so the honest outcome is "done, and it changed nothing you will notice".
    /// A report that said only "learned 3,013 folders" would be true and misleading.
    @Test func aWalkBesideAHandBuiltProfileSaysItIsNotInUse() async throws {
        let root = try Self.scratch(), profiles = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: profiles) }
        try Self.tree(in: root)

        // A hand-built profile: no `builtBy` header at all, which is how every one of them reads.
        let handBuilt = profiles.appendingPathComponent("father")
        try FileManager.default.createDirectory(at: handBuilt, withIntermediateDirectories: true)
        try #"{"schemaVersion": 1, "profileId": "father", "root": "~/Documents", "folders": []}"#
            .write(to: handBuilt.appendingPathComponent("folder-profile.json"),
                   atomically: true, encoding: .utf8)
        try #"{"schemaVersion": 1, "activeProfileId": "father"}"#
            .write(to: profiles.appendingPathComponent("profiles.json"),
                   atomically: true, encoding: .utf8)

        let result = await manager(profiles: profiles).deriveFolderProfile(root: root)
        let report = try #require(try? result.get())

        #expect(report.foldersProfiled > 0, "the walk itself should still have run")
        #expect(!report.becameActive)
        #expect(report.summary.contains("did not write"),
                "the summary reads as plain success — a user would not know it changed nothing")
        #expect(FilingProfileStore.activeProfileId(in: profiles) == "father")
        #expect(FilingProfileStore.profile(id: report.profileId, in: profiles) != nil,
                "the derived profile should be on disk — it is refused the pointer, not the write")
    }

    /// A second walk on a machine whose profile the app wrote **does** take over.
    ///
    /// The other side of the rule, and the case the old existence-keyed guard got wrong: a survey
    /// would run to completion and then be ignored, with nothing saying so.
    @Test func aSecondWalkSupersedesTheFirst() async throws {
        let root = try Self.scratch(), profiles = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: profiles) }
        try Self.tree(in: root)
        let manager = manager(profiles: profiles)

        let first = try #require(try? (await manager.deriveFolderProfile(
            root: root, now: Date(timeIntervalSince1970: 1_754_000_000))).get())
        let second = try #require(try? (await manager.deriveFolderProfile(
            root: root, now: Date(timeIntervalSince1970: 1_754_000_600))).get())

        #expect(first.profileId != second.profileId)
        #expect(second.becameActive)
        #expect(FilingProfileStore.activeProfileId(in: profiles) == second.profileId)
        #expect(FilingProfileStore.profile(id: first.profileId, in: profiles) != nil,
                "the superseded profile was deleted — it is the only record of what was in use")
    }
}
