import Testing
import Foundation
import AppKit
import FileExplorer
import Settings
@testable import SyncCloud

/// The real tabs, through the real router.
///
/// **This is the only place the two halves meet.** `SettingsTabDigestTests` proves the derivation
/// against a catalog the palette cannot see; `PaletteSettingsTests` proves the ranking against a
/// four-tab fixture written by hand. Both pass with the real 372-word vocabulary routing to the
/// wrong page, or to no page — a fixture agrees with whatever it was written from.
///
/// So the queries below are run against `SettingsTab.digests` itself: the words the feature was
/// argued from, checked against the tab they were promised to reach, with nothing standing in.
@Suite struct PaletteSettingsEndToEndTests {

    /// The index as the host builds it, minus the parts that need a live engine — the same `map`
    /// `paletteIndex` performs. Nothing else on the index affects a Settings row.
    private static let index = PaletteIndex(
        settingsTabs: SettingsView.SettingsTab.digests.map {
            PaletteSettingsTab(id: $0.id, name: $0.name, detail: $0.detail,
                               symbol: $0.symbol, vocabulary: $0.vocabulary)
        })

    private func leadingSettingsRow(_ query: String) -> PaletteRow? {
        PaletteRouter.rows(query: query, index: Self.index).first { $0.group == .settings }
    }

    /// **The ask, end to end**: type `appearance`, get Appearance, first.
    @Test func typingAppearanceLandsOnAppearance() throws {
        let row = try #require(leadingSettingsRow("appearance"))
        #expect(row.route == .settings(tab: SettingsView.SettingsTab.appearance.rawValue))
        #expect(row.title == "Settings ▸ Appearance")
    }

    /// Every tab is reachable by its own name — the ten doors, opened one at a time. A tab whose
    /// name collides with something the vocabulary answers better would fail here, which no fixture
    /// can see.
    @Test func everyTabIsReachedByItsOwnName() throws {
        for tab in SettingsView.SettingsTab.allCases {
            let row = try #require(leadingSettingsRow(tab.displayName),
                                   "nothing answers “\(tab.displayName)”")
            #expect(row.route == .settings(tab: tab.rawValue),
                    "“\(tab.displayName)” leads with \(row.title)")
        }
    }

    /// The words that justified folding a whole tab's vocabulary into one row, each against the
    /// page it was promised to reach. **Not a restatement of the catalog test**: that one asks
    /// whether the word is in the index, this asks whether it wins — a word present on the right
    /// tab and also on a better-scoring wrong one fails only here.
    @Test func thePromisedWordsLandOnThePromisedTab() throws {
        let promised: [(String, SettingsView.SettingsTab)] = [
            ("glass", .appearance), ("blur", .appearance), ("dark mode", .appearance),
            ("api key", .intelligence), ("anthropic", .intelligence), ("sk-ant", .intelligence),
            ("log level", .advanced), ("factory reset", .advanced),
            ("node_modules", .sync), ("keep both", .sync),
            ("icloud", .providers), ("dropbox", .providers),
            ("household", .people), ("loose files", .filing),
            ("row spacing", .readability), ("dotfiles", .general),
            ("fingerprint", .duplicates)
        ]
        for (query, tab) in promised {
            let row = try #require(leadingSettingsRow(query), "nothing answers “\(query)”")
            #expect(row.route == .settings(tab: tab.rawValue),
                    "“\(query)” leads with \(row.title), not \(tab.displayName)")
        }
    }

    /// Readability keeps `appearance` deliberately, so both tabs really do answer it — and
    /// Appearance really does lead. The live version of the collision the penalty exists for.
    @Test func bothTabsAnswerAppearanceAndTheRightOneLeads() throws {
        let rows = PaletteRouter.rows(query: "appearance", index: Self.index)
            .filter { $0.group == .settings }
        let ids = rows.map(\.id)
        #expect(ids.contains("settings.readability"),
                "Readability no longer answers “appearance” — the penalty has nothing left to order")
        let appearance = try #require(ids.firstIndex(of: "settings.appearance"))
        let readability = try #require(ids.firstIndex(of: "settings.readability"))
        #expect(appearance < readability)
    }

    /// Typing the parent lists all ten, in the rail's order.
    @Test func typingSettingsListsEveryTabInRailOrder() {
        let rows = PaletteRouter.rows(query: "settings", index: Self.index)
            .filter { $0.group == .settings }
        #expect(rows.map(\.route)
                == SettingsView.SettingsTab.railGroups.flatMap { $0 }
                    .map { PaletteRoute.settings(tab: $0.rawValue) })
    }

    /// Every route the real index can mint names a tab this app can turn back into a case — the
    /// string crossing the package wall, walked rather than assumed.
    @Test func everyRouteRawValueResolvesBackToATab() {
        for tab in SettingsView.SettingsTab.digests {
            #expect(SettingsView.SettingsTab(rawValue: tab.id) != nil,
                    "the palette would offer “\(tab.name)” and the host would refuse it")
        }
    }

    // MARK: What actually fits on the row

    /// **The width budget, measured against the row's own geometry.**
    ///
    /// The panel is as wide as the Go to field: 620pt at the ceiling, **320pt at the floor**. Both
    /// lines are `lineLimit(1)`, so an over-long one is tail-truncated rather than wrapped — which
    /// is graceful, and is exactly why nothing would report it. This is the only guard on the upper
    /// bound; `everyDetailSaysSomethingTheNameDoesNot` over in `SettingsTests` holds the lower one,
    /// and a bound in one direction is silent about the other.
    ///
    /// It caught a real one. Rewriting Sources' line to stop it repeating the tab's own name
    /// produced "Cloud accounts and the local folders you added" — 249.8pt, the longest of the ten
    /// and the only one that did not fit **at the default text size**. A repetition was traded for
    /// a sentence that stopped mid-clause, and only measuring said so.
    ///
    /// Measured on the selected row, which is the narrower case (it draws a trailing `↩`), and at
    /// the default text size. At the largest text size several still truncate: that is accepted —
    /// this list scrolls and truncates prose by design, unlike the Settings rail, whose fixed width
    /// is what gives the version line a hard budget.
    @MainActor
    @Test func everyDetailFitsTheFloorWidth() {
        let floor = GoToFieldMetrics.floorWidth
        let returnGlyph = width("↩", size: PaletteRowMetrics.detailSize, weight: .semibold)
        let opening = PaletteRowMetrics.textOpening(listWidth: floor, trailing: returnGlyph)
        for tab in SettingsView.SettingsTab.digests {
            let detail = width(tab.detail, size: PaletteRowMetrics.detailSize)
            #expect(detail <= opening,
                    "“\(tab.name)” draws \(rounded(detail))pt of detail into a \(rounded(opening))pt opening at the \(rounded(floor))pt floor — it will stop mid-sentence")
            // The title is what names the destination, so it truncating is a different and worse
            // failure: two Settings rows cut to the same visible text are one door, not two.
            let title = width("Settings ▸ \(tab.name)",
                              size: PaletteRowMetrics.titleSize, weight: .medium)
            #expect(title <= opening,
                    "“Settings ▸ \(tab.name)” draws \(rounded(title))pt of title into a \(rounded(opening))pt opening — the destination's own name is cut")
        }
    }

    /// One decimal place, so a failure names a width somebody can compare against the others
    /// rather than fifteen digits of Double.
    private func rounded(_ v: CGFloat) -> String { String(format: "%.1f", v) }

    @MainActor
    private func width(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
    }
}
