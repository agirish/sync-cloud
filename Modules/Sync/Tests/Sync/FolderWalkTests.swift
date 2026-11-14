import Foundation
import Testing
@testable import Sync

/// Walking a tree and writing a profile from it, the path that gives a machine a profile without
/// the out-of-repo builder: what it records, what it refuses, and the one outcome that looks like
/// success and isn't.
@MainActor
@Suite struct FolderWalkTests {

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

    /// A fresh tree root and profiles directory, both removed by `remove(_:)`.
    private func walkRoots() throws -> (root: URL, profiles: URL) {
        (try makeCanonicalTempRoot(prefix: "walk"), try makeCanonicalTempRoot(prefix: "walk"))
    }

    private func remove(_ urls: URL...) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    private func manager(profiles: URL) -> FileSyncManager {
        let m = FileSyncManager()
        m.filingProfilesDirectory = profiles
        return m
    }

    // MARK: - The happy path

    @Test func aWalkWritesAProfileAndBecomesActive() async throws {
        let (root, profiles) = try walkRoots()
        defer { remove(root, profiles) }
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

    /// The confirmed places reach the profile, and nothing else becomes one. Mining places from
    /// names is only about 83% right, and every miss is an invention, so the vocabulary is handed
    /// in; this checks the hand-in is honoured.
    @Test func onlyConfirmedPlacesBecomeJurisdictions() async throws {
        let (root, profiles) = try walkRoots()
        defer { remove(root, profiles) }
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

    /// Two walks inside one second don't collide. The stamp is second-resolution and `writeProfile`
    /// refuses over an existing id, so without a suffix pressing Learn again on a small tree would
    /// report "the profile could not be written".
    @Test func twoWalksInTheSameSecondBothLand() async throws {
        let (root, profiles) = try walkRoots()
        defer { remove(root, profiles) }
        try Self.tree(in: root)
        let manager = manager(profiles: profiles)
        let instant = Date(timeIntervalSince1970: 1_754_000_000)

        let first = try #require(try? (await manager.deriveFolderProfile(root: root, now: instant)).get())
        let second = try #require(try? (await manager.deriveFolderProfile(root: root, now: instant)).get())

        #expect(first.profileId != second.profileId)
        #expect(second.becameActive, "the second walk of the same second was refused")
        #expect(FilingProfileStore.activeProfileId(in: profiles) == second.profileId)
        #expect(FilingProfileStore.profile(id: first.profileId, in: profiles) != nil,
                "the superseded profile was deleted — it is the only record of what was in use")
        #expect(FilingProfileStore.profile(id: second.profileId, in: profiles) != nil)
    }

    // MARK: - What it refuses

    @Test func aWalkWithNowhereToWriteFails() async throws {
        let root = try makeCanonicalTempRoot(prefix: "walk")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.tree(in: root)

        let result = await FileSyncManager().deriveFolderProfile(root: root)
        #expect(throws: FileSyncManager.FolderWalkFailure.noProfilesDirectory) { try result.get() }
    }

    /// An unreadable root is refused, not recorded as "your tree has no folders". An empty profile
    /// decodes fine, reads as a surveyed tree everywhere downstream, and answers every routing
    /// question with a confident, latched "no destination".
    @Test func anUnreadableRootIsRefusedRatherThanRecordedAsEmpty() async throws {
        let profiles = try makeCanonicalTempRoot(prefix: "walk")
        defer { try? FileManager.default.removeItem(at: profiles) }
        let missing = URL(fileURLWithPath: "/private/tmp/does-not-exist-\(UUID().uuidString)")

        let result = await manager(profiles: profiles).deriveFolderProfile(root: missing)
        #expect(throws: FileSyncManager.FolderWalkFailure.rootUnreadable(missing.path)) {
            try result.get()
        }
        #expect(FilingProfileStore.activeProfileId(in: profiles) == nil,
                "a refused walk still moved the pointer")
    }

    /// A readable folder with nothing in it is refused too, for its own reason: the app could
    /// profile it, but the empty profile would answer every routing question with "no destination"
    /// while telling the user their tree was learned.
    @Test func anEmptyFolderIsRefusedRatherThanProfiledAsNothing() async throws {
        let (root, profiles) = try walkRoots()
        defer { remove(root, profiles) }

        let result = await manager(profiles: profiles).deriveFolderProfile(root: root)
        #expect(throws: FileSyncManager.FolderWalkFailure.nothingToLearn(root.path)) { try result.get() }
        #expect(FilingProfileStore.activeProfileId(in: profiles) == nil)
    }

    /// The root's own entry is always there, so it can't stand for a learned tree. This is why
    /// `nothingToLearn` counts entries below the root rather than asking `isEmpty`.
    @Test func anEmptyTreeStillProducesTheRootEntry() {
        let built = FolderSurveyBuilder.build(tree: [], root: "~/x", profileId: "p", registry: nil)
        #expect(built.folders.keys.sorted() == [FolderSurveyBuilder.rootEntryPath],
                "a guard written as folders.isEmpty would be a branch that never runs")
    }

    /// A file handed in where a folder was expected.
    @Test func aFileIsNotAFolderToLearn() async throws {
        let (root, profiles) = try walkRoots()
        defer { remove(root, profiles) }
        let file = root.appendingPathComponent("note.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let result = await manager(profiles: profiles).deriveFolderProfile(root: file)
        #expect(throws: FileSyncManager.FolderWalkFailure.rootUnreadable(file.path)) { try result.get() }
    }

    /// A write the disk refuses says why in a sentence, not as an `NSError` dump
    /// (`Error Domain=… UserInfo={…}`), since setup's Structure screen shows it under
    /// "Couldn’t save your folder profile".
    @Test func aRefusedWriteSaysWhyInASentence() async throws {
        let root = try makeCanonicalTempRoot(prefix: "walk"), elsewhere = try makeCanonicalTempRoot(prefix: "walk")
        defer { remove(root, elsewhere) }
        try Self.tree(in: root)
        let tree = await FileSyncManager.buildTree(url: root, sortOption: .name)
        // A regular file where the profiles folder's parent should be: nothing can be written.
        let blocker = elsewhere.appendingPathComponent("blocker")
        try Data("not a folder".utf8).write(to: blocker)

        let result = await manager(profiles: blocker.appendingPathComponent("profiles"))
            .writeWalkProfile(tree: tree, root: root)
        guard case .failure(.refused(let why)) = result else {
            Issue.record("premise: the write was refused — got \(result)")
            return
        }
        #expect(!why.isEmpty)
        #expect(!why.contains("Error Domain") && !why.contains("UserInfo"),
                "the refusal is an NSError dump: \(why)")
        #expect(FileSyncManager.FolderWalkFailure.refused(why).plainReason == why)
    }

    /// The store's own refusals each get a sentence; anything else, Foundation's own words.
    @Test func eachStoreRefusalHasItsOwnSentence() {
        typealias Failure = FileSyncManager.FolderWalkFailure
        #expect(Failure.plainRefusal(FilingProfileStore.WriteRefusal.indexUnreadable("not an object"))
                == "SyncCloud can’t read its list of folder profiles (profiles.json), so it won’t change it.")
        #expect(Failure.plainRefusal(FilingProfileStore.WriteRefusal.profileExists(id: "walk-1"))
                == "A profile with the same name was saved a moment ago. Try again.")
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        #expect(String(describing: cocoa).contains("Error Domain"),
                "premise: describing a Foundation error dumps it — the fallback below would be vacuous")
        #expect(Failure.plainRefusal(cocoa) == cocoa.localizedDescription)
        #expect(Failure.rootUnreadable("/Users/x/Documents").plainReason == "“Documents” couldn’t be read.")
    }

    // MARK: - The outcome that looks like success

    /// A walk on a machine with a hand-built profile succeeds, lands on disk, and is not used. The
    /// store won't re-point away from a profile it didn't write, since a hand-built one records
    /// judgements a walk can't see, so the report must say it changed nothing you'll notice; a
    /// plain "learned 3,013 folders" would be true and misleading.
    @Test func aWalkBesideAHandBuiltProfileSaysItIsNotInUse() async throws {
        let (root, profiles) = try walkRoots()
        defer { remove(root, profiles) }
        try Self.tree(in: root)

        // A hand-built profile: no `builtBy` header at all, which is how they all read.
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

    /// A Save while a reorganization lands is refused and says so: the landing's re-derive publishes
    /// its own profile when its replay ends, over whatever the walk wrote.
    @Test @MainActor func aWalkIsRefusedWhileALandingIsInProgress() async throws {
        let (root, profiles) = try walkRoots()
        defer { remove(root, profiles) }
        try Self.tree(in: root)
        let manager = manager(profiles: profiles)
        manager.restructureLandingInProgress = true
        let refused = await manager.deriveFolderProfile(root: root, now: Date(timeIntervalSince1970: 1_754_000_000))
        #expect(refused == .failure(.landingInProgress), "\(refused)")
        #expect(FilingProfileStore.activeProfileId(in: profiles) == nil, "a profile was written mid-landing")

        manager.restructureLandingInProgress = false
        let saved = await manager.deriveFolderProfile(root: root, now: Date(timeIntervalSince1970: 1_754_000_600))
        #expect((try? saved.get())?.becameActive == true, "the control walk did not land")
    }

    // MARK: - What the user made follows the profile (FR4)

    /// Writes the three files a user makes into a profile's folder, with recognisable bytes, and
    /// a finished landing whose Undo the newest walk must keep offering.
    @MainActor
    private static func curate(_ id: String, in profiles: URL) throws {
        let folder = profiles.appendingPathComponent(id)
        try Data(#"{"people":[{"id":"mum"}]}"#.utf8).write(to: folder.appendingPathComponent("people.json"))
        try Data(#"{"verdicts":["mum"]}"#.utf8).write(to: folder.appendingPathComponent("person-tags.json"))
        let manifest = RestructureManifest(profileId: id, manifestId: "landing-1",
                                           createdAt: "2026-10-23T10:00:00", family: "Tax",
                                           kind: .shape, actions: [])
        let store = RestructureStore(directory: profiles, profileId: id)
        try #require(store.recordApplied(.init(manifest: manifest, inverse: manifest,
                                                at: "2026-10-23T10:00:00", created: 0, skipped: 0,
                                                appliedUnderProfileId: "before-\(id)",
                                                producedProfileId: id, summary: "1 moved")))
    }

    /// Re-running Setup's Learn and Save writes a new walk profile and makes it active, and the
    /// roster, the verdicts and the ledger must move with it. Left in the old folder, the app would
    /// read an empty roster, lose the verdicts and the Undo, and a later refresh would delete them.
    @Test @MainActor func aSecondWalkCarriesWhatTheUserMade() async throws {
        let (root, profiles) = try walkRoots()
        defer { remove(root, profiles) }
        try Self.tree(in: root)
        let manager = manager(profiles: profiles)
        let first = try #require(try? (await manager.deriveFolderProfile(
            root: root, now: Date(timeIntervalSince1970: 1_754_000_000))).get())
        try Self.curate(first.profileId, in: profiles)

        let second = try #require(try? (await manager.deriveFolderProfile(
            root: root, now: Date(timeIntervalSince1970: 1_754_000_600))).get())

        try #require(second.becameActive)
        for name in FilingProfileStore.curatedArtifactNames {
            let old = try Data(contentsOf: profiles.appendingPathComponent("\(first.profileId)/\(name)"))
            let new = try? Data(contentsOf: profiles.appendingPathComponent("\(second.profileId)/\(name)"))
            #expect(new != nil, "\(name) stayed behind in \(first.profileId)")
            if name != "restructure.json" { #expect(new == old, "\(name) arrived changed") }
        }
        let ledger = RestructureStore(directory: profiles, profileId: second.profileId)
        #expect(ledger.undoableReorganisation(currentProfileId: second.profileId)?.manifest.manifestId
                == "landing-1", "the same folder walked again keeps the last landing's Undo")
    }

    /// A walk of a different folder still brings the roster, but not the Undo: the ledger's
    /// inverse is relative to the root, and Undo would replay it under the new one.
    @Test @MainActor func aWalkOfAnotherFolderDoesNotOfferTheOldUndo() async throws {
        let (root, profiles) = try walkRoots(), other = try makeCanonicalTempRoot(prefix: "walk")
        defer { remove(root, other, profiles) }
        try Self.tree(in: root)
        try Self.tree(in: other)
        let manager = manager(profiles: profiles)
        let first = try #require(try? (await manager.deriveFolderProfile(
            root: root, now: Date(timeIntervalSince1970: 1_754_000_000))).get())
        try Self.curate(first.profileId, in: profiles)

        let second = try #require(try? (await manager.deriveFolderProfile(
            root: other, now: Date(timeIntervalSince1970: 1_754_000_600))).get())

        #expect(FileManager.default.fileExists(
            atPath: profiles.appendingPathComponent("\(second.profileId)/people.json").path))
        let ledger = RestructureStore(directory: profiles, profileId: second.profileId)
        #expect(ledger.undoableReorganisation(currentProfileId: second.profileId) == nil)
    }

    /// The backstop: whatever re-pointed the index, retiring never takes the only copy of a
    /// curated file. With the copy gone from the active folder the old one is kept; once the
    /// active folder holds its own, the old one goes as it always did.
    @Test @MainActor func retiringNeverTakesTheOnlyCopyOfTheRoster() async throws {
        let (root, profiles) = try walkRoots()
        defer { remove(root, profiles) }
        try Self.tree(in: root)
        let manager = manager(profiles: profiles)
        let first = try #require(try? (await manager.deriveFolderProfile(
            root: root, now: Date(timeIntervalSince1970: 1_754_000_000))).get())
        try Data("roster".utf8).write(to: profiles.appendingPathComponent("\(first.profileId)/people.json"))
        let second = try #require(try? (await manager.deriveFolderProfile(
            root: root, now: Date(timeIntervalSince1970: 1_754_000_600))).get())
        // The state a carry that did not happen leaves behind.
        let carried = profiles.appendingPathComponent("\(second.profileId)/people.json")
        try? FileManager.default.removeItem(at: carried)

        let kept = try FilingProfileStore.retireSupersededProfiles(protecting: [], in: profiles)
        #expect(kept.isEmpty)
        #expect(FilingProfileStore.profile(id: first.profileId, in: profiles) != nil)

        try Data("roster".utf8).write(to: carried)
        let retired = try FilingProfileStore.retireSupersededProfiles(protecting: [], in: profiles)
        #expect(retired == [first.profileId])
    }
}
