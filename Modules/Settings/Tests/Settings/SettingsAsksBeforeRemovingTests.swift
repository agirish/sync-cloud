import Design
import Foundation
import Sync
import Testing
@testable import Settings

/// Five Settings controls ask before they throw away choices one click cannot bring back (HR).
///
/// **Each acted on a single click**: a folder source's Remove (its name and switched-off state go
/// with it), Sync's Clear All for ignored items, Organize's Clear All for kept names, Intelligence's
/// Clear for saved suggestions (the next Refine pays Claude again for every file), and choosing
/// "All columns" for column widths (the widths sized one at a time are erased, and choosing "Each
/// column" again does not restore them). A sixth, Hidden from Claude's Remove, asks the same way
/// (decision IP): it widens what Claude may see.
///
/// The decisions are pinned on the gates — a SwiftUI button's closure cannot be reached from a test
/// — over real stores where a store exists, and the last test holds each control to its gate, so a
/// revert cannot leave the gates tested and unused.
@MainActor
@Suite struct SettingsAsksBeforeRemovingTests {

    // MARK: Sources ▸ a folder source ▸ Remove

    private func folderManager(_ defaults: TestDefaults) -> SettingsManager {
        SettingsManager(autoDiscover: false,
                        userDefaults: defaults.defaults,
                        overridesDomainName: defaults.suiteName,
                        cloudStorageLister: { .read([]) },
                        pathValidator: { _ in true })
    }

