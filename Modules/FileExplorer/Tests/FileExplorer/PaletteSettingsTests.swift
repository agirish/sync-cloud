import Foundation
import Testing
@testable import FileExplorer

/// Pins the Settings rows: ten destinations, each carrying the vocabulary of every control on its
/// tab, so `appearance` lands on Appearance and `glass` lands there too.
///
/// The fixture is a hand-written stand-in for what `Settings` derives and `MacApp` passes through —
/// deliberately, because the point of the router being pure is that its behaviour is a function of
/// data a test can write down in full. That the *real* data is shaped like this is held on the
/// other side of the wall (`SettingsTabDigestTests`) and at the seam (`SyncCloudTests`).
@Suite struct PaletteSettingsTests {

    /// Four tabs in rail order, with the vocabulary that matters to these tests. `appearance` sits
    /// on Readability on purpose — it is a real keyword on the real tab, and it is the collision
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

    // MARK: The word that started this

    @Test func typingATabNameReachesThatTab() throws {
        let rows = settingsRows("appearance")
        let first = try #require(rows.first)
        #expect(first.title == "Settings ▸ Appearance")
        #expect(first.route == .settings(tab: "appearance"))
        #expect(first.detail == "Theme, accent, glass, and surfaces")
        #expect(first.symbol == "paintbrush")
    }

    /// Readability carries `appearance` as a keyword deliberately, so both tabs answer — and the
    /// one whose *name* it is has to lead.
    @Test func aTabNamedByTheQueryOutranksOneThatMerelyKnowsTheWord() throws {
        let rows = settingsRows("appearance")
        let ids = rows.map(\.id)
        let appearance = try #require(ids.firstIndex(of: "settings.appearance"))
        let readability = try #require(ids.firstIndex(of: "settings.readability"))
        #expect(appearance < readability)
    }

    /// **The penalty, pinned where position works against it.**
    ///
    /// The test above does not pin it, and believing it did was the mistake: in rail order
    /// Appearance precedes Readability, so its smaller position decrement orders the two correctly
    /// *even with the penalty deleted* — measured, by deleting it. A guard whose subject is carried
    /// by something else is a guard that reads green through the regression it names.
    ///
    /// Here the tab that merely knows the word is listed **first**, so position pushes the wrong
    /// answer to the top and only the penalty can pull it back.
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

    /// A row matched only through its vocabulary draws **no** emphasis, because the query is not in
    /// the text on screen. That is the honest outcome — and it is why the row carries a detail line
    /// saying what is on the tab. Pinned so nobody "fixes" the missing bold by tokenizing the
    /// vocabulary into the title.
    @Test func aVocabularyMatchDrawsNoEmphasis() throws {
        let first = try #require(settingsRows("glass").first)
        #expect(PaletteRouter.matchRange(first.title, "glass") == nil)
        #expect(PaletteRouter.matchRange(first.detail ?? "", "glass") != nil)
    }

    @Test func anUnknownWordReachesNothing() {
        #expect(settingsRows("zzzznotasetting").isEmpty)
    }

    // MARK: The parent word

    /// Typing `settings` lists every tab — the same shape `organize` already has, where the
    /// overview and all six lenses answer the parent word.
    @Test func typingTheParentListsEveryTab() {
        let rows = settingsRows("settings")
        #expect(rows.count == Self.tabs.count)
    }

