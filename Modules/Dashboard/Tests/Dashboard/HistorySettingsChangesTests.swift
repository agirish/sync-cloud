import Foundation
import Testing
import Events
import Settings
import Sync
@testable import Dashboard

/// Settings changed from the chat are listed in Activity's Events among the runs, by time, in plain
/// words, and its filters reach them.
@MainActor
@Suite struct HistorySettingsChangesTests {

    private let at = Date(timeIntervalSince1970: 1_793_000_000)

    private func change(_ name: String, _ from: String?, _ to: String?, how: SettingsChange.How = .claude,
                        minutes: Double = 0) -> SettingsChange {
        SettingsChange(at: at.addingTimeInterval(minutes * 60), setting: "appearance.theme", name: name,
                       from: from?.lowercased(), to: to?.lowercased(), fromLabel: from, toLabel: to, how: how)
    }

    @Test func aRowSaysWhoChangedItInPlainWords() {
        #expect(HistorySettingsChanges.source(.claude) == "Claude changed it")
        #expect(HistorySettingsChanges.source(.card) == "You chose it on a card in Ask Claude")
        #expect(HistorySettingsChanges.source(.undo) == "You undid it in Ask Claude")
        #expect(HistorySettingsChanges.source(.redo) == "You redid it in Ask Claude")
        #expect(HistorySettingsChanges.source(.revert) == "You reverted it here")
        #expect(HistorySettingsChanges.source(.rule) == "You saved it as a rule from a card in Ask Claude")
    }

    /// The path field also finds a setting, by its name or its values, ignoring case; the date
    /// range drops the older ones.
    @Test func theFilterFindsASettingByNameOrValue() {
        let theme = change("Theme", "Light", "Dark")
        let density = change("List density", "Comfortable", "Compact", minutes: -120)
        let both = [theme, density]
        #expect(HistorySettingsChanges.filter(both, search: "", start: nil) == both)
        #expect(HistorySettingsChanges.filter(both, search: "theme", start: nil) == [theme])
        #expect(HistorySettingsChanges.filter(both, search: " COMPACT ", start: nil) == [density])
        #expect(HistorySettingsChanges.filter(both, search: "Documents", start: nil).isEmpty)
        #expect(HistorySettingsChanges.filter(both, search: "", start: at.addingTimeInterval(-60)) == [theme])
    }

    /// All Events and Settings Changes show them; a kind of record, Messages or One-Way Sync don't.
    @Test func theActionFilterDecidesWhetherTheyShow() {
        let all = [change("Theme", "Light", "Dark")]
        func shown(_ choice: ActivityEventsChoice) -> Int {
            ActivityEvents.build(records: [], messages: [], oneWay: [], changes: all, choice: choice, search: "",
                                 start: nil).count
        }
        #expect(shown(.all) == 1)
        #expect(shown(.settings) == 1)
        #expect(shown(.action(.copy)) == 0)
        #expect(shown(.messages) == 0)
        #expect(shown(.oneWaySync) == 0)
        #expect(ActivityEventsView.settingsOption.label == "Settings Changes")
    }

    /// One list, newest first, runs and settings changes between each other by time.
    @Test func runsAndChangesInterleaveNewestFirst() {
        let older = SyncHistoryRecord(runId: UUID(), timestamp: at.addingTimeInterval(-600), action: .copy,
                                      sourcePath: "/a", destPath: "/b")
        let newer = SyncHistoryRecord(runId: UUID(), timestamp: at.addingTimeInterval(600), action: .move,
                                      sourcePath: "/c", destPath: "/d")
        let theme = change("Theme", "Light", "Dark")
        let ids = ActivityEvents.build(records: [older, newer], messages: [], oneWay: [], changes: [theme], choice: .all,
                                       search: "", start: nil).map(\.id)
        #expect(ids == ["run-\(newer.runId)", "setting-\(theme.id)", "run-\(older.runId)"])
    }

    /// Revert's "Show to Claude again?" asks as Settings' Remove and the card do, with Cancel the
    /// default; a Revert that only raises asks as a change, Return confirming.
    @Test func showingAFolderToClaudeAgainAsksAsSettingsDoes() {
        let defaults = ScratchDefaults("HistorySettingsChangesTests")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(defaults.scratchSuiteName + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = SettingsChangeLog(fileURL: url)
        let lookup = SettingsLookup(defaults: defaults, settings: nil, keyIsSaved: { false }, hiddenCount: { 0 },
                                    isHidden: { _ in false }, loginItemIsOn: { false })
        let writer = SettingsWriter(defaults: defaults, settings: nil)
        let lists = SettingsLists(settings: SettingsManager(autoDiscover: false, userDefaults: defaults), sync: nil, defaults: defaults)
        #expect(lists.add("intelligence.hidden", "/Users/me/Medical") == .done)
        let hid = SettingsChange(setting: "intelligence.hidden", target: "/Users/me/Medical", name: "Hidden from Claude",
                                 from: "false", to: "true", fromLabel: nil, toLabel: "hid a folder", how: .card)
        defaults.set(10.0, forKey: AskClaudeSpend.limitDefaultsKey)
        let off = SettingsChange(setting: "intelligence.monthlyLimit", name: "Monthly limit", from: "25.0", to: "10.0",
                                 fromLabel: "$25", toLabel: "$10", how: .claude)
        var asked: [RemovalPrompt] = []
        for change in [hid, off] {
            SettingsRevert.revert(change, lookup: lookup, writer: writer, lists: lists, log: log,
                                  center: NotificationCenter(), confirmRaising: { asked.append($0); return false })
        }
        #expect(asked.map(\.messageText) == ["Show “Medical” to Claude again?", "Put Monthly limit back to $25?"])
        #expect(asked.map(HistorySettingsChanges.asksAsSettings) == [true, false])
    }
}
