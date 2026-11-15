import Testing
import Foundation
@testable import Sync

/// A home picked inside an archive whose folder carries on outside it: the file goes to the live
/// folder, and the archive is offered next.
@Suite struct FilingLiveTwinTests {
    private func file(_ p: String) -> FileNode { FileNode(id: "/D/" + p, name: (p as NSString).lastPathComponent, isDirectory: false, fileSize: 9000) }
    private func dir(_ p: String, _ c: [FileNode]) -> FileNode { FileNode(id: "/D/" + p, name: (p as NSString).lastPathComponent, isDirectory: true, children: c) }
    /// `folder` with a year folder a year, a statement a month, named `NN. Mon YYYY.pdf`.
    private func statements(_ folder: String, years: ClosedRange<Int>) -> FileNode {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return dir(folder, years.map { y in
            dir("\(folder)/\(y)", months.enumerated().map { i, m in file(String(format: "%@/%d/%02d. %@ %d.pdf", folder, y, i + 1, m, y)) })
        })
    }
    private let archived = "Home/Archive/Old House/Utilities/Power Co"
    private let live = "Home/Utilities/Power Co"

    private func tree(live liveYears: ClosedRange<Int> = 2021...2025, more: [FileNode] = []) -> [FileNode] {
        [dir("Home", [
            dir("Home/Archive", [dir("Home/Archive/Old House", [dir("Home/Archive/Old House/Utilities", [
                statements(archived, years: 2018...2020)])])]),
            dir("Home/Utilities", [statements(live, years: liveYears)]),
        ] + more)]
    }

    private func card(leading path: String, remembered: Bool = false, fromAI: Bool = true, confidence: FilingConfidence = .medium,
                      evidenceToken: String? = nil, neighborMatches: Int = 0, account: FilingAccount? = nil,
                      others: [String] = ["Home"]) -> FilingSuggestion {
        FilingSuggestion(filePath: "/D/TODO/Statement.pdf", fileName: "Statement.pdf", size: 9000, modificationDate: nil,
                         candidates: [FilingDestination(path: "/D/" + path, confidence: confidence, reasons: ["Power Co energy statement"],
                                                        newSegments: [], remembered: remembered, fromAI: fromAI,
                                                        evidenceToken: evidenceToken, neighborMatches: neighborMatches, account: account)]
                            + others.map { FilingDestination(path: "/D/" + $0, confidence: .low, reasons: [], newSegments: []) })
    }
    private let facts = ["/D/TODO/Statement.pdf": DocumentFacts(page: "Account No: 7192380000-1\nStatement Date: 08/13/2026\nENERGY STATEMENT")]

    @Test func anArchivedHomeGivesWayToItsLiveTwin() throws {
        let out = FileSyncManager.preferringLiveTwins([card(leading: archived)], taxonomy: tree(), root: "/D", facts: facts)
        let s = try #require(out.first)
        #expect(s.best?.path == "/D/" + live + "/2026", "\(s.candidates.map(\.path))")
        #expect(s.best?.newSegments == ["2026"])
        #expect(s.best?.proposedName == "08. Aug 2026.pdf")
        #expect(s.best?.reasons.first == "Newer Power Co files are here; Archive › Old House › Utilities › Power Co holds the older ones")
        #expect(s.best?.fromAI == true, "still Claude's pick, moved")
        #expect(s.candidates.map(\.path) == ["/D/\(live)/2026", "/D/\(archived)", "/D/Home"], "the archive is next")
        #expect(s.best?.confidence == .medium)
    }

    @Test func aStatementWithNoKnownMonthIsNeverHigh() {
        let out = FileSyncManager.preferringLiveTwins([card(leading: archived, confidence: .high)], taxonomy: tree(), root: "/D")
        #expect(out.first?.best?.path == "/D/" + live, "no year folder can be chosen")
        #expect(out.first?.best?.confidence == .medium)
        let dated = FileSyncManager.preferringLiveTwins([card(leading: archived, confidence: .high)], taxonomy: tree(), root: "/D", facts: facts)
        #expect(dated.first?.best?.confidence == .high, "sure when the statement's year chose the folder")
    }

    /// No account read the statement (a tree with none to match): its page 1 still dates it.
    @Test func thePageDatesAStatementNoAccountRead() {
        let out = FileSyncManager.preferringLiveTwins([card(leading: archived)], taxonomy: tree(), root: "/D",
                                                      pages: ["/D/TODO/Statement.pdf": "Statement Date: 08/13/2026\nENERGY STATEMENT"])
        #expect(out.first?.best?.path == "/D/" + live + "/2026")
    }

