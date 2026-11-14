import Foundation
import Testing
@testable import Settings

/// Pins the header settings search: the pure index and filter that find a setting by name across
/// every tab. The SwiftUI wiring (field, results list, tab jump) isn't exercised here; this locks
/// the matching rules the UI leans on.
@Suite struct SettingsSearchTests {

    // MARK: filterSettings behavior

    /// An empty query, a whitespace-only one and one that matches nothing all find nothing.
    @Test(arguments: ["", "   \n\t", "zzzznotasetting"]) func aQueryWithNoWordsOrNoMatchFindsNothing(query: String) {
        #expect(filterSettings(SettingsSearchIndex.all, query: query).isEmpty)
    }

    /// Ask Claude's show_in_app opens Settings at the page holding a named setting.
    @Test func aSettingNamedInWordsFindsItsPage() {
        #expect(SettingsPlace.holding("Ask Claude") == SettingsPlace(.claudeGeneral))
        #expect(SettingsPlace.holding("monthly limit") == SettingsPlace(.keyAndSpending))
        #expect(SettingsPlace.holding("API key") == SettingsPlace(.keyAndSpending))
        #expect(SettingsPlace.holding("Theme") == SettingsPlace(.look))
        #expect(SettingsPlace.holding("row spacing") == SettingsPlace(.textAndSpacing))
        #expect(SettingsPlace.holding("Log level") == SettingsSearchIndex.all.first { $0.title == "Log level" }?.place)
        #expect(SettingsPlace.holding("log") == SettingsSearchIndex.all.first { $0.title == "Log level" }?.place)
        #expect(SettingsPlace.holding("zzzznotasetting") == nil)
        #expect(SettingsPlace.holding("  ") == nil)
    }

    /// An entry on a paged tab names its page, or a jump to it lands on whichever page was last
    /// shown, which may not hold it. A one-page tab's entry names no page.
    @Test func everyEntryOnAPagedTabNamesItsPage() {
        for entry in SettingsSearchIndex.all {
            if entry.tab.subTabs.isEmpty {
                #expect(entry.place.subTab == nil, "\(entry.title) names a page on a one-page tab")
            } else {
                #expect(entry.place.subTab != nil, "\(entry.title) is on \(entry.tab.displayName) but names no page")
            }
        }
    }

