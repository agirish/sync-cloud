import Foundation
import Testing
@testable import Sync

/// Past Chats' folder (TE306): kept by the last question's date, pruned and cleared as Settings says.
@Suite struct AskClaudePastChatFilesTests {

    private func files() -> AskClaudePastChatFiles {
        AskClaudePastChatFiles(folder: FileManager.default.temporaryDirectory.appendingPathComponent("PastChats-\(UUID().uuidString)"))
    }

    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    @Test func thirtyDaysIsTheDefaultAndAnUnknownValueFallsBackToIt() {
        let d = UserDefaults(suiteName: "AskClaudePastChatFilesTests-\(UUID().uuidString)")!
        #expect(AskClaudePastChatKeep.stored(in: d) == .month)
        d.set("fortnight", forKey: AskClaudePastChatKeep.defaultsKey)
        #expect(AskClaudePastChatKeep.stored(in: d) == .month)
        d.set("forever", forKey: AskClaudePastChatKeep.defaultsKey)
        #expect(AskClaudePastChatKeep.stored(in: d).days == nil)
    }

    @Test func pruningGoesByTheLastQuestionNotWhenTheChatWasPutAway() throws {
        let files = files()
        defer { try? FileManager.default.removeItem(at: files.folder) }
        let old = UUID(), recent = UUID()
        try files.write(Data("{}".utf8), id: old, lastAsked: now.addingTimeInterval(-31 * 86_400))
        try files.write(Data("{}".utf8), id: recent, lastAsked: now.addingTimeInterval(-29 * 86_400))
        try Data("x".utf8).write(to: files.folder.appendingPathComponent("notes.txt"))
        #expect(files.entries().map(\.id) == [recent, old])
        #expect(files.expired(keep: .forever, now: now).isEmpty)
        #expect(files.expired(keep: .week, now: now).count == 2)
        #expect(files.prune(keep: .month, now: now) == 1)
        #expect(files.entries().map(\.id) == [recent])
        // Not a chat's file: left alone.
        #expect(FileManager.default.fileExists(atPath: files.folder.appendingPathComponent("notes.txt").path))
    }

    @Test func clearAllDeletesEveryChatAndDescribeCountsThem() throws {
        let files = files()
        defer { try? FileManager.default.removeItem(at: files.folder) }
        #expect(AskClaudePastChatFiles.describe(files.entries()) == nil)
        try files.write(Data(repeating: 1, count: 2_000), id: UUID(), lastAsked: now)
        try files.write(Data(repeating: 1, count: 2_000), id: UUID(), lastAsked: now)
        #expect(AskClaudePastChatFiles.describe(files.entries())?.hasPrefix("2 chats, ") == true)
        #expect(files.clearAll() == 2)
        #expect(files.entries().isEmpty)
    }

    /// Decision LL: a reset must not delete chats kept "until I delete them".
    @Test func resetAllSettingsKeepsHowLongChatsAreKept() {
        #expect(SettingsResetKeeps.keys.contains(AskClaudePastChatKeep.defaultsKey))
    }
}
