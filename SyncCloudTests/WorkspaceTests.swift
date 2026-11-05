import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// The flat workspace selection, and the migrations off every selection it has replaced.
@Suite struct WorkspaceTests {

    // MARK: The two defaults that have to agree

    /// Where a first run lands and where an unresolvable selection lands must be the same place.
    ///
    /// They are two constants in two files: `migrateSelection` returns nil when nothing is stored,
    /// so `@AppStorage`'s default answers a first run, while ``WorkspaceSelection/default`` answers
    /// a stored value this build cannot read. Source-level because `ContentView` cannot be mounted
    /// (private stored properties make its memberwise init private), and an `@AppStorage` default
    /// is not reachable from a test otherwise.
    @Test func theFirstRunDefaultAgreesWithTheFallback() throws {
        /// The workspace case named at the end of the one line matching `anchor`.
        func workspaceCase(inFile name: String, after anchor: String) throws -> String {
            let url = URL(fileURLWithPath: #filePath)      // …/SyncCloudTests/WorkspaceTests.swift
                .deletingLastPathComponent()               // …/SyncCloudTests
                .deletingLastPathComponent()               // repo root
                .appendingPathComponent("MacApp/\(name)")
            let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                    "cannot read \(name) — this comparison would be vacuous")
            try #require(text.count > 500, "\(name) is implausibly short — truncated?")
            let start = try #require(text.range(of: anchor),
                                     "\(name) no longer contains “\(anchor)” — the declaration moved or was reworded, and this test is now measuring nothing")
            // Exactly once: `range(of:)` returns the first match, so a doc comment quoting the
            // declaration would silently be read instead of the code.
            let occurrences = text.components(separatedBy: anchor).count - 1
            try #require(occurrences == 1,
                         "“\(anchor)” appears \(occurrences)× in \(name); this reads the first, which may not be the declaration")
            // The rest of that line, then the token after its first `.`: `.browse` from
            // `= .browse`, and from `WorkspaceSelection(workspace: .browse, organizeLens: nil)`.
            // First, not last, because the fallback's line carries a second argument that could
            // gain a non-nil case.
            let line = text[start.upperBound...].prefix { $0 != "\n" }
            let dot = try #require(line.firstIndex(of: "."), "no case named after “\(anchor)”")
            let name = line[line.index(after: dot)...]
                .prefix { $0.isLetter }
            return String(name)
        }

        let firstRun = try workspaceCase(inFile: "ContentView.swift",
                                         after: "@AppStorage(Workspace.defaultsKey) var selectedWorkspace: Workspace =")
        let fallback = try workspaceCase(inFile: "Workspace.swift",
                                         after: "static let `default` = WorkspaceSelection(workspace:")

        // Non-vacuity: both reads must name a real workspace, or an empty parse would compare ""
        // to "" and pass.
        #expect(Workspace.allCases.map { String(describing: $0) }.contains(firstRun),
                "first-run default parsed as “\(firstRun)”, which is not a Workspace case")
        #expect(Workspace.allCases.map { String(describing: $0) }.contains(fallback),
                "fallback parsed as “\(fallback)”, which is not a Workspace case")

        #expect(firstRun == fallback,
                "a first run opens on \(firstRun) and an unresolvable stored selection opens on \(fallback); both files document them as the same place")
    }

    // MARK: Persistence format

    @Test func testRawValuesAreAStablePersistenceFormat() {
        // Persisted via @AppStorage(Workspace.defaultsKey). Renaming a raw value would silently
        // drop that user onto the default, which is why `title` is separate: the display name
        // differs from the id in three places.
        #expect(Workspace.browse.rawValue == "Browse")
        #expect(Workspace.compare.rawValue == "Differences")
        #expect(Workspace.filing.rawValue == "Filing")
        // "Storage" is a retired workspace raw value that names an `OrganizeLens` case;
        // `testAStoredStorageWorkspaceMigratesToTheStorageLens` follows it to its destination.
        #expect(!Workspace.allCases.map(\.rawValue).contains("Storage"))

        #expect(Workspace.browse.title == "Browse")
        #expect(Workspace.compare.title == "Compare")
        #expect(Workspace.filing.title == "Organize")
    }

    @Test func testRestoresFromStoredRawValue() {
        for workspace in Workspace.allCases {
            #expect(Workspace(rawValue: workspace.rawValue) == workspace)
        }
        // An unrecognised stored value must fail the RawRepresentable init, which is what makes
        // @AppStorage fall back to its default rather than crash.
        #expect(Workspace(rawValue: "NotAWorkspace") == nil)
    }

    // MARK: The five-segment bar

    @Test func testTheBarIsFiveKindsOfPlace() {
        // Browse shows one tree and proposes nothing, Compare holds two, Organize changes one, and
        // Editor changes what is inside one file. Everything that moves a file inside a single
        // tree on the app's suggestion is a lens inside Organize, so a new segment means something
        // was promoted out of it. Editor is a segment, not a lens, because it writes a file's
        // contents.
        #expect(Workspace.allCases.count == 4)
        #expect(Workspace.allCases.map(\.title)
                == ["Browse", "Compare", "Organize", "Edit"])
        // The raw values are the persistence format, so `Editor` stays even though the title is
        // "Edit".
        #expect(Workspace.allCases.map(\.rawValue)
                == ["Browse", "Differences", "Filing", "Editor"])
    }

    @Test func testTheFoldedWorkspacesAreGoneFromTheBar() {
        // Duplicates and Automations are rail items. Their raw values still have to be handled
        // (below); what must not come back is a segment.
        let titles = Set(Workspace.allCases.map(\.title))
        for retired in ["Duplicates", "Automations", "Rename"] {
            #expect(Workspace(rawValue: retired) == nil, "\(retired) is a lens, not a workspace")
            #expect(!titles.contains(retired))
        }
    }

    /// The bar's order: Browse leads, as the plainest place in the bar, and the workspaces that own
    /// a lens stay adjacent, so the bar reads as ordered rather than arbitrary. The bar has no
    /// groups, since Editor neither looks at a tree nor acts on one.
    @Test func testBarOrderPutsBrowseFirstAndKeepsTheLensPairTogether() {
        #expect(Workspace.allCases.first == .browse)
        let lensIndices = Workspace.allCases.indices.filter { Workspace.allCases[$0].lens != nil }
        #expect(lensIndices == Array(lensIndices.first!...lensIndices.last!),
                "the workspaces that own a lens are no longer adjacent in the bar")
        // Editor is last, which hands it ⌘4: the chords are positional.
        #expect(Workspace.allCases.last == .editor)
    }

    @Test func testEverySegmentHasItsOwnGlyph() {
        // At narrow widths the glyph is the only thing naming a workspace, so two sharing one
        // would be two unlabelled segments a user cannot tell apart.
        let symbols = Workspace.allCases.map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
        #expect(!symbols.contains(""))
    }

    // MARK: Programmatic navigation needs BOTH halves

    @Test func testALensDestinationCarriesTheRailItemNotJustTheWorkspace() {
        // The workspace alone is not enough: "Find duplicates of this" names one of the lenses
        // inside Organize, and a caller that set only the workspace would land on the overview
        // and lose the request.
        #expect(Workspace.destination(for: .duplicates)
                == WorkspaceSelection(workspace: .filing, organizeLens: .duplicates))
        #expect(Workspace.destination(for: .filing)
                == WorkspaceSelection(workspace: .filing, organizeLens: .toFile))
        #expect(Workspace.destination(for: .automations)
                == WorkspaceSelection(workspace: .filing, organizeLens: .rules))
        // Storage is a rail item like the rest, so "Analyze this folder's storage" from ⌘K lands
        // on the lens.
        #expect(Workspace.destination(for: .storage)
                == WorkspaceSelection(workspace: .filing, organizeLens: .storage))
    }

    @Test func testEveryLensResolvesToSomewhereReachable() {
        // No lens may resolve to a workspace that cannot show it.
        for lens in WorkspaceLensKind.allCases {
            let slot = Workspace.destination(for: lens).workspace.lens
            #expect(slot != nil, "\(lens.rawValue) resolves to a workspace with no lens slot")
        }
        #expect(Workspace.browse.lens == nil)
        #expect(Workspace.compare.lens == nil)
        #expect(Workspace.filing.lens == .filing)
        // Organize is the only workspace with a lens slot; every `WorkspaceLensKind` reaches it
        // through the rail, which is what the loop above checks.
        #expect(Workspace.lensWorkspaces == [.filing])
    }

    // MARK: Migration off the two-level selection

    @Test func testEveryOldPairMigratesToTheMatchingPlace() {
        // The table is the point: a stored value that stops resolving fails silently (@AppStorage
        // just takes its default). Each legacy pair has to land on the lens it named, not merely on
        // Organize.
        #expect(Workspace.migrated(tab: "Differences", lens: "Duplicates") == .default)
        #expect(Workspace.migrated(tab: "Tidy", lens: "Duplicates")
                == WorkspaceSelection(workspace: .filing, organizeLens: .duplicates))
        // Renames, the rail item hosting the risky-name findings; migrating to the retired
        // "Names" would write a value nothing decodes back into the stored selection.
        #expect(Workspace.migrated(tab: "Tidy", lens: "Rename")
                == WorkspaceSelection(workspace: .filing, organizeLens: .renames))
        #expect(Workspace.migrated(tab: "Tidy", lens: "Filing")
                == WorkspaceSelection(workspace: .filing, organizeLens: .toFile))
        #expect(Workspace.migrated(tab: "Tidy", lens: "Automations")
                == WorkspaceSelection(workspace: .filing, organizeLens: .rules))
        // A legacy Tidy lens of "Storage" is in `retiredWorkspaceRawValues`, so the retired-table
        // branch catches it before `Workspace(rawValue:)` and lands it on the lens.
        #expect(Workspace.migrated(tab: "Tidy", lens: "Storage")
                == WorkspaceSelection(workspace: .filing, organizeLens: .storage))
    }

    @Test func testTheFoldKeepsEveryDestinationDistinct() {
        // Five legacy lenses, five distinct destinations: the rail has a permanent place for each.
        let lenses = ["Duplicates", "Rename", "Filing", "Automations", "Storage"]
        let keys = lenses.map { name -> String in
            let selection = Workspace.migrated(tab: "Tidy", lens: name)
            return "\(selection.workspace.rawValue)/\(selection.organizeLens?.rawValue ?? "-")"
        }
        #expect(Set(keys).count == 5)
    }

    /// A stored selection that no longer reads lands in Browse. A fresh install's default is a
    /// separate constant, held to this one by `theFirstRunDefaultAgreesWithTheFallback`; this test
    /// owns the fallback half. Asserted as the concrete place, not `.default == .default`, which
    /// cannot fail.
    @Test func testTheDefaultIsBrowse() {
        #expect(WorkspaceSelection.default == WorkspaceSelection(workspace: .browse, organizeLens: nil))
        #expect(Workspace.migratedWorkspace("NotAWorkspace").workspace == .browse)
        #expect(Workspace.migrated(tab: nil, lens: nil).workspace == .browse)
    }

    /// …and the two Tidy arms do not follow it there. Someone whose session ended inside Tidy with
    /// an unreadable lens was in a lens, which is a nearer answer than a file browser, so
    /// `tidyDefault` stays put whatever the default.
    @Test func testTheTidyFallbacksDidNotFollowTheDefaultToBrowse() {
        #expect(Workspace.tidyDefault == WorkspaceSelection(workspace: .filing, organizeLens: .duplicates))
        #expect(Workspace.migrated(tab: "Tidy", lens: nil).workspace == .filing)
        #expect(Workspace.migrated(tab: "Tidy", lens: "NotALens").workspace == .filing)
        #expect(Workspace.migrated(tab: "Tidy", lens: nil) != .default)
    }

    @Test func testUnrecognisedInputLandsWhereAnEmptyDefaultWould() {
        // An unreadable stored value and no stored value at all must agree, or a corrupt pair
        // sends someone somewhere no fresh install starts.
        #expect(Workspace.migrated(tab: nil, lens: nil) == .default)
        #expect(Workspace.migrated(tab: "NotATab", lens: "NotALens") == .default)
        // Tidy with a lens that no longer exists takes Tidy's own former default rather than the
        // default workspace; see `testTheTidyFallbacksDidNotFollowTheDefaultToBrowse`.
        #expect(Workspace.migrated(tab: "Tidy", lens: nil) == Workspace.tidyDefault)
        #expect(Workspace.migrated(tab: "Tidy", lens: "NotALens") == Workspace.tidyDefault)
        // "Differences" is a Workspace raw value too; it must not be read as a *lens* and let
        // someone on Tidy resolve to Compare through the lens arm.
        #expect(Workspace.migrated(tab: "Tidy", lens: "Differences") == Workspace.tidyDefault)
    }

    @Test func testEveryRetiredWorkspaceValueLandsOnItsOwnLens() {
        // These raw values were once workspaces and no longer resolve, so @AppStorage would
        // silently drop the user in Browse. Asserted through the lens too: landing on Organize's
        // overview instead of the duplicates list is a quieter version of the same loss. `Rename`
        // lands on Renames because a migration must write only presented raw values.
        let retirements: [(String, OrganizeLens)] = [("Rename", .renames),
                                                     ("Duplicates", .duplicates),
                                                     ("Automations", .rules)]
        for (raw, lens) in retirements {
            let expected = WorkspaceSelection(workspace: .filing, organizeLens: lens)
            #expect(Workspace(rawValue: raw) == nil)
            #expect(Workspace.migratedWorkspace(raw) == expected,
                    "\(raw) must land on its own rail item")
        }
        #expect(Workspace.migratedWorkspace("Differences") == .default)
        #expect(Workspace.migratedWorkspace("NotAWorkspace") == .default)
    }

    // MARK: Migration is one-shot, and writes both halves

    private func defaults(_ name: String) -> UserDefaults {
        ScratchDefaults("WorkspaceTests.\(name)")
    }

    @Test func testMigrationWritesBothKeys() {
        let d = defaults("writes")
        d.set("Tidy", forKey: Workspace.legacyTabKey)
        d.set("Duplicates", forKey: Workspace.legacyLensKey)

        #expect(Workspace.migrateSelection(in: d)
                == WorkspaceSelection(workspace: .filing, organizeLens: .duplicates))
        #expect(d.string(forKey: Workspace.defaultsKey) == "Filing")
        #expect(d.string(forKey: Workspace.organizeLensKey) == "Duplicates")
    }

    @Test func testMigratingToAWorkspaceWithNoLensClearsTheRailKey() {
        // A migration that wrote only the workspace would leave whatever rail item was stored, so
        // someone migrated to a lensless workspace who then clicks Organize would land on a lens
        // they never picked.
        let d = defaults("clears")
        d.set(OrganizeLens.duplicates.rawValue, forKey: Workspace.organizeLensKey)
        d.set("NotAWorkspace", forKey: Workspace.defaultsKey)

        #expect(Workspace.migrateSelection(in: d) == .default)
        // The raw value the default writes, spelled out rather than derived from `.default`: this
        // asserts what lands on disk, and a derived expectation would agree with any future move
        // of the default.
        #expect(d.string(forKey: Workspace.defaultsKey) == "Browse")
        #expect(d.string(forKey: Workspace.organizeLensKey) == nil)
    }

    @Test func testARetiredValueAlreadyInTheNewKeyIsRemapped() {
        // A retired value the flat bar wrote itself sits in `selectedWorkspace`, not in the legacy
        // pair, so an early return on "is the new key present?" would skip it.
        let d = defaults("retired-in-new-key")
        d.set("Duplicates", forKey: Workspace.defaultsKey)

        #expect(Workspace.migrateSelection(in: d)
                == WorkspaceSelection(workspace: .filing, organizeLens: .duplicates))
        #expect(d.string(forKey: Workspace.defaultsKey) == Workspace.filing.rawValue)
        #expect(d.string(forKey: Workspace.organizeLensKey) == "Duplicates")
    }

    @Test func testMigrationDoesNotReRunOverADeliberateChoice() {
        let d = defaults("norerun")
        d.set("Tidy", forKey: Workspace.legacyTabKey)
        d.set("Storage", forKey: Workspace.legacyLensKey)
        Workspace.migrateSelection(in: d)

        // The user then picks something else. The legacy keys are still there, and App.init runs
        // again (SwiftUI re-runs it), so it must not stomp the new choice with the stale pair.
        d.set(Workspace.compare.rawValue, forKey: Workspace.defaultsKey)
        #expect(Workspace.migrateSelection(in: d) == nil)
        #expect(d.string(forKey: Workspace.defaultsKey) == "Differences")
    }

    @Test func testADeliberateRailChoiceSurvivesARerun() {
        // The rail key must not be touched when the workspace still resolves, or re-running would
        // clear a lens the user is standing in.
        let d = defaults("rail-survives")
        d.set(Workspace.filing.rawValue, forKey: Workspace.defaultsKey)
        d.set(OrganizeLens.renames.rawValue, forKey: Workspace.organizeLensKey)

        #expect(Workspace.migrateSelection(in: d) == nil)
        #expect(d.string(forKey: Workspace.organizeLensKey) == "Renames")
    }

    // MARK: The retired rail case

    /// A stored "Names" is rewritten to Renames, because no case decodes it. Otherwise
    /// `@AppStorage` takes this key's default, which is absent (the overview), and someone who left
    /// the app in the rename backlog would reopen elsewhere with nothing to explain the move.
    @Test func testAStoredNamesRailSelectionBecomesRenames() {
        let d = defaults("names-retired")
        d.set(Workspace.filing.rawValue, forKey: Workspace.defaultsKey)
        d.set("Names", forKey: Workspace.organizeLensKey)

        Workspace.migrateOrganizeLens(in: d)
        #expect(d.string(forKey: Workspace.organizeLensKey) == "Renames")
        // And the rewritten value is one the type can actually read back, which is the point.
        #expect(OrganizeLens(rawValue: d.string(forKey: Workspace.organizeLensKey) ?? "") == .renames)
    }

    /// It runs even though `migrateSelection` would have stopped, which is why it is its own
    /// function. `migrateSelection` returns before reading the rail key whenever the stored
    /// workspace resolves, and "Organize" does, which is exactly the state everyone this migration
    /// exists for is in.
    @Test func testTheRailMigrationDoesNotDependOnTheWorkspaceMigration() {
        let d = defaults("names-retired-standalone")
        d.set(Workspace.filing.rawValue, forKey: Workspace.defaultsKey)
        d.set("Names", forKey: Workspace.organizeLensKey)

        // The workspace half declines to act, as it does in the shipping app…
        #expect(Workspace.migrateSelection(in: d) == nil)
        #expect(d.string(forKey: Workspace.organizeLensKey) == "Names",
                "migrateSelection rewrote the rail key — this test no longer proves the two are separate")
        // …and the rail half still fixes the stored value.
        Workspace.migrateOrganizeLens(in: d)
        #expect(d.string(forKey: Workspace.organizeLensKey) == "Renames")
    }

    /// A live selection is left exactly as it is, and so is an absent one. A rewrite that ran
    /// unconditionally would move everyone onto Renames, and writing an absent key would turn "no
    /// lens picked" into a lens for every user who never chose one.
    @Test func testTheRailMigrationTouchesNothingElse() {
        let d = defaults("names-retired-noop")
        d.set("Duplicates", forKey: Workspace.organizeLensKey)
        Workspace.migrateOrganizeLens(in: d)
        #expect(d.string(forKey: Workspace.organizeLensKey) == "Duplicates")

        let empty = defaults("names-retired-absent")
        Workspace.migrateOrganizeLens(in: empty)
        #expect(empty.string(forKey: Workspace.organizeLensKey) == nil)
    }

    @Test func testAFirstRunIsLeftAloneRatherThanSeeded() {
        // No legacy keys means no upgrade to carry. Writing a value here would bake this
        // function's idea of the default into every fresh install, splitting the default in two.
        let d = defaults("firstrun")
        #expect(Workspace.migrateSelection(in: d) == nil)
        #expect(d.string(forKey: Workspace.defaultsKey) == nil)
        #expect(d.string(forKey: Workspace.organizeLensKey) == nil)
    }

    @Test func testAPartialLegacyStateStillMigrates() {
        // The legacy app wrote `selectedTidyLens` the first time a lens was picked, so a session
        // that never left Compare can have a lens key and no tab key, and vice versa.
        let lensOnly = defaults("lensonly")
        lensOnly.set("Filing", forKey: Workspace.legacyLensKey)
        #expect(Workspace.migrateSelection(in: lensOnly) == .default)

        let tabOnly = defaults("tabonly")
        tabOnly.set("Tidy", forKey: Workspace.legacyTabKey)
        #expect(Workspace.migrateSelection(in: tabOnly) == Workspace.tidyDefault)
    }

    /// Every destination the bridge can mint is a rail item, so no destination can write a lens
    /// the rail does not draw into the stored selection from outside the migration seam.
    @Test func testEveryLensDestinationLandsOnARailItem() {
        for kind in WorkspaceLensKind.allCases {
            let destination = Workspace.destination(for: kind)
            guard let lens = destination.organizeLens else {
                #expect(kind == .storage, "\(kind.rawValue) minted no rail item")
                continue
            }
            #expect(destination.workspace == .filing)
            #expect(OrganizeLens.railItems.contains(lens),
                    "\(kind.rawValue) mints \(lens.title), which the rail does not draw")
        }
        #expect(Workspace.destination(for: .duplicates).organizeLens == .duplicates)
        #expect(Workspace.destination(for: .storage).organizeLens == .storage)
    }

    /// Fixture from the stored string, because a test starting from the in-memory default cannot
    /// see what a migration writes: someone who quit in the old Rename workspace has "Rename" on
    /// disk, and what lands back on disk must be a raw value the rail presents, not "Names".
    @Test func testAStoredRenameWorkspaceMigratesWritingThePresentedRailItem() {
        let d = defaults("stored-rename")
        d.set("Rename", forKey: Workspace.defaultsKey)

        #expect(Workspace.migrateSelection(in: d)
                == WorkspaceSelection(workspace: .filing, organizeLens: .renames))
        #expect(d.string(forKey: Workspace.defaultsKey) == "Filing")
        #expect(d.string(forKey: Workspace.organizeLensKey) == "Renames")
    }

    /// The same stored-string check for the old Storage workspace. Its results survive a launch, so
    /// people are likely to have quit in it; a stored `"Storage"` that stopped resolving would drop
    /// them into Browse silently, their restored report one rail click away with no sign of it.
    @Test func testAStoredStorageWorkspaceMigratesToTheStorageLens() {
        let d = defaults("stored-storage")
        d.set("Storage", forKey: Workspace.defaultsKey)

        #expect(Workspace.migrateSelection(in: d)
                == WorkspaceSelection(workspace: .filing, organizeLens: .storage))
        // What lands back on disk is the pair the app now reads, not the retired single value.
        #expect(d.string(forKey: Workspace.defaultsKey) == "Filing")
        #expect(d.string(forKey: Workspace.organizeLensKey) == "Storage")
    }

    /// And the legacy pair's spelling of the same install: `Rename` stored as a Tidy lens.
    @Test func testAStoredRenameLensMigratesWritingThePresentedRailItem() {
        let d = defaults("stored-rename-lens")
        d.set("Tidy", forKey: Workspace.legacyTabKey)
        d.set("Rename", forKey: Workspace.legacyLensKey)

        #expect(Workspace.migrateSelection(in: d)
                == WorkspaceSelection(workspace: .filing, organizeLens: .renames))
        #expect(d.string(forKey: Workspace.organizeLensKey) == "Renames")
    }
}
