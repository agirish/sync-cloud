import Foundation
import Testing
@testable import Sync

/// Names made from a first page (TE328): which names change, and how the folder a file goes to
/// shapes its new one (decision JL).
@Suite struct ContentNameTests {

    private func files(_ folder: String, _ names: [String]) -> [FolderFile] {
        names.map { FolderFile(path: folder + "/" + $0, name: $0) }
    }

    private func entry(_ path: String, naming: String?) -> FolderProfile {
        FolderProfile(profileId: "t", root: "/r",
                      folders: [path: FolderProfileEntry(path: path, role: nil, naming: naming, anchors: [],
                                                         acceptsNewFiles: nil, fileCount: 3, subfolderCount: 0, axes: [:])],
                      personTokens: [])
    }

    @Test func onlyNamesThatSayNothingChange() {
        for poor in ["Scan 0042.pdf", "IMG_2231.HEIC", "document (3).pdf", "download-9.pdf", "Untitled 2.pdf",
                     "ScanSnap_20240101.pdf", "PXL_20240101_123456789.jpg", "0042.pdf", "Scanned Document 12.pdf"] {
            #expect(ContentName.needsName(poor), "\(poor)")
        }
        for named in ["W-2 2025.pdf", "Statement.pdf", "2024 Ally 1099-INT.pdf", "9829custbill07182023.pdf",
                      "Receipt 0042.pdf", "Lease.pdf"] {
            #expect(!ContentName.needsName(named), "\(named)")
        }
    }

    /// The sibling naming the same sender and kind keeps everything but its date.
    @Test func aDescriptiveFolderSwapsTheDateInItsClosestName() {
        let folder = "/r/Finance/US/Income Tax/2025"
        let p = ContentName.propose(.init(year: 2025, month: 2, from: "Ally", what: "1099-INT"), ext: "pdf",
                                    folderPath: folder, relativePath: "Finance/US/Income Tax/2025",
                                    folderFiles: files(folder, ["2024 Chase 1099-INT.pdf", "2024 Ally Bank 1099-INT.pdf", "W-2 2025.pdf"]),
                                    profile: entry("Finance/US/Income Tax/2025", naming: "descriptive"))
        // "Bank" is the sibling's, not the page's: only a swap keeps it.
        #expect(p == .init(name: "2025 Ally Bank 1099-INT.pdf", basis: .like("2024 Ally Bank 1099-INT.pdf")))
    }

    /// Only the kind matches: the sibling lends its layout, separator included, not its sender.
    @Test func aSiblingOfTheSameKindLendsItsLayout() {
        let folder = "/r/Taxes"
        let p = ContentName.propose(.init(year: 2025, from: "Ally", what: "1099-INT"), ext: "pdf",
                                    folderPath: folder, relativePath: "Taxes",
                                    folderFiles: files(folder, ["Passport 2019.pdf", "2024 - Chase 1099-INT.pdf"]),
                                    profile: nil)
        #expect(p == .init(name: "2025 - Ally 1099-INT.pdf", basis: .like("2024 - Chase 1099-INT.pdf")))
    }

    /// His special payments are "YYYY Mon DD - what"; a page with no day can't take that shape.
    @Test func aSpelledDateShapeIsKeptOrPassedOver() {
        let folder = "/r/Special Payments"
        let names = files(folder, ["2024 Dec 13 - Stock Payout.pdf"])
        let withDay = ContentName.propose(.init(year: 2025, month: 8, day: 29, from: "Acme", what: "Stock Payout"), ext: "pdf",
                                          folderPath: folder, relativePath: "Special Payments", folderFiles: names, profile: nil)
        #expect(withDay?.name == "2025 Aug 29 - Acme Stock Payout.pdf")
        let noDay = ContentName.propose(.init(year: 2025, month: 8, from: "Acme", what: "Stock Payout"), ext: "pdf",
                                        folderPath: folder, relativePath: "Special Payments", folderFiles: names, profile: nil)
        #expect(noDay == .init(name: "2025-08 Acme Stock Payout.pdf", basis: .plain))
    }

