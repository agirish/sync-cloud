import Foundation
import Testing
@testable import Sync

/// His statement numbering (2026-11-15) for `Finance/US` and `Vehicles/Tesla/Lease Statements`:
/// position by date, `1.` … `11.` below twelve statements and `01.` … `12.` from twelve on, ranges
/// by their end month, a CSV sharing its PDF's number, `0.` outside the count. Names are his,
/// copied from the tree as he renamed it.
@Suite struct StatementOrdinalsTests {

    /// A governed year folder.
    static let folder = "/T/Finance/US/Credit Accounts/American Express/Credit 1001/2025"
    static let rel = "Finance/US/Credit Accounts/American Express/Credit 1001/2025"

    private func files(_ names: [String], in folder: String = folder) -> [FolderFile] {
        names.map { FolderFile(path: folder + "/" + $0, name: $0) }
    }

    /// The backlog pass's renames for a governed folder holding `names`.
    private func renames(_ names: [String], rel: String = rel) -> [String: String] {
        let plan = RenamePlanner.plan(folderPath: Self.folder, relativePath: rel, files: files(names), entry: nil)
        return Dictionary(uniqueKeysWithValues: plan.steps.map { ($0.currentName, $0.proposedName) })
    }

    /// What filing `proposed` (an account's own name for it) into a governed folder holding `names`
    /// does: the name it lands under and the renames beside it.
    private func landing(_ proposed: String, into names: [String], fileName: String = "Statement.pdf")
        -> (name: String?, renumbers: [String: String])? {
        guard let l = FileSyncManager.incomingLanding(for: fileName, as: proposed, into: Self.folder,
                                                      relativePath: Self.rel, folderFiles: files(names),
                                                      profile: nil) else { return nil }
        return (l.name, Dictionary(uniqueKeysWithValues: l.renumbers.map { ($0.currentName, $0.proposedName) }))
    }

    private static let year11 = ["1. Jan 2026.pdf", "2. Feb 2026.pdf", "3. Mar 2026.pdf", "4. Apr 2026.pdf",
                                 "5. May 2026.pdf", "6. Jun 2026.pdf", "7. Jul 2026.pdf", "8. Aug 2026.pdf",
                                 "9. Sep 2026.pdf", "10. Oct 2026.pdf", "11. Nov 2026.pdf"]

    // MARK: Where it applies

    @Test func theRuleGovernsOnlyTheFoldersHeRenamedToIt() {
        #expect(StatementOrdinals.governs("Finance/US"))
        #expect(StatementOrdinals.governs("Finance/US/Bank Accounts/Chase/Checking 0779/2026"))
        #expect(StatementOrdinals.governs("finance/us/Credit Accounts"), "his volume ignores case")
        #expect(StatementOrdinals.governs("Vehicles/Tesla/Lease Statements/2026"))
        #expect(!StatementOrdinals.governs("Finance/USA/2026"), "a component, not a prefix of letters")
        #expect(!StatementOrdinals.governs("Finance/IN/HDFC/2014"))
        #expect(!StatementOrdinals.governs("Vehicles/Tesla/Insurance"))
        #expect(!StatementOrdinals.governs("Home/Utilities/PG&E/2025"))
    }