    @Test func theArchivesEvidenceStaysWithTheArchive() {
        let out = FileSyncManager.preferringLiveTwins([card(leading: archived, evidenceToken: "7192380000", neighborMatches: 12)],
                                                      taxonomy: tree(), root: "/D", facts: facts)
        #expect(out.first?.best?.evidenceToken == nil)
        #expect(out.first?.best?.neighborMatches == 0)
        #expect(out.first?.candidates[1].neighborMatches == 12, "the archive keeps its own")
    }

    /// An account's number decides an archived account (the move-out offer), and the live folder of
    /// the same name may hold another account.
    @Test func anAccountsHomeStands() {
        let account = FilingAccount(root: "/D/" + archived, ending: "0000", institution: "power co", archived: true, kind: .statement)
        let out = FileSyncManager.preferringLiveTwins([card(leading: archived, account: account)], taxonomy: tree(), root: "/D", facts: facts)
        #expect(out.first?.best?.path == "/D/" + archived)
    }

    @Test func anArchiveInsideTheFolderGivesWayToIt() {
        let t = [dir("Home", [dir("Home/Utilities", [dir(live, statements(live, years: 2021...2025).children!
                                                            + [statements(live + "/Archive", years: 2015...2018)])])])]
        for pick in [live + "/Archive", live + "/Archive/2017"] {
            let out = FileSyncManager.preferringLiveTwins([card(leading: pick)], taxonomy: t, root: "/D", facts: facts)
            #expect(out.first?.best?.path == "/D/" + live + "/2026", "\(pick)")
            #expect(out.first?.best?.reasons.first == "Newer Power Co files are here; Archive holds the older ones")
        }
    }

    /// Above an archive, a folder of categories (`Finance/US`) is no twin: only one that keeps its
    /// own statements is.
    @Test func aCategoryAboveAnArchiveIsNoTwin() {
        let t = [dir("Finance", [dir("Finance/US", [statements("Finance/US/Archive", years: 2015...2018),
                                                    statements("Finance/US/Bank", years: 2020...2025)])])]
        let out = FileSyncManager.preferringLiveTwins([card(leading: "Finance/US/Archive")], taxonomy: t, root: "/D", facts: facts)
        #expect(out.first?.best?.path == "/D/Finance/US/Archive")
    }

    @Test func theTwinsOwnFolderIsNotOfferedTwice() {
        let out = FileSyncManager.preferringLiveTwins([card(leading: archived, others: [live, "Home"])], taxonomy: tree(), root: "/D", facts: facts)
        #expect(out.first?.candidates.map(\.path) == ["/D/\(live)/2026", "/D/\(archived)", "/D/Home"])
    }

    /// An inbox the survey marks is no live folder, so it neither wins nor ties.
    @Test func anInboxIsNoTwin() {
        let t = tree(more: [dir("Home/Scans", [dir("Home/Scans/Utilities", [statements("Home/Scans/Utilities/Power Co", years: 2024...2025)])])])
        let tied = FileSyncManager.preferringLiveTwins([card(leading: archived)], taxonomy: t, root: "/D", facts: facts)
        #expect(tied.first?.best?.path == "/D/" + archived, "two twins")
        let out = FileSyncManager.preferringLiveTwins([card(leading: archived)], taxonomy: t, root: "/D",
                                                      isInbox: { $0.hasPrefix("Home/Scans") }, facts: facts)
        #expect(out.first?.best?.path == "/D/" + live + "/2026")
    }

    @Test func eachArchivedFolderOnTheMenuBringsItsTwin() {
        let twins = LiveTwinFinder(taxonomy: tree(), isArchived: { _ in false }).allTwins()
        #expect(twins[archived] == live)
        #expect(twins[archived + "/2019"] == live, "a year folder in the archive too")
        #expect(twins["Home/Archive"] == nil)
        let menu = FileSyncManager.withLiveTwins(["Home", archived, live, "Home/Utilities"], twins: twins)
        #expect(menu == ["Home", live, archived, "Home/Utilities"], "just before it, once")
    }

    @Test func aPickOfTheArchivesYearFolderGivesWayToo() {
        let out = FileSyncManager.preferringLiveTwins([card(leading: archived + "/2020")], taxonomy: tree(), root: "/D", facts: facts)
        #expect(out.first?.best?.path == "/D/" + live + "/2026")
    }

    @Test func theBanksFolderAboveTheArchiveCounts() {
        let t = [dir("Schwab", [dir("Schwab/Archive", [statements("Schwab/Archive/Roth IRA", years: 2015...2018)]),
                                statements("Schwab/Roth IRA", years: 2019...2025)])]
        let out = FileSyncManager.preferringLiveTwins([card(leading: "Schwab/Archive/Roth IRA")], taxonomy: t, root: "/D", facts: facts)
        #expect(out.first?.best?.path == "/D/Schwab/Roth IRA/2026")
    }

