import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// **The route-table walk** — ROADMAP_V4 §7's one stated silent-removal risk, owed since the 620pt
/// card was deleted in `7e8fff03` and taken 2026-08-19.
///
/// The card listed workspaces, sources, folders and actions in 620pt with room for a title *and* a
/// detail line. Its replacement is `GoToResultsPanel`, whose width is the toolbar field's — 620 at
/// the ceiling but **320 at the floor**. Anything the card alone made reachable went with it, and
/// nothing in the app would report that.
///
/// Two questions, and the second is the one with teeth:
///
/// 1. **Is every destination still listed?** Cheap, and a straight model walk.
/// 2. **Is every listed row still usable at 320pt?** The `detail` is what separates
///    `Clients/Legal` from `Archive/Legal` — both are a row titled "Legal". If it stops being drawn
///    at the floor width, two different destinations become the same visible row and one of them
///    has effectively lost its door. Geometry cannot see that, and neither can an ink count; it is
///    a pixel question (`.machinePinned(.pixelSampling)` for the half that renders).
@MainActor
@Suite(.serialized) struct PaletteRouteDoorTests {

    static let root = "/Users/x/Documents"

    /// Everything a route can be, flattened to a name, so a walk can assert coverage without
    /// `PaletteRoute` being `CaseIterable` — it has associated values and cannot be.
    ///
    /// **Written as an exhaustive `switch` deliberately.** A new case added to `PaletteRoute` fails
    /// to compile here, which is the only thing that makes "every destination" mean the whole set
    /// rather than the set someone remembered to list.
    static func kind(_ route: PaletteRoute) -> String {
        switch route {
        case .browse: return "browse"
        case .compare: return "compare"
        case .editor: return "editor"
        case .organize: return "organize"
        case .person: return "person"
        case .provider: return "provider"
        case .folder: return "folder"
        case .action(let action): return "action.\(action)"
        // One kind, not one per tab: which tabs are offered is a property of the list the host
        // injects, and it is walked where that list is derived (`everyTabIsOffered`) and where it
        // is passed through (`theHostOffersEverySettingsTab`). What is owed *here* is that the
        // Settings builder still emits at all.
        case .settings: return "settings"
        }
    }

    static let people = [Person(id: "p.aditi", displayName: "Aditi", relationship: "daughter",
                                fullNames: ["Aditi Girish"])]

    /// The path a route resolves under the provider root, or nil for a route that names none.
    ///
    /// **Exhaustive on purpose, like `kind` above.** "Which routes name a folder" is the question a
    /// root that did not answer has to be applied to, and the first attempt at that answered it
    /// from memory: `folderRows` and `emptyQueryRows` were marked and `verbRows` — which turns the
    /// same `index.folders` into an Organize *scope* — was not, so "organize legal" on a sleeping
    /// drive still wrote a scope for a folder that is not there and moved the workspace to show it.
    /// A new case with a path in it fails to compile here rather than being quietly unguarded.
    static func pathUnderRoot(of route: PaletteRoute) -> String? {
        switch route {
        case .folder(let path): return path
        case .organize(_, let scope): return scope
        case .browse, .compare, .editor, .person, .provider, .action, .settings:
            return nil
        }
    }

