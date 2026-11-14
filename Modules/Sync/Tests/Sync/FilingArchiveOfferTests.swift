import Testing
import Foundation
@testable import Sync

/// New statements for an account in an archive (decision 9): offered a move out of the archive
/// when they are newer than anything it holds; the move, the filing and the re-pointing are one ⌘Z.
@MainActor
@Suite struct FilingArchiveOfferTests {

    private nonisolated static func page(_ month: String) -> String {
        "Charles Schwab & Co., Inc.\nStatement Period: \(month) 1, 2026 to \(month) 28, 2026\nRoth IRA Account Number: 4401-2336"
    }

    /// The archived account and two inbox statements; `months` names their periods.
    /// `flat`: the account keeps its statements loose in its own folder, no year folders.
    private func fixture(_ prefix: String, archive: String, months: [String] = ["March", "April"], flat: Bool = false,
                         cloudOnly: Bool = false)
        async throws -> (root: URL, docs: URL, m: FileSyncManager, group: FilingCardGroup, undo: UndoManager) {
        let root = try makeCanonicalTempRoot(prefix: prefix)
        let docs = root.appendingPathComponent("Docs")
        for (i, month) in ["Jan", "Feb", "Mar", "Apr", "May", "Jun"].enumerated() {
            let name = flat ? String(format: "/Statement_2025-%02d-28.pdf", i + 1) : String(format: "/2025/%02d. %@ 2025.pdf", i + 1, month)
            try writeBytes(URL(fileURLWithPath: docs.path + "/" + archive + name), Data(repeating: UInt8(i), count: 64))
        }
        let inbox = root.appendingPathComponent("Inbox")
        var pages: [String: String] = [:]
        for (i, month) in months.enumerated() {
            let f = inbox.appendingPathComponent("Schwab/\(i). \(month).pdf")
            try writeBytes(f, Data(repeating: UInt8(0x61 + i), count: 70 + i))
            // "May 2025": that year; a bare month is 2026.
            let parts = month.split(separator: " ")
            let year = parts.count == 2 ? String(parts[1]) : "2026"
            pages[f.path] = "Charles Schwab & Co., Inc.\nStatement Period: \(parts[0]) 1, \(year) to \(parts[0]) 28, \(year)\nRoth IRA Account Number: 4401-2336"
        }
        let m = FileSyncManager(defaults: ScratchDefaults("FilingArchiveOfferTests.1"))
        let undo = UndoManager()
        m.undoManager = undo
        m.filingContentExtractor = { _ in [] }
        m.filingTokensFromText = { _ in [] }
        let captured = pages
        m.filingSnippetExtractor = { captured[$0] }
        m.setFilingScansSubfolders(true, for: inbox.path)
        if cloudOnly { m.filingHoldsCloudOnlyFile = { _ in true } }
        await m.findFilingSuggestions(folder: inbox, providerRoot: docs)
        let item = try #require(FilingCardGrouping.items(m.filingSuggestions).first { if case .group = $0 { true } else { false } })
        guard case .group(let group) = item else { throw CancellationError() }
        return (root, docs, m, group, undo)
    }

    @Test func theBankFolderBetweenTheArchiveAndTheAccountStays() async throws {
        let f = try await fixture("Between", archive: "Investments/Archive/Charles Schwab/Roth IRA 2336")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let offer = try #require(f.m.archiveOffer(for: f.group))
        #expect(offer.target == f.docs.path + "/Investments/Charles Schwab/Roth IRA 2336", "\(offer.target)")
    }

    @Test func noOfferWhenOnlyOneIsNewerOrTheFolderBesideIsTaken() async throws {
        let one = try await fixture("OneNewer", archive: "Investments/Charles Schwab/Archive/Roth IRA 2336",
                                    months: ["May 2025", "August 2025"])
        defer { try? FileManager.default.removeItem(at: one.root) }
        #expect(one.group.toFile.count == 2, "one card for both, in its 2025 folder")
        #expect(one.m.archiveOffer(for: one.group) == nil, "only August is newer than June, the newest it holds")
        let taken = try await fixture("Taken", archive: "Investments/Charles Schwab/Archive/Roth IRA 2336")
        defer { try? FileManager.default.removeItem(at: taken.root) }
        let offer = try #require(taken.m.archiveOffer(for: taken.group))
        try FileManager.default.createDirectory(atPath: offer.target, withIntermediateDirectories: true)
        #expect(await taken.m.moveOutOfArchiveThenFile(taken.group, offer: offer) == 0)
        #expect(FileManager.default.fileExists(atPath: offer.accountFolder + "/2025/01. Jan 2025.pdf"), "nothing moved")
    }

