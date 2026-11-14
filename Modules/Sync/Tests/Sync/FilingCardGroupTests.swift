import Testing
import Foundation
import CoreText
@testable import Sync

/// One card per account folder: statements matched to the same account and going to the same
/// folder group; everything else stays a card of its own. Filing a group is one ⌘Z, and a group
/// leaves behind what the account already holds and the inbox's duplicate copies.
@Suite struct FilingCardGroupTests {

    private func card(_ name: String, to folder: String, account: String?, confidence: FilingConfidence = .high,
                      proposed: String? = nil) -> FilingSuggestion {
        let acct = account.map { FilingAccount(root: $0, ending: "7863", institution: "charles schwab", archived: false, kind: .statement) }
        let dest = FilingDestination(path: folder, confidence: confidence, reasons: ["r"], newSegments: [],
                                     fromContent: true, proposedName: proposed, account: acct,
                                     nameOrigin: proposed == nil ? .planner : .template)
        return FilingSuggestion(filePath: "/In/" + name, fileName: name, size: 10, modificationDate: nil, candidates: [dest])
    }

    @Test func statementsForOneAccountFolderShareACard() {
        let a = "/D/IRA 7863"
        let s = [card("01. Jan 2026.pdf", to: a, account: a, proposed: "Brokerage Statement_2026-01-31_863.PDF"),
                 card("receipt.pdf", to: "/D/Receipts", account: nil),
                 card("02. Feb 2026.pdf", to: a, account: a, proposed: "Brokerage Statement_2026-02-28_863.PDF"),
                 card("03. Mar 2026.pdf", to: a + "/2026", account: a)]
        let items = FilingCardGrouping.items(s)
        #expect(items.count == 3, "one group, the receipt, and the file going elsewhere in the account: \(items.map(\.id))")
        guard case .group(let g) = items[0] else { Issue.record("the group stands where its first member was"); return }
        #expect(g.members.map(\.fileName) == ["01. Jan 2026.pdf", "02. Feb 2026.pdf"])
        #expect(g.dateRange.map { "\($0.first.month)-\($0.last.month)" } == "1-2")
    }

    @Test func aPulledOutFileAndALoneMemberAreCardsOfTheirOwn() {
        let a = "/D/IRA 7863"
        let s = [card("01.pdf", to: a, account: a), card("02.pdf", to: a, account: a)]
        let items = FilingCardGrouping.items(s, pulledOut: ["/In/02.pdf"])
        #expect(items.map(\.id) == ["/In/01.pdf", "/In/02.pdf"], "two singles once one is pulled out")
    }

    @Test func lowConfidenceAndMixedConfidenceDontGroup() {
        let a = "/D/IRA 7863"
        let low = [card("01.pdf", to: a, account: a, confidence: .low), card("02.pdf", to: a, account: a, confidence: .low)]
        #expect(FilingCardGrouping.items(low).count == 2)
        let mixed = [card("01.pdf", to: a, account: a, confidence: .high), card("02.pdf", to: a, account: a, confidence: .medium)]
        #expect(FilingCardGrouping.items(mixed).count == 2, "a sure card and a check-me card aren't one click")
    }

    @Test func alreadyFiledAndCopiesAreLeftBehind() {
        let a = "/D/IRA 7863"
        var dup = card("01 copy.pdf", to: a, account: a)
        dup.duplicateOf = "/In/01.pdf"
        let s = [card("01.pdf", to: a, account: a), card("02.pdf", to: a, account: a).alreadyFiled(at: ["IRA 7863"]), dup]
        guard case .group(let g) = FilingCardGrouping.items(s)[0] else { Issue.record("expected a group"); return }
        #expect(g.toFile.map(\.fileName) == ["01.pdf"])
        #expect(g.alreadyFiled.count == 1 && g.copies.count == 1)
    }
}

@Suite struct FilingLandingNameTests {
    @Test func twoStatementsWithOneDateDontShareAName() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FilingNames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("Statement01302026.pdf"))
        func card(_ n: String, _ proposed: String) -> FilingSuggestion {
            FilingSuggestion(filePath: "/In/" + n, fileName: n, size: 1, modificationDate: nil, candidates: [
                FilingDestination(path: folder.path, confidence: .high, reasons: ["r"], newSegments: [], fromContent: true,
                                  proposedName: proposed, nameOrigin: .template)])
        }
        let out = FileSyncManager.reservingLandingNames([card("a.pdf", "Statement12302025.pdf"),
                                                         card("b.pdf", "Statement12302025.pdf"),
                                                         card("c.pdf", "Statement01302026.pdf")])
        #expect(out.map { $0.best?.proposedName } == ["Statement12302025.pdf", "Statement12302025 2.pdf", "Statement01302026 2.pdf"])
        #expect(out[1].best?.reasons.last?.hasPrefix("Kept as") == true, "the card says so")
    }
}

