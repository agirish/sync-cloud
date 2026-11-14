import Testing
import Foundation
@testable import Sync

/// What the review of the statement-filing overhaul found in filing itself: folders a filing makes
/// leave with its ⌘Z, a group's chosen folder is checked like a typed one, a one-level scan keeps
/// the folders below as homes, File Once Here for one account still copies to the others, and what
/// is learned outlives the manager.
@MainActor
@Suite struct FilingReviewApplyTests {

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func undoTakesAwayTheFoldersAFilingMade() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingReviewMade")
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Docs")
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("Bank Accounts/Chase"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("In/03. Mar 2026.pdf")
        try writeBytes(file, Data(repeating: 1, count: 40))
        let m = FileSyncManager(defaults: ScratchDefaults("FilingReviewApplyTests.made"))
        let undo = UndoManager()
        m.undoManager = undo
        let account = docs.path + "/Bank Accounts/Chase/Checking 0779"
        let dest = FilingDestination(path: account + "/2026", confidence: .medium, reasons: ["No folder holds Chase ••0779"],
                                     newSegments: ["Checking 0779", "2026"], fromContent: true,
                                     account: FilingAccount(root: account, ending: "0779", institution: "chase", archived: false, kind: .statement))
        let card = FilingSuggestion(filePath: file.path, fileName: file.lastPathComponent, size: 40, modificationDate: nil,
                                    candidates: [dest], providerRoot: docs.path)
        #expect(await m.applyFilingSuggestion(card, to: dest) == .moved)
        #expect(FileManager.default.fileExists(atPath: account + "/2026/03. Mar 2026.pdf"))
        undo.undo()
        try await waitUntil { FileManager.default.fileExists(atPath: file.path) && !FileManager.default.fileExists(atPath: account) }
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: account), "no empty account folder for the next scan to read as real")
        #expect(FileManager.default.fileExists(atPath: docs.path + "/Bank Accounts/Chase"), "what was there stays")
    }

    @Test func aGroupsChosenFolderIsCheckedLikeATypedOne() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingReviewChosen")
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Docs")
        let account = docs.appendingPathComponent("IRA 7863")
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("TODO/Later"), withIntermediateDirectories: true)
        var cards: [FilingSuggestion] = []
        for n in ["01", "02"] {
            let f = docs.appendingPathComponent("TODO/\(n).pdf")
            try writeBytes(f, Data(repeating: 2, count: 40))
            let dest = FilingDestination(path: account.path, confidence: .high, reasons: ["r"], newSegments: [], fromContent: true,
                                         account: FilingAccount(root: account.path, ending: "7863", institution: "x", archived: false, kind: .statement))
            cards.append(FilingSuggestion(filePath: f.path, fileName: "\(n).pdf", size: 40, modificationDate: nil,
                                          candidates: [dest], providerRoot: docs.path))
        }
        let m = FileSyncManager(defaults: ScratchDefaults("FilingReviewApplyTests.chosen"))
        m.filingLastProviderRoot = docs.path
        guard case .group(let group) = FilingCardGrouping.items(cards)[0] else { Issue.record("no group"); return }
        #expect(await m.applyFilingGroup(group, into: docs.path + "/TODO/Later") == 0, "an inbox is never a home")
        #expect(FileManager.default.fileExists(atPath: cards[0].filePath))
    }

    @Test func aOneLevelScanKeepsTheFoldersBelowAsHomes() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingReviewOneLevel")
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Docs")
        let chase = docs.appendingPathComponent("Finance/Chase")
        for (i, month) in ["Jan", "Feb", "Mar", "Apr", "May", "Jun"].enumerated() {
            try writeBytes(chase.appendingPathComponent(String(format: "Checking 1234/2025/%02d. %@ 2025.pdf", i + 1, month)),
                           Data(repeating: UInt8(i), count: 50))
        }
        let loose = chase.appendingPathComponent("03. Mar 2026.pdf")
        try writeBytes(loose, Data(repeating: 9, count: 51))
        let m = FileSyncManager(defaults: ScratchDefaults("FilingReviewApplyTests.onelevel"))
        m.filingContentExtractor = { _ in [] }
        m.filingTokensFromText = { _ in [] }
        m.filingSnippetExtractor = { $0 == loose.path ? "JPMorgan Chase Bank\nStatement Period: March 1, 2026 through March 28, 2026\nAccount Number: 000012341234" : nil }
        await m.findFilingSuggestions(folder: chase, providerRoot: docs)
        let best = try #require(m.filingSuggestions.first { $0.filePath == loose.path }?.best)
        #expect(best.path == chase.path + "/Checking 1234/2026", "as in v7.1: \(best.path)")
    }

    @Test func fileOnceForOneAccountStillCopiesToTheOthers() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingReviewExcept")
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Docs")
        let file = root.appendingPathComponent("In/03. Mar 2026.pdf")
        try writeBytes(file, Data(repeating: 3, count: 40))
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("Fidelity/Brokerage 1750"), withIntermediateDirectories: true)
        func acct(_ name: String, _ ending: String) -> FilingCopy {
            FilingCopy(path: docs.path + "/Fidelity/\(name)", proposedName: nil,
                       account: FilingAccount(root: docs.path + "/Fidelity/\(name)", ending: ending, institution: "fidelity", archived: false, kind: .statement))
        }
        var dest = FilingDestination(path: docs.path + "/Fidelity/Brokerage 1750", confidence: .high, reasons: ["r"], newSegments: [], fromContent: true)
        dest.alsoCopiesTo = [acct("Roth IRA 4657", "4657"), acct("HSA 0012", "0012")]
        let card = FilingSuggestion(filePath: file.path, fileName: file.lastPathComponent, size: 40, modificationDate: nil,
                                    candidates: [dest], providerRoot: docs.path)
        let m = FileSyncManager(defaults: ScratchDefaults("FilingReviewApplyTests.except"))
        #expect(await m.applyFilingSuggestion(card, to: dest, exceptCopiesTo: [docs.path + "/Fidelity/Roth IRA 4657"]) == .moved)
        #expect(!FileManager.default.fileExists(atPath: docs.path + "/Fidelity/Roth IRA 4657/03. Mar 2026.pdf"))
        #expect(FileManager.default.fileExists(atPath: docs.path + "/Fidelity/HSA 0012/03. Mar 2026.pdf"), "the other copy is still made")
    }

    @Test func lessonsAndPreferencesOutliveTheManagerUntilRemoved() {
        let defaults = ScratchDefaults("FilingReviewApplyTests.persist")
        let a = FileSyncManager(defaults: defaults)
        a.filingLearnedAccounts = [LearnedAccount(id: UUID(), institution: "chase", institutionName: "Chase", ending: "4139",
                                                  folder: "Bank/Chase/Joint", surveyRoot: "/D", taughtAt: Date(),
                                                  taughtBy: .groupRedirect, filedCount: 2, teaching: [])]
        a.setFilingPreference(FilingPreference(scope: .institution("fidelity"), copies: false, label: "Fidelity"))
        let b = FileSyncManager(defaults: defaults)
        #expect(b.filingLearnedAccounts.map(\.ending) == ["4139"])
        #expect(b.filingPreferences.map(\.label) == ["Fidelity"])
        b.removeLearnedAccount(id: b.filingLearnedAccounts[0].id)
        b.removeFilingPreference(id: b.filingPreferences[0].id)
        let c = FileSyncManager(defaults: defaults)
        #expect(c.filingLearnedAccounts.isEmpty && c.filingPreferences.isEmpty)
    }
}
