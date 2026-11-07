import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// The route-table walk: every destination the palette can reach must keep a door. The results list
/// is `GoToResultsPanel`, as wide as the toolbar field: 620pt at the ceiling but 320 at the floor.
/// A destination that lost its row would go unreported by anything else in the app.
///
/// Two questions, and the second has the teeth:
///
/// 1. Is every destination still listed? A straight model walk.
/// 2. Is every listed row still usable at 320pt? The `detail` is what separates `Clients/Legal`
///    from `Archive/Legal`, both rows titled "Legal". If it stops being drawn at the floor width,
///    two destinations become one visible row and one has lost its door. Geometry and ink counts
///    can't see that; it is a pixel question (`.machinePinned(.pixelSampling)` for that half).
@MainActor
@Suite(.serialized) struct PaletteRouteDoorTests {

    static let root = "/Users/x/Documents"
    /// A second mounted source the pane is not aimed at: the only configuration that can produce a
    /// `.folderInSource` route.
    static let dropbox = "/Users/x/Dropbox"

    /// Everything a route can be, flattened to a name, so a walk can assert coverage without
    /// `PaletteRoute` being `CaseIterable` (it has associated values and can't be).
    ///
    /// An exhaustive `switch` on purpose: a new `PaletteRoute` case fails to compile here, which is
    /// what makes "every destination" mean the whole set rather than the set someone remembered.
    static func kind(_ route: PaletteRoute) -> String {
        switch route {
        case .browse: return "browse"
        case .compare: return "compare"
        case .editor: return "editor"
        case .organize: return "organize"
        case .person: return "person"
        case .provider: return "provider"
        case .folder: return "folder"
        case .folderInSource: return "folderInSource"
        case .action(let action): return "action.\(action)"
        // One kind, not one per tab: which tabs are offered is a property of the injected list,
        // walked where it is derived (`everyTabIsOffered`) and passed through
        // (`theHostOffersEverySettingsTab`). What is owed here is that the Settings builder emits.
        case .settings: return "settings"
        }
    }

    static let people = [Person(id: "p.daughter", displayName: "Daughter", relationship: "daughter",
                                fullNames: ["Daughter Elder"])]

    /// The path a route resolves under the provider root, or nil for a route that names none.
    ///
    /// Exhaustive on purpose, like `kind` above. A root that didn't answer has to be applied to
    /// every route that names a folder, and a list kept from memory misses one: `verbRows` turns
    /// the same `index.folders` into an Organize scope. A new case with a path in it fails to
    /// compile here rather than going unguarded.
    static func pathUnderRoot(of route: PaletteRoute) -> String? {
        switch route {
        case .folder(let path): return path
        case .organize(_, let scope): return scope
        // `.folderInSource` names a path under another source's root, so it is not one of these, on
        // purpose. `foldersUnavailable` is a verdict on the root the pane is aimed at, and another
        // source has its own `isMounted`, which `pathRow` checks before offering the switch.
        // Applying the aimed root's verdict would refuse a folder on a disk that is wide awake.
        case .browse, .compare, .editor, .person, .provider, .folderInSource, .action, .settings:
            return nil
        }
    }

