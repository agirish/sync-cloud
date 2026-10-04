import Testing
import Foundation
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
    /// otherwise claim every folder.
    @Test func aTabWithNoRootClaimsNothing() {
        let rootless = EditorTabFollow.Tab(id: Self.b, root: "", location: "")
        #expect(Self.decide("/c/Photos", active: Self.docs, others: [rootless]) == .nowhere)
    }
}
