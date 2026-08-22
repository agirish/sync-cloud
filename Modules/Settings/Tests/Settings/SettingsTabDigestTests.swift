import Foundation
import Testing
@testable import Settings

/// Pins ``SettingsTabDigest`` — what this module hands the ⌘K palette so a person can type
/// `appearance` (or `glass`, or `sk-ant`) and land on the tab that answers it.
///
/// **The derivation is tested here rather than where it is used, and that is the point of the type
/// existing.** The palette is in `FileExplorer`, a sibling package that cannot import this one, and
/// the wiring between them is in `MacApp`, which belongs to no SPM package at all. So everything
/// that could silently be wrong — a tab missing, a detail line empty, a vocabulary that stopped
/// following the index — is pulled down to where `swift test` compiles it.
@Suite struct SettingsTabDigestTests {

    private typealias Tab = SettingsView.SettingsTab

    // MARK: Coverage

    @Test func everyTabIsOffered() {
        let ids = Set(Tab.digests.map(\.id))
        #expect(ids == Set(Tab.allCases.map(\.rawValue)))
    }

    /// The list is built from `railGroups`, not `allCases`, so that the palette lists the tabs in
    /// the order somebody has actually looked at them in. A regrouping in the rail moves ⌘K with
    /// it; this is what would fail if the two lists were ever built independently.
    @Test func digestsAreInRailOrder() {
        #expect(Tab.digests.map(\.id) == Tab.railGroups.flatMap { $0 }.map(\.rawValue))
    }

    // MARK: The row's own text

    @Test func nameAndSymbolAreTheRailsOwn() {
        for tab in Tab.allCases {
            #expect(tab.digest.name == tab.displayName)
            #expect(tab.digest.symbol == tab.symbolName)
        }
    }

    /// A detail line that is empty, or that only repeats the tab's name, is a second line of text
    /// saying nothing — and it is the one thing on the row that is hand-written, so nothing else
    /// would catch it. The name check is substring-wise in both directions: "Sources" under
    /// "Settings ▸ Sources" tells a reader nothing they cannot already see.
    @Test func everyDetailSaysSomethingTheNameDoesNot() {
        for tab in Tab.allCases {
            let detail = tab.digest.detail
            #expect(!detail.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(!detail.localizedCaseInsensitiveContains(tab.displayName))
            #expect(detail.count > tab.displayName.count)
        }
    }

    // MARK: Vocabulary

    /// **The derivation itself.** A tab's vocabulary is exactly the titles and keywords of its own
    /// entries in `SettingsSearchIndex` — nothing hand-added, nothing dropped, and nothing borrowed
    /// from another tab. This is what makes the index the single catalog: a control added there
    /// reaches ⌘K with no second edit, and `everyControlLabelInTheTabSourcesIsIndexed` now guards
    /// both surfaces at once.
    @Test func everyTabsVocabularyIsItsIndexEntries() {
        for tab in Tab.allCases {
            let mine = SettingsSearchIndex.all.filter { $0.tab == tab }
            let expected = Set(mine.map(\.title) + mine.flatMap(\.keywords))
            #expect(Set(tab.digest.vocabulary) == expected)
            // Sorted and unique, so a test may compare the array without sorting it first —
            // several tabs carry a keyword on two controls ("cache" is on both of Intelligence's
            // suggestion rows).
            #expect(tab.digest.vocabulary == expected.sorted())
        }
    }

    /// The words the design was argued from, each checked against the tab it is claimed to reach.
    /// Not a restatement of the derivation above: this is the claim that the *catalog* actually
    /// contains the vocabulary the feature was justified by, which the derivation cannot see.
    @Test func thePromisedWordsReachTheirTab() {
        let promised: [(String, Tab)] = [
            ("glass", .appearance), ("dark mode", .appearance),
            ("api key", .intelligence), ("anthropic", .intelligence), ("sk-ant", .intelligence),
            ("log level", .advanced), ("factory reset", .advanced),
            ("node_modules", .sync), ("keep both", .sync),
            ("icloud", .providers), ("dropbox", .providers),
            ("household", .people), ("loose files", .filing),
            ("row spacing", .readability), ("startup", .general),
            ("fingerprint", .duplicates)
        ]
        for (word, tab) in promised {
            let reached = Tab.digests.filter { digest in
                digest.vocabulary.contains { $0.localizedCaseInsensitiveContains(word) }
            }
            #expect(reached.contains { $0.id == tab.rawValue },
                    "“\(word)” should reach \(tab.displayName)")
        }
    }

    /// `appearance` is a keyword on Readability *deliberately* — the tab moved out of Appearance
    /// and people still look for it there. That collision is the reason the palette penalises a
    /// vocabulary match, so it is pinned here as a live property rather than left as a remark in a
    /// comment: if it ever stopped being true, the penalty's justification would go with it.
    @Test func readabilityStillAnswersTheWordAppearance() {
        #expect(Tab.readability.digest.vocabulary.contains("appearance"))
    }
}
