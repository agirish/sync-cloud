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
        // Every lens EXCEPT `.rename` round-trips. Rename deliberately does not: it has no
        // workspace of its own — it is a finding inside Organize — so a caller naming that lens is
        // asking for Organize. Asserted rather than skipped, because a silent identity here would
        // mean the flat bar had grown a sixth segment again.
        for lens in TidyLens.allCases where lens != .rename {
            #expect(Workspace(lens).lens == lens)
        }
        #expect(Workspace(.rename) == .filing)
        // Every workspace's lens is reachable, and no workspace claims `.rename`.
        #expect(Set(Workspace.lensWorkspaces.compactMap(\.lens))
                == Set(TidyLens.allCases).subtracting([.rename]))
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
        // Rename is a finding inside Organize now, not a place — see the retired-value tests.
        #expect(Workspace.migrated(tab: "Tidy", lens: "Rename") == .filing)
        #expect(Workspace.migrated(tab: "Tidy", lens: "Filing") == .filing)
        #expect(Workspace.migrated(tab: "Tidy", lens: "Automations") == .automations)
        #expect(Workspace.migrated(tab: "Tidy", lens: "Storage") == .storage)
    }

    @Test func testOnTidyTheLensDecidesNotTheTab() {
        // The tab said "Tidy" for all five lenses, so migrating on the tab alone would collapse
        // five distinct places into one — the exact information the flat bar exists to keep.
        // Four survive as destinations, not five: Rename folded into Organize, so those two share
        // one. That collision is the only one allowed, and naming it here is what stops a future
        // mapping bug from hiding behind a merely-smaller count.
        let lenses = ["Duplicates", "Rename", "Filing", "Automations", "Storage"]
        let migrated = lenses.map { Workspace.migrated(tab: "Tidy", lens: $0) }
        #expect(Set(migrated).count == 4)
        #expect(Workspace.migrated(tab: "Tidy", lens: "Rename")
                == Workspace.migrated(tab: "Tidy", lens: "Filing"))
        // Every OTHER pair is still distinct.
        let others = lenses.filter { $0 != "Rename" }.map { Workspace.migrated(tab: "Tidy", lens: $0) }
        #expect(Set(others).count == others.count)
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

    @Test func testTheRetiredRenameValueResolvesToOrganizeFromBothSpellings() {
        // `Rename` persisted twice over: as a TidyLens (2.8 and earlier) and, for one commit, as a
        // Workspace of its own. Both spellings are still on disk in the wild, and NEITHER resolves
        // any more — @AppStorage would silently take its default and drop the user on Compare,
        // which is nowhere near what they were doing. This is the only mapping in the table whose
        // source case no longer exists in the enum, which is exactly why it needs pinning.
        #expect(Workspace(rawValue: Workspace.retiredRenameRawValue) == nil)
        #expect(Workspace.migrated(tab: "Tidy", lens: "Rename") == .filing)
        #expect(Workspace.migrated(tab: "Rename", lens: nil) == .filing)
        #expect(Workspace.migrated(tab: "Rename", lens: "Rename") == .filing)
    }

    @Test func testRenameIsNotABarSegment() {
        // The bar is five now. A sixth segment reappearing means the fold was undone somewhere.
        #expect(Workspace.allCases.count == 5)
        #expect(!Workspace.allCases.contains { $0.title == "Rename" })
        #expect(!Workspace.allCases.contains { $0.rawValue == Workspace.retiredRenameRawValue })
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

    @Test func testARetiredValueAlreadyInTheNewKeyIsRemapped() {
        // The gap the pure-function tests above could not see. `Rename` was a Workspace for one
        // commit, so anyone who ran it and sat there has "Rename" in `selectedWorkspace` — not in
        // the legacy pair. The first cut guarded on "is the new key present?" and returned early,
        // so those users skipped the migration entirely and @AppStorage silently took its default:
        // dropped on Compare, mid-task, with nothing to explain it. Everything else about that
        // path was correct, which is exactly why it needed a test through `migrateSelection`
        // rather than through `migrated(tab:lens:)`.
        let d = defaults("retired-in-new-key")
        d.set(Workspace.retiredRenameRawValue, forKey: Workspace.defaultsKey)

        #expect(Workspace.migrateSelection(in: d) == .filing)
        #expect(d.string(forKey: Workspace.defaultsKey) == Workspace.filing.rawValue)
    }

    @Test func testAnUnreadableValueInTheNewKeyLandsWhereAFreshInstallWould() {
        // Not a retired case — corruption, a hand edit, a downgrade-and-back. It must resolve to
        // the same place an empty install starts rather than staying unresolvable forever.
        let d = defaults("garbage-in-new-key")
        d.set("NotAWorkspace", forKey: Workspace.defaultsKey)

        #expect(Workspace.migrateSelection(in: d) == .compare)
        #expect(d.string(forKey: Workspace.defaultsKey) == Workspace.compare.rawValue)
    }

    @Test func testEveryRetiredValueIsAccountedForByName() {
        // The mapping is a lookup on a constant, so the risk is not that it computes wrongly —
        // it is that a future retirement adds a case here and forgets this function. Pinning both
        // arms makes that omission a failure rather than a silent fallback to Compare.
        #expect(Workspace.migratedWorkspace(Workspace.retiredRenameRawValue) == .filing)
        #expect(Workspace.migratedWorkspace("Differences") == .compare)
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
