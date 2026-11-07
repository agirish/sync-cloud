import Testing
import Foundation
import AppKit
import FileExplorer
import Settings
@testable import SyncCloud

/// The real tabs, through the real router: the only place the two halves meet.
/// `SettingsTabDigestTests` checks the derivation and `PaletteSettingsTests` the ranking against a
/// hand-written fixture; both would pass with the real vocabulary routing to the wrong page. So
/// these queries run against `SettingsTab.digests` itself, each checked against the tab it is
/// meant to reach.
@Suite struct PaletteSettingsEndToEndTests {

    /// The index as the host builds it, minus the parts that need a live engine: the same `map`
    /// `paletteIndex` performs. Nothing else on the index affects a Settings row.
    private static let index = PaletteIndex(
        settingsTabs: SettingsView.SettingsTab.digests.map {
            PaletteSettingsTab(id: $0.id, name: $0.name, detail: $0.detail,
                               symbol: $0.symbol, vocabulary: $0.vocabulary, pages: $0.pages,
                               pageOrder: $0.pageOrder)
        })

    private func leadingSettingsRow(_ query: String) -> PaletteRow? {
        PaletteRouter.rows(query: query, index: Self.index).first { $0.group == .settings }
    }

    /// End to end: type `appearance`, get Appearance, first.
    @Test func typingAppearanceLandsOnAppearance() throws {
        let row = try #require(leadingSettingsRow("appearance"))
        #expect(row.route == .settings(tab: SettingsView.SettingsTab.appearance.rawValue))
        #expect(row.title == "Settings ▸ Appearance")
    }