    /// …and it lists them in the **rail's** order, not alphabetically. Without the per-position
    /// decrement every row scores identically and `sorted` falls back to the title, which puts
    /// Appearance ahead of General and reorders a list the user knows by sight.
    @Test func theParentWordKeepsTheRailsOrder() {
        #expect(settingsRows("settings").map(\.id)
                == Self.tabs.map { "settings.\($0.id)" })
    }

    /// The position decrement must never lift a row across a match tier — the tiers are 100 apart
    /// and the vocabulary penalty is 20, so ten positions are safe and eleven would still be. This
    /// is the property, not the arithmetic: the *last* tab matched by name beats the *first* tab
    /// matched only by vocabulary.
    @Test func positionNeverOutranksHowWellSomethingMatched() throws {
        let many = (0..<10).map { i in
            PaletteSettingsTab(id: "t\(i)", name: i == 9 ? "Advanced" : "Tab \(i)",
                               detail: "d\(i)", symbol: "gearshape",
                               vocabulary: i == 0 ? ["advanced"] : [])
        }
        let rows = PaletteRouter.rows(query: "advanced", index: PaletteIndex(settingsTabs: many))
            .filter { $0.group == .settings }
        #expect(rows.map(\.id) == ["settings.t9", "settings.t0"])
    }

    /// The clamp, at a list long enough to need it.
    ///
    /// Ten tabs never reach `maxPositionDecrement`, so nothing above exercises it — and the version
    /// of this that shipped first stated the bound in a comment and clamped nothing. With 25 tabs
    /// the last one's raw offset (24) exceeds the penalty (20), so an unclamped decrement would let
    /// a tab that merely *knows* the word outrank the tab the word *names*, purely because of where
    /// it sits in the rail.
    @Test func aLongTabListCannotReorderItselfByPosition() {
        let many = (0..<25).map { i in
            PaletteSettingsTab(id: "t\(i)", name: i == 24 ? "Advanced" : "Tab \(i)",
                               detail: "d\(i)", symbol: "gearshape",
                               vocabulary: i == 0 ? ["advanced"] : [])
        }
        let rows = PaletteRouter.rows(query: "advanced", index: PaletteIndex(settingsTabs: many))
            .filter { $0.group == .settings }
        #expect(rows.map(\.id) == ["settings.t24", "settings.t0"])
    }

    /// The bound itself, as arithmetic rather than as behaviour: the largest decrement must stay
    /// strictly under the smallest gap between two distinct outcomes, and that gap *is* the
    /// penalty (a penalised exact, 380, against a full-score exact, 400).
    @Test func theDecrementCeilingStaysUnderThePenalty() {
        #expect(PaletteRouter.maxPositionDecrement < PaletteRouter.vocabularyPenalty)
        #expect(PaletteRouter.maxPositionDecrement > 0)
    }

    // MARK: Boundaries

    /// An index with no tabs offers no Settings rows — which is what every fixture written before
    /// this feature gets, so none of them has to reason about a preferences page it never mentioned.
    @Test func anIndexWithoutTabsOffersNothing() {
        #expect(PaletteRouter.rows(query: "appearance", index: PaletteIndex())
            .allSatisfy { $0.group != .settings })
    }

    /// The tabs stay off the empty-query landing: that list is recents and places, and ten more
    /// rows would push what you were just doing off the opening. `Settings…` is already there as
    /// the action.
    @Test func theEmptyQueryLandingHasNoSettingsRows() {
        #expect(PaletteRouter.rows(query: "", index: Self.index)
            .allSatisfy { $0.group != .settings })
        #expect(PaletteRouter.rows(query: "   ", index: Self.index)
            .allSatisfy { $0.group != .settings })
    }

    /// `Settings…` and `Settings ▸ General` are two rows, and they are not a duplicate landing:
    /// the action opens the tab you were last on, the row opens a named one. Both answer
    /// `settings`, and the ids stay distinct so `aDestinationIsNeverListedTwice` still holds.
    @Test func theSettingsActionSurvivesBesideTheTabs() throws {
        let rows = PaletteRouter.rows(query: "settings", index: Self.index)
        #expect(rows.contains { $0.route == .action(.settings) })
        #expect(rows.contains { $0.route == .settings(tab: "general") })
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    /// **A folder of his that happens to be named like a Settings tab still leads.**
    ///
    /// Not hypothetical: the tree this runs against has ~3,000 folders, and General, People,
    /// Sources and Advanced are all ordinary folder names. Both halves are measured, and they fail
    /// differently — a shallow folder wins on score (400 against 396), while a folder deep enough
    /// for its depth penalty to bring it level **ties** at 396 and is separated only by
    /// ``PaletteGroup/rank``, which puts Folders ahead of Settings. That tie is the one thing the
    /// group's position in `allCases` actually decides, so moving `settings` earlier in that enum
    /// would silently put a preferences page above the folder somebody was looking for.
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

    /// The group draws as one run under one header, like every other group — a Settings row
    /// stranded between two Places rows would put the same heading on screen twice.
    @Test func theGroupDrawsContiguously() {
        let rows = PaletteRouter.rows(query: "s", index: Self.index)
        let positions = rows.indices.filter { rows[$0].group == .settings }
        #expect(positions.isEmpty || positions == Array(positions.first!...positions.last!))
    }
}