    /// **Both same-leaf folders are RECENTS**, deliberately. With one pinned and one recent the two
    /// rows differ by the word "Pinned" against "Recent" — a label, not the path — and the render
    /// check below would pass even if the path truncated away entirely, which is the collapse it
    /// exists to catch. Same group, same leaf: only `Clients/` against `Archive/` tells them apart.
    /// **The paths share a long head and a leaf, and differ only in the middle** — which is
    /// precisely what a middle-truncated detail elides first. Short paths make this test vacuous:
    /// measured 2026-08-19, `Clients/Legal` against `Archive/Legal` renders identically at 620 and
    /// at 320 because neither width truncates anything, so the fixture could not have detected a
    /// collapse at either.
    static func index(recents: [String] = ["Clients/Acme Holdings International/2024 Filings/Legal",
                                           "Clients/Acme Holdings International/2019 Filings/Legal"],
                      pinned: [String] = [],
                      unavailable: String? = nil) -> PaletteIndex {
        PaletteIndex(
            providers: [PaletteProvider(id: "icloud", name: "iCloud", isMounted: true,
                                        isCurrent: true, root: root),
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
                                     // **A typed path is the fourth builder**, and the walk could
                                     // not see it until 2026-08-20: `pathRow` only fires when a
                                     // probe is supplied, and the walk called `rows` without one —
                                     // so the guard written so "a fourth builder cannot be missed
                                     // the same way" was blind to the fourth builder. It is passed
                                     // one now (see `probe`), which is what makes that promise true.
                                     "\(root)/Finance"]

    /// The disk, for the one builder that asks it. Answers `.directory` for anything under the
    /// fixture's root and `.missing` elsewhere, which is enough for the walk: what is under test is
    /// whether a route that names a path is *marked*, not whether the folder is there.
    static let probe: PalettePathProbe = { path in
        path.hasPrefix(root) ? .directory : .missing
    }

    /// **Every destination the palette can reach still has a door.**
    ///
    /// The queries are the doors: the empty landing, plus one query per destination that the
    /// landing does not carry. If a builder stopped emitting a group, its kind is missing here and
    /// the failure names it.
    @Test func everyRouteKindIsStillReachableFromSomeQuery() {
        let index = Self.index()
        let queries = ["", "browse", "compare", "storage", "organize", "aditi", "icloud",
                       "legal", "rescan", "new folder", "choose", "find", "settings",
                       "shortcuts", "activity"]
        var reached = Set<String>()
        for query in queries {
            for row in PaletteRouter.rows(query: query, index: index) where row.isAvailable {
                reached.insert(Self.kind(row.route))
            }
        }

        // "storage" is gone as a route KIND — `PaletteRoute.storage` was deleted when Storage
        // became a lens, and the place now arrives as `organize` carrying `lens: .storage`. The
        // door is still there; it is one of Organize's. `CommandPaletteTests` is where the query
        // "storage" is followed to that route, including with a folder.
        var expected: Set<String> = ["browse", "compare", "organize", "person",
                                     "provider", "folder", "settings"]
        for action in PaletteAction.allCases { expected.insert("action.\(action)") }

        let missing = expected.subtracting(reached).sorted()
        #expect(missing.isEmpty,
                "these destinations have no door left in the palette, and the 620pt card that used to show them is deleted: \(missing.joined(separator: ", "))")
    }

    /// **A root that did not answer must take EVERY route that names a path under it, not the two
    /// builders somebody remembered.**
    ///
    /// This is the walk the first fix should have been: three builders mint a path under
    /// `providerRoot` — the landing's recents and pins, a folder match, and a verb row's Organize
    /// scope — and marking two of them left "organize legal" writing a scope for a folder on a
    /// sleeping drive, moving the workspace to Organize to show it, and revealing nothing. The
    /// route is walked by `pathUnderRoot`, so a fourth builder cannot be missed the same way.
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

    /// The awake half, so the assertion above is not "unavailable is whatever we passed" — and so a
    /// fix that simply marked everything always would fail here.
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

    /// The landing alone — what ⌘K opens on — must carry the four groups the card led with.
    /// A destination reachable only by typing its name is a destination a stranger cannot find.
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

    /// **Two folders with the same leaf must not render as the same row — at either width.**
    ///
    /// The fixture's two folders are both titled "Legal"; only the detail line — the same
    /// "Recent · " prefix over two paths that share a long head and their leaf, and differ in the
    /// middle — tells them apart. At the 620pt ceiling there is room for it. At the **320pt floor**
    /// there may not be, and if the detail is dropped or middle-truncated down to that common head
    /// the two rows become one visible destination with the other silently unreachable — the exact
    /// removal the card's deletion put at risk. (`PaletteRouteDoorTests.index` carries why both are
    /// recents and why the paths are long; two short ones could not fail.)
    ///
    /// Rendered and compared pixel-for-pixel rather than measured: this codebase's own record is
    /// that geometry and ink counts cannot see "omitted" versus "truncated".
    @Test(arguments: [620.0, 320.0]) func sameLeafFoldersStayDistinguishable(width: Double) {
        let rows = PaletteRouter.rows(query: "", index: PaletteRouteDoorTests.index())
            .filter { $0.group == .folders }
        let leaves = rows.map(\.title)
        #expect(leaves.count == 2 && Set(leaves).count == 1,
                "the fixture no longer produces two same-leaf folders — it cannot detect the collapse it is here for")

        // One row each, rendered alone at the same size, so any difference IS the row's content.
        let first = CommandPaletteRenderTests.renderList(rows: [rows[0]], selection: nil,
                                                        scheme: .light, width: width, height: 60)
        let second = CommandPaletteRenderTests.renderList(rows: [rows[1]], selection: nil,
                                                         scheme: .light, width: width, height: 60)
        let differing = CommandPaletteRenderTests.differingPixels(first, second)
        // Measured 2026-08-19: 1256 differing at 620pt, 1783 at 320pt (the count RISES at the
        // floor, because truncation shifts glyphs as well as removing them). Dropping the detail
        // line entirely takes both to **0** — the two rows render identically — which is what the
        // threshold is set against, and what a collapse actually looks like.
        #expect(differing > 200,
                "at \(Int(width))pt two different folders draw the same row (\(differing) pixels differ, against ~1256 at 620pt and ~1783 at 320pt when they are distinct) — one of them has no door a person can pick")
    }
}
