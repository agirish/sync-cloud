import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// The flat workspace selection, and the one-time migration off the two-level `Compare | Tidy`
/// plus lens tabs it replaces.
@Suite struct WorkspaceTests {

    // MARK: Persistence format

    @Test func testRawValuesAreAStablePersistenceFormat() {
        // Persisted via @AppStorage(Workspace.defaultsKey). Every raw value is inherited from one
        // of the two enums this collapsed, so a stored selection keeps resolving; renaming one
        // would silently drop that user onto the .compare default. `title` is separate for exactly
        // this reason — the display names differ from the ids in two places.
        #expect(Workspace.compare.rawValue == "Differences")
        #expect(Workspace.filing.rawValue == "Filing")
        #expect(Workspace.duplicates.rawValue == "Duplicates")
        #expect(Workspace.rename.rawValue == "Rename")
        #expect(Workspace.automations.rawValue == "Automations")
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

    @Test func testEveryLensWorkspaceCarriesItsLensAndCompareCarriesNone() {
        #expect(Workspace.compare.lens == nil)
        for workspace in Workspace.allCases where workspace != .compare {
            #expect(workspace.lens != nil, "\(workspace.rawValue) must resolve to a lens")
        }
        // The mapping round-trips, so `Workspace(lens)` and `workspace.lens` cannot drift apart.
        for lens in TidyLens.allCases {
            #expect(Workspace(lens).lens == lens)
        }
        // And every lens is reachable: a lens with no workspace would be dead code the bar can
        // never select.
        #expect(Set(Workspace.lensWorkspaces.compactMap(\.lens)) == Set(TidyLens.allCases))
    }

    @Test func testBarOrderPutsCompareFirstAndKeepsTheLensGroupTogether() {
        // The bar draws its one separator after the first segment, so Compare has to BE the first
        // segment — otherwise the rule lands mid-group and stops meaning "two panes | one pane".
        #expect(Workspace.allCases.first == .compare)
        #expect(Workspace.allCases.dropFirst().allSatisfy { $0.lens != nil })
    }

    @Test func testEverySegmentHasItsOwnGlyph() {
        // At narrow widths the glyph is the only thing naming a workspace (see
        // WorkspaceBarMetricsTests), so two workspaces sharing one would be two unlabelled
        // segments a user cannot tell apart.
        let symbols = Workspace.allCases.map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
        #expect(!symbols.contains(where: { $0.isEmpty }))
    }

    // MARK: Migration off the two-level selection

    @Test func testEveryOldPairMigratesToTheMatchingWorkspace() {
        // The table is the point: folding two keys into one deletes destinations, and a stored
        // value that stops resolving fails SILENTLY (@AppStorage just takes its default). Each of
        // these was reachable in 2.8, so each has to land somewhere deliberate.
        #expect(Workspace.migrated(tab: "Differences", lens: "Duplicates") == .compare)
        #expect(Workspace.migrated(tab: "Tidy", lens: "Duplicates") == .duplicates)
        #expect(Workspace.migrated(tab: "Tidy", lens: "Rename") == .rename)
        #expect(Workspace.migrated(tab: "Tidy", lens: "Filing") == .filing)
        #expect(Workspace.migrated(tab: "Tidy", lens: "Automations") == .automations)
        #expect(Workspace.migrated(tab: "Tidy", lens: "Storage") == .storage)
    }

    @Test func testOnTidyTheLensDecidesNotTheTab() {
        // The tab said "Tidy" for all five lenses, so migrating on the tab alone would collapse
        // five distinct places into one — the exact information the flat bar exists to keep.
        let migrated = ["Duplicates", "Rename", "Filing", "Automations", "Storage"]
            .map { Workspace.migrated(tab: "Tidy", lens: $0) }
        #expect(Set(migrated).count == 5)
    }

    @Test func testUnrecognisedInputLandsWhereAnEmptyDefaultWould() {
        // An unreadable stored value and no stored value at all must agree, or a corrupt pair
        // sends someone somewhere no fresh install ever starts.
        #expect(Workspace.migrated(tab: nil, lens: nil) == .compare)
        #expect(Workspace.migrated(tab: "NotATab", lens: "NotALens") == .compare)
        // Tidy with a lens that no longer exists takes Tidy's own former default rather than
        // bouncing to Compare — the user was in a lens, so a lens is the nearer answer.
        #expect(Workspace.migrated(tab: "Tidy", lens: nil) == .duplicates)
        #expect(Workspace.migrated(tab: "Tidy", lens: "NotALens") == .duplicates)
        // "Differences" is a Workspace raw value too; it must not be read as a *lens* and let
        // someone on Tidy resolve to Compare through the lens arm.
        #expect(Workspace.migrated(tab: "Tidy", lens: "Differences") == .duplicates)
    }

    // MARK: Migration is one-shot

    private func defaults(_ name: String) -> UserDefaults {
        let suite = UserDefaults(suiteName: "WorkspaceTests.\(name).\(UUID().uuidString)")!
        return suite
    }

    @Test func testMigrationWritesTheResolvedWorkspaceOnce() {
        let d = defaults("writes")
        d.set("Tidy", forKey: Workspace.legacyTabKey)
        d.set("Storage", forKey: Workspace.legacyLensKey)

        #expect(Workspace.migrateSelection(in: d) == .storage)
        #expect(d.string(forKey: Workspace.defaultsKey) == "Storage")
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

    @Test func testAFirstRunIsLeftAloneRatherThanSeeded() {
        // No legacy keys means no upgrade to carry. Writing a value here would bake this
        // function's idea of the default into every fresh install, splitting the default in two.
        let d = defaults("firstrun")
        #expect(Workspace.migrateSelection(in: d) == nil)
        #expect(d.string(forKey: Workspace.defaultsKey) == nil)
    }

    @Test func testAPartialLegacyStateStillMigrates() {
        // 2.8 wrote `selectedTidyLens` the first time a lens was picked, so a session that never
        // left Compare can have a lens key and no tab key — and vice versa.
        let lensOnly = defaults("lensonly")
        lensOnly.set("Filing", forKey: Workspace.legacyLensKey)
        #expect(Workspace.migrateSelection(in: lensOnly) == .compare)

        let tabOnly = defaults("tabonly")
        tabOnly.set("Tidy", forKey: Workspace.legacyTabKey)
        #expect(Workspace.migrateSelection(in: tabOnly) == .duplicates)
    }
}
