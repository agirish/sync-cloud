import Foundation
import Sync
import Testing
@testable import SyncCloud

/// The hand-off between the two halves of setup: a walk writes a profile, and the answers the form
/// collected before there was one land in the roster it creates.
///
/// `SetupDraft` holds the You and People answers because a fresh machine has no `profiles/<id>/`
/// to write `people.json` into; the walk mints it. The join, `FilingArtifacts.attach(to:)`,
/// triggers no SwiftUI invalidation (the filing artifacts are plain `var`s), so a form that read
/// its roster once would never see it, and the household would sit unread with nothing failing.
/// Pinned here because the view cannot be driven from a test.
@MainActor
@Suite struct WalkHandoffTests {

    private static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func tree(in root: URL) throws {
        for path in ["Family/Mother", "Finance/Receipts", "Finance/TODO"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path),
                                                    withIntermediateDirectories: true)
        }
    }

    /// A walk creates a roster where there was none, reachable from the manager: after `attach`,
    /// `filingPeopleStore` is non-nil, so a view reading through the manager can place the draft.
    @Test func aWalkGivesTheManagerARosterToWriteInto() async throws {
        let root = try Self.scratch(), profiles = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: profiles) }
        try Self.tree(in: root)

        let manager = FileSyncManager.scratch()
        manager.filingProfilesDirectory = profiles
        #expect(manager.filingPeopleStore == nil, "the fixture already had a roster — this proves nothing")

        let result = await manager.deriveFolderProfile(root: root)
        let report = try #require(try? result.get())
        #expect(report.becameActive)

        // `attach` reads from the real Application Support directory, so the store is pointed at
        // the scratch one by hand: what is under test is that a fresh profile becomes readable.
        let loaded = try #require(FilingProfileStore.active(in: profiles))
        manager.filingPeopleStore = PeopleStore(directory: profiles, profileId: loaded.id,
                                                profile: loaded.profile)
        #expect(manager.filingPeopleStore != nil)
    }

    /// The draft lands in that roster, and its answers survive the trip.
    @Test func theDraftLandsInTheRosterTheWalkCreated() async throws {
        let root = try Self.scratch(), profiles = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: profiles) }
        try Self.tree(in: root)

        var draft = SetupDraft()
        draft.yourName = "Father"
        draft.yourFullNames = ["Father Elder"]
        draft.others = [SetupDraft.DraftPerson(displayName: "Mother", relationship: "wife")]

        let manager = FileSyncManager.scratch()
        manager.filingProfilesDirectory = profiles
        let report = try #require(try? (await manager.deriveFolderProfile(root: root)).get())

        let loaded = try #require(FilingProfileStore.active(in: profiles))
        let store = PeopleStore(directory: profiles, profileId: loaded.id, profile: loaded.profile)
        SetupDraft.apply(draft, to: store)

        #expect(Set(store.people.map(\.displayName)) == ["Father", "Mother"])
        #expect(store.people.first { $0.displayName == "Father" }?.relationship == "me")
        #expect(report.profileId == loaded.id, "the walk's profile is not the one the roster hangs off")

        // And it is on disk under the profile the walk just wrote, so it survives a relaunch.
        let onDisk = profiles.appendingPathComponent("\(loaded.id)/people.json")
        #expect(FileManager.default.fileExists(atPath: onDisk.path))
    }

    /// The walk records the household the form collected, even with no roster on disk. This is why
    /// People is asked before Folders: the roster's registry is nil on a fresh machine, and passing
    /// it would leave the profile with no person axis and no `person-bucket` roles.
    @Test func theWalkRecordsAHouseholdThatOnlyExistsInTheDraft() async throws {
        let root = try Self.scratch(), profiles = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: profiles) }
        try Self.tree(in: root)

        let manager = FileSyncManager.scratch()
        manager.filingProfilesDirectory = profiles

        // What the form holds before any profile exists.
        let drafted = PersonRegistry(people: [Person(id: "mother", displayName: "Mother")],
                                     source: .profileAxis)
        let report = try #require(try? (await manager.deriveFolderProfile(root: root,
                                                                          registry: drafted)).get())
        let written = try #require(FilingProfileStore.profile(id: report.profileId, in: profiles))
        #expect(written.personTokens.contains("mother"),
                "the walk built a profile with no person axis from a form that had just collected one")
    }

    /// The form hands the walk the draft household, not the roster's. A call-site scan: the tests
    /// above prove the engine records a household it is given, not what the form gives it, and
    /// `registry: roster?.registry` is nil on the machine this form exists for.
    @Test func theFormHandsTheWalkTheHouseholdItCollected() throws {
        let source = try Self.setupSheetSource()
        // Both call sites: the preview Structure reads, and the write Save performs. A household
        // handed to only one would show a profile the save does not produce.
        #expect(source.components(separatedBy: "registry: walkRegistry").count - 1 >= 2,
                "the walk is no longer handed the draft household at both the preview and the write")
        #expect(!source.contains("registry: roster?.registry"),
                "the walk is back to passing a roster that is nil on a fresh machine")
    }

    /// The form reads its roster through the engine, not from a capture: the filing artifacts are
    /// plain `var`s, so attaching a fresh profile invalidates nothing and a captured `peopleStore`
    /// stays nil for the life of the view.
    @Test func theFormReadsItsRosterLive() throws {
        let source = try Self.setupSheetSource()
        let body = try #require(source.range(of: "private let draftURL"))
        // Comments stripped first: a comment naming `peopleStore` is documentation, not a read.
        let afterInit = String(source[body.lowerBound...])
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!afterInit.contains("peopleStore"),
                "the form is reading the captured store again — it goes stale the moment a walk lands")
        #expect(afterInit.contains("roster"))
    }

    /// The positive control: the scan can see a read when there is one. Without it, a stripper
    /// that removed everything would pass the check above on any file.
    @Test func theRosterScanCanActuallyFail() {
        let sample = ["        // peopleStore in a comment is not a read",
                      "        let a = roster?.people",
                      "        let b = peopleStore?.people"].joined(separator: "\n")
        let stripped = sample.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(stripped.contains("peopleStore"), "the stripper removed a real read")
        #expect(!stripped.contains("not a read"), "the stripper is keeping comments")
    }

    /// `SetupModel.swift`, where the roster is read and the walk is called, so where the two
    /// failures this suite guards would recur. The size floor makes a scan of an emptied file fail
    /// instead of passing vacuously.
    private static func setupSheetSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/Setup/SetupModel.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read SetupModel.swift — this scan would be vacuous")
        try #require(source.count > 5000, "SetupModel.swift is implausibly short")
        return source
    }

    /// Seeding the root does not walk the tree. A source scan, because the cost is invisible in a
    /// test: the root is seeded from the primary source, which `reconcilePrimary` moves on every
    /// source toggle, so a walking seed would run two full walks per click on the Sources step.
    /// Each step asks when it is reached instead.
    @Test func seedingTheRootDoesNotStartAWalk() throws {
        let source = try Self.setupSheetSource()
        let body = try #require(Self.bodyOf("func seedWalkRoot()", in: source))
        #expect(!body.contains("startWalk()"), "seeding reads the tree again")
        #expect(!body.contains("walkForSetup"), "seeding reads the tree again")
        #expect(body.contains("invalidateProposals()"), "seeding no longer drops the old tree's work")
    }

    /// A function's body, brace-matched from its declaration, not a fixed-length window, which
    /// could miss a call added at the end of a grown function and let the negative checks pass.
    /// Nil when the braces do not balance, so a body it cannot find fails rather than reads empty.
    static func bodyOf(_ declaration: String, in source: String) -> String? {
        guard let decl = source.range(of: declaration),
              let open = source[decl.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[source.index(after: open)..<index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// The control: with no household handed over, the axis really is absent. Without it, the
    /// household test would pass on a builder that recorded every folder name as a person.
    @Test func theWalkRecordsNoHouseholdWhenItIsGivenNone() async throws {
        let root = try Self.scratch(), profiles = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: profiles) }
        try Self.tree(in: root)

        let manager = FileSyncManager.scratch()
        manager.filingProfilesDirectory = profiles
        let report = try #require(try? (await manager.deriveFolderProfile(root: root)).get())
        let written = try #require(FilingProfileStore.profile(id: report.profileId, in: profiles))
        #expect(written.personTokens.isEmpty,
                "a folder name became a person with no roster to say so")
    }
}