    /// A numbered folder takes Renames' slot for the page's month: position, not the month number.
    @Test func aNumberedFolderTakesTheNextSlot() {
        let folder = "/r/Home/Utilities/PG&E/2025"
        let p = ContentName.propose(.init(year: 2025, month: 10, from: "PG&E", what: "Bill"), ext: "pdf",
                                    folderPath: folder, relativePath: "Home/Utilities/PG&E/2025",
                                    folderFiles: files(folder, ["01. Jan 2025.pdf", "02. Mar 2025.pdf", "03. Sep 2025.pdf"]),
                                    profile: entry("Home/Utilities/PG&E/2025", naming: "ordinal-month"))
        #expect(p == .init(name: "04. Oct 2025.pdf", basis: .numbered(after: "03. Sep 2025.pdf")))
    }

    /// A slot that would renumber the files after it is Renames' job, reviewed as a folder change.
    @Test func aSlotThatWouldRenumberOthersFallsBackToAPlainName() {
        let folder = "/r/PG&E/2025"
        let p = ContentName.propose(.init(year: 2025, month: 2, from: "PG&E", what: "Bill"), ext: "pdf",
                                    folderPath: folder, relativePath: "PG&E/2025",
                                    folderFiles: files(folder, ["01. Mar 2025.pdf", "02. Apr 2025.pdf", "03. May 2025.pdf"]),
                                    profile: entry("PG&E/2025", naming: "ordinal-month"))
        #expect(p == .init(name: "2025-02 PG&E Bill.pdf", basis: .plain))
    }

    /// A day-keyed folder takes the period-ending day.
    @Test func aDayKeyedFolderUsesTheDay() {
        let folder = "/r/Salary Statements/2025"
        let p = ContentName.propose(.init(year: 2025, month: 11, day: 15, from: "Acme", what: "Earnings Statement"), ext: "pdf",
                                    folderPath: folder, relativePath: "Salary Statements/2025",
                                    folderFiles: files(folder, ["01. Oct 15 2025.pdf", "02. Oct 31 2025.pdf"]),
                                    profile: entry("Salary Statements/2025", naming: "ordinal-day"))
        #expect(p == .init(name: "03. Nov 15 2025.pdf", basis: .numbered(after: "02. Oct 31 2025.pdf")))
    }

    @Test func noPatternGivesAPlainNameAndThinFactsGiveNone() {
        let plain = ContentName.propose(.init(year: 2025, month: 3, from: "Kaiser", what: "Explanation of Benefits"), ext: "pdf",
                                        folderPath: "/r/Health", relativePath: "Health",
                                        folderFiles: files("/r/Health", ["Scan 2023.pdf"]), profile: nil)
        #expect(plain == .init(name: "2025-03 Kaiser Explanation of Benefits.pdf", basis: .plain))
        #expect(ContentName.propose(.init(year: 2025, from: " ", what: ""), ext: "pdf", folderPath: "/r", relativePath: "",
                                    folderFiles: [], profile: nil) == nil)
        #expect(ContentName.propose(.init(year: 12025, from: "Ally", what: "Statement"), ext: "pdf", folderPath: "/r",
                                    relativePath: "", folderFiles: [], profile: nil) == nil)
    }

    /// A model's words can't address another folder or hide the file.
    @Test func modelWordsAreMadeSafe() {
        let p = ContentName.propose(.init(year: 2025, from: "..Ally/Bank", what: "1099:INT\nform"), ext: "pdf",
                                    folderPath: "/r", relativePath: "", folderFiles: [], profile: nil)
        #expect(p?.name == "2025 Ally Bank 1099 INT form.pdf")
    }
}

/// A card's new names (TE328): typed, kept, made again for another folder, and counted as taken.
@Suite struct AskClaudePlanNameTests {

    private func plan(_ dir: String) -> AskClaudePlan {
        var row = AskClaudePlan.Row(id: 0, name: "Scan 0042.pdf", change: .move(from: dir + "/Scan 0042.pdf", toFolder: dir + "/Taxes"),
                                    ticked: true, choices: [.init(label: "Taxes", path: dir + "/Taxes"), .init(label: "Bank", path: dir + "/Bank")])
        row.newName = "2025 Ally 1099-INT.pdf"
        row.nameBasis = "Named like 2024 Ally 1099-INT.pdf"
        row.nameFacts = .init(year: 2025, from: "Ally", what: "1099-INT")
        return AskClaudePlan(title: "Move Scan 0042.pdf", subtitle: "", rows: [row])
    }