    @Test func decliningRemoveKeepsTheFolderSourceItsNameAndItsSwitch() async {
        let defaults = TestDefaults()
        let settings = folderManager(defaults)
        let id = settings.addFolderSource(path: "/Users/u/Projects")
        await settings.discoverProviders()
        settings.setCustomName("Work", for: id)
        settings.setEnabled(false, for: id)
        defaults.defaults.set("Clients", forKey: "openAt_override_\(id)")
        var asked = 0

        let removed = ProviderSettingsSection.removeFolderSourceIfConfirmed(
            id: id, from: settings, confirm: { asked += 1; return false })
        await settings.discoverProviders()

        #expect(!removed)
        #expect(asked == 1, "Remove did not ask")
        #expect(settings.folderSources.map(\.id) == [id], "a declined Remove removed the source")
        #expect(defaults.defaults.string(forKey: "name_override_\(id)") == "Work",
                "a declined Remove lost the name given to the source")
        #expect(settings.disabledProviderIds.contains(id),
                "a declined Remove lost the source's switched-off state")
        #expect(defaults.defaults.string(forKey: "openAt_override_\(id)") == "Clients",
                "a declined Remove lost where the source opens")
    }

    @Test func confirmingRemoveAsksBeforeRemoving() async {
        let defaults = TestDefaults()
        let settings = folderManager(defaults)
        let id = settings.addFolderSource(path: "/Users/u/Projects")
        await settings.discoverProviders()
        defaults.defaults.set("Clients", forKey: "openAt_override_\(id)")
        var sourcesWhenAsked = -1

        let removed = ProviderSettingsSection.removeFolderSourceIfConfirmed(
            id: id, from: settings,
            confirm: { sourcesWhenAsked = settings.folderSources.count; return true })

        #expect(removed)
        #expect(sourcesWhenAsked == 1, "the source went before the question")
        #expect(settings.folderSources.isEmpty)
        // The question says where it opens is forgotten; the key used to outlive the source.
        #expect(defaults.defaults.string(forKey: "openAt_override_\(id)") == nil,
                "Remove left where the source opens behind")
    }

    // MARK: Sync ▸ Ignored items ▸ Clear All

    @Test func decliningClearAllKeepsTheIgnoredItems() {
        var cleared = 0
        var asked = 0
        let list = IgnoredItemsList(store: IgnoredItemsStore(userDefaults: ScratchDefaults("AskFirst-ignored")),
                                    onRemove: { _ in }, onClear: { cleared += 1 })

        let done = list.clearAll(confirm: { asked += 1; return false })

        #expect(!done)
        #expect(asked == 1, "Clear All did not ask")
        #expect(cleared == 0, "a declined Clear All cleared the ignored items")
    }

    @Test func confirmingClearAllClearsAfterAsking() {
        var order: [String] = []
        let list = IgnoredItemsList(store: IgnoredItemsStore(userDefaults: ScratchDefaults("AskFirst-ignored")),
                                    onRemove: { _ in }, onClear: { order.append("clear") })

        let done = list.clearAll(confirm: { order.append("ask"); return true })

        #expect(done)
        #expect(order == ["ask", "clear"], "the ignored items went before the question: \(order)")
    }

    /// **Clears the pair it asked about, or nothing.** The comparison can move to another pair
    /// while the alert is up (a source removed meanwhile); a yes must not clear that pair instead.
    @Test func clearAllDoesNothingWhenTheComparedPairChangedWhileItAsked() {
        let store = IgnoredItemsStore(userDefaults: ScratchDefaults("AskFirst-ignored-pair"))
        store.activate(pairKey: IgnoredItemsStore.pairKey("a", "b"))
        store.add(["x.txt"])
        var cleared = 0
        let list = IgnoredItemsList(store: store, onRemove: { _ in }, onClear: { cleared += 1 })

        let done = list.clearAll(confirm: {
            store.activate(pairKey: IgnoredItemsStore.pairKey("a", "c"))
            return true
        })

        #expect(!done)
        #expect(cleared == 0, "a yes cleared the ignores of a pair the question never named")

        // Unmoved, the same yes clears.
        #expect(list.clearAll(confirm: { true }))
        #expect(cleared == 1)
    }

    // MARK: Organize ▸ Kept names ▸ Clear All

    @Test func decliningClearAllKeepsEveryKeptName() {
        let defaults = ScratchDefaults("AskFirst-kept-decline")
        let store = KeptNamesStore(userDefaults: defaults)
        for name in ["a ", "b:"] { store.keep(name) }
        var asked = 0

        let done = KeptNamesList(store: store).clearAll(confirm: { asked += 1; return false })

        #expect(!done)
        #expect(asked == 1, "Clear All did not ask")
        #expect(store.names.count == 2, "a declined Clear All withdrew keeps")
        #expect(KeptNamesStore(userDefaults: defaults).names.count == 2)
    }

    @Test func confirmingClearAllWithdrawsTheKeepsAfterAsking() {
        let store = KeptNamesStore(userDefaults: ScratchDefaults("AskFirst-kept-confirm"))
        for name in ["a ", "b:", "c"] { store.keep(name) }
        var keptWhenAsked = -1

        let done = KeptNamesList(store: store).clearAll(confirm: { keptWhenAsked = store.names.count; return true })

        #expect(done)
        #expect(keptWhenAsked == 3, "the keeps went before the question")
        #expect(store.names.isEmpty)
    }

    // MARK: Intelligence ▸ Saved suggestions ▸ Clear

    @Test func decliningClearKeepsTheSavedSuggestions() {
        var asked = 0
        var cleared = 0
        let done = IntelligenceSettingsTab.clearSavedSuggestionsIfConfirmed(
            confirm: { asked += 1; return false }, clear: { cleared += 1 })
        #expect(!done)
        #expect(asked == 1, "Clear did not ask")
        #expect(cleared == 0, "a declined Clear forgot the saved suggestions")
    }

    @Test func confirmingClearForgetsTheSuggestionsAfterAsking() {
        var order: [String] = []
        let done = IntelligenceSettingsTab.clearSavedSuggestionsIfConfirmed(
            confirm: { order.append("ask"); return true }, clear: { order.append("clear") })
        #expect(done)
        #expect(order == ["ask", "clear"], "the suggestions went before the question: \(order)")
    }

    // MARK: Readability ▸ Column widths ▸ All columns

    private let sized = ColumnWidthOverrides(widths: [1: 480, 3: 300])

    /// Declined, the gate answers nil: the setter then writes neither setting.
    @Test func decliningAllColumnsWritesNothing() {
        var asked = 0
        let choice = ReadabilitySettingsTab.chooseResizeMode(
            ColumnResizeMode.allColumns.rawValue, overrides: sized,
            confirm: { asked += 1; return false })
        #expect(choice == nil, "a declined All columns still produced something to store")
        #expect(asked == 1, "All columns did not ask")
    }

    @Test func confirmingAllColumnsReleasesTheWidths() throws {
        var asked = 0
        let choice = try #require(ReadabilitySettingsTab.chooseResizeMode(
            ColumnResizeMode.allColumns.rawValue, overrides: sized,
            confirm: { asked += 1; return true }))
        #expect(asked == 1)
        #expect(choice.mode == ColumnResizeMode.allColumns.rawValue)
        #expect(choice.overrides.widths.isEmpty)
    }

    /// Nothing sized on its own means nothing to lose, so there is nothing to ask.
    @Test func allColumnsDoesNotAskWhenNoColumnWasSizedOnItsOwn() {
        var asked = 0
        let choice = ReadabilitySettingsTab.chooseResizeMode(
            ColumnResizeMode.allColumns.rawValue, overrides: ColumnWidthOverrides(),
            confirm: { asked += 1; return false })
        #expect(asked == 0)
        #expect(choice?.mode == ColumnResizeMode.allColumns.rawValue)
    }

    /// Each column keeps the widths, so choosing it never asks and never touches them.
    @Test func eachColumnNeverAsksAndKeepsTheWidths() {
        var asked = 0
        let choice = ReadabilitySettingsTab.chooseResizeMode(
            ColumnResizeMode.eachColumn.rawValue, overrides: sized,
            confirm: { asked += 1; return false })
        #expect(asked == 0)
        #expect(choice?.mode == ColumnResizeMode.eachColumn.rawValue)
        #expect(choice?.overrides == sized)
    }

    // MARK: Intelligence ▸ Hidden from Claude ▸ Remove

    @Test func decliningRemoveKeepsTheItemHiddenFromClaude() {
        let defaults = ScratchDefaults("AskFirst-hidden-decline")
        AskClaudePrivacy.hide("/Users/u/Private", in: defaults)
        AskClaudePrivacy.hide("/Users/u/Taxes", in: defaults)
        var asked = 0

        let done = IntelligenceSettingsTab.unhideIfConfirmed("/Users/u/Private", in: defaults,
                                                             confirm: { asked += 1; return false })

        #expect(!done)
        #expect(asked == 1, "Remove did not ask")
        #expect(AskClaudePrivacy.hiddenFolders(in: defaults) == ["/Users/u/Private", "/Users/u/Taxes"],
                "a declined Remove showed the folder to Claude")
    }

    @Test func confirmingRemoveShowsOnlyThatItemAfterAsking() {
        let defaults = ScratchDefaults("AskFirst-hidden-confirm")
        AskClaudePrivacy.hide("/Users/u/Private", in: defaults)
        AskClaudePrivacy.hide("/Users/u/Taxes", in: defaults)
        var hiddenWhenAsked: [String] = []

        let done = IntelligenceSettingsTab.unhideIfConfirmed("/Users/u/Private", in: defaults, confirm: {
            hiddenWhenAsked = AskClaudePrivacy.hiddenFolders(in: defaults); return true
        })

        #expect(done)
        #expect(hiddenWhenAsked.contains("/Users/u/Private"), "the folder was shown before the question")
        #expect(AskClaudePrivacy.hiddenFolders(in: defaults) == ["/Users/u/Taxes"])
    }

    /// A folder that is gone asks in a folder's words, and a file in a file's.
    @Test func theQuestionNamesWhatTheItemIs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskFirst-hidden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("statement.pdf")
        try Data("x".utf8).write(to: file)

        #expect(IntelligenceSettingsTab.isFolderOrMissing(directory.path))
        #expect(!IntelligenceSettingsTab.isFolderOrMissing(file.path))
        #expect(IntelligenceSettingsTab.isFolderOrMissing(directory.appendingPathComponent("gone").path))
    }

    // MARK: The words

    /// Each question says what goes, the button says the verb, and none of them claims more than
    /// it does: no file is touched by any of the five.
    @Test func eachQuestionSaysWhatGoesAndThatFilesStay() {
        let source = RemovalPrompt.removeFolderSource(named: "Work")
        #expect(source.messageText == "Remove “Work” from your sources?")
        #expect(source.informativeText.contains("name you gave it"))
        #expect(source.informativeText.contains("switched off"))
        #expect(source.informativeText.contains("where it opens"))
        #expect(source.informativeText.contains("what you ignored while comparing it"),
                "Remove orphans the source's ignored items, and the question does not say so")
        #expect(source.informativeText.contains("its files stay where they are"))
        #expect(source.confirmTitle == "Remove")

        #expect(RemovalPrompt.clearIgnoredItems(count: 3).messageText == "Stop ignoring all 3 items?")
        #expect(RemovalPrompt.clearIgnoredItems(count: 1).messageText == "Stop ignoring 1 item?")
        #expect(RemovalPrompt.clearIgnoredItems(count: 3).informativeText.contains("Differences"))
        // Ignore works on a whole selection, so it is not "one item at a time" to undo.
        #expect(!RemovalPrompt.clearIgnoredItems(count: 3).informativeText.contains("one item at a time"))
        // Counts read the way the rest of the app writes them.
        #expect(RemovalPrompt.clearIgnoredItems(count: 1_234).messageText
                    == "Stop ignoring all \(1_234.formatted()) items?")
        #expect(RemovalPrompt.clearSavedSuggestions(count: 4_000).messageText
                    == "Clear \(4_000.formatted()) saved suggestions?")
        #expect(RemovalPrompt.clearIgnoredItems(count: 3).confirmTitle == "Clear All")

        #expect(RemovalPrompt.clearKeptNames(count: 2).messageText == "Stop keeping all 2 names?")
        #expect(RemovalPrompt.clearKeptNames(count: 1).messageText == "Stop keeping 1 name?")
        #expect(RemovalPrompt.clearKeptNames(count: 2).informativeText.contains("No file is renamed"))
        // Withdrawing a keep brings the badge back at once but Organize's row only with a scan.
        #expect(RemovalPrompt.clearKeptNames(count: 2).informativeText.contains("in Organize from the next scan"))
        #expect(RemovalPrompt.clearKeptNames(count: 2).confirmTitle == "Clear All")

        let suggestions = RemovalPrompt.clearSavedSuggestions(count: 40)
        #expect(suggestions.messageText == "Clear 40 saved suggestions?")
        #expect(RemovalPrompt.clearSavedSuggestions(count: 1).messageText == "Clear 1 saved suggestion?")
        // The cost is the part nobody would guess, so the question has to say it.
        #expect(suggestions.informativeText.contains("Refine sends every file to Claude again"))
        #expect(suggestions.informativeText.contains("pays for each one"))
        #expect(suggestions.confirmTitle == "Clear Suggestions")

        let columns = RemovalPrompt.releaseColumnWidths(count: 2)
        #expect(columns.informativeText.contains("The 2 columns you sized on their own"))
        #expect(columns.informativeText.contains("doesn’t bring their widths back"))
        #expect(RemovalPrompt.releaseColumnWidths(count: 1).informativeText
                    .contains("The column you sized on its own"))
        #expect(columns.confirmTitle == "Use All Columns")

        let folder = RemovalPrompt.showToClaude(named: "Private", isFolder: true)
        let file = RemovalPrompt.showToClaude(named: "statement.pdf", isFolder: false)
        #expect(folder.messageText == "Show “Private” to Claude again?")
        #expect(folder.informativeText.contains("this folder"))
        #expect(file.informativeText.contains("this file"))
        // What a yes gives away, and the way back.
        for prompt in [folder, file] {
            #expect(prompt.informativeText.contains("ask this Mac to read"))
            #expect(prompt.informativeText.contains("Add… here"))
            #expect(prompt.informativeText.contains("Hide from Claude on its right-click menu"))
            #expect(prompt.confirmTitle == "Show to Claude")
        }

        for prompt in [source, RemovalPrompt.clearIgnoredItems(count: 3), RemovalPrompt.clearKeptNames(count: 2),
                       suggestions, columns, folder, file] {
            #expect(!prompt.informativeText.localizedCaseInsensitiveContains("trash"),
                    "\(prompt.messageText) talks of the Trash, but nothing goes there")
        }
    }

    // MARK: The wiring

    /// **Each control goes through its gate, and the gate asks with the standard alert.** Scanned
    /// rather than driven: a SwiftUI control's action cannot be reached from a test, and this is
    /// the half that connects the shipping control to the decisions tested above.
    @Test func everyControlGoesThroughItsGate() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Settings")
        func source(_ name: String) throws -> String {
            let text = try #require(
                try? String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8),
                "cannot read \(name) — the checks below would be vacuous")
            try #require(text.count > 1_000, "\(name) is implausibly short")
            return Self.withoutComments(text)
        }
        func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }
        let settings = try source("SettingsView.swift")
        let prompt = try source("RemovalPrompt.swift")

        // The alert: Cancel the default, the destructive button off Return.
        #expect(prompt.contains("NativeAlerts.confirmIrreversible("),
                "the questions no longer ask with the standard irreversible alert")

        // **Each deletion is called once in Settings, from inside its gate.** Counted rather than
        // spelled, so a second, unasked call is caught however it is written.
        #expect(count("removeFolderSource(id:", in: settings) == 1)
        #expect(settings.contains("RemovalPrompt.actIfConfirmed(confirm: confirm) { settings.removeFolderSource(id: id) }"))
        #expect(settings.contains("Self.removeFolderSourceIfConfirmed("), "a folder source's Remove no longer asks")
        #expect(settings.contains("confirm: RemovalPrompt.removeFolderSource(named: provider.displayName).ask"))

        #expect(count("clearAllIgnoredItems()", in: settings) == 1)
        #expect(count("onClear()", in: settings) == 1, "the ignored items are cleared outside the gate")
        #expect(!settings.contains("action: onClear"), "ignored items' Clear All clears on one click again")
        #expect(settings.contains("clearAll(confirm: RemovalPrompt.clearIgnoredItems("),
                "ignored items' Clear All no longer asks")

        #expect(count("stopKeepingAll()", in: settings) == 1)
        #expect(settings.contains("RemovalPrompt.actIfConfirmed(confirm: confirm) { store.stopKeepingAll() }"))
        #expect(settings.contains("clearAll(confirm: RemovalPrompt.clearKeptNames("),
                "kept names' Clear All no longer asks")

        #expect(count("clearFilingVerdictCache(", in: settings) == 1)
        #expect(settings.contains("clear: { syncManager.clearFilingVerdictCache() }"))
        #expect(settings.contains("Self.clearSavedSuggestionsIfConfirmed("), "saved suggestions' Clear no longer asks")
        #expect(settings.contains("confirm: RemovalPrompt.clearSavedSuggestions("))

        #expect(count("columnWidthOverrides = ", in: settings) == 1,
                "the column widths are written somewhere in Settings besides the gated setter")
        #expect(settings.contains("columnWidthOverrides = choice.overrides"))
        #expect(settings.contains("guard let choice = Self.chooseResizeMode("),
                "the Column widths picker no longer goes through its gate")
        #expect(settings.contains("RemovalPrompt.releaseColumnWidths(count: $0).ask()"),
                "the Column widths picker no longer asks with the standard alert")
        #expect(settings.contains("confirm: { confirmReleasingColumnWidths(overrides.widths.count) }"))

        #expect(count("AskClaudePrivacy.unhide(", in: settings) == 1,
                "an item leaves Hidden from Claude somewhere in Settings besides the gate")
        #expect(settings.contains("RemovalPrompt.actIfConfirmed(confirm: confirm) { AskClaudePrivacy.unhide(path, in: defaults) }"))
        #expect(settings.contains("Self.unhideIfConfirmed(folder, in: .standard, confirm: RemovalPrompt.showToClaude("),
                "Hidden from Claude's Remove no longer asks")
    }

    /// The source with every `//` comment removed — whole lines and trailing ones — so a call named
    /// in a comment cannot stand in for the call. String literals are respected.
    static func withoutComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            var inString = false
            var previous: Character = " "
            for index in line.indices {
                let character = line[index]
                if character == "\"" && previous != "\\" { inString.toggle() }
                if !inString, character == "/", previous == "/" {
                    return line[..<line.index(before: index)]
                }
                previous = character
            }
            return line
        }.joined(separator: "\n")
    }

    @Test func commentsAreStrippedAndStringsKept() {
        let stripped = Self.withoutComments("""
            a() // b()
            // c()
            let url = "http://x" // d()
            """)
        #expect(stripped.contains("a()") && stripped.contains("\"http://x\""))
        #expect(!stripped.contains("b()") && !stripped.contains("c()") && !stripped.contains("d()"))
    }
}
