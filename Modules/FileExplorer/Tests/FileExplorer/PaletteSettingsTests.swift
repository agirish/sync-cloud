import Foundation
import Testing
@testable import FileExplorer

/// The Settings rows: one destination per tab, carrying the vocabulary of every control on it, so
/// `appearance` and `glass` both land on Appearance. The fixture is hand-written (the router is
/// pure); `SettingsTabDigestTests` holds that the real data has this shape.
@Suite struct PaletteSettingsTests {

    /// Four tabs in rail order. `appearance` on Readability is a real keyword, and the collision
    /// the vocabulary penalty exists for.
    private static let tabs: [PaletteSettingsTab] = [
        .init(id: "general", name: "General", detail: "Startup, sorting, and notifications",
              symbol: "gearshape", vocabulary: ["Sort panes by", "login", "startup", "dotfiles"]),
        .init(id: "appearance", name: "Appearance", detail: "Theme, accent, glass, and surfaces",
              symbol: "paintbrush",
              vocabulary: ["Glass effect", "Theme", "appearance", "blur", "dark mode", "frosted"]),
        .init(id: "readability", name: "Readability", detail: "Text size and row spacing",
              symbol: "textformat.size",
              vocabulary: ["Size & spacing", "Text size", "appearance", "zoom"]),
        .init(id: "intelligence", name: "Intelligence",
              detail: "On-device AI, Claude, and what it costs", symbol: "sparkles",
              vocabulary: ["Anthropic API key", "api key", "anthropic", "sk-ant", "claude"])
    ]

    private static var index: PaletteIndex { PaletteIndex(settingsTabs: tabs) }

    private func settingsRows(_ query: String) -> [PaletteRow] {
        PaletteRouter.rows(query: query, index: Self.index).filter { $0.group == .settings }
    }

    // MARK: Pages

    /// A row matched through a word carries the word's page (`tab/page`), and one matched by its
    /// name carries the tab alone, so ⌘K opens the page the word is on, never a page it isn't.
    @Test func aWordOpensItsPageAndTheNameOpensTheTab() throws {
        let paged = PaletteSettingsTab(id: "appearance", name: "Appearance", detail: "Theme, accent, glass, text size",
                                       symbol: "paintbrush",
                                       vocabulary: ["Glass effect", "Row spacing", "glass"],
                                       pages: ["glass effect": ["look"], "glass": ["look"], "row spacing": ["textAndSpacing"]])
        let index = PaletteIndex(settingsTabs: [paged])
        func route(_ query: String) -> PaletteRoute? {
            PaletteRouter.rows(query: query, index: index).first { $0.group == .settings }?.route
        }
        #expect(route("glass") == .settings(tab: "appearance/look"))
        #expect(route("row spacing") == .settings(tab: "appearance/textAndSpacing"))
        #expect(route("appearance") == .settings(tab: "appearance"))
    }

    // MARK: The word that started this

