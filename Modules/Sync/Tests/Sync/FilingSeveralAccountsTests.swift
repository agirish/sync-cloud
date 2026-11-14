import Testing
import Foundation
@testable import Sync

/// A statement printing two accounts' own numbers (decision 11) files into the first and is copied
/// into the other, one ⌘Z for both; a "file once" preference, at the narrowest scope that applies,
/// stops the copy.
@MainActor
@Suite struct FilingSeveralAccountsTests {

    private nonisolated static let page = """
        Fidelity Investments INVESTMENT REPORT
        Statement Period: March 1, 2026 through March 31, 2026
        Brokerage Account Number: Z26-141750
        Roth IRA Account Number: 228-344657
        """

    private func fixture(_ prefix: String) throws -> (root: URL, docs: URL, inbox: URL, file: URL, m: FileSyncManager) {
        let root = try makeCanonicalTempRoot(prefix: prefix)
        let docs = root.appendingPathComponent("Docs")
        for (i, month) in ["Jan", "Feb", "Mar", "Apr", "May", "Jun"].enumerated() {
            for acct in ["Brokerage 1750", "Roth IRA 4657"] {
                try writeBytes(docs.appendingPathComponent(String(format: "Investments/Fidelity/\(acct)/2025/%02d. %@ 2025.pdf", i + 1, month)),
                               Data(repeating: UInt8(i), count: 64 + acct.count))
            }
        }
        let inbox = root.appendingPathComponent("Inbox")
        let file = inbox.appendingPathComponent("Fidelity/03. Mar 2026.pdf")
        try writeBytes(file, Data(repeating: 0x5A, count: 80))
        let m = FileSyncManager()
        m.filingRuleDefaults = ScratchDefaults("FilingSeveralAccounts." + prefix)
        m.filingContentExtractor = { _ in [] }
        m.filingTokensFromText = { _ in [] }
        m.filingSnippetExtractor = { $0 == file.path ? Self.page : nil }
        m.setFilingScansSubfolders(true, for: inbox.path)
        return (root, docs, inbox, file, m)
    }

    @Test func aStatementNamingTwoAccountsIsFiledInTheFirstAndCopiedToTheOther() async throws {
        let f = try fixture("Copy")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let undo = UndoManager()
        f.m.undoManager = undo
        await f.m.findFilingSuggestions(folder: f.inbox, providerRoot: f.docs)
        let card = try #require(f.m.filingSuggestions.first { $0.filePath == f.file.path })
        let best = try #require(card.best)
        #expect(best.path == f.docs.path + "/Investments/Fidelity/Brokerage 1750/2026", "\(best.path)")
        #expect(best.confidence == .high)
        #expect(best.alsoCopiesTo.map(\.path) == [f.docs.path + "/Investments/Fidelity/Roth IRA 4657/2026"])
        #expect(await f.m.applyFilingSuggestion(card, to: best) == .moved)
        let main = f.docs.path + "/Investments/Fidelity/Brokerage 1750/2026/03. Mar 2026.pdf"
        let copy = f.docs.path + "/Investments/Fidelity/Roth IRA 4657/2026/03. Mar 2026.pdf"
        #expect(FileManager.default.fileExists(atPath: main) && FileManager.default.fileExists(atPath: copy))
        #expect(f.m.ignoredDuplicateKeys.contains([main, copy].sorted().joined(separator: "\n")), "copies on purpose")
        undo.undo()
        let deadline = Date().addingTimeInterval(10)
        while (!FileManager.default.fileExists(atPath: f.file.path) || FileManager.default.fileExists(atPath: copy)),
              Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(FileManager.default.fileExists(atPath: f.file.path), "one ⌘Z moves it back")
        #expect(!FileManager.default.fileExists(atPath: copy), "and takes the copy away")
    }

    @Test func fileOnceAtTheNarrowestScopeStopsTheCopy() async throws {
        let f = try fixture("Once")
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.m.setFilingPreference(FilingPreference(scope: .institution("fidelity"), copies: false, label: "Fidelity"))
        await f.m.findFilingSuggestions(folder: f.inbox, providerRoot: f.docs)
        var best = try #require(f.m.filingSuggestions.first { $0.filePath == f.file.path }?.best)
        #expect(best.alsoCopiesTo.isEmpty)
        #expect(best.reasons.contains { $0.contains("filed once") }, "\(best.reasons)")
        // An account-level "copy" beats the bank-level "file once".
        f.m.setFilingPreference(FilingPreference(scope: .account(institution: "fidelity", ending: "4657"), copies: true,
                                                 label: "Fidelity ••4657"))
        await f.m.findFilingSuggestions(folder: f.inbox, providerRoot: f.docs)
        best = try #require(f.m.filingSuggestions.first { $0.filePath == f.file.path }?.best)
        #expect(best.alsoCopiesTo.count == 1)
        // File Once Here, just this time.
        let card = try #require(f.m.filingSuggestions.first { $0.filePath == f.file.path })
        #expect(await f.m.applyFilingSuggestion(card, to: best, fileOnce: true) == .moved)
        #expect(FileManager.default.fileExists(atPath: f.docs.path + "/Investments/Fidelity/Brokerage 1750/2026/03. Mar 2026.pdf"))
        #expect(!FileManager.default.fileExists(atPath: f.docs.path + "/Investments/Fidelity/Roth IRA 4657/2026"))
    }

    @Test func oneNumberAtTwoAccountsIsStillAmbiguous() {
        func file(_ p: String) -> FileNode { FileNode(id: "/D/" + p, name: (p as NSString).lastPathComponent, isDirectory: false, fileSize: 9000) }
        func dir(_ p: String, _ c: [FileNode]) -> FileNode { FileNode(id: "/D/" + p, name: (p as NSString).lastPathComponent, isDirectory: true, children: c) }
        func acct(_ p: String) -> FileNode { dir(p, [dir(p + "/2025", (1...6).map { file(p + String(format: "/2025/eStmt_2025-%02d-28.pdf", $0)) })]) }
        let tree = [dir("Fidelity", [acct("Fidelity/Brokerage 1750"), acct("Fidelity/Joint 1750")])]
        let index = AccountIndex.build(tree: tree)
        let facts = DocumentFacts(page: "Fidelity Investments\nStatement Period: March 1, 2026 through March 31, 2026\nAccount Number: Z26-141750")
        if case .ambiguous = index.match(facts) {} else { Issue.record("\(index.match(facts))") }
        let preferences = [FilingPreference(scope: .statements, copies: false, label: "statements"),
                           FilingPreference(scope: .all, copies: true, label: "everything")]
        let a = FilingAccount(root: "/x", ending: "1750", institution: "fidelity", archived: false, kind: .statement)
        #expect(!FilingPreference.copies(into: a, kind: .statement, preferences: preferences), "statements is narrower than everything")
        #expect(FilingPreference.copies(into: a, kind: .other, preferences: preferences))
    }
}
