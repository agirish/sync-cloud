import Foundation
import AppKit
import Testing
import Sync
@testable import Dashboard

/// What follows a card renamed in Finder, on the two surfaces outside `SettingsManager`.
///
/// `FolderSource.following(volumeRenameFrom:to:in:)` moves the source itself (`VolumeRenameTests` in
/// Sync). The pins, recents and Favorites order are keyed by provider root, which is what a rename
/// changes, so left alone they would sit on disk under a key nothing asks for. `reachable` can't
/// catch it: it filters what a root holds, not the root moving. The pane-collapse glyph tests are
/// here because the constant they pin lives in this module.
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

    /// A root inside the renamed volume moves too: a source can be rooted at `/Volumes/CARD/DCIM` as
    /// easily as at the mount point, and the rewrite is the same prefix substitution.
    @Test func aRootInsideTheRenamedVolumeMovesWithIt() {
        let after = FolderJumpStore.rekeyed(["\(Self.old)/DCIM": [location("100MSDCF")]],
                                            whenVolumeMovedFrom: Self.old, to: Self.new)
        #expect(after[FolderJumpStore.key(forRoot: "\(Self.new)/DCIM")] == [location("100MSDCF")])
    }

    /// Merged, not overwritten: the user may re-add the card under its new name and pin something
    /// before the rename is followed, and dropping either side loses pins. The destination's own
    /// entries lead, the arrivals follow, deduplicated by relative path.
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

    /// The order is a list of `root\u{0}relative` keys, so only the root half moves, and it must, or
    /// every favorite on the renamed card drops to the unranked tail, a reorder nobody asked for.
    @Test func theFavoritesOrderMovesTheRootHalfOfItsKeys() {
        let order = [FolderJumpStore.favoriteKey(root: Self.old, relativePath: "DCIM"),
                     FolderJumpStore.favoriteKey(root: "~/Downloads", relativePath: "Invoices")]
        let after = FolderJumpStore.rekeyedFavoriteOrder(order,
                                                         whenVolumeMovedFrom: Self.old, to: Self.new)
        #expect(after == [FolderJumpStore.favoriteKey(root: Self.new, relativePath: "DCIM"),
                          FolderJumpStore.favoriteKey(root: "~/Downloads", relativePath: "Invoices")])
    }

    /// The separator matters: a relative path may contain `/` and a root may contain spaces, so
    /// only NUL splits `("/Volumes/OLD CARD", "DCIM/100MSDCF")` in one place. Splitting on anything
    /// a path can hold would rewrite the wrong half.
    @Test func onlyTheRootHalfMovesEvenWhenTheRelativePathHasSlashes() {
        let key = FolderJumpStore.favoriteKey(root: Self.old, relativePath: "DCIM/100MSDCF")
        #expect(FolderJumpStore.rekeyedFavoriteOrder([key],
                                                     whenVolumeMovedFrom: Self.old, to: Self.new)
                == [FolderJumpStore.favoriteKey(root: Self.new, relativePath: "DCIM/100MSDCF")])
    }

    // MARK: The pane-collapse glyph

    /// The pane's collapse button must not wear the window sidebar toggle's glyph: the two sit about
    /// forty points apart on the same edge for unrelated acts (show the folder column, fold this
    /// pane into the spine). Compared with literals, because the constant is what's under test.
    /// Nor the Back button's, the pill right beside it: a bare `<` would trade a clash at forty
    /// points for one at eight. And the mark must exist, or the button draws nothing and
    /// `PaneNavMetricsTests` still passes over an empty frame.
    @Test func theCollapseGlyphIsARealSymbolUnlikeItsNeighbours() {
        #expect(PaneBarItem.collapseSymbol != "sidebar.left")
        #expect(PaneBarItem.collapseSymbol != "sidebar.leading")
        #expect(PaneBarItem.collapseSymbol != "chevron.left")
        #expect(PaneBarItem.collapseSymbol != "chevron.backward")
        #expect(PaneBarItem.backForward.paletteSymbol == "chevron.left",
                "Back's glyph moved — the clash this guards against is now a different pair")
        #expect(NSImage(systemSymbolName: PaneBarItem.collapseSymbol,
                        accessibilityDescription: nil) != nil)
    }

    /// The call site, not just the constant: `PaneBarItem.collapseSymbol` is worth nothing if the
    /// bar spells the glyph as a literal.
    @Test func theBarAndItsOverflowMenuBothDrawTheConstant() throws {
        let views = try DashboardSource.read("DashboardViews.swift")
        #expect(!views.contains("\"sidebar.left\""),
                "DashboardViews spells a sidebar glyph literally again")
        #expect(views.components(separatedBy: "PaneBarItem.collapseSymbol").count - 1 == 2,
                "the rung and the overflow item should both read the constant")
    }

    // MARK: The observer

    /// A rule with no caller is not a fix. The two followers above and
    /// `SettingsManager.followVolumeRename` are reached only from `ContentView`'s subscription to
    /// `didRenameVolumeNotification`, and nothing would notice it dropped. `MacApp/` is in no SPM
    /// package, so a source scan is the only way a test can read it.
    @Test func contentViewFollowsTheVolumeRenameNotification() throws {
        let content = try DashboardSource.app("ContentView.swift")
        #expect(content.contains("didRenameVolumeNotification"),
                "nothing subscribes to the volume-rename notification")
        #expect(content.contains("settings.followVolumeRename"),
                "the sources are not moved when a volume is renamed")
        #expect(content.contains("FolderJumpStore.shared.followVolumeRename"),
                "the pins and recents are not moved when a volume is renamed")
    }

    /// The sidebar's way out of a dead source, for a rename made while SyncCloud was quit and so
    /// not followed. Unless the caller wires it, the menu item is present and does nothing.
    @Test func theSidebarIsGivenAWayToRemoveAFolderSource() throws {
        let host = try DashboardSource.app("ContentView+FolderSidebar.swift")
        #expect(host.contains("onRemoveSource:"), "the sidebar is not given a removal handler")
        #expect(host.contains("removableSourceIds:"),
                "the sidebar is not told which rows may be removed")
        #expect(host.contains("settings.removeFolderSource"),
                "the handler does not actually remove the source")
        let sidebar = try DashboardSource.read("FolderSidebar.swift")
        #expect(sidebar.contains("Remove Source…"), "the context menu offers no Remove")
        #expect(sidebar.contains("case .removeSource(let row): onRemoveSource(row)"),
                "Remove is not routed through the confirmation — and it is not reversible, so it must be")
    }
}
