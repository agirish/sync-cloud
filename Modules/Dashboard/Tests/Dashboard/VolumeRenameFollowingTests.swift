import Foundation
import AppKit
import Testing
import Sync
@testable import Dashboard

/// **What follows a card renamed in Finder, on the two surfaces outside `SettingsManager`.**
///
/// `FolderSource.following(volumeRenameFrom:to:in:)` moves the source itself, and `VolumeRenameTests`
/// in the Sync package pins that rule. The source moving is not enough on its own: the pins, the
/// recents and the Favorites order are all keyed by provider ROOT, and the root is exactly what a
/// rename changes. Left alone they survive on disk under a key nothing will ever ask for again, and
/// `reachable` cannot report it — that filters what a root holds, and this is the root moving out
/// from under it.
///
/// The glyph half is here for a different reason: it is the same session's report, and the constant
/// it pins lives in this module.
@Suite struct VolumeRenameFollowingTests {

    private static let old = "/Volumes/OLD CARD"
    private static let new = "/Volumes/NEW CARD"

    private func location(_ relative: String) -> JumpLocation {
        JumpLocation(relativePath: relative, name: (relative as NSString).lastPathComponent)
    }

    // MARK: The per-root maps

    @Test func pinsOnTheRenamedVolumeMoveToItsNewRoot() {
        let before = [Self.old: [location("DCIM")], "~/Downloads": [location("Invoices")]]
        let after = FolderJumpStore.rekeyed(before, whenVolumeMovedFrom: Self.old, to: Self.new)
        #expect(after[FolderJumpStore.key(forRoot: Self.new)] == [location("DCIM")])
        #expect(after[Self.old] == nil)
        // The untouched root keeps its own entries, normalised the way the store spells keys.
        #expect(after[FolderJumpStore.key(forRoot: "~/Downloads")] == [location("Invoices")])
    }

    /// A root INSIDE the renamed volume moves too — a source can be rooted at `/Volumes/CARD/DCIM`
    /// as easily as at the mount point, and the rewrite is the same prefix substitution.
    @Test func aRootInsideTheRenamedVolumeMovesWithIt() {
        let after = FolderJumpStore.rekeyed(["\(Self.old)/DCIM": [location("100MSDCF")]],
                                            whenVolumeMovedFrom: Self.old, to: Self.new)
        #expect(after[FolderJumpStore.key(forRoot: "\(Self.new)/DCIM")] == [location("100MSDCF")])
    }

