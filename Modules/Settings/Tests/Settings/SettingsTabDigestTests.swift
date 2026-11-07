import Foundation
import Testing
@testable import Settings

/// Pins ``SettingsTabDigest``: what this module hands the ⌘K palette so typing `appearance` (or
/// `glass`, or `sk-ant`) lands on the tab that answers it. Tested here because the palette lives
/// in `FileExplorer`, which cannot import this package, and the wiring in `MacApp`, which no
/// package test compiles. A missing tab, an empty detail or a drifting vocabulary fails here.
@Suite struct SettingsTabDigestTests {

    private typealias Tab = SettingsView.SettingsTab

    // MARK: Coverage

    @Test func everyTabIsOffered() {
        let ids = Set(Tab.digests.map(\.id))
        #expect(ids == Set(Tab.allCases.map(\.rawValue)))
    }

    /// Built from `railGroups`, not `allCases`, so the palette lists tabs in the order the rail
    /// shows them. Fails if the two lists are ever built independently.
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

    /// The detail line is the row's one hand-written text, so nothing else catches it being empty
    /// or only repeating the tab's name ("Sources" under "Settings ▸ Sources" says nothing).
    @Test func everyDetailSaysSomethingTheNameDoesNot() {
        for tab in Tab.allCases {
            let detail = tab.digest.detail
            #expect(!detail.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(!detail.localizedCaseInsensitiveContains(tab.displayName))
            #expect(detail.count > tab.displayName.count)
        }
    }

    // MARK: Vocabulary

    /// A tab's vocabulary is exactly the titles and keywords of its own `SettingsSearchIndex`
    /// entries: nothing added, dropped or borrowed. So the index is the single catalog: a control
    /// added there reaches ⌘K with no second edit, and `everyControlLabelInTheTabSourcesIsIndexed`
    /// guards both surfaces.
    @Test func everyTabsVocabularyIsItsIndexEntries() {
        for tab in Tab.allCases {
            let mine = SettingsSearchIndex.all.filter { $0.tab == tab }
            let expected = Set(mine.map(\.title) + mine.flatMap(\.keywords))
            #expect(Set(tab.digest.vocabulary) == expected)
            // Sorted and unique, though several tabs carry a keyword on two controls ("cache" is on
            // both of Intelligence's suggestion rows).
            #expect(tab.digest.vocabulary == expected.sorted())
        }
    }

    /// The words the feature was justified by, each checked against the tab it should reach. The
    /// derivation test can't see whether the *catalog* actually contains them; this can.
    @Test func thePromisedWordsReachTheirTab() {
        let promised: [(String, Tab)] = [
            ("glass", .appearance), ("dark mode", .appearance),
            ("api key", .intelligence), ("anthropic", .intelligence), ("sk-ant", .intelligence),
            ("log level", .advanced), ("factory reset", .advanced),
            ("node_modules", .sync), ("keep both", .general),
            ("icloud", .providers), ("dropbox", .providers),
            ("household", .filing), ("loose files", .filing),
            ("row spacing", .appearance), ("startup", .general),
            ("fingerprint", .filing), ("sidebar", .browse), ("word wrap", .edit)
        ]
        for (word, tab) in promised {
            let reached = Tab.digests.filter { digest in
                digest.vocabulary.contains { $0.localizedCaseInsensitiveContains(word) }
            }
            #expect(reached.contains { $0.id == tab.rawValue },
                    "“\(word)” should reach \(tab.displayName)")
        }
    }

    /// `browse` is a keyword on Sources (Synchronized path's Browse… button) and the name of the
    /// Browse tab. That collision is why the palette penalises a vocabulary match below a name, so
    /// it is pinned: if it stopped being true, the penalty's justification would go with it.
    @Test func sourcesStillAnswersTheWordBrowse() {
        #expect(Tab.providers.digest.vocabulary.contains("browse"))
        #expect(Tab.browse.displayName.lowercased() == "browse")
    }
}