/// The two operations on disk: a group files as one ⌘Z, and a statement whose text the account
/// already holds is marked, though saved there under the bank's own name.
@MainActor
@Suite struct FilingGroupApplyTests {

    private func writePDF(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        ctx.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: CTFontCreateWithName("Helvetica" as CFString, 12, nil)]))
        ctx.textPosition = CGPoint(x: 40, y: 700)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    @Test func aGroupFilesAsOneUndo() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingGroupApply")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = root.appendingPathComponent("Docs/IRA 7863")
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        var cards: [FilingSuggestion] = []
        for m in ["01", "02"] {
            let f = root.appendingPathComponent("In/\(m).pdf")
            try writeBytes(f, Data(repeating: 0x41, count: 64))
            let dest = FilingDestination(path: account.path, confidence: .high, reasons: ["r"], newSegments: [],
                                         fromContent: true, proposedName: "Statement_\(m).pdf",
                                         account: FilingAccount(root: account.path, ending: "7863", institution: "x",
                                                                archived: false, kind: .statement),
                                         nameOrigin: .template)
            cards.append(FilingSuggestion(filePath: f.path, fileName: "\(m).pdf", size: 64, modificationDate: nil, candidates: [dest]))
        }
        let m = FileSyncManager()
        let undo = UndoManager()
        m.undoManager = undo
        guard case .group(let group) = FilingCardGrouping.items(cards)[0] else { Issue.record("expected a group"); return }
        let filed = await m.applyFilingGroup(group)
        #expect(filed == 2)
        #expect(FileManager.default.fileExists(atPath: account.path + "/Statement_01.pdf"), "the template name lands as shown")
        #expect(FileManager.default.fileExists(atPath: account.path + "/Statement_02.pdf"))
        #expect(undo.canUndo)
        undo.undo()
        try await Task.sleep(for: .milliseconds(500))
        #expect(FileManager.default.fileExists(atPath: root.path + "/In/01.pdf")
                && FileManager.default.fileExists(atPath: root.path + "/In/02.pdf"), "one ⌘Z puts both back")
    }

    @Test func aStatementTheAccountHoldsUnderAnotherNameIsMarkedFiled() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingGroupFiled")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = root.appendingPathComponent("Docs/Fidelity/Statements")
        let text = "Fidelity INVESTMENT REPORT January 1, 2026 - January 31, 2026 Account Number: Z26-141750 balance 1,234.56"
        try writePDF(text, to: account.appendingPathComponent("2026/Statement01302026.pdf"))
        try writePDF(text, to: root.appendingPathComponent("In/01. Jan 2026.pdf"))
        try writePDF(text, to: root.appendingPathComponent("In/Brokerage/01. Jan 2026.pdf"))
        try writePDF(text.replacingOccurrences(of: "January", with: "February"), to: root.appendingPathComponent("In/02. Feb 2026.pdf"))
        func card(_ rel: String) -> FilingSuggestion {
            let dest = FilingDestination(path: account.path + "/2026", confidence: .high, reasons: ["r"], newSegments: [],
                                         fromContent: true,
                                         account: FilingAccount(root: account.path, ending: "1750", institution: "fidelity",
                                                                archived: false, kind: .statement))
            return FilingSuggestion(filePath: root.path + "/In/" + rel, fileName: (rel as NSString).lastPathComponent, size: 10,
                                    modificationDate: nil, candidates: [dest], providerRoot: root.path + "/Docs")
        }
        let m = FileSyncManager()
        let marked = await m.markingFiledInAccounts([card("01. Jan 2026.pdf"), card("Brokerage/01. Jan 2026.pdf"), card("02. Feb 2026.pdf")])
        let byName = Dictionary(uniqueKeysWithValues: marked.map { ($0.filePath, $0) })
        #expect(byName[root.path + "/In/01. Jan 2026.pdf"]?.isAlreadyFiled == true, "the same statement under Fidelity's name")
        #expect(byName[root.path + "/In/Brokerage/01. Jan 2026.pdf"]?.isAlreadyFiled == true)
        #expect(byName[root.path + "/In/02. Feb 2026.pdf"]?.isAlreadyFiled == false, "a different month is not")
    }
}
