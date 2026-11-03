import Foundation
import Testing
import Events
import Sync
@testable import Dashboard

/// TE290 step 5: settings changed from the chat are listed in History among the sync records, by
/// time, in plain words, and History's filters reach them.
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

    /// All Actions and Settings Changes show them; a kind of record, or one run's records, don't.
    @Test func theActionFilterAndShowInHistoryDecideWhetherTheyShow() {
        let all = [change("Theme", "Light", "Dark")]
        #expect(SyncHistoryView.shownChanges(all, choice: .all, runId: nil, search: "", start: nil) == all)
        #expect(SyncHistoryView.shownChanges(all, choice: .settings, runId: nil, search: "", start: nil) == all)
        #expect(SyncHistoryView.shownChanges(all, choice: .action(.copy), runId: nil, search: "", start: nil).isEmpty)
        #expect(SyncHistoryView.shownChanges(all, choice: .all, runId: UUID(), search: "", start: nil).isEmpty)
        #expect(SyncHistoryView.settingsOption.label == "Settings Changes")
    }

    /// One list, newest first, records and settings changes between each other by time.
    @Test func recordsAndChangesInterleaveNewestFirst() {
        let older = SyncHistoryRecord(runId: UUID(), timestamp: at.addingTimeInterval(-600), action: .copy,
                                      sourcePath: "/a", destPath: "/b")
        let newer = SyncHistoryRecord(runId: UUID(), timestamp: at.addingTimeInterval(600), action: .move,
                                      sourcePath: "/c", destPath: "/d")
        let theme = change("Theme", "Light", "Dark")
        let ids = SyncHistoryView.items(records: [newer, older], changes: [theme]).map(\.id)
        #expect(ids == ["record-\(newer.id)", "setting-\(theme.id)", "record-\(older.id)"])
    }
}
