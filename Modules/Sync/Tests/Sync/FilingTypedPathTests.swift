import Testing
import Foundation
@testable import Sync

/// A home typed in full on the card: levels that exist are matched as they are spelled on disk, the
/// rest are made at filing; nothing outside the tree, into the inbox or into the source.
@MainActor
@Suite struct FilingTypedPathTests {

    private func setUp(_ prefix: String) throws -> (root: URL, m: FileSyncManager, card: FilingSuggestion) {
        let root = try makeCanonicalTempRoot(prefix: prefix)
        let docs = root.appendingPathComponent("Docs")
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("Vehicles/Tesla/Insurance"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("TODO/Finance"), withIntermediateDirectories: true)
        let m = FileSyncManager(defaults: ScratchDefaults("FilingTypedPathTests.1"))
        m.filingLastProviderRoot = docs.path
        m.filingScanFolder = docs.path + "/TODO"
        m.filingLastExistingFolders = ["Vehicles", "Vehicles/Tesla", "Vehicles/Tesla/Insurance", "Finance", "Finance/US"]
        let card = FilingSuggestion(filePath: docs.path + "/TODO/Finance/lease.pdf", fileName: "lease.pdf", size: 1,
                                    modificationDate: nil, candidates: [], providerRoot: docs.path)
        return (root, m, card)
    }

    @Test func existingLevelsKeepTheirSpellingAndTheRestAreNew() throws {
        let (root, m, card) = try setUp("FilingTypedNew")
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = try m.filingDestination(typed: "vehicles/tesla/Lease/Statements", for: card).get()
        #expect(dest.path == root.path + "/Docs/Vehicles/Tesla/Lease/Statements")
        #expect(dest.newSegments == ["Lease", "Statements"])
        let existing = try m.filingDestination(typed: " Vehicles/Tesla/Insurance/ ", for: card).get()
        #expect(existing.newSegments.isEmpty)
    }

    @Test func pathsThatCantBeAHomeAreRefusedWithAReason() throws {
        let (root, m, card) = try setUp("FilingTypedRefused")
        defer { try? FileManager.default.removeItem(at: root) }
        func refusal(_ t: String) -> FileSyncManager.TypedPathRefusal? {
            if case .failure(let r) = m.filingDestination(typed: t, for: card) { return r } else { return nil }
        }
        #expect(refusal("") == .empty)
        #expect(refusal("Vehicles/../Secrets") == .invalidName(".."))
        #expect(refusal("/etc/hosts") == .outsideTree(root.path + "/Docs"))
        #expect(refusal("Inbox/New") == .intoInbox("Inbox"), "names the inbox level")
        #expect(refusal("Vehicles/.hidden") == .hiddenName(".hidden"))
        try writeBytes(root.appendingPathComponent("Docs/Vehicles/Tesla/notes.txt"), Data("x".utf8))
        #expect(refusal("Vehicles/Tesla/notes.txt/2026") == .fileInTheWay("notes.txt"))
        #expect(refusal("TODO") == .intoInbox("TODO"))
        // A link inside the tree to the folder being filed from is the source.
        try FileManager.default.createSymbolicLink(atPath: root.path + "/Docs/Shortcut",
                                                   withDestinationPath: root.path + "/Docs/TODO")
        #expect(refusal("Shortcut/Chase") == .intoSource)
        // And one to outside the tree is outside it.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Elsewhere"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.path + "/Docs/Away",
                                                   withDestinationPath: root.path + "/Elsewhere")
        #expect(refusal("Away/New") == .outsideTree(root.path + "/Docs"))
        #expect(refusal("TODO/Finance/Chase") != nil, "the folder being filed from (also an inbox by name)")
        // A source folder not named like an inbox is refused as the source.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Docs/Scans/Batch"), withIntermediateDirectories: true)
        m.filingScanFolder = root.path + "/Docs/Scans"
        #expect(refusal("Scans/Batch") == .intoSource)
        m.filingScanFolder = root.path + "/Docs/TODO"
        #expect(refusal("Vehicles/Te:sla") == .invalidName("Te:sla"))
    }

    @Test func aFullOrHomeRelativePathInsideTheTreeIsTheSameHome() throws {
        let (root, m, card) = try setUp("FilingTypedFull")
        defer { try? FileManager.default.removeItem(at: root) }
        let full = try m.filingDestination(typed: root.path + "/Docs/Vehicles/Tesla/Lease", for: card).get()
        #expect(full.path == root.path + "/Docs/Vehicles/Tesla/Lease" && full.newSegments == ["Lease"])
        let none = FileSyncManager(defaults: ScratchDefaults("FilingTypedPathTests.2"))
        #expect(none.filingDestination(typed: "Vehicles", for: FilingSuggestion(filePath: "/x/a.pdf", fileName: "a.pdf", size: 1,
                                                                                modificationDate: nil, candidates: []))
                == .failure(.noTree))
    }

    @Test func completionsFollowWhatIsTyped() throws {
        let (root, m, _) = try setUp("FilingTypedComplete")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(m.filingPathCompletions("veh") == ["Vehicles", "Vehicles/Tesla", "Vehicles/Tesla/Insurance"])
        #expect(m.filingPathCompletions("Vehicles/T") == ["Vehicles/Tesla", "Vehicles/Tesla/Insurance"])
        #expect(m.filingPathCompletions("") == [])
    }
}

