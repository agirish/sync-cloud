import Foundation
import Testing
@testable import Sync

/// Changed from Chat keeps every change made from the chat in its own file: written at once, 90
/// days or 500 at most, read without what's hidden from Claude.
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

    /// A hidden name is matched as a whole word or path part, never inside another word, or a
    /// hidden "Old" would blank every "Folder" setting's row and its Revert.
    @Test func aHiddenNameIsMatchedAsAWordNotInsideOne() {
        let folder = SettingsChange(setting: "sources.folderNameRule", name: "Check folder names against", from: "oneDrive",
                                    to: "dropBox", fromLabel: "OneDrive (strictest)", toLabel: "Dropbox", how: .card)
        #expect(SettingsChangeLog.redacted(folder, hiding: ["Old"]) == folder)
        let path = SettingsChange(setting: "sources.openAt", name: "Open at for Dropbox", from: "Archive/Old", to: "Work",
                                  fromLabel: "Archive/Old", toLabel: "Work", how: .card)
        #expect(SettingsChangeLog.redacted(path, hiding: ["old"]).name == "A change about an item hidden from Claude")
    }

    /// Rows this build can't read survive its writes; another copy's rows are merged in, not lost.
    @Test func rowsItCantReadAndRowsAnotherCopyWroteAreKept() throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url) }
        let mine = change("Mine")
        let other = change("Other")
        let json = String(data: try JSONEncoder().encode([mine]), encoding: .utf8)!
        try ("[{\"how\":\"someday\",\"name\":\"Future\"}," + json.dropFirst()).write(to: url, atomically: true, encoding: .utf8)
        let log = SettingsChangeLog(fileURL: url)
        #expect(log.changes == [mine])
        // Another copy of the app adds a row behind this one's back.
        let elsewhere = SettingsChangeLog(fileURL: url)
        elsewhere.record(other)
        log.record(change("Third"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("someday") && text.contains("Future"))
        #expect(Set(SettingsChangeLog(fileURL: url).changes.map(\.name)) == ["Mine", "Other", "Third"])
    }

    /// With two copies running, a row one copy trimmed or cleared stays gone when the other writes:
    /// it isn't added back as the newest, and a Clear isn't undone.
    @Test func whatAnotherCopyTrimmedOrClearedStaysGone() throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        let full = (0..<SettingsChangeLog.maxChanges).map { change("\($0)", at: now.addingTimeInterval(Double($0) - 1_000)) }
        try JSONEncoder().encode(full).write(to: url)
        let one = SettingsChangeLog(fileURL: url)
        let other = SettingsChangeLog(fileURL: url)
        one.record(change("One", at: now))
        other.record(change("Other", at: now.addingTimeInterval(1)))
        let names = SettingsChangeLog(fileURL: url).changes.map(\.name)
        #expect(!names.contains("0"), "a row the other copy trimmed came back")
        #expect(names.count == SettingsChangeLog.maxChanges)
        #expect(names.suffix(2) == ["One", "Other"])

        one.clear()
        other.record(change("After", at: now.addingTimeInterval(2)))
        #expect(SettingsChangeLog(fileURL: url).changes.map(\.name) == ["After"])
    }

    /// A row this copy couldn't write is still written by its next write.
    @Test func aRowThatCouldntBeWrittenIsWrittenNextTime() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsChangeLogTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("changes.json")
        let log = SettingsChangeLog(fileURL: url)
        log.record(change("First"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        log.record(change("Second"))
        #expect(SettingsChangeLog(fileURL: url).changes.map(\.name) == ["First", "Second"])
    }

    @Test func aFileThatIsntARecordIsSetAsideNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsChangeLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("changes.json")
        try "{ not a list".write(to: url, atomically: true, encoding: .utf8)
        let log = SettingsChangeLog(fileURL: url)
        log.record(change())
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.hasPrefix("changes.unreadable-") })
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

    /// A source's display name needn't hold its folder's name: Google Drive's folder is
    /// GoogleDrive-a@b.com, its name Google Drive (a@b.com). A change made before the folder was
    /// hidden goes by its target, then; one with no target by its words alone.
    @Test func aChangeOnASourceHiddenSinceIsShownWithoutItsWords() {
        let url = file(); defer { try? FileManager.default.removeItem(at: url) }
        let log = SettingsChangeLog(fileURL: url)
        log.record(SettingsChange(setting: "sources.openAt", target: "GoogleDrive-a@b.com", name: "Open at for Google Drive (a@b.com)",
                                  from: "My Drive", to: "My Drive/Work", fromLabel: "My Drive", toLabel: "My Drive/Work", how: .card))
        log.record(change())
        let hidden = { (target: String) in target == "GoogleDrive-a@b.com" }
        let shown = log.visible(hiding: ["GoogleDrive-a@b.com"], hidingTargets: hidden)
        #expect(shown.map(\.name) == ["Theme", "A change about an item hidden from Claude"])
        #expect(shown[1].from == nil && shown[1].toLabel == nil)
        #expect(log.visible(hiding: ["GoogleDrive-a@b.com"]).last?.name == "Open at for Google Drive (a@b.com)")
    }
}

/// Off the main actor: resolving the test file sweeps the temp directory, which can take over a
/// second with a crowded temp directory and starve other suites' main-actor waits.
@Suite struct SettingsChangeLogFileTests {
    @Test func aTestRunNeverWritesTheRealFile() {
        #expect(SettingsChangeLog.defaultFileURL().path != NSHomeDirectory() + "/sync-cloud-settings-changes.json")
    }
}
