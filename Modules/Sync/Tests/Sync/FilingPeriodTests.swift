import Testing
import Foundation
@testable import Sync

/// Months and ordinal prefixes are periods, not topics. The dry run filed `05. May 2026.pdf` into
/// `…/Trade Confirms/2024/05. May 2024` because "May" and "05" counted as words the folder shared.
@Suite struct FilingPeriodTests {

    private func file(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false, fileSize: 8192)
    }
    private func dir(_ path: String, _ children: [FileNode] = []) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true, children: children)
    }

    @Test func monthWordsAndSlotsAreRead() {
        #expect(FilingPeriod.month(of: "May") == 5 && FilingPeriod.month(of: "sept") == 9
                && FilingPeriod.month(of: "December") == 12)
        #expect(FilingPeriod.month(of: "mayo") == nil && FilingPeriod.month(of: "statement") == nil)
        #expect(FilingPeriod.isShortNumber("05") && !FilingPeriod.isShortNumber("2026") && !FilingPeriod.isShortNumber("x1"))
        #expect(FilingPeriod.monthSlot(ofFolderNamed: "05. May 2024") == 5)
        #expect(FilingPeriod.monthSlot(ofFolderNamed: "July") == 7)
        #expect(FilingPeriod.monthSlot(ofFolderNamed: "2021-03") == 3)
        #expect(FilingPeriod.monthSlot(ofFolderNamed: "Statements") == nil)
        #expect(FilingPeriod.monthSlot(ofFolderNamed: "Jan-Mar 2026") == nil, "two months is not one slot")
        #expect(FilingPeriod.month(inFileName: "05. May 2026.pdf") == 5)
        #expect(FilingPeriod.month(inFileName: "Q1 Jan-Mar 2026.pdf") == nil)
        #expect(FilingPeriod.isPeriodToken("april") && !FilingPeriod.isPeriodToken("april", keeping: ["april"]))
    }

    /// The keyword engine: a month folder shares "May" with the name, and that alone used to make a
    /// Medium home. Control: a real topic word still matches.
    @Test func aMonthWordAloneIsNoCategoryForTheKeywordEngine() {
        let taxonomy = [dir("/root/Trade Confirms", [dir("/root/Trade Confirms/2024", [
            dir("/root/Trade Confirms/2024/05. May 2024", [file("/root/Trade Confirms/2024/05. May 2024/confirm.pdf")])])])]
        let monthOnly = FilingEngine.suggest(looseFiles: [file("/root/In/05. May 2026.pdf")],
                                             taxonomy: taxonomy, providerRoot: "/root")
        #expect(!(monthOnly.first?.candidates ?? []).contains { $0.path.hasSuffix("05. May 2024") },
                "\(monthOnly.first?.candidates.map(\.path) ?? [])")
        let topical = FilingEngine.suggest(looseFiles: [file("/root/In/Trade Confirms May 2026.pdf")],
                                           taxonomy: taxonomy, providerRoot: "/root")
        #expect((topical.first?.candidates ?? []).contains { $0.path.contains("Trade Confirms") },
                "a topic word still places the file")
    }

    @Test func aMonthNamingAPersonKeepsItsMeaning() {
        let taxonomy = [dir("/root/Family", [dir("/root/Family/April", [file("/root/Family/April/report.pdf")])])]
        let registry = PersonRegistry(people: [Person(id: "april", displayName: "April")])
        let s = FilingEngine.suggest(looseFiles: [file("/root/In/April report card.pdf")], taxonomy: taxonomy,
                                     providerRoot: "/root", registry: registry)
        #expect((s.first?.candidates ?? []).contains { $0.path == "/root/Family/April" },
                "\(s.first?.candidates.map(\.path) ?? [])")
    }

    /// The router: "May" and "05" no longer reach a month folder by name. A month slot is reached
    /// through its year, and the file's month picks the slot over its siblings and its year folder.
    @Test func theRouterPicksAMonthSlotByYearAndMonth() throws {
        let folders = ["Trade Confirms/2024/11. Nov 2024", "Trade Confirms/2026/11. Nov 2026",
                       "Trade Confirms/2026/06. Jun 2026", "Trade Confirms/2024", "Trade Confirms/2026"]
        let index = FilingRouter.makeIndex(destinations: folders, profile: nil, memory: nil)
        for name in ["Trade Confirms 11. Nov 2026.pdf", "Trade Confirms 2026-11.pdf"] {
            let r = FilingRouter.rank(fileName: name, contentSnippet: nil, index: index)
            #expect(r.best?.relativePath == "Trade Confirms/2026/11. Nov 2026", "\(name): \(r.candidates.map(\.relativePath))")
        }
        // A flat layout: the slot carries its own year.
        let flat = FilingRouter.makeIndex(destinations: ["Bank/Statements/05. May 2024", "Bank/Statements/05. May 2026",
                                                         "Bank/Statements/06. Jun 2026"], profile: nil, memory: nil)
        let r = FilingRouter.rank(fileName: "Bank Statements 05. May 2026.pdf", contentSnippet: nil, index: flat)
        #expect(r.best?.relativePath == "Bank/Statements/05. May 2026", "\(r.candidates.map(\.relativePath))")

        // A bare statement name: "05" and "May" used to reach another year's month folder by name
        // and beat the right year. Now they reach nothing; the year picks.
        let bareIndex = FilingRouter.makeIndex(destinations: ["Trade Confirms/2024/05. May 2024", "Bank/Statements/2026"],
                                               profile: nil, memory: nil)
        let bare = FilingRouter.rank(fileName: "05. May 2026.pdf", contentSnippet: nil, index: bareIndex)
        #expect(bare.best?.relativePath == "Bank/Statements/2026", "\(bare.candidates.map(\.relativePath))")
    }

    /// A number that isn't a date keeps its meaning: `Class 10` is not `Class 12`.
    @Test func aNumberThatIsNoDateStillCounts() {
        #expect(FilingPeriod.periodTokens(inStem: "05. May 2026") == ["05", "may"])
        #expect(FilingPeriod.periodTokens(inStem: "Son Class 10 report") == [])
        let index = FilingRouter.makeIndex(destinations: ["School/Son/Class 10", "School/Son/Class 12"], profile: nil, memory: nil)
        let r = FilingRouter.rank(fileName: "Son Class 10 report.pdf", contentSnippet: nil, index: index)
        #expect(r.best?.relativePath == "School/Son/Class 10", "\(r.candidates.map(\.relativePath))")
    }

    @Test func numericMonthsAndStrictSlots() {
        #expect(FilingPeriod.month(inFileName: "Statement 2026-11.pdf") == 11)
        #expect(FilingPeriod.month(inFileName: "eStmt_2026-03-28.pdf") == 3)
        #expect(FilingPeriod.month(inFileName: "05. Statement.pdf") == 5)
        #expect(FilingPeriod.monthSlot(ofFolderNamed: "Jan Smith") == nil, "a person, not a month slot")
        #expect(FilingPeriod.monthSlot(ofFolderNamed: "Dec Pages") == nil)
    }
}
