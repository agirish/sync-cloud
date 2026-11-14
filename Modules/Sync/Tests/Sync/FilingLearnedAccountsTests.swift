import Testing
import Foundation
@testable import Sync

/// An account taught by filing its statements somewhere To File didn't offer (decision 8): the next
/// statement printing that number files there, a folder name carrying the number still wins, and
/// Undo of the teaching filing forgets it.
@MainActor
@Suite struct FilingLearnedAccountsTests {

    private struct Fixture {
        let root: URL
        let docs: URL
        let inbox: URL
        let m: FileSyncManager
    }

    /// A tree whose Chase checking folder names no number (`Joint Checking`), and a named Chase
    /// credit account so the bank is known.
    private func fixture(_ prefix: String) throws -> Fixture {
        let root = try makeCanonicalTempRoot(prefix: prefix)
        let docs = root.appendingPathComponent("Docs")
        for (i, month) in ["Jan", "Feb", "Mar", "Apr", "May", "Jun"].enumerated() {
            try writeBytes(docs.appendingPathComponent(String(format: "Bank Accounts/Chase/Joint Checking/2025/%02d. %@ 2025.pdf", i + 1, month)),
                           Data(repeating: 0x41, count: 64))
            try writeBytes(docs.appendingPathComponent(String(format: "Credit Accounts/Chase/Credit 1768/2025/%02d. %@ 2025.pdf", i + 1, month)),
                           Data(repeating: 0x42, count: 64))
        }
        let m = FileSyncManager(defaults: ScratchDefaults("FilingLearnedAccountsTests.1"))
        m.filingContentExtractor = { _ in [] }
        m.filingTokensFromText = { _ in [] }
        let inbox = root.appendingPathComponent("Inbox")
        m.setFilingScansSubfolders(true, for: inbox.path)
        return Fixture(root: root, docs: docs, inbox: inbox, m: m)
    }

    private nonisolated static func statement(_ ending: String, month: String, kind: String = "Statement Period") -> String {
        "JPMorgan Chase Bank\n\(kind): \(month) 1, 2026 through \(month) 28, 2026\nAccount Number: 000012345\(ending)\nA PERSON"
    }

    private func write(_ f: Fixture, _ name: String) throws -> URL {
        let url = f.inbox.appendingPathComponent(name)
        try writeBytes(url, Data(repeating: UInt8(name.count), count: 64))
        return url
    }

    @Test func aStatementFiledWithRememberTeachesItsAccount() async throws {
        let f = try fixture("Teach")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try write(f, "Chase/03. Mar 2026.pdf")
        f.m.filingSnippetExtractor = { $0 == first.path ? Self.statement("4139", month: "March") : nil }
        await f.m.findFilingSuggestions(folder: f.inbox, providerRoot: f.docs)
        let card = try #require(f.m.filingSuggestions.first { $0.filePath == first.path })
        #expect(card.best?.confidence != .high, "nothing names ••4139 yet")
        #expect(f.m.rememberableEnding(for: [card]) == "4139")
        let chosen = f.docs.path + "/Bank Accounts/Chase/Joint Checking/2026"
        let result = await f.m.applyFilingSuggestion(
            card, to: FilingDestination(path: chosen, confidence: .high, reasons: ["You chose this folder"], newSegments: ["2026"]),
            teachAccount: true)
        #expect(result == .moved)
        let learned = try #require(f.m.filingLearnedAccounts.first)
        #expect(learned.folder == "Bank Accounts/Chase/Joint Checking", "the account, not its year")
        #expect(learned.ending == "4139" && learned.institution == "chase" && learned.institutionName == "Chase")

        // The next statement printing ••4139 goes there at High, placed by year.
        let next = try write(f, "Chase/04. Apr 2026.pdf")
        f.m.filingSnippetExtractor = { $0 == next.path ? Self.statement("4139", month: "April") : nil }
        await f.m.findFilingSuggestions(folder: f.inbox, providerRoot: f.docs)
        let best = try #require(f.m.filingSuggestions.first { $0.filePath == next.path }?.best)
        #expect(best.path == chosen, "\(best.path)")
        #expect(best.confidence == .high)
    }