    /// Both same-leaf folders are recents, on purpose. With one pinned and one recent the rows
    /// would differ by "Favorite" against "Recent", and the render check below would pass even if
    /// the path truncated away entirely. Same group, same leaf: only the path tells them apart.
    ///
    /// The paths share a long head and a leaf and differ only in the middle, which is what a
    /// middle-truncated detail elides first. Short paths make the test vacuous: they render without
    /// truncating at both widths, so a collapse couldn't show.
    static func index(recents: [String] = ["Clients/Acme Holdings International/2024 Filings/Legal",
                                           "Clients/Acme Holdings International/2019 Filings/Legal"],
                      pinned: [String] = [],
                      unavailable: String? = nil) -> PaletteIndex {
        PaletteIndex(
            providers: [PaletteProvider(id: "icloud", name: "iCloud", isMounted: true,
                                        isCurrent: true, root: root),
                        // Mounted, and not the one the pane is on: the only shape that can produce
                        // `.folderInSource`. Without it the walk below can't reach that destination
                        // at all.
                        PaletteProvider(id: "dropbox", name: "Dropbox", isMounted: true,
                                        isCurrent: false, root: dropbox),
                        PaletteProvider(id: "ssd", name: "Backup SSD", isMounted: false,
                                        isCurrent: false, root: "/Volumes/Backup")],
            providerRoot: root,
            folders: recents + ["Finance"],
            recentFolders: recents, pinnedFolders: pinned,
            foldersUnavailable: unavailable,
            people: people, registry: PersonRegistry(people: people),
            isScanning: false, hasSurvey: true,
            // Two tabs, so the Settings builder has a door to be found through. Real names and a
            // real keyword, because the walk below reaches it with the query "settings".
            settingsTabs: [
                PaletteSettingsTab(id: "general", name: "General",
                                   detail: "Startup, sorting, and notifications",
                                   symbol: "gearshape", vocabulary: ["Sort panes by", "login"]),
                PaletteSettingsTab(id: "appearance", name: "Appearance",
                                   detail: "Theme, accent, glass, and surfaces",
                                   symbol: "paintbrush", vocabulary: ["Glass effect", "blur"])
            ])
    }

    /// The queries that reach every builder able to mint a path under the root: the landing
    /// (`emptyQueryRows`), a plain folder match (`folderRows`), and a verb with an object
    /// (`verbRows`).
    static let pathBearingQueries = ["", "legal", "organize legal", "finance", "organize finance",
                                     // A typed path is the fourth builder. `pathRow` fires only
                                     // when a probe is supplied, so the walk passes one (see
                                     // `probe`).
                                     "\(root)/Finance"]

    /// The disk, for the one builder that asks it. Answers `.directory` for anything under the
    /// fixture's root and `.missing` elsewhere: what is under test is whether a route that names a
    /// path is marked, not whether the folder is there.
    static let probe: PalettePathProbe = { path in
        path.hasPrefix(root) ? .directory : .missing
    }