    /// Readability carries `appearance` as a keyword, so both tabs answer, and the one whose name
    /// it is has to lead.
    @Test func typingATabNameReachesThatTab() throws {
        let rows = settingsRows("appearance")
        #expect(rows.map(\.id).contains("settings.readability"),
                "Readability no longer answers “appearance”, so nothing here outranks it")
        let first = try #require(rows.first)
        #expect(first.title == "Settings ▸ Appearance")
        #expect(first.route == .settings(tab: "appearance"))
        #expect(first.detail == "Theme, accent, glass, and surfaces")
        #expect(first.symbol == "paintbrush")
    }

    /// The vocabulary penalty, pinned where position works against it: the tab that merely knows
    /// the word is listed first, so only the penalty puts the named tab on top.
    @Test func aVocabularyMatchCannotOutrankANameNoMatterWhereItSits() {
        let stacked = [
            PaletteSettingsTab(id: "readability", name: "Readability", detail: "Text size",
                               symbol: "textformat.size", vocabulary: ["appearance"]),
            PaletteSettingsTab(id: "appearance", name: "Appearance", detail: "Theme and glass",
                               symbol: "paintbrush", vocabulary: ["blur"])
        ]
        let rows = PaletteRouter.rows(query: "appearance", index: PaletteIndex(settingsTabs: stacked))
            .filter { $0.group == .settings }
        #expect(rows.map(\.id) == ["settings.appearance", "settings.readability"])
    }

    // MARK: Vocabulary

    @Test func aWordFromAControlOnTheTabReachesIt() throws {
        for (query, id) in [("glass", "settings.appearance"), ("api key", "settings.intelligence"),
                            ("sk-ant", "settings.intelligence"), ("zoom", "settings.readability"),
                            ("dotfiles", "settings.general")] {
            let first = try #require(settingsRows(query).first)
            #expect(first.id == id, "“\(query)” should lead with \(id)")
        }
    }

    /// A row matched only through its vocabulary draws no emphasis: the query isn't in the text on
    /// screen, and the detail line says what is on the tab.
    @Test func aVocabularyMatchDrawsNoEmphasis() throws {
        let first = try #require(settingsRows("glass").first)
        #expect(PaletteRouter.matchRange(first.title, "glass") == nil)
        #expect(PaletteRouter.matchRange(first.detail ?? "", "glass") != nil)
    }

    @Test func anUnknownWordReachesNothing() {
        #expect(settingsRows("zzzznotasetting").isEmpty)
    }

    // MARK: The parent word

    /// Typing `settings` lists every tab in the rail's order, as `organize` does; without the
    /// per-position decrement `sorted` falls back to the title.
    @Test func theParentWordKeepsTheRailsOrder() {
        #expect(settingsRows("settings").map(\.id)
                == Self.tabs.map { "settings.\($0.id)" })
    }

    /// The position decrement never lifts a row across a match tier: the last tab matched by name
    /// beats the first matched by vocabulary. At 25 tabs the raw offset (24) passes the penalty
    /// (20), so it is the `maxPositionDecrement` clamp that holds.
    @Test(arguments: [10, 25])
    func positionNeverOutranksHowWellSomethingMatched(count: Int) {
        let many = (0..<count).map { i in
            PaletteSettingsTab(id: "t\(i)", name: i == count - 1 ? "Advanced" : "Tab \(i)",
                               detail: "d\(i)", symbol: "gearshape",
                               vocabulary: i == 0 ? ["advanced"] : [])
        }
        let rows = PaletteRouter.rows(query: "advanced", index: PaletteIndex(settingsTabs: many))
            .filter { $0.group == .settings }
        #expect(rows.map(\.id) == ["settings.t\(count - 1)", "settings.t0"])
    }

    /// The bound as arithmetic: the largest decrement must stay strictly under the smallest gap
    /// between two distinct outcomes, which is the penalty (a penalised exact against a full one).
    @Test func theDecrementCeilingStaysUnderThePenalty() {
        #expect(PaletteRouter.maxPositionDecrement < PaletteRouter.vocabularyPenalty)
        #expect(PaletteRouter.maxPositionDecrement > 0)
    }

    // MARK: Boundaries

    /// An index with no tabs offers no Settings rows, so fixtures that don't mention Settings never
    /// have to reason about it.
    @Test func anIndexWithoutTabsOffersNothing() {
        #expect(PaletteRouter.rows(query: "appearance", index: PaletteIndex())
            .allSatisfy { $0.group != .settings })
    }

    /// The tabs stay off the empty-query landing (recents and places); `Settings…` is there as the
    /// action.
    @Test func theEmptyQueryLandingHasNoSettingsRows() {
        #expect(PaletteRouter.rows(query: "", index: Self.index)
            .allSatisfy { $0.group != .settings })
        #expect(PaletteRouter.rows(query: "   ", index: Self.index)
            .allSatisfy { $0.group != .settings })
    }

    /// `Settings…` (the tab you were last on) and `Settings ▸ General` are two rows with distinct
    /// ids, so `aDestinationIsNeverListedTwice` holds.
    @Test func theSettingsActionSurvivesBesideTheTabs() throws {
        let rows = PaletteRouter.rows(query: "settings", index: Self.index)
        #expect(rows.contains { $0.route == .action(.settings) })
        #expect(rows.contains { $0.route == .settings(tab: "general") })
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    /// A folder named like a Settings tab still leads. A deep one ties on score, and only
    /// ``PaletteGroup/rank`` (Folders ahead of Settings) separates them, so moving `settings`
    /// earlier in `allCases` fails here.
    @Test func aFolderNamedLikeATabKeepsItsLead() throws {
        for folder in ["People", "Archive/Old/Family/Records/People"] {
            let rows = PaletteRouter.rows(
                query: "people",
                index: PaletteIndex(providerRoot: "/r", folders: [folder], settingsTabs: Self.tabs
                    + [.init(id: "people", name: "People", detail: "Who filing attributes to",
                             symbol: "person.2", vocabulary: ["household"])]))
            let groups = rows.map(\.group)
            let folderAt = try #require(groups.firstIndex(of: .folders),
                                        "“people” no longer offers the folder \(folder) at all")
            let settingsAt = try #require(groups.firstIndex(of: .settings))
            #expect(folderAt < settingsAt,
                    "“people” puts Settings ▸ People above the folder \(folder)")
        }
    }

    /// The group draws as one run under one header: a Settings row stranded between two Places rows
    /// would put the same heading on screen twice.
    @Test func theGroupDrawsContiguously() throws {
        let rows = PaletteRouter.rows(query: "s", index: Self.index)
        let positions = rows.indices.filter { rows[$0].group == .settings }
        try #require(positions.count >= 2, "“s” offers \(positions.count) Settings rows, too few to test the run")
        #expect(positions == Array(positions.first!...positions.last!))
    }
}
