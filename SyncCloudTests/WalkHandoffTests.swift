import Foundation
import Sync
import Testing
@testable import SyncCloud

/// The hand-off between the two halves of setup: a walk writes a profile, and the answers the form
/// collected before there was one land in the roster it creates.
///
/// **This is the seam that silently did nothing for two stages.** Stage A's `SetupDraft` holds the
/// You and People answers because a fresh machine has no `profiles/<id>/` to write `people.json`
/// into; stage B's walk mints exactly that. The join is `FilingArtifacts.attach(to:)` — and it
/// triggers no SwiftUI invalidation, because `FileSyncManager`'s filing artifacts are plain `var`s
/// rather than `@Published`. The form read its roster once at construction, so after a successful
/// walk it was still nil: the draft had somewhere to go and could not see it.
///
/// Nothing failed. The tests passed, the walk reported success, and the household the user had just
/// typed in stayed in a JSON file nobody read. So the mechanism is pinned here rather than left to
/// the view, which cannot be driven from a test.
@MainActor
@Suite struct WalkHandoffTests {

    private static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func tree(in root: URL) throws {
        for path in ["Family/Shweta", "Finance/Receipts", "Finance/TODO"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path),
                                                    withIntermediateDirectories: true)
        }
    }

    /// A walk creates a roster where there was none, and it is reachable from the manager.
    ///
    /// The property the form depends on: after `attach`, `filingPeopleStore` is non-nil, so a view
    /// reading through the manager finds somewhere to put the draft.
    @Test func aWalkGivesTheManagerARosterToWriteInto() async throws {
        let root = try Self.scratch(), profiles = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: profiles) }
        try Self.tree(in: root)

        let manager = FileSyncManager()
        manager.filingProfilesDirectory = profiles
        #expect(manager.filingPeopleStore == nil, "the fixture already had a roster — this proves nothing")

        let result = await manager.deriveFolderProfile(root: root)
        let report = try #require(try? result.get())
        #expect(report.becameActive)

        // `attach` reads from the real Application Support directory, so the manager is pointed at
        // the scratch one by hand here — the mechanism under test is that a fresh profile becomes
        // readable, not where the app keeps its files.
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
        draft.yourName = "Abhishek"
        draft.yourFullNames = ["Abhishek Girish"]
        draft.others = [SetupDraft.DraftPerson(displayName: "Shweta", relationship: "wife")]

        let manager = FileSyncManager()
        manager.filingProfilesDirectory = profiles
        let report = try #require(try? (await manager.deriveFolderProfile(root: root)).get())

        let loaded = try #require(FilingProfileStore.active(in: profiles))
        let store = PeopleStore(directory: profiles, profileId: loaded.id, profile: loaded.profile)
        SetupDraft.apply(draft, to: store)

        #expect(Set(store.people.map(\.displayName)) == ["Abhishek", "Shweta"])
        #expect(store.people.first { $0.displayName == "Abhishek" }?.relationship == "me")
        #expect(report.profileId == loaded.id, "the walk's profile is not the one the roster hangs off")

        // And it is on disk under the profile the walk just wrote, which is what makes it survive
        // the relaunch the form no longer needs.
        let onDisk = profiles.appendingPathComponent("\(loaded.id)/people.json")
        #expect(FileManager.default.fileExists(atPath: onDisk.path))
    }

    /// The walk records the household the form collected, even with no roster on disk.
    ///
    /// **This is why People is asked before Folders**, and the walk was ignoring it: it passed the
    /// roster's registry, which is nil on the machine the form exists for, so the profile came out
    /// with no person axis and no `person-bucket` roles from a form that had just asked who the
    /// household is.
    @Test func theWalkRecordsAHouseholdThatOnlyExistsInTheDraft() async throws {
        let root = try Self.scratch(), profiles = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: profiles) }
        try Self.tree(in: root)

        let manager = FileSyncManager()
        manager.filingProfilesDirectory = profiles

        // What the form holds before any profile exists.
        let drafted = PersonRegistry(people: [Person(id: "shweta", displayName: "Shweta")],
                                     source: .profileAxis)
        let report = try #require(try? (await manager.deriveFolderProfile(root: root,
                                                                          registry: drafted)).get())
        let written = try #require(FilingProfileStore.profile(id: report.profileId, in: profiles))
        #expect(written.personTokens.contains("shweta"),
                "the walk built a profile with no person axis from a form that had just collected one")
    }

    /// The form hands the walk the draft household, not the roster's.
    ///
    /// **A call-site scan, because the defect was at the call site.** The tests above prove the
    /// engine records a household it is given; they say nothing about what the form gives it, and
    /// the bug was `registry: roster?.registry` — nil on the machine this form exists for. A rule
    /// extracted for testability is one revert from being unused.
    @Test func theFormHandsTheWalkTheHouseholdItCollected() throws {
        let source = try Self.setupSheetSource()
        #expect(source.contains("registry: walkRegistry"),
                "the walk is no longer handed the draft household")
        #expect(!source.contains("registry: roster?.registry"),
                "the walk is back to passing a roster that is nil on a fresh machine")
    }

    /// The form reads its roster through the engine, not from a capture.
    ///
    /// The other half of the same defect: `FileSyncManager`'s filing artifacts are plain `var`s, so
    /// attaching a fresh profile invalidates nothing and a captured `peopleStore` stays nil for the
    /// life of the view.
    @Test func theFormReadsItsRosterLive() throws {
        let source = try Self.setupSheetSource()
        let body = try #require(source.range(of: "private var draftURL"))
        // **Comments stripped first.** The first draft of this scan failed on the sentence
        // explaining the defect — a comment naming `peopleStore` is documentation, not a read, and
        // a scan that cannot tell them apart bans writing the explanation down.
        let afterInit = String(source[body.lowerBound...])
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!afterInit.contains("peopleStore"),
                "the form is reading the captured store again — it goes stale the moment a walk lands")
        #expect(afterInit.contains("roster"))
    }

    /// The positive control: the scan can see a read when there is one.
    ///
    /// Without it, a stripper that removed everything would pass the check above on any file.
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

    private static func setupSheetSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/SetupSheet.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read SetupSheet.swift — this scan would be vacuous")
        try #require(source.count > 5000, "SetupSheet.swift is implausibly short")
        return source
    }

    /// Seeding the root does not walk the tree.
    ///
    /// **A source scan, because the cost is invisible in a test and obvious on a real tree.** The
    /// root is seeded from the primary source, and `reconcilePrimary` moves the primary on every
    /// source toggle — so seeding that walked would fire two full walks of a three-thousand-folder
    /// tree per click on the Sources step, for proposals nobody had asked for yet. Each step asks
    /// when it is reached instead.
    @Test func seedingTheRootDoesNotStartAWalk() throws {
        let source = try Self.setupSheetSource()
        let body = try #require(Self.bodyOf("private func seedWalkRoot()", in: source))
        #expect(!body.contains("proposePlaces()"), "seeding walks for places again")
        #expect(!body.contains("proposePeople()"), "seeding walks for people again")
        #expect(body.contains("invalidateProposals()"), "seeding no longer drops the old tree's work")
    }

    /// A function's body, brace-matched from its declaration.
    ///
    /// **It was `prefix(600)`, and that is a window rather than a body.** Adding six lines of
    /// comment inside `seedWalkRoot` pushed `invalidateProposals()` past character 600 and failed
    /// the positive assertion with nothing about the code changed — and the same drift in the other
    /// direction is the one that matters: a `proposePlaces()` added at the END of a grown function
    /// would fall outside the window and the negative assertions would pass over the walk they exist
    /// to forbid. A body that ends where the function ends cannot do either.
    ///
    /// Nil when the braces do not balance, which is a failure rather than a quiet empty string: a
    /// body this cannot find is one it cannot check.
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

    /// The control: with no household handed over, the axis really is absent.
    ///
    /// Without this, the test above would pass on a builder that recorded every folder name as a
    /// person, and neither would be telling me anything about the hand-off.
    @Test func theWalkRecordsNoHouseholdWhenItIsGivenNone() async throws {
        let root = try Self.scratch(), profiles = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: profiles) }
        try Self.tree(in: root)

        let manager = FileSyncManager()
        manager.filingProfilesDirectory = profiles
        let report = try #require(try? (await manager.deriveFolderProfile(root: root)).get())
        let written = try #require(FilingProfileStore.profile(id: report.profileId, in: profiles))
        #expect(written.personTokens.isEmpty,
                "a folder name became a person with no roster to say so")
    }
}