    /// A ⌘Z whose folder move-back refuses (the folder changed since) leaves learned accounts
    /// pointing where the folder is, not at the empty archive path.
    @Test func aFolderThatCantGoBackKeepsWhatPointsAtIt() async throws {
        let f = try await fixture("NoBack", archive: "Investments/Charles Schwab/Archive/Roth IRA 2336")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let live = "Investments/Charles Schwab/Roth IRA 2336"
        f.m.filingLearnedAccounts = [LearnedAccount(id: UUID(), institution: "charles schwab", institutionName: "Charles Schwab",
                                                    ending: "9999", folder: "Investments/Charles Schwab/Archive/Roth IRA 2336",
                                                    surveyRoot: f.docs.path, taughtAt: Date(), taughtBy: .groupRedirect,
                                                    filedCount: 1, teaching: [])]
        let offer = try #require(f.m.archiveOffer(for: f.group))
        #expect(await f.m.moveOutOfArchiveThenFile(f.group, offer: offer) == 2)
        // He files something else into it before undoing.
        try writeBytes(URL(fileURLWithPath: offer.target + "/2027/other.pdf"), Data(repeating: 1, count: 9))
        f.undo.undo()
        // The statements back in the inbox, then every queued step of the same ⌘Z done.
        let deadline = Date().addingTimeInterval(10)
        while !f.group.toFile.allSatisfy({ FileManager.default.fileExists(atPath: $0.filePath) }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(f.group.toFile.allSatisfy { FileManager.default.fileExists(atPath: $0.filePath) })
        await f.m.enqueueFileOperation {}
        try await Task.sleep(for: .milliseconds(100))
        await f.m.enqueueFileOperation {}
        #expect(FileManager.default.fileExists(atPath: offer.target), "the folder stayed out of the archive")
        #expect(f.m.filingLearnedAccounts.first?.folder == live, "and what points at it still does")
    }

    @Test func newerStatementsOfferAMoveOutOfTheArchiveUndoneInOneStep() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingArchiveOffer")
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Docs")
        let archived = docs.path + "/Investments/Charles Schwab/Archive/Roth IRA 2336"
        for (i, month) in ["Jan", "Feb", "Mar", "Apr", "May", "Jun"].enumerated() {
            try writeBytes(URL(fileURLWithPath: archived + String(format: "/2025/%02d. %@ 2025.pdf", i + 1, month)),
                           Data(repeating: UInt8(i), count: 64))
            try writeBytes(docs.appendingPathComponent(String(format: "Investments/Charles Schwab/Brokerage 8071/2025/%02d. %@ 2025.pdf", i + 1, month)),
                           Data(repeating: UInt8(i + 10), count: 64))
        }
        let inbox = root.appendingPathComponent("Inbox")
        let mar = inbox.appendingPathComponent("Schwab/03. Mar 2026.pdf")
        let apr = inbox.appendingPathComponent("Schwab/04. Apr 2026.pdf")
        try writeBytes(mar, Data(repeating: 0x61, count: 70))
        try writeBytes(apr, Data(repeating: 0x62, count: 71))
        let m = FileSyncManager(defaults: ScratchDefaults("FilingArchiveOfferTests.2"))
        let undo = UndoManager()
        m.undoManager = undo
        m.filingContentExtractor = { _ in [] }
        m.filingTokensFromText = { _ in [] }
        m.filingSnippetExtractor = {
            switch $0 {
            case mar.path: return Self.page("March")
            case apr.path: return Self.page("April")
            default: return nil
            }
        }
        m.setFilingScansSubfolders(true, for: inbox.path)
        await m.findFilingSuggestions(folder: inbox, providerRoot: docs)
        m.filingLearnedAccounts = [LearnedAccount(id: UUID(), institution: "charles schwab", institutionName: "Charles Schwab",
                                                  ending: "9999", folder: "Investments/Charles Schwab/Archive/Roth IRA 2336",
                                                  surveyRoot: docs.path, taughtAt: Date(), taughtBy: .groupRedirect,
                                                  filedCount: 1, teaching: [])]
        guard case .group(let group) = try #require(FilingCardGrouping.items(m.filingSuggestions).first { 
            if case .group = $0 { return true } else { return false } }) else { Issue.record("no group"); return }
        #expect(group.account.archived)
        let offer = try #require(m.archiveOffer(for: group))
        let live = docs.path + "/Investments/Charles Schwab/Roth IRA 2336"
        #expect(offer.target == live && offer.archiveName == "Archive")

        #expect(await m.moveOutOfArchiveThenFile(group, offer: offer) == 2)
        #expect(FileManager.default.fileExists(atPath: live + "/2026/03. Mar 2026.pdf"))
        #expect(!FileManager.default.fileExists(atPath: archived))
        #expect(m.filingLearnedAccounts.first?.folder == "Investments/Charles Schwab/Roth IRA 2336", "re-pointed")

        undo.undo()
        let deadline = Date().addingTimeInterval(10)
        // The re-point waits in the file-operation queue behind the moves back: wait for it too.
        while !(FileManager.default.fileExists(atPath: archived) && FileManager.default.fileExists(atPath: mar.path)
                && m.filingLearnedAccounts.first?.folder == "Investments/Charles Schwab/Archive/Roth IRA 2336"),
              Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(FileManager.default.fileExists(atPath: mar.path) && FileManager.default.fileExists(atPath: apr.path),
                "one ⌘Z puts the statements back")
        #expect(FileManager.default.fileExists(atPath: archived + "/2025/01. Jan 2025.pdf"), "and the account back in the archive")
        #expect(!FileManager.default.fileExists(atPath: live))
        #expect(m.filingLearnedAccounts.first?.folder == "Investments/Charles Schwab/Archive/Roth IRA 2336")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// The bank folder exists only inside the archive: the move makes it beside, and ⌘Z removes it.
    @Test func theMoveMakesTheBankFolderAndUndoTakesItAway() async throws {
        let f = try await fixture("Parent", archive: "Investments/Archive/Charles Schwab/Roth IRA 2336")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let offer = try #require(f.m.archiveOffer(for: f.group))
        #expect(await f.m.moveOutOfArchiveThenFile(f.group, offer: offer) == 2)
        #expect(FileManager.default.fileExists(atPath: offer.target + "/2026"))
        f.undo.undo()
        try await waitUntil { FileManager.default.fileExists(atPath: offer.accountFolder)
            && !FileManager.default.fileExists(atPath: (offer.target as NSString).deletingLastPathComponent) }
        #expect(FileManager.default.fileExists(atPath: offer.accountFolder + "/2025/01. Jan 2025.pdf"))
        #expect(!FileManager.default.fileExists(atPath: (offer.target as NSString).deletingLastPathComponent),
                "the bank folder it made is gone")
        #expect(!FileManager.default.fileExists(atPath: offer.accountFolder + "/2026"), "and the year it made")
    }

    /// Statements loose in the account's own folder: ⌘Z still puts the account back in the archive.
    @Test func aFlatAccountGoesBackIntoTheArchive() async throws {
        let f = try await fixture("Flat", archive: "Investments/Charles Schwab/Archive/Roth IRA 2336", flat: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let offer = try #require(f.m.archiveOffer(for: f.group))
        #expect(await f.m.moveOutOfArchiveThenFile(f.group, offer: offer) == 2)
        f.undo.undo()
        try await waitUntil { FileManager.default.fileExists(atPath: offer.accountFolder) }
        #expect(FileManager.default.fileExists(atPath: offer.accountFolder + "/Statement_2025-01-28.pdf"), "back in the archive")
        #expect(!FileManager.default.fileExists(atPath: offer.target))
    }

    /// ⇧⌘Z moves it out again and points what referred to it there too.
    @Test func redoMovesItOutAndPointsThere() async throws {
        let f = try await fixture("Redo", archive: "Investments/Charles Schwab/Archive/Roth IRA 2336")
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.m.filingLearnedAccounts = [LearnedAccount(id: UUID(), institution: "charles schwab", institutionName: "Charles Schwab",
                                                    ending: "9999", folder: "Investments/Charles Schwab/Archive/Roth IRA 2336",
                                                    surveyRoot: f.docs.path, taughtAt: Date(), taughtBy: .groupRedirect,
                                                    filedCount: 1, teaching: [])]
        let offer = try #require(f.m.archiveOffer(for: f.group))
        #expect(await f.m.moveOutOfArchiveThenFile(f.group, offer: offer) == 2)
        f.undo.undo()
        try await waitUntil { f.m.filingLearnedAccounts.first?.folder == "Investments/Charles Schwab/Archive/Roth IRA 2336" }
        #expect(f.undo.canRedo)
        f.undo.redo()
        try await waitUntil { f.m.filingLearnedAccounts.first?.folder == "Investments/Charles Schwab/Roth IRA 2336" }
        #expect(FileManager.default.fileExists(atPath: offer.target + "/2025/01. Jan 2025.pdf"), "out again")
        #expect(f.m.filingLearnedAccounts.first?.folder == "Investments/Charles Schwab/Roth IRA 2336", "and pointed there")
    }

    @Test func aStatementOnlyInTheCloudRefusesTheMove() async throws {
        let f = try await fixture("Cloud", archive: "Investments/Charles Schwab/Archive/Roth IRA 2336", cloudOnly: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let offer = try #require(f.m.archiveOffer(for: f.group))
        #expect(await f.m.moveOutOfArchiveThenFile(f.group, offer: offer) == 0)
        #expect(FileManager.default.fileExists(atPath: offer.accountFolder + "/2025/01. Jan 2025.pdf"), "nothing moved")
        #expect(f.group.toFile.allSatisfy { FileManager.default.fileExists(atPath: $0.filePath) })
    }
}
