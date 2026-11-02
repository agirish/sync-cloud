import Foundation
import Testing
import Sync
@testable import Dashboard

/// TE290 step 5: a Changed from Chat row says what changed, who changed it, and when.
@MainActor
@Suite struct ChangedFromChatRowsTests {

    @Test func aRowSaysWhatWhoAndWhen() {
        let at = Date(timeIntervalSince1970: 1_793_000_000)
        let theme = SettingsChange(at: at, setting: "appearance.theme", name: "Theme", from: "system", to: "dark",
                                   fromLabel: "System", toLabel: "Dark", how: .claude)
        let when = at.formatted(date: .abbreviated, time: .shortened)
        #expect(ChangedFromChatRows.detail(theme) == "System → Dark · by Claude · \(when)")
        let rule = SettingsChange(at: at, setting: "organize.rules", name: "Rule “Tickets”", from: nil, to: nil,
                                  fromLabel: nil, toLabel: nil, how: .rule)
        #expect(ChangedFromChatRows.detail(rule) == "saved from a card · \(when)")
    }
}
