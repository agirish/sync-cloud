import Testing
import Foundation
import Sync
@testable import SyncCloud

/// **Where the file pane goes when Edit opens a file** — the tab already at its folder, or a new
/// one. See ``EditorTabFollow``.
@Suite struct EditorTabFollowTests {

    private static let a = UUID(), b = UUID(), c = UUID()
    /// Relativizing by plain prefix, which is all these cases need; production passes
    /// `PaneLogic.relativePath(of:under:)`, which also follows iCloud Drive's links.
    private static func relative(_ folder: String, _ root: String) -> String? {
        if folder == root { return "" }
        let base = root.hasSuffix("/") ? root : root + "/"
        return folder.hasPrefix(base) ? String(folder.dropFirst(base.count)) : nil
    }
    private static func decide(_ folder: String, active: EditorTabFollow.Tab, others: [EditorTabFollow.Tab] = [],
                               route: ExternalOpen.SourceRoute? = nil) -> EditorTabFollow.Decision {
        EditorTabFollow.decide(folder: folder, active: active, others: others,
                               relative: Self.relative, route: { _ in route })
    }
    private static let docs = EditorTabFollow.Tab(id: a, root: "/c", location: "Documents")

    /// **The same parent: the tab you are in.** Only Edit's view of it may move (Tree vs Columns).
    @Test func theFolderTheActiveTabIsAtStaysInIt() {
        #expect(Self.decide("/c/Documents", active: Self.docs) == .inPlace)
        // Case-folded, as the volumes are.
        #expect(Self.decide("/c/documents", active: Self.docs) == .inPlace)
        // The source's own root is a location too.
        #expect(Self.decide("/c", active: .init(id: Self.a, root: "/c", location: "")) == .inPlace)
    }

    /// **A tab already there is reused** — the one at that folder, on whichever source. Mutation:
    /// skip the scan of the other tabs and this opens a duplicate.
    @Test func anOpenTabAtTheFolderIsSwitchedTo() {
        let others = [EditorTabFollow.Tab(id: Self.b, root: "/c", location: "Photos"),
                      EditorTabFollow.Tab(id: Self.c, root: "/d", location: "Work/Notes")]
        #expect(Self.decide("/d/Work/Notes", active: Self.docs, others: others) == .switchTo(Self.c))
    }

    /// **Anywhere else: a new tab** — a subfolder of the active tab included, which is a different
    /// parent. The tab you were in keeps its place; the hand-off used to re-root it.
    @Test func aDifferentFolderOpensANewTab() {
        let route = ExternalOpen.SourceRoute(providerId: "home", relativePath: "Projects/app")
        #expect(Self.decide("/Users/me/Projects/app", active: Self.docs, route: route) == .open(route))
        let sub = ExternalOpen.SourceRoute(providerId: "c", relativePath: "Documents/Tax")
        #expect(Self.decide("/c/Documents/Tax", active: Self.docs, route: sub) == .open(sub))
    }

    /// No source holds it: the pane stays, nothing invented.
    @Test func aFolderInNoSourceGoesNowhere() {
        #expect(Self.decide("/Volumes/Card", active: Self.docs) == .nowhere)
    }

    /// A tab with no root (a source with no path) is never "at" anything — an empty base would
    /// otherwise claim every folder. **Its location is the one an empty base WOULD produce**
    /// (`relative("/c/Photos", "")` is `c/Photos` here), so the guard is what this rests on — the
    /// review found the first version passing with the guard gone. Mutation: drop
    /// `!tab.root.isEmpty` and this switches to the rootless tab.
    @Test func aTabWithNoRootClaimsNothing() {
        let rootless = EditorTabFollow.Tab(id: Self.b, root: "", location: "c/Photos")
        #expect(Self.decide("/c/Photos", active: Self.docs, others: [rootless]) == .nowhere)
    }

    // MARK: Keeping the source — from Compare and Organize

    private static func keeping(_ folder: String, active: EditorTabFollow.Tab, others: [EditorTabFollow.Tab] = [],
                                route: ExternalOpen.SourceRoute? = nil) -> EditorTabFollow.Decision {
        EditorTabFollow.decide(folder: folder, active: active, others: others, keepsSource: true,
                               relative: Self.relative, route: { _ in route })
    }
    private static let onC = EditorTabFollow.Tab(id: a, root: "/c", location: "Documents", providerId: "c")

