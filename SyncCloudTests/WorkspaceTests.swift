import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// The flat workspace selection, and the migrations off every selection it has replaced.
@Suite struct WorkspaceTests {

    // MARK: Persistence format

    @Test func testRawValuesAreAStablePersistenceFormat() {
        // Persisted via @AppStorage(Workspace.defaultsKey). Every raw value is inherited from one
        // of the enums this collapsed, so a stored selection keeps resolving; renaming one would
        // silently drop that user onto the .compare default. `title` is separate for exactly this
        // reason — the display name differs from the id in two places.
        #expect(Workspace.compare.rawValue == "Differences")
        #expect(Workspace.filing.rawValue == "Filing")
        #expect(Workspace.storage.rawValue == "Storage")

        #expect(Workspace.compare.title == "Compare")
        #expect(Workspace.filing.title == "Organize")
    }

    @Test func testRestoresFromStoredRawValue() {
        for workspace in Workspace.allCases {
            #expect(Workspace(rawValue: workspace.rawValue) == workspace)
        }
        // An unrecognised stored value must fail the RawRepresentable init — that is what makes
        // @AppStorage fall back to its default rather than crash.
        #expect(Workspace(rawValue: "NotAWorkspace") == nil)
    }

    // MARK: The three-segment bar

    @Test func testTheBarIsThreeKindsOfPlace() {
        // Compare holds two trees, Storage reads one, Organize changes one. Everything that moves
        // a file inside a single tree is a lens inside Organize — a fourth segment reappearing
        // means something was promoted back out of the umbrella.
        #expect(Workspace.allCases.count == 3)
        #expect(Workspace.allCases.map(\.title) == ["Compare", "Organize", "Storage"])
    }

    @Test func testTheFoldedWorkspacesAreGoneFromTheBar() {
        // Duplicates and Automations are rail items now. Their raw values still have to be
        // *handled* (below) — what must not come back is a segment.
        let titles = Set(Workspace.allCases.map(\.title))
        for retired in ["Duplicates", "Automations", "Rename"] {
            #expect(Workspace(rawValue: retired) == nil, "\(retired) is a lens, not a workspace")
            #expect(!titles.contains(retired))
        }
    }

