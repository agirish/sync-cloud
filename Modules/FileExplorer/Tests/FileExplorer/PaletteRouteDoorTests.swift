import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// The route-table walk: every destination the palette can reach keeps a door. Is every
/// destination still listed (a model walk), and is every row still usable at the 320pt floor of
/// `GoToResultsPanel`, where only the `detail` tells two "Legal" rows apart (a pixel question,
/// `PaletteRouteDoorRenderTests`)?
@MainActor
@Suite(.serialized) struct PaletteRouteDoorTests {

    static let root = "/Users/x/Documents"
    /// A second mounted source the pane is not aimed at: the only configuration that can produce a
    /// `.folderInSource` route.
    static let dropbox = "/Users/x/Dropbox"

    /// Every route kind as a name, since `PaletteRoute` can't be `CaseIterable`. Exhaustive on
    /// purpose: a new case fails to compile here, so "every destination" means the whole set.
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
        // One kind, not one per tab: the tabs are walked in `everyTabIsOffered`.
        case .settings: return "settings"
        }
    }

    static let people = [Person(id: "p.daughter", displayName: "Daughter", relationship: "daughter",
                                fullNames: ["Daughter Elder"])]

    /// The path a route names under the provider root, or nil. Exhaustive like `kind`: a root
    /// that didn't answer must reach every route that names a folder, `verbRows`' scope included.
    static func pathUnderRoot(of route: PaletteRoute) -> String? {
        switch route {
        case .folder(let path): return path
        case .organize(_, let scope): return scope
        // `.folderInSource` is under another source's root, which has its own `isMounted`; the
        // aimed root's `foldersUnavailable` would refuse a folder on a disk that is awake.
        case .browse, .compare, .editor, .person, .provider, .folderInSource, .action, .settings:
            return nil
        }
    }

    /// Both same-leaf folders are recents, so only the path tells them apart (a pin would differ by
    /// "Favorite"). The paths are long and differ only in the middle, what middle truncation elides
    /// first; short paths never truncate, and the render check would be vacuous.
    static func index(recents: [String] = ["Clients/Acme Holdings International/2024 Filings/Legal",
                                           "Clients/Acme Holdings International/2019 Filings/Legal"],
                      pinned: [String] = [],
                      unavailable: String? = nil) -> PaletteIndex {
        PaletteIndex(
            providers: [PaletteProvider(id: "icloud", name: "iCloud", isMounted: true,
                                        isCurrent: true, root: root),
                        // Mounted and not the pane's: the only shape that produces `.folderInSource`.
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
            // Two tabs, so the walk's "settings" query reaches the Settings builder.
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
                                     // A typed path, the fourth builder; needs `probe`.
                                     "\(root)/Finance"]

    /// The disk for `pathRow`: `.directory` under the fixture's root, `.missing` elsewhere.
    static let probe: PalettePathProbe = { path in
        path.hasPrefix(root) ? .directory : .missing
    }

    /// Every destination still has a door: the landing plus one query per destination it lacks. A
    /// builder that stops emitting shows up by kind in the failure.
    @Test func everyRouteKindIsStillReachableFromSomeQuery() {
        let index = Self.index()
        let queries = ["", "browse", "compare", "storage", "organize", "daughter", "icloud",
                       "legal", "rescan", "new folder", "choose", "find", "settings",
                       "shortcuts", "activity",
                       // Typed paths: `folder` in the pane's source, `folderInSource` in another.
                       "\(Self.root)/Finance", "\(Self.dropbox)/Legal"]
        var reached = Set<String>()
        for query in queries {
            for row in PaletteRouter.rows(query: query, index: index, probe: Self.probe)
            where row.isAvailable {
                reached.insert(Self.kind(row.route))
            }
        }

        // Storage is a lens, so "storage" arrives as `organize` (see `CommandPaletteTests`).
        var expected: Set<String> = ["browse", "compare", "organize", "person",
                                     "provider", "folder", "folderInSource", "settings"]
        for action in PaletteAction.allCases { expected.insert("action.\(action)") }

        let missing = expected.subtracting(reached).sorted()
        #expect(missing.isEmpty,
                "these destinations have no door left in the palette, and the 620pt card that used to show them is deleted: \(missing.joined(separator: ", "))")
    }

    /// A root that didn't answer refuses every route naming a path under it (recents and pins, a
    /// folder match, a verb's Organize scope), walked through `pathUnderRoot`; else "organize legal"
    /// would scope a sleeping drive. The awake case fails a fix that marks everything.
    @Test(arguments: ["Not available", nil] as [String?])
    func everyPathBearingRouteIsRefusedWhenTheRootIsAsleep(unavailable: String?) {
        let index = Self.index(unavailable: unavailable)
        var seen = 0
        for query in Self.pathBearingQueries {
            for row in PaletteRouter.rows(query: query, index: index, probe: Self.probe) {
                guard let path = Self.pathUnderRoot(of: row.route) else { continue }
                seen += 1
                if let unavailable {
                    #expect(row.unavailable == unavailable,
                            "“\(query)” offers \(path) as a live destination under a root that did not answer")
                } else {
                    #expect(row.isAvailable, "“\(query)” refuses a folder under a root that is right there")
                }
            }
        }
        #expect(seen >= 7,
                "only \(seen) path-bearing rows were reached — the queries no longer cover the builders this is about")
    }

    /// The landing ⌘K opens on carries all four groups: a destination reachable only by typing
    /// its name is one a stranger can't find.
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

    /// Two "Legal" folders must not render as the same row at either width: only the detail line
    /// tells them apart, and at the 320pt floor it could drop or truncate to the common head.
    /// Pixel for pixel, since geometry and ink counts can't tell "omitted" from "truncated".
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
        // Distinct rows differ by over a thousand pixels; dropping the detail line takes both to 0.
        #expect(differing > 200,
                "at \(Int(width))pt two different folders draw the same row (\(differing) pixels differ, against ~1256 at 620pt and ~1783 at 320pt when they are distinct) — one of them has no door a person can pick")
    }
}