    /// **A tab on another source is no candidate**, even one already at the folder — switching to it
    /// adopts that source, which resets the comparison or clears Organize's results. Mutation: drop
    /// the provider filter and this switches to it.
    @Test func keepingTheSourceSkipsATabOnAnotherOne() {
        let elsewhere = EditorTabFollow.Tab(id: Self.b, root: "/d", location: "Notes", providerId: "d")
        let sameSource = EditorTabFollow.Tab(id: Self.c, root: "/c", location: "Photos", providerId: "c")
        #expect(Self.keeping("/d/Notes", active: Self.onC, others: [elsewhere]) == .nowhere)
        #expect(Self.keeping("/c/Photos", active: Self.onC, others: [elsewhere, sameSource]) == .switchTo(Self.c))
    }

    /// **A new tab opens on the pane's own source, never another**, even where another owns the
    /// folder more specifically — and outside its root, nowhere: the pane stays, as before tabs.
    /// Mutations: fall through to `route` and the first line opens on "d"; drop the root guard and
    /// the second opens somewhere it is not.
    @Test func keepingTheSourceOpensOnlyOnIt() {
        let owner = ExternalOpen.SourceRoute(providerId: "d", relativePath: "Notes")
        #expect(Self.keeping("/c/Documents/Notes", active: Self.onC, route: owner)
                == .open(.init(providerId: "c", relativePath: "Documents/Notes")))
        #expect(Self.keeping("/elsewhere/Notes", active: Self.onC, route: owner) == .nowhere)
    }

    // MARK: Edit's own view, after the move

    private static func needsReroot(_ folder: String, editShows: String, root: String = "/c") -> Bool {
        EditorTabFollow.needsRerootInPlace(folder: folder, editShows: editShows, root: root, relative: Self.relative)
    }

    /// **Tree lists a tab's scope**, so a tab at the folder by its column stack still has Edit on the
    /// scope — re-rooted in place. Mutation: return `false` and the first fails.
    @Test func treeShowingTheScopeIsRerootedAtTheFolder() {
        #expect(Self.needsReroot("/c/Documents/Notes", editShows: "/c/Documents"))
        // A pane Edit reads as no folder at all, under the same root.
        #expect(Self.needsReroot("/c/Documents/Notes", editShows: ""))
    }

    /// Columns already shows the folder — case-folded, as the volumes are. Mutation: compare
    /// without folding and the second fails.
    @Test func editAlreadyAtTheFolderIsLeftAlone() {
        #expect(!Self.needsReroot("/c/Documents/Notes", editShows: "/c/Documents/Notes"))
        #expect(!Self.needsReroot("/c/Documents/Notes", editShows: "/c/documents/notes"))
    }

    /// **A folder not under the live tab's root means the move did not happen** — a tab verb refused
    /// during the launch bootstrap, or a tab dropped as unavailable — and re-rooting there would
    /// name a path that is not. An empty root is no root. Mutations: drop `!root.isEmpty` and the
    /// second fails; answer `true` for a folder outside the root and the first does.
    @Test func aMoveThatDidNotHappenIsNotPapered() {
        #expect(!Self.needsReroot("/elsewhere/Notes", editShows: "/c/Documents"))
        #expect(!Self.needsReroot("/c/Documents/Notes", editShows: "/c/Documents", root: ""))
    }

    // MARK: The tab a follow opens

    /// **Rooted at the folder** — the whole path its scope, no column stack — so the tab walks the
    /// folder itself. Stacked under the pane's scope it leaned on that scope's walk reaching the
    /// folder, and on a large source the walk stops at 200,000 entries: the stack was pruned and
    /// the pane landed a folder short (measured 2026-10-03, `~/Downloads/pm/a` → `pm`). Mutation:
    /// cut it through `PaneTabOpening.location` with the pane's scope and the second line fails.
    @Test func aFollowedTabIsRootedAtItsFolder() {
        let tab = ContentView.tabAtRoute(.init(providerId: "home", relativePath: "Downloads/pm/a"), selecting: ["/h/x.md"])
        #expect(tab.providerId == "home" && tab.relativePath == "Downloads/pm/a")
        #expect(tab.browsePath.depth == 0, "the folder is in the column stack, where a short walk prunes it")
        #expect(tab.selection == ["/h/x.md"])
    }
}