    @Test func aNumberAFolderNameCarriesIsNotTaught() async throws {
        let f = try fixture("Named")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let file = try write(f, "Chase/03. Mar 2026.pdf")
        f.m.filingSnippetExtractor = { $0 == file.path ? Self.statement("1768", month: "March") : nil }
        await f.m.findFilingSuggestions(folder: f.inbox, providerRoot: f.docs)
        let card = try #require(f.m.filingSuggestions.first { $0.filePath == file.path })
        #expect(card.best?.account?.isNamedByFolder == true, "Credit 1768 names it")
        #expect(await f.m.applyFilingSuggestion(
            card, to: FilingDestination(path: f.docs.path + "/Bank Accounts/Chase/Joint Checking", confidence: .high,
                                        reasons: ["r"], newSegments: []), teachAccount: true) == .moved)
        #expect(f.m.filingLearnedAccounts.isEmpty, "Credit 1768's name would outrank it; nothing to list")
    }

    @Test func nothingIsLearnedWithoutANumberOrFromATaxForm() async throws {
        let f = try fixture("Nothing")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let plain = try write(f, "Chase/03. Mar 2026.pdf")
        let form = try write(f, "Chase/1099.pdf")
        f.m.filingSnippetExtractor = {
            switch $0 {
            case plain.path: return "JPMorgan Chase Bank\nStatement Period: March 1, 2026 through March 28, 2026\nA PERSON"
            case form.path: return "JPMorgan Chase Bank\nForm 1099-INT Tax Year 2025\nAccount Number: 0000123454139"
            default: return nil
            }
        }
        await f.m.findFilingSuggestions(folder: f.inbox, providerRoot: f.docs)
        let cards = f.m.filingSuggestions.filter { [plain.path, form.path].contains($0.filePath) }
        #expect(cards.count == 2)
        for card in cards {
            #expect(f.m.rememberableEnding(for: [card]) == nil, "\(card.fileName)")
            let dest = FilingDestination(path: f.docs.path + "/Bank Accounts/Chase/Joint Checking",
                                         confidence: .high, reasons: ["r"], newSegments: [])
            #expect(await f.m.applyFilingSuggestion(card, to: dest, teachAccount: true) == .moved, "\(card.fileName)")
        }
        #expect(f.m.filingLearnedAccounts.isEmpty)
    }

    @Test func undoingTheFilingThatTaughtItForgetsIt() async throws {
        let f = try fixture("Undo")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let undo = UndoManager()
        f.m.undoManager = undo
        let file = try write(f, "Chase/03. Mar 2026.pdf")
        f.m.filingSnippetExtractor = { $0 == file.path ? Self.statement("4139", month: "March") : nil }
        await f.m.findFilingSuggestions(folder: f.inbox, providerRoot: f.docs)
        let card = try #require(f.m.filingSuggestions.first { $0.filePath == file.path })
        #expect(await f.m.applyFilingSuggestion(
            card, to: FilingDestination(path: f.docs.path + "/Bank Accounts/Chase/Joint Checking", confidence: .high,
                                        reasons: ["r"], newSegments: []), teachAccount: true) == .moved)
        #expect(f.m.filingLearnedAccounts.count == 1)
        f.m.forgetUndoneLearnedAccounts()
        #expect(f.m.filingLearnedAccounts.count == 1, "still filed: still taught")
        #expect(f.m.filingLearnedAccounts.first?.filedCount == 1, "counted once")
        undo.undo()
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: file.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: file.path), "Undo put it back")
        // The same ⌘Z forgets it, once the file is back: no rescan needed.
        let forgetDeadline = Date().addingTimeInterval(10)
        while !f.m.filingLearnedAccounts.isEmpty, Date() < forgetDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(f.m.filingLearnedAccounts.isEmpty, "forgotten by the undo itself")
        // And the next scan doesn't offer it: the statement isn't offered the undone lesson.
        await f.m.findFilingSuggestions(folder: f.inbox, providerRoot: f.docs)
        #expect(f.m.filingLearnedAccounts.isEmpty)
        let again = try #require(f.m.filingSuggestions.first { $0.filePath == file.path })
        #expect(again.best?.confidence != .high, "\(again.best?.path ?? "")")
    }

    /// The index side: a folder whose name carries the number at the same bank outranks what was
    /// learned; two learned folders for one number stay ambiguous; a learned folder gone is unused.
    @Test func whatTheTreeSaysOutranksALearnedAccount() {
        func file(_ p: String) -> FileNode { FileNode(id: "/D/" + p, name: (p as NSString).lastPathComponent, isDirectory: false, fileSize: 9000) }
        func dir(_ p: String, _ c: [FileNode]) -> FileNode { FileNode(id: "/D/" + p, name: (p as NSString).lastPathComponent, isDirectory: true, children: c) }
        let named = "Bank Accounts/Chase/Checking 4139"
        let joint = "Bank Accounts/Chase/Joint Checking"
        let other = "Bank Accounts/Chase/Household"
        let tree = [dir("Bank Accounts", [dir("Bank Accounts/Chase", [
            dir(named, [dir(named + "/2025", (1...6).map { file(named + String(format: "/2025/eStmt_2025-%02d-28.pdf", $0)) })]),
            dir(joint, []), dir(other, []),
        ])])]
        let base = AccountIndex.build(tree: tree)
        func learned(_ folder: String, _ ending: String) -> LearnedAccount {
            LearnedAccount(id: UUID(), institution: "chase", institutionName: "Chase", ending: ending, folder: folder,
                           surveyRoot: "/D", taughtAt: Date(), taughtBy: .singleRedirect, filedCount: 1, teaching: [])
        }
        let facts = DocumentFacts(page: "JPMorgan Chase Bank\nStatement Period: March 1, 2026 through March 28, 2026\nAccount Number: 000012344139")
        #expect(base.adding(learned: [learned(joint, "4139")], root: "/D", tree: tree).match(facts).account?.root == named)
        let two = base.adding(learned: [learned(joint, "5555"), learned(other, "5555")], root: "/D", tree: tree)
        let factsB = DocumentFacts(page: "JPMorgan Chase Bank\nStatement Period: March 1, 2026 through March 28, 2026\nAccount Number: 000012345555")
        if case .ambiguous(let accounts) = two.match(factsB) {
            #expect(Set(accounts.map(\.root)) == [joint, other])
        } else { Issue.record("expected two accounts for one number: \(two.match(factsB))") }
        let gone = base.adding(learned: [learned("Bank Accounts/Chase/Gone", "7777")], root: "/D", tree: tree)
        #expect(gone.accounts.count == base.accounts.count)
        let elsewhere = base.adding(learned: [learned(joint, "7777")], root: "/Other", tree: tree)
        #expect(elsewhere.accounts.count == base.accounts.count, "another tree's lesson")
        #expect(FileSyncManager.accountFolder(of: "A/Checking/2026/03. Mar") == "A/Checking")
        // An account learned from reading its statements (no number in its name) gives the number
        // up to a lesson.
        let read = AccountIndex(accounts: base.accounts + [AccountIndex.Account(root: other, identities: ["8888"], institution: "chase", archived: false)],
                                institutionTokens: base.institutionTokens)
        let factsC = DocumentFacts(page: "JPMorgan Chase Bank\nStatement Period: March 1, 2026 through March 28, 2026\nAccount Number: 000012348888")
        #expect(read.adding(learned: [learned(joint, "8888")], root: "/D", tree: tree).match(factsC).account?.root == joint)
    }
}