    /// Every tab is reachable by its own name. A tab whose name collides with something the
    /// vocabulary answers better fails here, which no fixture can see.
    @Test func everyTabIsReachedByItsOwnName() throws {
        for tab in SettingsView.SettingsTab.allCases {
            let row = try #require(leadingSettingsRow(tab.displayName),
                                   "nothing answers “\(tab.displayName)”")
            #expect(row.route == .settings(tab: tab.rawValue),
                    "“\(tab.displayName)” leads with \(row.title)")
        }
    }

    /// Key words, each against the page it should reach. Unlike the catalog test, which asks
    /// whether the word is in the index, this asks whether it wins: a word on the right tab and on
    /// a better-scoring wrong one fails only here.
    @Test func thePromisedWordsLandOnThePromisedTab() throws {
        let promised: [(String, SettingsView.SettingsTab)] = [
            ("glass", .appearance), ("blur", .appearance), ("dark mode", .appearance),
            ("api key", .intelligence), ("anthropic", .intelligence), ("sk-ant", .intelligence),
            ("log level", .advanced), ("factory reset", .advanced),
            ("node_modules", .sync), ("keep both", .general),
            ("icloud", .providers), ("dropbox", .providers),
            ("household", .filing), ("loose files", .filing),
            ("row spacing", .appearance), ("dotfiles", .browse),
            ("fingerprint", .filing), ("word wrap", .edit)
        ]
        for (query, tab) in promised {
            let row = try #require(leadingSettingsRow(query), "nothing answers “\(query)”")
            #expect(row.id == "settings.\(tab.rawValue)",
                    "“\(query)” leads with \(row.title), not \(tab.displayName)")
        }
    }

    /// A word found on a page opens that page, not whichever page the tab last showed (TE332):
    /// the route carries `tab/page`, and the host opens `SettingsPlace(page)` for it.
    @Test func aWordOpensThePageItIsOn() throws {
        let promised: [(String, String)] = [
            ("glass", "appearance/look"), ("row spacing", "appearance/textAndSpacing"),
            ("api key", "intelligence/keyAndSpending"), ("hide folder", "intelligence/privacy"),
            ("node_modules", "sync/ignored"), ("household", "filing/people"),
            ("word wrap", "edit/text"), ("sidebar", "browse/window"),
            // Ties between pages go to the page the query is most about: three Ignored entries
            // start "ign", one Differences switch does; "folder" is on both Sources lists.
            ("ign", "sync/ignored"), ("folder", "providers/localFolders"),
        ]
        for (query, route) in promised {
            let row = try #require(leadingSettingsRow(query), "nothing answers “\(query)”")
            #expect(row.route == .settings(tab: route), "“\(query)” routes to \(row.route), not \(route)")
        }
        // A tab's own name opens the tab, on the page it last showed: no word chose one.
        #expect(try #require(leadingSettingsRow("Organize")).route == .settings(tab: "filing"))
        // And every route the index can mint resolves to the page it names.
        for query in promised.map(\.0) {
            guard case .settings(let raw) = try #require(leadingSettingsRow(query)).route else { continue }
            let place = try #require(SettingsPlace(paletteRoute: raw))
            #expect(place.subTab?.rawValue == raw.split(separator: "/").last.map(String.init))
        }
    }

    /// Sources carries `browse` as a keyword (Synchronized path's Browse… button), so both Sources
    /// and the Browse tab answer it and Browse must lead: the live case of the collision the
    /// penalty exists for.
    @Test func bothTabsAnswerBrowseAndTheRightOneLeads() throws {
        let rows = PaletteRouter.rows(query: "browse", index: Self.index)
            .filter { $0.group == .settings }
        let ids = rows.map(\.id)
        #expect(ids.contains("settings.providers"),
                "Sources no longer answers “browse” — the penalty has nothing left to order")
        let browse = try #require(ids.firstIndex(of: "settings.browse"))
        let sources = try #require(ids.firstIndex(of: "settings.providers"))
        #expect(browse < sources)
    }

    /// Typing the parent lists all nine, in the rail's order.
    @Test func typingSettingsListsEveryTabInRailOrder() {
        let rows = PaletteRouter.rows(query: "settings", index: Self.index)
            .filter { $0.group == .settings }
        #expect(rows.map(\.route)
                == SettingsView.SettingsTab.railGroups.flatMap { $0 }
                    .map { PaletteRoute.settings(tab: $0.rawValue) })
    }

    /// Every route the real index can mint names a tab this app can turn back into a case: the
    /// string crosses the package wall, so it is walked rather than assumed.
    @Test func everyRouteRawValueResolvesBackToATab() {
        for tab in SettingsView.SettingsTab.digests {
            #expect(SettingsView.SettingsTab(rawValue: tab.id) != nil,
                    "the palette would offer “\(tab.name)” and the host would refuse it")
        }
    }

    // MARK: What actually fits on the row

    /// The width budget, measured against the row's own geometry. The panel is as wide as the Go
    /// to field, 320pt at the floor. Both lines are `lineLimit(1)`, so an over-long one truncates
    /// quietly and nothing else would report it. This guards the upper bound;
    /// `everyDetailSaysSomethingTheNameDoesNot` in `SettingsTests` holds the lower.
    ///
    /// Measured on the selected row, the narrower case (it draws a trailing `↩`), at the default
    /// text size. At the largest size some truncate, which is accepted: this list scrolls and
    /// truncates prose by design.
    @MainActor
    @Test func everyDetailFitsTheFloorWidth() {
        let floor = GoToFieldMetrics.floorWidth
        let returnGlyph = width("↩", size: PaletteRowMetrics.detailSize, weight: .semibold)
        let opening = PaletteRowMetrics.textOpening(listWidth: floor, trailing: returnGlyph)
        for tab in SettingsView.SettingsTab.digests {
            let detail = width(tab.detail, size: PaletteRowMetrics.detailSize)
            #expect(detail <= opening,
                    "“\(tab.name)” draws \(rounded(detail))pt of detail into a \(rounded(opening))pt opening at the \(rounded(floor))pt floor — it will stop mid-sentence")
            // The title names the destination, so its truncating is worse: two rows cut to the
            // same visible text read as one destination.
            let title = width("Settings ▸ \(tab.name)",
                              size: PaletteRowMetrics.titleSize, weight: .medium)
            #expect(title <= opening,
                    "“Settings ▸ \(tab.name)” draws \(rounded(title))pt of title into a \(rounded(opening))pt opening — the destination's own name is cut")
        }
    }

    /// One decimal place, so a failure names a width one can compare, not fifteen digits.
    private func rounded(_ v: CGFloat) -> String { String(format: "%.1f", v) }

    @MainActor
    private func width(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
    }
}