    /// Every page has something to find, so a search can reach each.
    @Test func everyPageHasAnEntry() {
        for page in SettingsSubTab.allCases {
            #expect(SettingsSearchIndex.all.contains { $0.place.subTab == page },
                    "No searchable settings on \(SettingsPlace(page).name)")
        }
    }

    @Test func titleMatchIsFoundInAnyCase() {
        let results = filterSettings(SettingsSearchIndex.all, query: "Log level")
        #expect(results.contains { $0.title == "Log level" })
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
        // "Solid" belongs to the material control, not the shape one. Searching it must land on
        // Glass effect alone, or the two controls' meanings blur.
        let results = filterSettings(SettingsSearchIndex.all, query: "solid")
        #expect(results.contains { $0.title == "Glass effect" })
        #expect(!results.contains { $0.title == "Content surface style" })
    }

    @Test func themeIsFindableAndOwnsTheThemeKeyword() {
        // The Theme control governs light/dark, so the words people type for that must land on
        // it, and "theme" must not also be an Accent color keyword steering searches elsewhere.
        for query in ["theme", "dark mode", "light", "system", "appearance"] {
            let results = filterSettings(SettingsSearchIndex.all, query: query)
            #expect(results.contains { $0.title == "Theme" && $0.tab == .appearance },
                    "'\(query)' should surface the Theme control")
        }
        #expect(!filterSettings(SettingsSearchIndex.all, query: "theme")
            .contains { $0.title == "Accent color" })
    }

    @Test func rowSpacingIsFindableByValueNameAndByItsRetiredTitle() {
        // The density control must be findable by title, by the value words people type, and by
        // its retired title "List density", which stays in the entry's keywords so anyone who
        // learned that word still finds it.
        let byOldTitle = filterSettings(SettingsSearchIndex.all, query: "list density")
        #expect(byOldTitle.contains { $0.title == "Row spacing" && $0.place == SettingsPlace(.textAndSpacing) })

        let byNewTitle = filterSettings(SettingsSearchIndex.all, query: "row spacing")
        #expect(byNewTitle.contains { $0.title == "Row spacing" && $0.place == SettingsPlace(.textAndSpacing) })

        for value in ["compact", "comfortable"] {
            #expect(filterSettings(SettingsSearchIndex.all, query: value)
                .contains { $0.title == "Row spacing" },
                    "searching for the value name \(value) does not find the control that sets it")
        }
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
        let entry = SettingsSearchEntry(at: .general, title: "Confirm before deleting",
                                        keywords: ["trash", "delete confirmation"])
        #expect(entry.matches("confirm"))       // title substring
        #expect(entry.matches("Trash"))         // keyword, case-insensitive
        #expect(!entry.matches("checksum"))     // unrelated term
        #expect(!entry.matches(""))             // empty never matches
    }

    // MARK: index integrity

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

    // MARK: The pages that own each control

    /// Each entry that moved in TE332 must point at the page that holds its control.
    /// `everyEntryOnAPagedTabNamesItsPage` can't tell: every page is real, so pointing every entry
    /// at any one of them passes it. Landing on the wrong page is worse than no result, because the
    /// setting isn't there and the strip says it should be. Spelled out per title, so a failure
    /// names the misfiled control.
    @Test func theRegroupedEntriesLandOnThePageThatOwnsTheirControl() {
        let expected: [SettingsSubTab?: [String]] = [
            nil: ["When a file already exists", "Confirm before copying or moving",
                  "Confirm before deleting", "Warn before quitting during file operations"],
            .panes: ["Show hidden files by default", "Sort panes by", "Rescan when files change", "Column widths"],
            .textAndSpacing: ["Size & spacing", "Text size", "Row spacing"],
            .nameChecks: ["Check folder names against", "Allowed names"],
            .duplicates: ["Ignore files smaller than", "Folders overlap at", "Detect versions"],
            .toFile: ["Loose-files inbox", "Rules you taught by correcting", "Folder surveys"],
            .suggestions: ["Suggest folders with Apple Intelligence", "Read file contents on this Mac",
                           "Reuse suggestions for files that haven’t changed", "Saved suggestions"],
            .keyAndSpending: ["Claude API key", "Monthly limit", "This month", "Of that, Organize"],
            .people: ["People", "Add Person…"],
            .oneWaySync: ["One-Way Sync"],
        ]

        for (page, titles) in expected {
            let place = page.map(SettingsPlace.init) ?? SettingsPlace(.general)
            for title in titles {
                let entry = SettingsSearchIndex.all.first { $0.title == title }
                #expect(entry?.place == place,
                        "\"\(title)\" points at \(entry?.place.name ?? "nothing"), not \(place.name)")
            }
        }
    }

    /// Someone who knew these settings by Organize's old names must still find them. The keyword
    /// lists carry "organize" and "filing", and nothing else checks it: every entry stays
    /// well-formed with those words dropped.
    @Test func organizesSettingsAreStillFoundByItsOldNames() {
        for query in ["organize", "filing"] {
            let results = filterSettings(SettingsSearchIndex.all, query: query)
            #expect(results.contains { $0.place == SettingsPlace(.suggestions) },
                    "'\(query)' reaches nothing on Organize ▸ Suggestions")
            #expect(results.contains { $0.place == SettingsPlace(.people) },
                    "'\(query)' reaches nothing on Organize ▸ People")
            // Asserted on the entry, not the page: "Rules you taught by correcting" carries
            // "filing rules" and matching is substring, so a page check can't fail. Naming the title
            // makes deleting the alias red, as in `looseFilesInboxIsFindableByTheWordsItsControlUses`.
            #expect(results.contains { $0.title == "Loose-files inbox" && $0.tab == .filing },
                    "'\(query)' does not reach the Loose-files inbox — the alias keyword left the entry that carries it")
        }
    }

    /// The offer that says "set up cloud refine" has to open the page that can actually set it up.
    ///
    /// The link lives in `MacApp/ContentView.swift`, which no package test compiles, so this pins
    /// the `cloudRefineSetup` place it opens. Asserted against the index, not a spelled-out page:
    /// the right destination is wherever the key is, so if it moves this fails instead of agreeing
    /// with itself. Refine has no switch of its own since TE335: a saved key is the opt-in, and the
    /// model and limit are Ask Claude's, all on Ask Claude ▸ Key & Spending.
    @Test func theCloudRefineOfferLandsOnThePageThatHoldsTheKey() throws {
        let key = try #require(SettingsSearchIndex.all.first { $0.title == "Claude API key" })
        let limit = try #require(SettingsSearchIndex.all.first { $0.title == "Monthly limit" })

        let offer = SettingsView.SettingsTab.cloudRefineSetup
        #expect(offer == key.place,
                "The cloud-refine offer opens \(offer.name) but the key it asks for is on \(key.place.name).")
        #expect(offer == limit.place,
                "The cloud-refine offer opens \(offer.name) but the limit Refine runs under is on \(limit.place.name).")
        #expect(offer == SettingsPlace(.keyAndSpending))
        // The retired switch and model picker are not in the index to be found.
        #expect(!SettingsSearchIndex.all.contains { $0.title == "Use Claude (cloud) to refine suggestions" || $0.title == "Cloud model" })
    }

    /// Refine has no switch to search for any more (TE335), but someone who remembers one still types
    /// "refine", "cloud" or "cloud model", and an empty result reads as "that setting is gone". They
    /// land on the page that holds what replaced it: the key, and the one limit.
    @Test func theWordsForTheRetiredCloudSwitchReachTheKeyPage() {
        for query in ["refine", "cloud", "cloud refine", "use claude", "cloud model", "monthly cap", "try another"] {
            let results = filterSettings(SettingsSearchIndex.all, query: query)
            #expect(results.contains { $0.place == SettingsPlace(.keyAndSpending) },
                    "'\(query)' reaches nothing on Ask Claude ▸ Key & Spending")
        }
    }

    /// The API key is the most-hunted control in Settings, and "Intelligence" is not what anyone
    /// types when looking for where to paste an `sk-ant-…`. Search is its whole discoverability,
    /// so the queries people actually use are pinned.
    @Test func theApiKeyIsFindableByTheWordsPeopleActuallyType() {
        for query in ["api key", "anthropic", "claude", "keychain", "sk-ant", "token", "secret"] {
            let results = filterSettings(SettingsSearchIndex.all, query: query)
            #expect(results.contains { $0.title == "Claude API key" && $0.place == SettingsPlace(.keyAndSpending) },
                    "'\(query)' should surface the Claude API key control")
        }
    }

    /// "Tidy" is no longer a tab, but someone who remembers it has nothing else to type, and an
    /// empty result reads as "that setting is gone". The word must reach both pages it became.
    @Test func searchingTidyStillReachesBothPagesItBecame() {
        let results = filterSettings(SettingsSearchIndex.all, query: "tidy")

        #expect(results.contains { $0.place == SettingsPlace(.toFile) }, "\"tidy\" surfaces nothing on To File")
        #expect(results.contains { $0.place == SettingsPlace(.duplicates) }, "\"tidy\" surfaces nothing on Duplicates")
    }

    // MARK: Index coverage, checked against the tab sources

    /// The loose-files inbox is the one setting whose *value* is the word people search ("TODO"),
    /// and its title hyphenates "Loose-files", so the obvious queries all need a keyword to land.
    @Test func looseFilesInboxIsFindableByTheWordsItsControlUses() {
        for query in ["inbox", "loose files", "todo", "default folder", "organize"] {
            let results = filterSettings(SettingsSearchIndex.all, query: query)
            #expect(results.contains { $0.title == "Loose-files inbox" && $0.tab == .filing },
                    "'\(query)' should surface the Loose-files inbox control")
        }
    }

    /// The index promises one entry per control that changes something, and
    /// `indexIsNonEmptyAndCoversEveryTab` passes with one entry per tab. This reads the labels out
    /// of the tab sources and requires each to reach an entry or be exempted. A scan, not a proof:
    /// it sees only string-literal labels in the vehicles `controlLabelsInTabSources` models.
    @Test func everyControlLabelInTheTabSourcesIsIndexed() throws {
        let byVehicle = try controlLabelsInTabSources()

        // Each vehicle must still find labels. A total count is too coarse: a vehicle carrying
        // only a couple of labels could go dead and its controls would silently leave the check.
        for (vehicle, labels) in byVehicle {
            #expect(!labels.isEmpty, "The \(vehicle) scan matched nothing — the scan is broken, not the index")
        }

        let labels = Set(byVehicle.values.joined())
        for label in labels.sorted() where !Self.unindexedByDesign.contains(label) {
            #expect(indexCovers(label),
                    "\"\(label)\" is on screen but reaches no search entry — add one to SettingsSearchIndex.all")
        }
    }

    /// On-screen labels that are deliberately not settings, so they have no entry of their own.
    /// Two kinds, and nothing else belongs here:
    ///
    /// - Group headers: a `SettingsSection` title over controls indexed under their own row
    ///   titles. "Copying and moving" heads the conflict-policy picker; "Inbox" heads To File's
    ///   inbox path and rules pointer. A header that is its section's only control is indexed.
    /// - Readouts in section clothing, on People: "Across your tree" heads `PeopleOverviewRow`,
    ///   and "Names found in your documents" heads the queue "Look for Names" fills, offers to
    ///   accept or refuse rather than settings. And Ask Claude ▸ Privacy's "Every folder", which
    ///   says what a folder neither shared nor hidden does, and sets nothing.
    ///
    /// Every entry is load-bearing: drop one and the scan fails on it. Headers covered by a control
    /// entry under `indexCovers`'s containment rule ("On-device", "Claude (cloud)") stay out. An
    /// exemption added to silence a real control is the failure this test exists to catch.
    static let unindexedByDesign: Set<String> = [
        "Startup", "Copying and moving", "Notifications", "Logging", "Maintenance", "Setup",
        "Inbox", "Saved scan data", "Markdown", "Reading", "Organize",
        "On-device", "What Claude may see",
        "Across your tree", "Names found in your documents", "Every folder",
        // Organize ▸ Suggestions' "Refine": a group header over one jump row to Key & Spending,
        // where "refine" is a keyword of the key and the limit (TE335).
        "Refine",
        // A notice that shows once, after Refine's own limits were retired (TE335, E5), under one
        // heading or the other.
        "Refine’s own limits are gone", "Try Another asks Claude now",
    ]

    /// Whether some entry's title and this on-screen label name the same control. Containment runs
    /// both ways: a title may trim a label's parenthetical ("Detect versions") or extend a terse
    /// label ("Surface tint" for "Tint"). Titles only, never keywords: keywords are deliberately
    /// broad ("ai", "key"), so a new control would be waved through by an unrelated word.
    private func indexCovers(_ label: String) -> Bool {
        let needle = label.lowercased()
        return SettingsSearchIndex.all.contains { entry in
            let title = entry.title.lowercased()
            return needle.contains(title) || title.contains(needle)
        }
    }

    /// Every control label written into the Settings sources, keyed by vehicle:
    /// `SettingsRow("…")`, `SettingsSection("…")`, `Toggle`'s label in its string and
    /// trailing-closure forms, and `LabeledContent("…")`. Whitespace is collapsed first, because
    /// many `SettingsSection` titles sit on their own line and a line scan would miss them.
    ///
    /// Not scanned: `TextField`/`SecureField` first arguments (placeholders such as "TODO"),
    /// `Button` titles (actions within a row), and `Picker` titles (they restate their row). A
    /// `Toggle("")` is labelled by its row, so it is indexed under a written title.
    private func controlLabelsInTabSources() throws -> [String: Set<String>] {
        let sources = URL(fileURLWithPath: #filePath)   // …/Tests/Settings/SettingsSearchTests.swift
            .deletingLastPathComponent()                // …/Tests/Settings
            .deletingLastPathComponent()                // …/Tests
            .deletingLastPathComponent()                // …/Modules/Settings
            .appendingPathComponent("Sources/Settings")

        let files = try FileManager.default
            .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "No Swift sources under \(sources.path)")

        let vehicles = [
            "SettingsRow": #"SettingsRow\( ?"([^"]+)""#,
            "SettingsSection": #"SettingsSection\( ?"([^"]+)""#,
            "Toggle(label:)": #"Toggle\( ?"([^"]+)""#,
            // One level of parentheses inside the binding: `$x.loggingSettingsChange("id")`.
            "Toggle(isOn:){Text}": #"Toggle\(isOn: (?:[^()]|\([^()]*\))*\) \{ Text\("([^"]+)"\)"#,
            // A control labelled this way ("Column widths") is invisible to the scan without it.
            "LabeledContent": #"LabeledContent\( ?"([^"]+)""#,
        ]

        let collapsed = try files.map {
            try String(contentsOf: $0, encoding: .utf8)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        }

        var found: [String: Set<String>] = [:]
        for (vehicle, pattern) in vehicles {
            let regex = try NSRegularExpression(pattern: pattern)
            var labels: Set<String> = []
            for source in collapsed {
                let whole = NSRange(source.startIndex..., in: source)
                for match in regex.matches(in: source, range: whole) {
                    guard let range = Range(match.range(at: 1), in: source) else { continue }
                    labels.insert(String(source[range]))
                }
            }
            found[vehicle] = labels
        }
        return found
    }
}