    @Test func aFolderOutsideTheRuleKeepsItsOwnNumbering() {
        // PG&E pads by cadence and numbers by month: the same names in a governed folder would be
        // renumbered 1, 2, 3.
        let names = ["01. Jan 2025.pdf", "06. Jun 2025.pdf", "10. Oct 2025.pdf"]
        #expect(renames(names, rel: "Home/Utilities/PG&E/2025").isEmpty)
        #expect(renames(names) == ["01. Jan 2025.pdf": "1. Jan 2025.pdf", "06. Jun 2025.pdf": "2. Jun 2025.pdf",
                                   "10. Oct 2025.pdf": "3. Oct 2025.pdf"])
    }

    // MARK: Reading the date

    @Test func aStatementIsDatedByTheEndOfItsPeriod() {
        func d(_ body: String) -> String? {
            StatementOrdinals.date(ofBody: body).map { "\($0.year)-\($0.month)" + ($0.day.map { "-\($0)" } ?? "") }
        }
        #expect(d("Oct 2026") == "2026-10")
        #expect(d("October 2026") == "2026-10")
        #expect(d("Oct  2019") == "2019-10")
        #expect(d("Nov 2014 -2") == "2014-11")
        #expect(d("Nov 2018 (RC)") == "2018-11")
        #expect(d("Jan-Mar 2021") == "2021-3")
        #expect(d("May - Jun 2020") == "2020-6")
        #expect(d("July-Aug 2021") == "2021-8")
        #expect(d("Apr 2009 - Mar 2010") == "2010-3")
        #expect(d("Apr 2007 to Aug 2007") == "2007-8")
        #expect(d("Feb 28 2019") == "2019-2-28")
        #expect(d("Transunion - Aug 2019") == nil, "a name that doesn't start with its date isn't a statement's")
        #expect(d("Summary 2022") == nil)
        #expect(d("2014-2015 (1)") == nil)
    }

    // MARK: The rule over a folder as it stands

    @Test func aSparseFolderCountsItsStatementsNotItsMonths() {
        // Amex with January, June and October.
        #expect(renames(["1. Jan 2025.pdf", "2. Jun 2025.pdf", "3. Oct 2025.pdf"]).isEmpty)
        #expect(renames(["1. Jan 2025.pdf", "6. Jun 2025.pdf", "10. Oct 2025.pdf"])
                == ["6. Jun 2025.pdf": "2. Jun 2025.pdf", "10. Oct 2025.pdf": "3. Oct 2025.pdf"])
        // Fewer than twelve: no leading zero, the part year included.
        #expect(renames(Self.year11).isEmpty)
        #expect(renames(["01. Jan 2025.pdf", "02. Jun 2025.pdf"])
                == ["01. Jan 2025.pdf": "1. Jan 2025.pdf", "02. Jun 2025.pdf": "2. Jun 2025.pdf"])
    }

    @Test func twelveOrMoreStatementsAreTwoDigitsEveryOne() {
        let twelve = (1...12).map { String(format: "%02d. %@ 2025.pdf", $0, OrdinalMonthName.monthAbbreviations[$0 - 1]) }
        #expect(renames(twelve).isEmpty)
        let unpadded = Self.year11.map { $0.replacingOccurrences(of: "2026", with: "2025") } + ["12. Dec 2025.pdf"]
        let r = renames(unpadded)
        #expect(r.count == 9, "the nine one-digit names gain their zero; 10. to 12. are already two digits")
        #expect(r["1. Jan 2025.pdf"] == "01. Jan 2025.pdf")
        #expect(r["9. Sep 2025.pdf"] == "09. Sep 2025.pdf")
        // Two statements in one month are two positions: thirteen in BoA 5696's 2014.
        let boa = ["01. Jan 2014.pdf", "02. Feb 2014.pdf", "03. Mar 2014.pdf", "04. Apr 2014.pdf", "05. May 2014.pdf",
                   "06. Jun 2014.pdf", "07. Jul 2014.pdf", "08. Aug 2014.pdf", "09. Sep 2014.pdf", "10. Oct 2014.pdf",
                   "11. Nov 2014 -1.pdf", "12. Nov 2014 -2.pdf", "13. Dec 2014.pdf"]
        #expect(renames(boa).isEmpty)
    }

    @Test func aRangeSortsByItsEndMonth() {
        // Schwab Checking 6436's 2021, as he renamed it.
        #expect(renames(["1. Jan 2021.pdf", "2. Feb 2021.pdf", "3. Mar 2021.pdf", "4. Apr-Jun 2021.PDF",
                         "5. Jul-Sep 2021.PDF", "6. Oct 2021.PDF", "7. Nov-Dec 2021.PDF"]).isEmpty)
        // A range the rename missed (`May - Jun`) is placed by June, after April and before July.
        #expect(renames(["1. Apr 2020.pdf", "05. May - Jun 2020.pdf", "2. Jul 2020.pdf"])
                == ["05. May - Jun 2020.pdf": "2. May - Jun 2020.pdf", "2. Jul 2020.pdf": "3. Jul 2020.pdf"])
        // A range and a month ending alike keep the order their numbers give them.
        #expect(renames(["1. Jan-Mar 2017.pdf", "2. Jul-Aug 2017.pdf", "3. Aug 2017.pdf"]).isEmpty)
    }

    @Test func aCSVSharesItsPDFsNumber() {
        // Apple Card's 2022: a PDF and its CSV export each month.
        #expect(renames(["1. Jan 2022.pdf", "1. Jan 2022.csv", "2. Feb 2022.pdf", "2. Feb 2022.csv",
                         "3. Mar 2022.pdf"]).isEmpty)
        // A CSV numbered apart from its PDF takes the PDF's number, and counts as nothing more.
        #expect(renames(["1. Jan 2022.pdf", "2. Jan 2022.csv", "2. Feb 2022.pdf"]) == ["2. Jan 2022.csv": "1. Jan 2022.csv"])
        // Filed after its PDF, a CSV takes the PDF's number and renumbers nothing.
        let csv = landing("02. Feb 2022.csv", into: ["1. Jan 2022.pdf", "2. Feb 2022.pdf"], fileName: "Feb.csv")
        #expect(csv?.name == "2. Feb 2022.csv")
        #expect(csv?.renumbers.isEmpty == true)
    }

    @Test func theSummarySlotIsOutsideTheCount() {
        // Eleven statements and a year-end summary: still eleven, still one digit.
        let withSummary = ["0. Summary 2026.pdf", "0. Spend 2026.pdf"] + Self.year11
        #expect(renames(withSummary).isEmpty)
        // At twelve the statements gain their zero and the summary keeps `0.`.
        let r = landing("12. Dec 2026.pdf", into: withSummary)
        #expect(r?.name == "12. Dec 2026.pdf")
        #expect(r?.renumbers["0. Summary 2026.pdf"] == nil)
        #expect(r?.renumbers["0. Spend 2026.pdf"] == nil)
        #expect(r?.renumbers.count == 9)
    }

    @Test func aFolderWhoseNumbersMeanSomethingElseIsLeftAlone() {
        // Credit reports numbered by bureau, not statements.
        #expect(renames(["01. Equifax - Aug 2019.pdf", "01. Transunion - Aug 2019.pdf",
                         "02. Transunion - Jul 2019.pdf", "02. Transunion - Jun 2019.pdf"]).isEmpty)
        // A statement filed there keeps the account's name and renumbers nothing.
        let filed = landing("08. Aug 2019.pdf", into: ["01. Equifax - Aug 2019.pdf"])
        #expect(filed?.name == "08. Aug 2019.pdf")
        #expect(filed?.renumbers.isEmpty == true)
    }

    @Test func theBacklogPassNumbersNoRawNameAlreadyThere() {
        // A date in a name doesn't make a statement: BoA Credit 6397's 2024 holds a renewal notice,
        // and counting it would renumber December.
        #expect(renames(["1. Jan 2024.pdf", "Renewal Notice - Jun 2024.pdf", "2. Dec 2024.pdf"]).isEmpty)
        // Nor his raw bank names, which wait for him to read and rename them.
        #expect(renames(["eStmt_2023-01-15.pdf", "eStmt_2023-02-15.pdf", "eStmt_2023-03-15.pdf"]).isEmpty)
    }

    @Test func aFolderThatBreaksTheRuleIsProposedWhole() {
        // Discover 2241's 2019 as the rename left it: `Oct  2019` (two spaces) kept 10. beside Nov's.
        let r = renames(["1. Jan 2019.pdf", "2. Feb 2019.pdf", "3. Mar 2019.pdf", "4. Apr 2019.pdf",
                         "5. May 2019.pdf", "6. Jun 2019.pdf", "7. Jul 2019.pdf", "8. Aug 2019.pdf",
                         "9. Sep 2019.pdf", "10. Oct  2019.pdf", "10. Nov 2019.pdf", "11. Dec 2019.pdf"])
        #expect(r["10. Oct  2019.pdf"] == "10. Oct 2019.pdf")
        #expect(r["10. Nov 2019.pdf"] == "11. Nov 2019.pdf")
        #expect(r["11. Dec 2019.pdf"] == "12. Dec 2019.pdf")
        #expect(r["1. Jan 2019.pdf"] == "01. Jan 2019.pdf")
        // Citi 8806's 2019: a month written out, and a collision with it.
        #expect(renames(["0. Summary 2019.pdf", "1. Aug 2019.pdf", "1. July 2019.pdf", "2. Sep 2019.PDF"])
                == ["1. July 2019.pdf": "1. Jul 2019.pdf", "1. Aug 2019.pdf": "2. Aug 2019.pdf",
                    "2. Sep 2019.PDF": "3. Sep 2019.PDF"])
        let plan = RenamePlanner.plan(folderPath: Self.folder, relativePath: Self.rel,
                                      files: files(["1. Jan 2025.pdf", "6. Jun 2025.pdf"]), entry: nil)
        #expect(Set(plan.steps.map(\.cohort)) == [1], "one renumbering, applied whole or not at all")
    }

    // MARK: Filing a statement in

    @Test func aStatementFiledMidYearRenumbersTheOnesAfterIt() {
        // The account's own template numbers by month; the rule numbers by position.
        let r = landing("03. Mar 2025.pdf", into: ["1. Jan 2025.pdf", "2. Jun 2025.pdf"])
        #expect(r?.name == "2. Mar 2025.pdf")
        #expect(r?.renumbers == ["2. Jun 2025.pdf": "3. Jun 2025.pdf"])
        // Appended, it renumbers nothing.
        let end = landing("10. Oct 2025.PDF", into: ["1. Jan 2025.pdf", "2. Jun 2025.pdf"])
        #expect(end?.name == "3. Oct 2025.PDF")
        #expect(end?.renumbers.isEmpty == true)
        // Into a folder not made yet: the first statement there.
        let fresh = FileSyncManager.incomingLanding(for: "s.pdf", as: "10. Oct 2027.PDF", into: Self.folder,
                                                    relativePath: Self.rel, folderFiles: [], profile: nil)
        #expect(fresh?.name == "1. Oct 2027.PDF")
    }

    @Test func theTwelfthStatementGivesEveryOneTwoDigits() {
        let r = landing("12. Dec 2026.pdf", into: Self.year11)
        #expect(r?.name == "12. Dec 2026.pdf")
        #expect(r?.renumbers.count == 9)
        #expect(r?.renumbers["1. Jan 2026.pdf"] == "01. Jan 2026.pdf")
        #expect(r?.renumbers["9. Sep 2026.pdf"] == "09. Sep 2026.pdf")
        #expect(r?.renumbers["10. Oct 2026.pdf"] == nil, "already two digits")
        // The eleventh, into ten: still one digit.
        let eleventh = landing("11. Nov 2026.pdf", into: Array(Self.year11.prefix(10)))
        #expect(eleventh?.name == "11. Nov 2026.pdf")
        #expect(eleventh?.renumbers.isEmpty == true)
    }

    @Test func aSecondStatementOfAMonthGoesAfterTheFirst() {
        // Chase 3931's 2016 holds two July statements, `1.` and `2.`. June arriving shifts both,
        // through each other's names, so the renames come in an order that never collides.
        guard let l = FileSyncManager.incomingLanding(
            for: "s.pdf", as: "06. Jun 2016.pdf", into: Self.folder, relativePath: Self.rel,
            folderFiles: files(["1. Jul 2016.pdf", "2. Jul 2016.pdf", "3. Aug 2016.pdf"]), profile: nil)
        else { Issue.record("no landing"); return }
        #expect(l.name == "1. Jun 2016.pdf")
        #expect(l.renumbers.map { "\($0.currentName)→\($0.proposedName)" }
                == ["2. Jul 2016.pdf→3. Jul 2016.pdf", "1. Jul 2016.pdf→2. Jul 2016.pdf",
                    "3. Aug 2016.pdf→4. Aug 2016.pdf"])
        // Another July arriving goes after the two already there.
        #expect(landing("07. Jul 2016.pdf", into: ["1. Jul 2016.pdf", "2. Jul 2016.pdf"])?.name == "3. Jul 2016.pdf")
    }

    @Test func aRawBillFiledInIsNamedAndNumberedByTheRule() {
        // A planner-named file (no account template): dated from its name, then numbered.
        let l = FileSyncManager.incomingLanding(for: "eStmt_2025-03-15.pdf", into: Self.folder, relativePath: Self.rel,
                                                folderFiles: files(["1. Jan 2025.pdf", "2. Jun 2025.pdf"]), profile: nil)
        #expect(l?.name == "2. Mar 2025.pdf")
        #expect(l?.renumbers.map(\.proposedName) == ["3. Jun 2025.pdf"])
        // The one-file door still refuses a name whose neighbours would have to move with it.
        #expect(FileSyncManager.incomingName(for: "eStmt_2025-03-15.pdf", into: Self.folder, relativePath: Self.rel,
                                             folderFiles: files(["1. Jan 2025.pdf", "2. Jun 2025.pdf"]),
                                             profile: nil) == nil)
        #expect(FileSyncManager.incomingName(for: "eStmt_2025-07-15.pdf", into: Self.folder, relativePath: Self.rel,
                                             folderFiles: files(["1. Jan 2025.pdf", "2. Jun 2025.pdf"]),
                                             profile: nil) == "3. Jul 2025.pdf")
    }

    @Test func theCardSaysWhatFileHereRenumbers() {
        let root = "/T"
        let template = FilingDestination(path: Self.folder, confidence: .high, reasons: [], newSegments: [],
                                         proposedName: "03. Mar 2025.pdf", nameOrigin: .template)
        let named = FileSyncManager.named(template, fileName: "Statement.pdf", rootPath: root,
                                          folderFiles: files(["1. Jan 2025.pdf", "2. Jun 2025.pdf"]), profile: nil)
        #expect(named.proposedName == "2. Mar 2025.pdf")
        #expect(named.nameOrigin == .template)
        #expect(named.renumbersOthers == 1)
        // A new year folder: the account's name, numbered as the first statement there.
        let new = FilingDestination(path: Self.folder, confidence: .high, reasons: [], newSegments: ["2025"],
                                    proposedName: "10. Oct 2025.PDF", nameOrigin: .template)
        #expect(FileSyncManager.named(new, fileName: "s.pdf", rootPath: root, folderFiles: nil, profile: nil)
                    .proposedName == "1. Oct 2025.PDF")
        // Outside the rule, the account's name stands as it was.
        let pge = FilingDestination(path: "/T/Home/PGE/2025", confidence: .high, reasons: [], newSegments: [],
                                    proposedName: "03. Mar 2025.pdf", nameOrigin: .template)
        #expect(FileSyncManager.named(pge, fileName: "s.pdf", rootPath: root,
                                      folderFiles: files(["01. Jan 2025.pdf"], in: "/T/Home/PGE/2025"), profile: nil) == pge)
        // A typed name is never touched.
        let typed = template.naming("Mine.pdf", origin: .typed)
        #expect(FileSyncManager.named(typed, fileName: "s.pdf", rootPath: root,
                                      folderFiles: files(["1. Jan 2025.pdf"]), profile: nil) == typed)
    }

    // MARK: Undo order

    @Test func aFileMovedTwiceIsUndoneFromWhereItIsNow() {
        func m(_ a: String, _ b: String) -> FileSyncManager.MoveItemState {
            (from: URL(fileURLWithPath: a), to: URL(fileURLWithPath: b), overwritten: nil)
        }
        // Filed as 11., then renumbered by the twelfth, which also renamed 1. to 01.
        let applied = [m("/in/a.pdf", "/f/11. Nov.pdf"), m("/f/1. Jan.pdf", "/f/01. Jan.pdf"),
                       m("/in/b.pdf", "/f/12. Dec.pdf")]
        #expect(FileSyncManager.undoOrder(applied).map { "\($0.from.path)→\($0.to.path)" }
                == ["/in/b.pdf→/f/12. Dec.pdf", "/f/1. Jan.pdf→/f/01. Jan.pdf", "/in/a.pdf→/f/11. Nov.pdf"])
        let chained = [m("/in/a.pdf", "/f/1. Jun.pdf"), m("/f/1. Jun.pdf", "/f/01. Jun.pdf")]
        #expect(FileSyncManager.undoOrder(chained).map { "\($0.from.path)→\($0.to.path)" }
                == ["/in/a.pdf→/f/01. Jun.pdf"])
        // A chain through names: 2→3 made before 1→2 is undone after it.
        let cascade = [m("/f/2. Jul.pdf", "/f/3. Jul.pdf"), m("/f/1. Jul.pdf", "/f/2. Jul.pdf")]
        #expect(FileSyncManager.undoOrder(cascade).map(\.from.path) == ["/f/1. Jul.pdf", "/f/2. Jul.pdf"])
    }
}
