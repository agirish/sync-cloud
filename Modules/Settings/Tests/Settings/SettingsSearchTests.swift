import Foundation
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

    /// The entries that used to say `.tidy` now have to say the right one of FOUR things, and
    /// `everyEntryPointsAtARealTab` cannot tell: `.filing`, `.duplicates`, `.intelligence` and
    /// `.people` are all real, so pointing every one at any single tab passes it. Search is how
    /// someone reaches a setting without knowing which tab holds it, and landing on the wrong tab
    /// of four that look alike is worse than landing on none — the setting isn't there, and the
    /// rail says it should be.
    ///
    /// The two-way version of this list was what the Tidy split needed. Splitting Organize again —
    /// the engine and its cost to `.intelligence`, the roster to `.people` — is the same hazard a
    /// second time and on more entries: eleven of the twelve moved, and `.filing` kept three. A
    /// test that only knew about Organize and Duplicates would have passed with every one of them
    /// still pointing at the tab they had just left.
    ///
    /// Spelled out per title rather than by counting, so the assertion says which control is
    /// misfiled instead of only that one is.
    @Test func theOldTidyEntriesLandOnTheTabThatOwnsTheirControl() {
        let expected: [SettingsView.SettingsTab: [String]] = [
            .duplicates: ["Ignore files smaller than", "Folders overlap at", "Detect versions"],
            // What Organize kept: the job, not the machinery.
            .filing: ["Loose-files inbox", "Remembered rules", "Kept names"],
            .intelligence: ["Suggest folders with on-device AI",
                            "Read file contents on-device for better signals",
                            "Use Claude (cloud) to refine suggestions",
                            "Anthropic API key", "Cloud model",
                            "Cost and limits", "Monthly budget cap", "Total budget cap",
                            "Reuse suggestions for files that haven’t changed", "Saved suggestions"],
            .people: ["People", "Add Person…"],
        ]

        for (tab, titles) in expected {
            for title in titles {
                let entry = SettingsSearchIndex.all.first { $0.title == title }
                #expect(entry?.tab == tab,
                        "\"\(title)\" points at \(entry?.tab.displayName ?? "nothing"), not \(tab.displayName)")
            }
        }
    }

    /// Someone who knew these settings as Organize's has to still find them after they moved.
    ///
    /// The split is invisible to a user who last looked a version ago: they remember an Organize
    /// tab with an API key in it. The keyword lists carry "organize" and "filing" across to the
    /// entries that left for exactly this, and nothing else checks that they do — every entry
    /// would still be individually well-formed with those words dropped.
    @Test func theSettingsThatLeftOrganizeAreStillFoundByItsName() {
        for query in ["organize", "filing"] {
            let results = filterSettings(SettingsSearchIndex.all, query: query)
            #expect(results.contains { $0.tab == .intelligence },
                    "'\(query)' reaches nothing on Intelligence — the engine settings left Organize silently")
            #expect(results.contains { $0.tab == .people },
                    "'\(query)' reaches nothing on People — the roster left Organize silently")
            // The tab itself, too: "filing" stopped appearing anywhere on screen when the
            // "Filing" section header became "Inbox and rules", so — like "tidy" — the word only
            // finds the settings that kept it as an alias keyword.
            #expect(results.contains { $0.tab == .filing },
                    "'\(query)' reaches nothing on Organize — the word left the tab silently")
        }
    }

    /// The offer that says "set up cloud refine" has to open the tab that can actually set it up.
    ///
    /// The link lives in `MacApp/ContentView.swift`, which is in no SPM package — only the app
    /// target compiles it — so a stale `.filing` there would have survived every test in the
    /// repo while sending anyone who accepted the offer to a tab with no key on it. Asserted
    /// against the INDEX rather than against `.intelligence` spelled twice: what makes a tab the
    /// right destination is that the key is on it, and if the key ever moves again this fails
    /// instead of agreeing with itself.
    @Test func theCloudRefineOfferLandsOnTheTabThatHoldsTheKey() throws {
        let key = try #require(SettingsSearchIndex.all.first { $0.title == "Anthropic API key" })
        let toggle = try #require(SettingsSearchIndex.all.first {
            $0.title == "Use Claude (cloud) to refine suggestions"
        })

        #expect(SettingsView.SettingsTab.cloudRefineSetup == key.tab,
                """
                The cloud-refine offer opens \(SettingsView.SettingsTab.cloudRefineSetup.displayName) \
                but the API key is on \(key.tab.displayName).
                """)
        #expect(SettingsView.SettingsTab.cloudRefineSetup == toggle.tab,
                """
                The cloud-refine offer opens \(SettingsView.SettingsTab.cloudRefineSetup.displayName) \
                but the toggle it exists to turn on is on \(toggle.tab.displayName).
                """)
    }

    /// The API key is the single most-hunted control in Settings and the one the rail's word does
    /// the least for: "Intelligence" is not what anybody types when they are looking for where to
    /// paste an `sk-ant-…`. Search is the whole of its discoverability, so the queries someone
    /// actually uses are pinned rather than left to the keyword list's good intentions.
    @Test func theApiKeyIsFindableByTheWordsPeopleActuallyType() {
        for query in ["api key", "anthropic", "claude", "keychain", "sk-ant", "token", "secret"] {
            let results = filterSettings(SettingsSearchIndex.all, query: query)
            #expect(results.contains { $0.title == "Anthropic API key" && $0.tab == .intelligence },
                    "'\(query)' should surface the Anthropic API key control")
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

    // MARK: Index coverage, checked against the tab sources

    /// The loose-files inbox went unindexed from the day it shipped — through the Tidy split,
    /// which re-pointed the twelve entries around it without noticing there should be a
    /// thirteenth. It is the one setting whose *value* is the word people would search ("TODO"),
    /// and the title spells "Loose-files" hyphenated, so the three obvious queries all need a
    /// keyword to land.
    @Test func looseFilesInboxIsFindableByTheWordsItsControlUses() {
        for query in ["inbox", "loose files", "todo", "default folder", "organize"] {
            let results = filterSettings(SettingsSearchIndex.all, query: query)
            #expect(results.contains { $0.title == "Loose-files inbox" && $0.tab == .filing },
                    "'\(query)' should surface the Loose-files inbox control")
        }
    }

    /// The index claims one entry per control that changes something. Nothing enforced that, and
    /// the claim was false: `indexIsNonEmptyAndCoversEveryTab` passes with a single entry per tab,
    /// so a control added without an entry — the loose-files inbox, for one — cost nothing.
    ///
    /// This reads the labels back out of the tab sources and requires each to reach an entry. It
    /// is a scan, not a proof: it can only see the labels written as string literals in the three
    /// vehicles below, and it cannot know about one it fails to model. What it does hold is that a
    /// control added the way every current control is written must be indexed or explicitly
    /// exempted here — which is the step that was skipped.
    @Test func everyControlLabelInTheTabSourcesIsIndexed() throws {
        let byVehicle = try controlLabelsInTabSources()

        // Each vehicle has to still be finding labels. A count over the whole scan is too coarse
        // to notice one going dead: `Toggle(isOn:)`'s trailing-closure form carries just two
        // labels, so losing that vehicle entirely drops the total from 47 to 45 and every
        // threshold worth setting still passes — the two controls simply leave the denominator,
        // unchecked and unmentioned. Asserted per vehicle, that is a failure instead of a shrug.
        for (vehicle, labels) in byVehicle {
            #expect(!labels.isEmpty, "The \(vehicle) scan matched nothing — the scan is broken, not the index")
        }

        let labels = Set(byVehicle.values.joined())
        for label in labels.sorted() where !Self.unindexedByDesign.contains(label) {
            #expect(indexCovers(label),
                    "\"\(label)\" is on screen but reaches no search entry — add one to SettingsSearchIndex.all")
        }
    }

    /// On-screen labels that are deliberately not settings, and so have no entry of their own.
    /// Two kinds, and nothing else belongs here:
    ///
    /// - **Group headers** — a `SettingsSection` title standing over other controls rather than
    ///   naming one. "Conflicts" heads the conflict-policy picker, which is indexed under its own
    ///   row title. (Headers that *are* their section's only control — "Tint", "List density",
    ///   "Cloud spend" — are indexed like any other control and are not listed here.)
    /// - **Readouts** — a `SettingsRow` showing a figure with nothing to change. All four are in
    ///   Organize's Cloud spend section, which is indexed as a whole.
    ///
    /// Adding a line here is how you say "this label is not a setting". Adding one to silence a
    /// real control is the failure this test exists to catch, so each entry earns its line.
    ///
    /// The list shrank when Organize split. "Suggestions" was Organize's group header and is gone;
    /// the four readout labels — "Total spent", "Tokens", "Cloud scans", "Last scan" — were
    /// `SettingsRow`s and are now drawn by `FilingSpendReadout`, which the scan does not see at
    /// all, so keeping them here would have been five lines claiming to exempt labels that no
    /// longer exist. An exemption nobody can fail is worse than none: it reads as a decision.
    ///
    /// "Inbox and rules" is the one addition — the group header over Organize's inbox path and
    /// rules pointer, both of which are indexed under their own row titles. (It said "Filing"
    /// until the v4 vocabulary rename; the word survives as an alias keyword on the inbox entry.)
    ///
    /// Every entry is load-bearing: drop one and the scan fails on it. The other new section
    /// headers are deliberately absent, because each is genuinely covered by a control entry
    /// under the containment rule above — "On-device" by "Read file contents on-device…",
    /// "Claude (cloud)" by "Use Claude (cloud) to refine suggestions", and "Cost and limits" and
    /// "Saved suggestions" by entries of their own.
    static let unindexedByDesign: Set<String> = [
        "Startup", "Conflicts", "Comparison", "Confirmations", "Logging", "Maintenance",
        "Inbox and rules", "Saved scan data",
    ]

    /// Whether some entry's title and this on-screen label name the same control. Containment runs
    /// both ways because the two legitimately differ in length: a title trims a parenthetical the
    /// label carries ("Detect versions" for "Detect versions (Report, Report (1), Report-final)"),
    /// and extends a label too terse to stand alone in a results list ("Surface tint" for "Tint").
    ///
    /// Titles only, never keywords: keywords are short and deliberately broad ("ai", "key", "path"),
    /// so a brand-new control would be waved through by a word that has nothing to do with it.
    private func indexCovers(_ label: String) -> Bool {
        let needle = label.lowercased()
        return SettingsSearchIndex.all.contains { entry in
            let title = entry.title.lowercased()
            return needle.contains(title) || title.contains(needle)
        }
    }

    /// Every control label written into the Settings sources, from the three vehicles that carry
    /// one: `SettingsRow("…")`, `SettingsSection("…")`, and `Toggle`'s label in both its string
    /// and its trailing-closure form.
    ///
    /// Each file's whitespace is collapsed before matching. Most `SettingsSection` titles are
    /// wrapped onto their own line, so a line-oriented scan silently misses "Tint", "List density",
    /// "Cloud spend" and "Ignored name patterns" — four real controls, quietly uncovered.
    ///
    /// Deliberately not scanned: `TextField`/`SecureField` first arguments, which are placeholders
    /// rather than labels here ("TODO", "Paste sk-ant-… key"); `Button` titles, which are actions
    /// within a control's row ("Browse…", "Clear Log") rather than settings; and `Picker` titles,
    /// which restate the `SettingsRow` they sit in. A `Toggle("")` — the provider enable switch,
    /// labelled by the row around it — has no label to match and is indexed under a written title.
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
            "Toggle(isOn:){Text}": #"Toggle\(isOn: [^)]*\) \{ Text\("([^"]+)"\)"#,
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