/// In a scan: a statement from a bank the tree knows, for an account no folder holds, is proposed
/// as a NEW account folder named like the bank's other accounts of that type, at Medium.
@MainActor
@Suite struct FilingNewAccountScanTests {
    @Test func aNumberlessCheckingStatementIsProposedBesideTheOtherChecking() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingNewAccount")
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Docs")
        for m in 1...6 {
            try writeBytes(docs.appendingPathComponent(String(format: "Bank Accounts/Bank of America/Checking 5696/2025/eStmt_2025-%02d-28.pdf", m)),
                           Data(repeating: 0x41, count: 64))
            let month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun"][m - 1]
            try writeBytes(docs.appendingPathComponent(String(format: "Credit Accounts/Chase/Credit 1768/2025/%02d. %@ 2025.pdf", m, month)),
                           Data(repeating: 0x41, count: 64))
        }
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("Bank Accounts/Chase"), withIntermediateDirectories: true)
        let inbox = root.appendingPathComponent("Inbox")
        let statement = inbox.appendingPathComponent("Chase/Checking 0779/2026/03. Mar 2026.pdf")
        try writeBytes(statement, Data(repeating: 0x41, count: 64))
        let m = FileSyncManager(defaults: ScratchDefaults("FilingTypedPathTests.3"))
        m.setFilingScansSubfolders(true, for: inbox.path)
        m.filingContentExtractor = { _ in [] }
        m.filingSnippetExtractor = { $0 == statement.path ? "Chase Total Checking\nFebruary 13, 2026 through March 12, 2026\nAccount Number:\nA PERSON" : nil }
        m.filingTokensFromText = { _ in [] }
        await m.findFilingSuggestions(folder: inbox, providerRoot: docs)
        let card = try #require(m.filingSuggestions.first { $0.filePath == statement.path })
        let best = try #require(card.best)
        #expect(best.path == docs.path + "/Bank Accounts/Chase/Checking 0779/2026", "\(card.candidates.map(\.path))")
        #expect(best.newSegments == ["Checking 0779", "2026"])
        #expect(best.confidence == .medium, "a new folder is never High")
        #expect(best.reasons.first?.contains("named like Checking 5696") == true, "\(best.reasons)")
        #expect(best.createsAccountFolder)
    }

    /// A page not read as a statement gets a NEW account only when its own number is the folder's.
    @Test func aLeaseBillWhoseNumberIsItsFoldersIsProposed() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingLeaseAccount")
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Docs")
        for (m, month) in ["Jan", "Feb", "Mar", "Apr", "May", "Jun"].enumerated() {
            try writeBytes(docs.appendingPathComponent(String(format: "Credit Accounts/Chase/Credit 1768/2025/%02d. %@ 2025.pdf", m + 1, month)),
                           Data(repeating: 0x41, count: 64))
        }
        let inbox = root.appendingPathComponent("Inbox")
        let lease = inbox.appendingPathComponent("Chase/Auto Lease 2388/2026/03. Mar 2026.pdf")
        let other = inbox.appendingPathComponent("Chase/Auto Lease 2388/2026/04. Apr 2026.pdf")
        try writeBytes(lease, Data(repeating: 0x41, count: 64))
        try writeBytes(other, Data(repeating: 0x42, count: 64))
        let m = FileSyncManager(defaults: ScratchDefaults("FilingTypedPathTests.4"))
        m.setFilingScansSubfolders(true, for: inbox.path)
        m.filingContentExtractor = { _ in [] }
        m.filingSnippetExtractor = {
            switch $0 {
            case lease.path: return "Thank you for being a CHASE AUTO customer. Lease Information | Account Number 0014202388 | Amount Due $498.97"
            case other.path: return "Thank you for being a CHASE AUTO customer. Lease Information | Account Number 0014209999 | Amount Due $498.97"
            default: return nil
            }
        }
        m.filingTokensFromText = { _ in [] }
        await m.findFilingSuggestions(folder: inbox, providerRoot: docs)
        let best = try #require(m.filingSuggestions.first { $0.filePath == lease.path }?.best)
        #expect(best.path == docs.path + "/Credit Accounts/Chase/Auto Lease 2388", "\(best.path)")
        #expect(best.confidence == .medium && best.createsAccountFolder)
        let unproposed = m.filingSuggestions.first { $0.filePath == other.path }
        #expect(unproposed?.best?.createsAccountFolder != true, "its number isn't the folder's")
    }

    /// A numberless statement whose inbox folder names an account the bank already has goes to that
    /// account, not to a NEW folder beside it.
    @Test func theInboxFoldersNumberFindsTheAccountTheTreeHas() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingHintedAccount")
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Docs")
        for (m, month) in ["Jan", "Feb", "Mar", "Apr", "May", "Jun"].enumerated() {
            try writeBytes(docs.appendingPathComponent(String(format: "Bank Accounts/Chase/Checking 0779/2025/%02d. %@ 2025.pdf", m + 1, month)),
                           Data(repeating: 0x41, count: 64))
        }
        let inbox = root.appendingPathComponent("Inbox")
        let statement = inbox.appendingPathComponent("Chase/Checking 0779/2026/03. Mar 2026.pdf")
        try writeBytes(statement, Data(repeating: 0x41, count: 64))
        let m = FileSyncManager(defaults: ScratchDefaults("FilingTypedPathTests.5"))
        m.setFilingScansSubfolders(true, for: inbox.path)
        m.filingContentExtractor = { _ in [] }
        m.filingSnippetExtractor = { $0 == statement.path ? "Chase Total Checking\nFebruary 13, 2026 through March 12, 2026\nA PERSON" : nil }
        m.filingTokensFromText = { _ in [] }
        await m.findFilingSuggestions(folder: inbox, providerRoot: docs)
        let best = try #require(m.filingSuggestions.first { $0.filePath == statement.path }?.best)
        #expect(best.path == docs.path + "/Bank Accounts/Chase/Checking 0779/2026", "\(best.path)")
        #expect(!best.createsAccountFolder, "the account exists; only its year is new")
        #expect(best.confidence == .medium)
    }
}