    @Test func testBarOrderPutsCompareFirstAndKeepsTheLensGroupTogether() {
        // The bar draws its one separator after the first segment, so Compare has to BE the first
        // segment — otherwise the rule lands mid-group and stops meaning "two panes | one pane".
        let afterCompare = Workspace.allCases.dropFirst().compactMap(\.lens)
        #expect(Workspace.allCases.first == .compare)
        #expect(afterCompare.count == Workspace.allCases.count - 1)
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
        // The fold made the workspace insufficient on its own: "Find duplicates of this" used to
        // name a workspace that WAS the answer and now names one of six lenses inside Organize. A
        // caller that set only the workspace would land on the overview and lose the request.
        #expect(Workspace.destination(for: .duplicates)
                == WorkspaceSelection(workspace: .filing, organizeLens: .duplicates))
        #expect(Workspace.destination(for: .filing)
                == WorkspaceSelection(workspace: .filing, organizeLens: .toFile))
        #expect(Workspace.destination(for: .rename)
                == WorkspaceSelection(workspace: .filing, organizeLens: .names))
        #expect(Workspace.destination(for: .automations)
                == WorkspaceSelection(workspace: .filing, organizeLens: .rules))
        // Storage is the one lens that is still a workspace, so it takes no rail item.
        #expect(Workspace.destination(for: .storage)
                == WorkspaceSelection(workspace: .storage, organizeLens: nil))
    }

    @Test func testEveryLensResolvesToSomewhereReachable() {
        // No lens may resolve to a workspace that cannot show it.
        for lens in TidyLens.allCases {
            let slot = Workspace.destination(for: lens).workspace.lens
            #expect(slot != nil, "\(lens.rawValue) resolves to a workspace with no lens slot")
        }
        #expect(Workspace.compare.lens == nil)
        #expect(Workspace.filing.lens == .filing)
        #expect(Workspace.storage.lens == .storage)
    }

    // MARK: Migration off the two-level selection

    @Test func testEveryOldPairMigratesToTheMatchingPlace() {
        // The table is the point: folding keys together deletes destinations, and a stored value
        // that stops resolving fails SILENTLY (@AppStorage just takes its default). Each of these
        // was reachable in 2.8, so each has to land somewhere deliberate — and now each lands on
        // the LENS it named, not merely on the umbrella that swallowed it.
        #expect(Workspace.migrated(tab: "Differences", lens: "Duplicates") == .default)
        #expect(Workspace.migrated(tab: "Tidy", lens: "Duplicates")
                == WorkspaceSelection(workspace: .filing, organizeLens: .duplicates))
        #expect(Workspace.migrated(tab: "Tidy", lens: "Rename")
                == WorkspaceSelection(workspace: .filing, organizeLens: .names))
        #expect(Workspace.migrated(tab: "Tidy", lens: "Filing")
                == WorkspaceSelection(workspace: .filing, organizeLens: .toFile))
        #expect(Workspace.migrated(tab: "Tidy", lens: "Automations")
                == WorkspaceSelection(workspace: .filing, organizeLens: .rules))
        #expect(Workspace.migrated(tab: "Tidy", lens: "Storage")
                == WorkspaceSelection(workspace: .storage, organizeLens: nil))
    }

    @Test func testTheFoldKeepsEveryDestinationDistinct() {
        // Five lenses, five distinct destinations — the fold cost nothing this time, because the
        // rail has a permanent place for each. When Rename folded in it had to share Organize
        // with Filing (a chip might not exist); that collision is gone.
        let lenses = ["Duplicates", "Rename", "Filing", "Automations", "Storage"]
        let keys = lenses.map { name -> String in
            let selection = Workspace.migrated(tab: "Tidy", lens: name)
            return "\(selection.workspace.rawValue)/\(selection.organizeLens?.rawValue ?? "-")"
        }
        #expect(Set(keys).count == 5)
    }

    @Test func testUnrecognisedInputLandsWhereAnEmptyDefaultWould() {
        // An unreadable stored value and no stored value at all must agree, or a corrupt pair
        // sends someone somewhere no fresh install ever starts.
        #expect(Workspace.migrated(tab: nil, lens: nil) == .default)
        #expect(Workspace.migrated(tab: "NotATab", lens: "NotALens") == .default)
        // Tidy with a lens that no longer exists takes Tidy's own former default rather than
        // bouncing to Compare — the user was in a lens, so a lens is the nearer answer.
        #expect(Workspace.migrated(tab: "Tidy", lens: nil) == Workspace.tidyDefault)
        #expect(Workspace.migrated(tab: "Tidy", lens: "NotALens") == Workspace.tidyDefault)
        // "Differences" is a Workspace raw value too; it must not be read as a *lens* and let
        // someone on Tidy resolve to Compare through the lens arm.
        #expect(Workspace.migrated(tab: "Tidy", lens: "Differences") == Workspace.tidyDefault)
    }

    @Test func testEveryRetiredWorkspaceValueLandsOnItsOwnLens() {
        // Three raw values have now been a Workspace and stopped being one. NONE of them resolves
        // any more, so @AppStorage would silently take its default and drop the user on Compare —
        // nowhere near what they were doing. This is the table that prevents it, and it is
        // asserted through the lens as well as the workspace: landing on Organize's overview
        // instead of the duplicates list would be a quieter version of the same loss.
        let retirements: [(String, OrganizeLens)] = [("Rename", .names),
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
        UserDefaults(suiteName: "WorkspaceTests.\(name).\(UUID().uuidString)")!
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
        // A migration that wrote only the workspace would leave whatever rail item happened to be
        // stored, so someone migrating to Compare and then clicking Organize would land on a lens
        // they never picked.
        let d = defaults("clears")
        d.set(OrganizeLens.duplicates.rawValue, forKey: Workspace.organizeLensKey)
        d.set("NotAWorkspace", forKey: Workspace.defaultsKey)

        #expect(Workspace.migrateSelection(in: d) == .default)
        #expect(d.string(forKey: Workspace.defaultsKey) == "Differences")
        #expect(d.string(forKey: Workspace.organizeLensKey) == nil)
    }

    @Test func testARetiredValueAlreadyInTheNewKeyIsRemapped() {
        // The gap the pure-function tests cannot see: a value the flat bar wrote ITSELF. Anyone
        // sitting in Duplicates when this shipped has "Duplicates" in `selectedWorkspace`, not in
        // the legacy pair, and an early return on "is the new key present?" would skip them.
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

        // The user then picks something else. The legacy keys are still sitting there — App.init
        // runs again (SwiftUI re-runs it), and must not stomp the new choice with the stale pair.
        d.set(Workspace.compare.rawValue, forKey: Workspace.defaultsKey)
        #expect(Workspace.migrateSelection(in: d) == nil)
        #expect(d.string(forKey: Workspace.defaultsKey) == "Differences")
    }

    @Test func testADeliberateRailChoiceSurvivesARerun() {
        // The rail key must not be touched when the workspace still resolves — re-running would
        // clear a lens the user is standing in.
        let d = defaults("rail-survives")
        d.set(Workspace.filing.rawValue, forKey: Workspace.defaultsKey)
        d.set(OrganizeLens.renames.rawValue, forKey: Workspace.organizeLensKey)

        #expect(Workspace.migrateSelection(in: d) == nil)
        #expect(d.string(forKey: Workspace.organizeLensKey) == "Renames")
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
        // 2.8 wrote `selectedTidyLens` the first time a lens was picked, so a session that never
        // left Compare can have a lens key and no tab key — and vice versa.
        let lensOnly = defaults("lensonly")
        lensOnly.set("Filing", forKey: Workspace.legacyLensKey)
        #expect(Workspace.migrateSelection(in: lensOnly) == .default)

        let tabOnly = defaults("tabonly")
        tabOnly.set("Tidy", forKey: Workspace.legacyTabKey)
        #expect(Workspace.migrateSelection(in: tabOnly) == Workspace.tidyDefault)
    }
}