    private func scratch() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("names-\(UUID().uuidString)").path
        for folder in ["Taxes", "Bank"] {
            try FileManager.default.createDirectory(atPath: dir + "/" + folder, withIntermediateDirectories: true)
        }
        return dir
    }

    @Test func aTypedNameKeepsItsExtensionAndIsChecked() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var p = plan(dir)
        #expect(p.setName(".hidden", row: 0) == "A name starting with “.” would hide the file.")
        #expect(p.rows[0].newName == "2025 Ally 1099-INT.pdf", "a refused name changes nothing")
        #expect(p.setName("  Ally 1099-INT Corrected ", row: 0) == nil)
        #expect(p.rows[0].newName == "Ally 1099-INT Corrected.pdf" && p.rows[0].nameBasis == "Your name" && p.rows[0].nameTyped == true)
        #expect(p.newNames == [0: "Ally 1099-INT Corrected.pdf"])
        #expect(p.setName(nil, row: 0) == nil)
        #expect(p.rows[0].newName == nil && p.newNames.isEmpty, "Keep its name")
    }

    /// A taken new name is noted as where it lands, by the name Apply gives.
    @Test func aTakenNewNameIsNoted() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        FileManager.default.createFile(atPath: dir + "/Taxes/2025 Ally 1099-INT.pdf", contents: Data("filed".utf8))
        var p = plan(dir)
        p.noteLandingNames()
        #expect(p.rows[0].note == "Kept as 2025 Ally 1099-INT 2.pdf: the name is taken")
    }

    /// Sent to another folder, a made name is made again for it; a typed one stays.
    @Test func aFolderChangeRemakesAMadeNameButNotATypedOne() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var p = plan(dir)
        p.choose(.init(label: "Bank", path: dir + "/Bank"), forRow: 0)
        p.renameForFolders { facts, _, folder in
            folder.hasSuffix("/Bank") ? .init(name: "\(facts.year) Bank Copy.pdf", basis: .plain) : nil
        }
        #expect(p.rows[0].newName == "2025 Bank Copy.pdf" && p.rows[0].nameBasis == "Named by year, who it’s from and what it is")
        _ = p.setName("Mine", row: 0)
        p.renameForFolders { _, _, _ in .init(name: "Other.pdf", basis: .plain) }
        #expect(p.rows[0].newName == "Mine.pdf")
    }

    /// What the strip says, and that a held card's loose-files result counts names without them.
    @Test func heldNamesAreCountedNotNamed() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let p = plan(dir)
        let held = AskClaudeLooseFiles.result(p, leftHereCount: 0, nextFrom: nil, rows: false)
        #expect(held.contains("1 with a new name made on their Mac") && !held.contains("Ally"))
        let shared = AskClaudeLooseFiles.result(p, leftHereCount: 0, nextFrom: nil, rows: true)
        #expect(shared.contains("renamed to 2025 Ally 1099-INT.pdf"))
        #expect(AskClaudeHeldNames().line(2) == "Claude hasn’t seen the 2 new names or where the files go. Apple Intelligence made them on this Mac from what the files say.")
        #expect(AskClaudeHeldNames(shared: true).line(1) == "Claude has the name and folder you shared.")
        #expect(AskClaudeHeldNames(shared: true, sharedBy: "Downloads").line(2) == "Downloads shares without asking, so Claude has these names and folders.")
    }

    /// Filing help's answer names a new name only where the file shares.
    @Test func filingHelpSaysANewNameOnlyWhereTheFileShares() {
        var folder = AskClaudeFilingCard.Folder(label: "iCloud › Taxes", path: "/r/Taxes", confidence: "High", reason: "Like its neighbours", fromFile: false)
        folder.newName = "2025 Ally 1099-INT.pdf"
        var card = AskClaudeFilingCard(fileName: "Scan 0042.pdf", filePath: "/d/Scan 0042.pdf", kind: .suggestions, folders: [folder])
        let held = AskClaudeFiling.result(card, sharesFreely: false)
        #expect(!held.contains("Ally") && held.contains("Their card has Share Names and Folders"))
        #expect(AskClaudeFiling.result(card, sharesFreely: true).contains("renamed there to 2025 Ally 1099-INT.pdf"))
        card.names = AskClaudeHeldNames(shared: true)
        #expect(AskClaudeFiling.result(card, sharesFreely: false).contains("renamed there to 2025 Ally 1099-INT.pdf"))
    }
}