    /// Every destination the palette can reach still has a door. The queries are the doors: the
    /// empty landing, plus one per destination the landing doesn't carry. If a builder stops
    /// emitting a group, its kind is missing and the failure names it.
    @Test func everyRouteKindIsStillReachableFromSomeQuery() {
        let index = Self.index()
        let queries = ["", "browse", "compare", "storage", "organize", "daughter", "icloud",
                       "legal", "rescan", "new folder", "choose", "find", "settings",
                       "shortcuts", "activity",
                       // The two typed-path doors, two different destinations: a path inside the
                       // source the pane is showing (`folder`) and one inside another mounted
                       // source (`folderInSource`). Both need the probe: `rows` without one emits
                       // no path row.
                       "\(Self.root)/Finance", "\(Self.dropbox)/Legal"]
        var reached = Set<String>()
        for query in queries {
            for row in PaletteRouter.rows(query: query, index: index, probe: Self.probe)
            where row.isAvailable {
                reached.insert(Self.kind(row.route))
            }
        }

        // "storage" is not a route kind: Storage is a lens, so the place arrives as `organize`
        // carrying `lens: .storage`. `CommandPaletteTests` follows the query "storage" to that
        // route, including with a folder.
        var expected: Set<String> = ["browse", "compare", "organize", "person",
                                     "provider", "folder", "folderInSource", "settings"]
        for action in PaletteAction.allCases { expected.insert("action.\(action)") }

        let missing = expected.subtracting(reached).sorted()
        #expect(missing.isEmpty,
                "these destinations have no door left in the palette, and the 620pt card that used to show them is deleted: \(missing.joined(separator: ", "))")
    }

    /// A root that didn't answer must take every route that names a path under it. Three builders
    /// mint such a path: the landing's recents and pins, a folder match, and a verb row's Organize
    /// scope. Missing one would let "organize legal" write a scope for a folder on a sleeping
    /// drive, move the workspace to show it, and reveal nothing. Walked through `pathUnderRoot`, so
    /// a new builder can't be missed the same way.
    @Test func everyPathBearingRouteIsRefusedWhenTheRootIsAsleep() {
        let index = Self.index(unavailable: "Not available")
        var seen = 0
        for query in Self.pathBearingQueries {
            for row in PaletteRouter.rows(query: query, index: index, probe: Self.probe) {
                guard let path = Self.pathUnderRoot(of: row.route) else { continue }
                seen += 1
                #expect(row.unavailable == "Not available",
                        "“\(query)” offers \(path) as a live destination under a root that did not answer")
            }
        }
        #expect(seen >= 7,
                "only \(seen) path-bearing rows were reached — the queries no longer cover the builders this is about")
    }

    /// The awake half, so the test above isn't just "unavailable is whatever we passed", and a fix
    /// that marked everything always would fail here.
    @Test func thoseSameRoutesAreLiveWhenTheRootAnswers() {
        let index = Self.index()
        var seen = 0
        for query in Self.pathBearingQueries {
            for row in PaletteRouter.rows(query: query, index: index, probe: Self.probe) where Self.pathUnderRoot(of: row.route) != nil {
                seen += 1
                #expect(row.isAvailable, "“\(query)” refuses a folder under a root that is right there")
            }
        }
        #expect(seen >= 7, "only \(seen) path-bearing rows were reached — this pair is not measuring the same set")
    }

    /// The landing alone, what ⌘K opens on, must carry the four groups. A destination reachable
    /// only by typing its name is one a stranger can't find.
    @Test func theLandingStillLeadsWithAllFourGroups() {
        let rows = PaletteRouter.rows(query: "", index: Self.index())
        for group in [PaletteGroup.folders, .places, .sources, .actions] {
            #expect(rows.contains { $0.group == group },
                    "the \(group) group is gone from the empty-query landing — ⌘K opens without it")
        }
    }
}

/// The pixel half of the walk, split out so only it carries the machine pin.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct PaletteRouteDoorRenderTests {

    /// Two folders with the same leaf must not render as the same row, at either width.
    ///
    /// Both are titled "Legal"; only the detail line (the same "Recent · " prefix over two paths
    /// that share a long head and leaf) tells them apart. At 620pt there is room for it; at the
    /// 320pt floor there may not be, and a detail dropped or truncated to the common head would
    /// make the two rows one visible destination. (`PaletteRouteDoorTests.index` says why both are
    /// recents and why the paths are long.)
    ///
    /// Compared pixel for pixel rather than measured, because geometry and ink counts can't tell
    /// "omitted" from "truncated".
    @Test(arguments: [620.0, 320.0]) func sameLeafFoldersStayDistinguishable(width: Double) {
        let rows = PaletteRouter.rows(query: "", index: PaletteRouteDoorTests.index())
            .filter { $0.group == .folders }
        let leaves = rows.map(\.title)
        #expect(leaves.count == 2 && Set(leaves).count == 1,
                "the fixture no longer produces two same-leaf folders — it cannot detect the collapse it is here for")

        // One row each, rendered alone at the same size, so any difference is the row's content.
        let first = CommandPaletteRenderTests.renderList(rows: [rows[0]], selection: nil,
                                                        scheme: .light, width: width, height: 60)
        let second = CommandPaletteRenderTests.renderList(rows: [rows[1]], selection: nil,
                                                         scheme: .light, width: width, height: 60)
        let differing = CommandPaletteRenderTests.differingPixels(first, second)
        // Distinct rows differ by over a thousand pixels at both widths (more at the floor, since
        // truncation shifts glyphs too). Dropping the detail line takes both to 0, which is what
        // the threshold is set against.
        #expect(differing > 200,
                "at \(Int(width))pt two different folders draw the same row (\(differing) pixels differ, against ~1256 at 620pt and ~1783 at 320pt when they are distinct) — one of them has no door a person can pick")
    }
}
