import Foundation
import Testing
@testable import Sync

/// TE290 step 5: Changed from Chat keeps every change made from the chat in its own file — written
/// at once, 90 days or 500 at most, read without what's hidden from Claude.
@MainActor
@Suite struct SettingsChangeLogTests {

    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SettingsChangeLogTests-\(UUID().uuidString).json")
    }

    private func change(_ name: String = "Theme", at: Date = Date(), how: SettingsChange.How = .card) -> SettingsChange {
        SettingsChange(at: at, setting: "appearance.theme", name: name, from: "system", to: "dark",
                       fromLabel: "System", toLabel: "Dark", how: how)
    }

    @Test func aChangeIsOnDiskTheMomentItIsRecorded() {
        let url = file(); defer { try? FileManager.default.removeItem(at: url) }
        let log = SettingsChangeLog(fileURL: url)
        let theme = change(how: .claude)
        log.record(theme)
        #expect(SettingsChangeLog(fileURL: url).changes == [theme])
        log.clear()
        #expect(SettingsChangeLog(fileURL: url).changes.isEmpty)
    }

    @Test func itKeepsNinetyDaysAndFiveHundredAtMost() throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url) }
        let log = SettingsChangeLog(fileURL: url)
        let now = Date()
        log.record(change("Old", at: now.addingTimeInterval(-91 * 86_400)))
        log.record(change("Recent", at: now.addingTimeInterval(-89 * 86_400)))
        #expect(log.changes.map(\.name) == ["Recent"])
        // A full record seeded in one write: recording 500 one by one rewrites the file 500 times
        // on the main actor, long enough on CI's 3 cores to starve other suites' waits.
        let full = (0..<SettingsChangeLog.maxChanges).map { change("\($0)", at: now) }
        try JSONEncoder().encode(full).write(to: url)
        let reloaded = SettingsChangeLog(fileURL: url)
        reloaded.record(change("Newest", at: now))
        #expect(reloaded.changes.count == SettingsChangeLog.maxChanges)
        #expect(reloaded.changes.first?.name == "1")
        #expect(reloaded.changes.last?.name == "Newest")
    }

    @Test func oneUnreadableChangeIsLeftOutNotTheRecord() throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url) }
        let good = change()
        let json = String(data: try JSONEncoder().encode([good]), encoding: .utf8)!
        try ("[{\"how\":\"someday\"}," + json.dropFirst()).write(to: url, atomically: true, encoding: .utf8)
        #expect(SettingsChangeLog(fileURL: url).changes == [good])
    }

    @Test func whatNamesAHiddenItemIsShownWithoutItsWords() {
        let url = file(); defer { try? FileManager.default.removeItem(at: url) }
        let log = SettingsChangeLog(fileURL: url)
        log.record(change())
        log.record(SettingsChange(setting: "organize.rules", name: "Rule “Tickets into Travel”", from: nil, to: nil,
                                  fromLabel: nil, toLabel: nil, how: .rule))
        let shown = log.visible(hiding: ["travel"])
        #expect(shown.map(\.name) == ["A change about an item hidden from Claude", "Theme"])
        #expect(shown[0].how == .rule)
        #expect(log.visible(hiding: []).first?.name == "Rule “Tickets into Travel”")
    }
}

/// Off the main actor: resolving the test file sweeps the temp directory, which took 1.3 s on the
/// main actor with 200,000 entries in it, long enough to starve other suites' main-actor waits.
@Suite struct SettingsChangeLogFileTests {
    @Test func aTestRunNeverWritesTheRealFile() {
        #expect(SettingsChangeLog.defaultFileURL().path != NSHomeDirectory() + "/sync-cloud-settings-changes.json")
    }
}
