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
        case .storage: return "storage"
        case .organize: return "organize"
        case .person: return "person"
        case .provider: return "provider"
        case .folder: return "folder"
        case .action(let action): return "action.\(action)"
        }
    }

    static let people = [Person(id: "p.aditi", displayName: "Aditi", relationship: "daughter",
                                fullNames: ["Aditi Girish"])]

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
                      pinned: [String] = []) -> PaletteIndex {
        PaletteIndex(
            providers: [PaletteProvider(id: "icloud", name: "iCloud", isMounted: true, isCurrent: true),
                        PaletteProvider(id: "ssd", name: "Backup SSD", isMounted: false, isCurrent: false)],
            providerRoot: root,
            folders: recents + ["Finance"],
            recentFolders: recents, pinnedFolders: pinned,
            people: people, registry: PersonRegistry(people: people),
            isScanning: false, hasSurvey: true)
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

        var expected: Set<String> = ["browse", "compare", "storage", "organize", "person",
                                     "provider", "folder"]
        for action in PaletteAction.allCases { expected.insert("action.\(action)") }

        let missing = expected.subtracting(reached).sorted()
        #expect(missing.isEmpty,
                "these destinations have no door left in the palette, and the 620pt card that used to show them is deleted: \(missing.joined(separator: ", "))")
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
    /// `Clients/Legal` and `Archive/Legal` are both titled "Legal"; only the detail line
    /// ("Recent · Clients/Legal" against "Pinned · Archive/Legal") tells them apart. At the 620pt
    /// ceiling there is room for it. At the **320pt floor** there may not be, and if the detail is
    /// dropped or truncated to a common prefix the two rows become one visible destination with the
    /// other silently unreachable — the exact removal the card's deletion put at risk.
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
