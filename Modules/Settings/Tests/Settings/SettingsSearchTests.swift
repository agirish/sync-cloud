import Testing
@testable import Settings

/// Pins the header settings search (item 5.1): the pure index + filter that lets someone find a
/// setting by name across every tab. The SwiftUI wiring (field, results list, tab jump) isn't
/// exercised here — this locks the matching rules the UI leans on.
@Suite struct SettingsSearchTests {

    // MARK: filterSettings behavior

    @Test func emptyQueryReturnsNothing() {
        #expect(filterSettings(SettingsSearchIndex.all, query: "").isEmpty)
    }

    @Test func whitespaceOnlyQueryReturnsNothing() {
        #expect(filterSettings(SettingsSearchIndex.all, query: "   \n\t").isEmpty)
    }

    @Test func noMatchReturnsNothing() {
        #expect(filterSettings(SettingsSearchIndex.all, query: "zzzznotasetting").isEmpty)
    }

    @Test func titleMatchIsFound() {
        let results = filterSettings(SettingsSearchIndex.all, query: "Log level")
        #expect(results.contains { $0.title == "Log level" })
    }

    @Test func matchIsCaseInsensitive() {
        let lower = filterSettings(SettingsSearchIndex.all, query: "log level")
        let upper = filterSettings(SettingsSearchIndex.all, query: "LOG LEVEL")
        #expect(!lower.isEmpty)
        #expect(lower.map(\.id) == upper.map(\.id))
    }

    @Test func keywordMatchIsFound() {
        // "blur" appears only as a keyword on the Glass effect control, never in a title.
        let results = filterSettings(SettingsSearchIndex.all, query: "blur")
        #expect(results.contains { $0.title == "Glass effect" })
    }

    @Test func solidIsFoundUnderGlassEffectNotContentSurface() {
        // "Solid" moved from the shape control to the material one. Searching it must land on
        // Glass effect alone — while it lived in both, the two controls' meanings blurred.
        let results = filterSettings(SettingsSearchIndex.all, query: "solid")
        #expect(results.contains { $0.title == "Glass effect" })
        #expect(!results.contains { $0.title == "Content surface style" })
    }

    @Test func themeIsFindableAndOwnsTheThemeKeyword() {
        // The Theme control governs light/dark, so the words people type for that must land on
        // it — including "theme" itself, which used to be an Accent color keyword and steered
        // searches at the wrong control.
        for query in ["theme", "dark mode", "light", "system", "appearance"] {
            let results = filterSettings(SettingsSearchIndex.all, query: query)
            #expect(results.contains { $0.title == "Theme" && $0.tab == .appearance },
                    "'\(query)' should surface the Theme control")
        }
        #expect(!filterSettings(SettingsSearchIndex.all, query: "theme")
            .contains { $0.title == "Accent color" })
    }

    @Test func listDensityIsFindableByValueName() {
        // H7: the new density control must be findable like its Appearance neighbors —
        // both by title and by the value words people would type.
        let byTitle = filterSettings(SettingsSearchIndex.all, query: "list density")
        #expect(byTitle.contains { $0.title == "List density" && $0.tab == .appearance })
        let byValue = filterSettings(SettingsSearchIndex.all, query: "compact")
        #expect(byValue.contains { $0.title == "List density" })
    }

    @Test func partialSubstringMatches() {
        // Typing part of a word still surfaces the setting.
        let results = filterSettings(SettingsSearchIndex.all, query: "trash")
        #expect(results.contains { $0.title == "Confirm before deleting" })
    }

    @Test func surroundingWhitespaceIsTrimmedBeforeMatching() {
        let padded = filterSettings(SettingsSearchIndex.all, query: "  accent  ")
        #expect(padded.contains { $0.title == "Accent color" })
    }

    // MARK: matches() on a single entry

    @Test func entryMatchesTitleAndKeyword() {
        let entry = SettingsSearchEntry(tab: .sync, title: "Confirm before deleting",
                                        keywords: ["trash", "delete confirmation"])
        #expect(entry.matches("confirm"))       // title substring
        #expect(entry.matches("Trash"))         // keyword, case-insensitive
        #expect(!entry.matches("checksum"))     // unrelated term
        #expect(!entry.matches(""))             // empty never matches
    }

    // MARK: index integrity

    @Test func everyEntryPointsAtARealTab() {
        for entry in SettingsSearchIndex.all {
            #expect(SettingsView.SettingsTab.allCases.contains(entry.tab))
        }
    }

    @Test func indexIsNonEmptyAndCoversEveryTab() {
        #expect(!SettingsSearchIndex.all.isEmpty)
        for tab in SettingsView.SettingsTab.allCases {
            #expect(SettingsSearchIndex.all.contains { $0.tab == tab },
                    "No searchable settings indexed for the \(tab.displayName) tab")
        }
    }

    @Test func entryIdsAreUnique() {
        let ids = SettingsSearchIndex.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    // MARK: The Tidy split

    /// The twelve entries that used to say `.tidy` now have to say the right one of two things,
    /// and `everyEntryPointsAtARealTab` cannot tell: `.filing` and `.duplicates` are both real, so
    /// pointing all twelve at either one passes it. Search is how someone reaches a setting
    /// without knowing which tab holds it, and landing on the wrong tab of two that look alike is
    /// worse than landing on none — the setting isn't there, and the rail says it should be.
    ///
    /// Spelled out per title rather than by counting, so the assertion says which control is
    /// misfiled instead of only that one is.
    @Test func theOldTidyEntriesLandOnTheTabThatOwnsTheirControl() {
        let duplicates = ["Ignore files smaller than", "Folders overlap at", "Detect versions"]
        let organize = ["Suggest folders with on-device AI", "Use Claude (cloud) for the best suggestions",
                        "Anthropic API key", "Cloud model", "Read file contents on-device for better signals",
                        "Remembered rules", "Cloud spend", "Monthly budget cap", "Total budget cap"]

        for title in duplicates {
            let entry = SettingsSearchIndex.all.first { $0.title == title }
            #expect(entry?.tab == .duplicates, "\"\(title)\" points at \(entry?.tab.displayName ?? "nothing")")
        }
        for title in organize {
            let entry = SettingsSearchIndex.all.first { $0.title == title }
            #expect(entry?.tab == .filing, "\"\(title)\" points at \(entry?.tab.displayName ?? "nothing")")
        }
    }

    /// "Tidy" left the product with this split, so the word has to keep finding something. Someone
    /// who remembers the tab has nothing else to type — and an empty result set reads as "that
    /// setting is gone", which is the opposite of what happened to it.
    @Test func searchingTidyStillReachesBothTabsItSplitInto() {
        let results = filterSettings(SettingsSearchIndex.all, query: "tidy")

        #expect(results.contains { $0.tab == .filing }, "\"tidy\" surfaces nothing on Organize")
        #expect(results.contains { $0.tab == .duplicates }, "\"tidy\" surfaces nothing on Duplicates")
    }
}