    /// **Merged, not overwritten.** The user re-added the card under its new name and pinned
    /// something there before the rename was followed — which is exactly the sequence reported on
    /// 2026-08-29. Either side dropped is pins lost to a rename, which is what this exists to stop.
    /// The destination's own entries lead, the arrivals follow, deduplicated by relative path.
    @Test func pinsMergeWhenBothTheOldAndNewRootsHaveSome() {
        let before = [Self.old: [location("DCIM"), location("MP_ROOT")],
                      Self.new: [location("PRIVATE"), location("DCIM")]]
        let after = FolderJumpStore.rekeyed(before, whenVolumeMovedFrom: Self.old, to: Self.new)
        #expect(after.count == 1)
        #expect(after[FolderJumpStore.key(forRoot: Self.new)]
                == [location("PRIVATE"), location("DCIM"), location("MP_ROOT")])
    }

    @Test func aMapWithNothingOnTheRenamedVolumeIsUnchanged() {
        let before = [FolderJumpStore.key(forRoot: "~/Downloads"): [location("Invoices")]]
        #expect(FolderJumpStore.rekeyed(before, whenVolumeMovedFrom: Self.old, to: Self.new)
                == before)
    }

    // MARK: The Favorites order

    /// The order is a list of `root\u{0}relative` keys, so only the root half moves — and it has to
    /// move, or every favorite on the renamed card drops to the section's unranked tail, which is a
    /// silent reordering the user did not ask for.
    @Test func theFavoritesOrderMovesTheRootHalfOfItsKeys() {
        let order = [FolderJumpStore.favoriteKey(root: Self.old, relativePath: "DCIM"),
                     FolderJumpStore.favoriteKey(root: "~/Downloads", relativePath: "Invoices")]
        let after = FolderJumpStore.rekeyedFavoriteOrder(order,
                                                         whenVolumeMovedFrom: Self.old, to: Self.new)
        #expect(after == [FolderJumpStore.favoriteKey(root: Self.new, relativePath: "DCIM"),
                          FolderJumpStore.favoriteKey(root: "~/Downloads", relativePath: "Invoices")])
    }

    /// **The separator is load-bearing.** A relative path may contain `/` and a root may contain
    /// spaces; only the NUL splits `("/Volumes/OLD CARD", "DCIM/100MSDCF")` in one place. Splitting
    /// on anything a path can hold would rewrite the wrong half of this key.
    @Test func onlyTheRootHalfMovesEvenWhenTheRelativePathHasSlashes() {
        let key = FolderJumpStore.favoriteKey(root: Self.old, relativePath: "DCIM/100MSDCF")
        #expect(FolderJumpStore.rekeyedFavoriteOrder([key],
                                                     whenVolumeMovedFrom: Self.old, to: Self.new)
                == [FolderJumpStore.favoriteKey(root: Self.new, relativePath: "DCIM/100MSDCF")])
    }

    // MARK: The pane-collapse glyph

    /// **The pane's collapse button may not wear the window sidebar toggle's glyph.**
    ///
    /// Both were `sidebar.left`, about forty points apart down the same edge of the window, for two
    /// unrelated acts — show the folder column, fold this pane into the spine. Reported as exactly
    /// that confusion on 2026-08-29.
    ///
    /// Pinned as a *literal* rather than read back from `PaneBarItem`, because the constant is the
    /// thing under test: comparing it to itself would hold whatever it was changed to.
    @Test func theCollapseGlyphIsNotTheWindowSidebarToggles() {
        #expect(PaneBarItem.collapseSymbol != "sidebar.left")
        #expect(PaneBarItem.collapseSymbol != "sidebar.leading")
    }

    /// And not the Back button's either, which is the pill immediately to its right — a bare `<`
    /// would have traded a collision at forty points for one at eight.
    @Test func theCollapseGlyphIsNotTheBackChevron() {
        #expect(PaneBarItem.collapseSymbol != "chevron.left")
        #expect(PaneBarItem.collapseSymbol != "chevron.backward")
        #expect(PaneBarItem.backForward.paletteSymbol == "chevron.left",
                "Back's glyph moved — the clash this guards against is now a different pair")
    }

    /// The mark has to exist, or the button draws nothing at all and every geometry assertion in
    /// `PaneNavMetricsTests` still passes over an empty frame.
    @Test func theCollapseGlyphIsARealSymbol() {
        #expect(NSImage(systemSymbolName: PaneBarItem.collapseSymbol,
                        accessibilityDescription: nil) != nil)
    }

    /// **The call site, not just the constant.** `PaneBarItem.collapseSymbol` being right is worth
    /// nothing if the bar goes back to spelling a literal — which is the state this replaced, with
    /// the same string written out in three places.
    @Test func theBarAndItsOverflowMenuBothDrawTheConstant() throws {
        let views = try Self.source("Sources/Dashboard/DashboardViews.swift")
        #expect(!views.contains("\"sidebar.left\""),
                "DashboardViews spells a sidebar glyph literally again")
        #expect(views.components(separatedBy: "PaneBarItem.collapseSymbol").count - 1 == 2,
                "the rung and the overflow item should both read the constant")
    }

    // MARK: The observer

    /// **A rule with no caller is not a fix.** The two followers above and
    /// `SettingsManager.followVolumeRename` are all reached from one place — `ContentView`'s
    /// subscription to `didRenameVolumeNotification` — and nothing else in the app would notice if
    /// that subscription were dropped. `MacApp/` is in no SPM package, so a source scan is the only
    /// reading of it available from a test.
    @Test func contentViewFollowsTheVolumeRenameNotification() throws {
        let content = try Self.appSource("ContentView.swift")
        #expect(content.contains("didRenameVolumeNotification"),
                "nothing subscribes to the volume-rename notification")
        #expect(content.contains("settings.followVolumeRename"),
                "the sources are not moved when a volume is renamed")
        #expect(content.contains("FolderJumpStore.shared.followVolumeRename"),
                "the pins and recents are not moved when a volume is renamed")
    }

    /// The sidebar's own way out of a dead source, for the rename that happened while SyncCloud was
    /// quit and therefore could not be followed. Without the caller wiring it, the menu item is
    /// present and does nothing.
    @Test func theSidebarIsGivenAWayToRemoveAFolderSource() throws {
        let host = try Self.appSource("ContentView+FolderSidebar.swift")
        #expect(host.contains("onRemoveSource:"), "the sidebar is not given a removal handler")
        #expect(host.contains("removableSourceIds:"),
                "the sidebar is not told which rows may be removed")
        #expect(host.contains("settings.removeFolderSource"),
                "the handler does not actually remove the source")
        let sidebar = try Self.source("Sources/Dashboard/FolderSidebar.swift")
        #expect(sidebar.contains("Remove Source…"), "the context menu offers no Remove")
        #expect(sidebar.contains("pendingSourceRemoval"),
                "Remove is not confirmed — and it is not reversible, so it must be")
    }

    // MARK: Reading the tree

    /// This module's directory, from this file's own path.
    private static let moduleDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // …/Modules/Dashboard/Tests/Dashboard
        .deletingLastPathComponent()   // …/Modules/Dashboard/Tests
        .deletingLastPathComponent()   // …/Modules/Dashboard

    private static func source(_ relative: String) throws -> String {
        let url = moduleDir.appendingPathComponent(relative)
        return try #require(try? String(contentsOf: url, encoding: .utf8),
                            "cannot read \(url.path) — the scan would pass vacuously")
    }

    private static func appSource(_ name: String) throws -> String {
        let url = moduleDir
            .deletingLastPathComponent()   // …/Modules
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("MacApp").appendingPathComponent(name)
        return try #require(try? String(contentsOf: url, encoding: .utf8),
                            "cannot read \(url.path) — the scan would pass vacuously")
    }
}