    @Test func aSurveyMarkedArchiveCounts() {
        let t = [dir("Home", [dir("Home/Closed", [dir("Home/Closed/Utilities", [statements("Home/Closed/Utilities/Power Co", years: 2018...2020)])]),
                              dir("Home/Utilities", [statements(live, years: 2021...2025)])])]
        let out = FileSyncManager.preferringLiveTwins([card(leading: "Home/Closed/Utilities/Power Co")], taxonomy: t, root: "/D",
                                                      isArchived: { $0 == "Home/Closed" }, facts: facts)
        #expect(out.first?.best?.path == "/D/" + live + "/2026")
    }

    /// His survey marks the archive and every folder below it: those still name what they hold.
    @Test func aSurveyThatMarksEveryFolderBelowTheArchiveToo() {
        let out = FileSyncManager.preferringLiveTwins([card(leading: archived)], taxonomy: tree(), root: "/D",
                                                      isArchived: { $0.hasPrefix("Home/Archive") }, facts: facts)
        #expect(out.first?.best?.path == "/D/" + live + "/2026")
    }

    /// An archive with nothing after it stands for the folder it sits in, not for a namesake of
    /// that folder elsewhere.
    @Test func aBareArchiveIsNotTwinnedWithANamesakeOfItsFolder() {
        let t = [dir("Work", [statements("Work/Archive", years: 2015...2018)]),
                 dir("Projects", [statements("Projects/Work", years: 2021...2025)])]
        let out = FileSyncManager.preferringLiveTwins([card(leading: "Work/Archive")], taxonomy: t, root: "/D", facts: facts)
        #expect(out.first?.best?.path == "/D/Work/Archive")
    }

    /// A folder of the same names holding a file now and then is no run of statements.
    @Test func aTwinKeepsARegularRunOfStatements() {
        let t = tree(live: 2025...2025).map { home in
            dir("Home", (home.children ?? []).map { c in
                c.name == "Utilities" ? dir("Home/Utilities", [dir(live, [dir(live + "/2025", [file(live + "/2025/12. Dec 2025.pdf")])])]) : c
            })
        }
        let out = FileSyncManager.preferringLiveTwins([card(leading: archived)], taxonomy: t, root: "/D", facts: facts)
        #expect(out.first?.best?.path == "/D/" + archived)
    }

    /// The live-looking folder stopped first: the archive holds the newest, so it isn't left behind.
    @Test func aTwinNoNewerThanTheArchiveIsNone() {
        let out = FileSyncManager.preferringLiveTwins([card(leading: archived)], taxonomy: tree(live: 2015...2017), root: "/D", facts: facts)
        #expect(out.first?.best?.path == "/D/" + archived)
    }

    @Test func twoTwinsAreNoAnswer() {
        let t = tree(more: [dir("Home/Rental", [dir("Home/Rental/Utilities", [statements("Home/Rental/Utilities/Power Co", years: 2022...2025)])])])
        let out = FileSyncManager.preferringLiveTwins([card(leading: archived)], taxonomy: t, root: "/D", facts: facts)
        #expect(out.first?.best?.path == "/D/" + archived)
    }

    /// Only the name, not the place above it: `Water` under another parent is another folder.
    @Test func aTwinMustShareTheParentsNameToo() {
        let t = [dir("Home", [dir("Home/Archive", [dir("Home/Archive/Utilities", [statements("Home/Archive/Utilities/Power Co", years: 2018...2020)])]),
                              dir("Home/Business", [statements("Home/Business/Power Co", years: 2021...2025)])])]
        let out = FileSyncManager.preferringLiveTwins([card(leading: "Home/Archive/Utilities/Power Co")], taxonomy: t, root: "/D", facts: facts)
        #expect(out.first?.best?.path == "/D/Home/Archive/Utilities/Power Co")
    }

    @Test func hisOwnRuleStands() {
        let out = FileSyncManager.preferringLiveTwins([card(leading: archived, remembered: true)], taxonomy: tree(), root: "/D", facts: facts)
        #expect(out.first?.best?.path == "/D/" + archived)
    }

    @Test func aTwinHeTurnedDownIsNotOfferedAgain() {
        // The folder, or the year folder Try Another recorded.
        for refused in ["/D/" + live, "/D/" + live + "/2026"] {
            let out = FileSyncManager.preferringLiveTwins([card(leading: archived)], taxonomy: tree(), root: "/D", facts: facts,
                                                          rejected: ["/D/TODO/Statement.pdf": [refused]])
            #expect(out.first?.best?.path == "/D/" + archived, "\(refused)")
        }
    }

    @Test func claudeIsToldToKeepNewFilesOutOfArchives() throws {
        let body = CloudFilingProtocol.requestBody(taxonomyFolders: ["Home"], files: [])
        let system = try #require(body["system"] as? [[String: Any]])
        let text = try #require(system.first?["text"] as? String)
        #expect(text.contains("A folder inside an archive"))
        #expect(text.contains("When the only folder that fits is archived, choose it"))
    }
}
