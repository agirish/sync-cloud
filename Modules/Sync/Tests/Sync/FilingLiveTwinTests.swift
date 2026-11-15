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

    private func card(leading path: String, remembered: Bool = false, fromAI: Bool = true) -> FilingSuggestion {
        FilingSuggestion(filePath: "/D/TODO/Statement.pdf", fileName: "Statement.pdf", size: 9000, modificationDate: nil,
                         candidates: [FilingDestination(path: "/D/" + path, confidence: .medium, reasons: ["Power Co energy statement"],
                                                        newSegments: [], remembered: remembered, fromAI: fromAI),
                                      FilingDestination(path: "/D/Home", confidence: .low, reasons: [], newSegments: [])])
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
        let out = FileSyncManager.preferringLiveTwins([card(leading: archived)], taxonomy: tree(), root: "/D", facts: facts,
                                                      rejected: ["/D/TODO/Statement.pdf": ["/D/" + live]])
        #expect(out.first?.best?.path == "/D/" + archived)
    }

    @Test func claudeIsToldToKeepNewFilesOutOfArchives() throws {
        let body = CloudFilingProtocol.requestBody(taxonomyFolders: ["Home"], files: [])
        let system = try #require(body["system"] as? [[String: Any]])
        let text = try #require(system.first?["text"] as? String)
        #expect(text.contains("A folder inside an archive"))
    }
}
