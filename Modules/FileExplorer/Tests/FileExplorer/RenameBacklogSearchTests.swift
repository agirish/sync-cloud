import Foundation
import Sync
import Testing
@testable import FileExplorer

/// Searching the rename backlog. The backlog rides `.filing`'s lens, so a query must reach this
/// list rather than only the filing queue, and match by folder and by file name.
@Suite struct RenameBacklogSearchTests {

    private func plan(_ rel: String, current: String = "1. Jan 2021.pdf",
                      proposed: String = "01. Jan 2021.pdf", skip: String? = nil) -> RenamePlan {
        RenamePlan(folderPath: "/root/" + rel, relativePath: rel, scheme: .position,
                   steps: [RenameStep(currentPath: "/root/\(rel)/\(current)", currentName: current,
                                      proposedName: proposed, kind: .tidied, reason: "")],
                   skips: skip.map { [RenameSkip(path: "/root/\(rel)/\($0)", fileName: $0, reason: "")] } ?? [])
    }

    @Test("An empty query keeps every folder")
    func emptyQueryKeepsEverything() {
        #expect(RenameBacklogSearch.matches("", plan("Home/Utilities/PG&E/2021")))
        #expect(RenameBacklogSearch.matches("   ", plan("Home/Utilities/PG&E/2021")))
    }

    @Test("A folder is findable by any part of its path")
    func matchesFolderPath() {
        let p = plan("Home/Utilities/PG&E/2021")
        #expect(RenameBacklogSearch.matches("PG&E", p))
        #expect(RenameBacklogSearch.matches("pg&e", p))      // case-insensitive
        #expect(RenameBacklogSearch.matches("2021", p))
        #expect(!RenameBacklogSearch.matches("Vodafone", p))
    }

    @Test("A folder is findable by a name inside it, before or after the rename")
    func matchesFileNames() {
        // Names are searched because what you remember is the file (`9829custbill…`), not the
        // folder it landed in, and the backlog runs to a hundred folders and more.
        let p = plan("Home/Utilities/X/2023", current: "9829custbill07182023.pdf",
                     proposed: "07. Jul 2023.pdf", skip: "Interest Certificate.pdf")
        #expect(RenameBacklogSearch.matches("custbill", p))
        #expect(RenameBacklogSearch.matches("07. Jul", p))            // the proposed name
        #expect(RenameBacklogSearch.matches("Interest", p))           // and a file left alone
        #expect(!RenameBacklogSearch.matches("Vodafone", p))
    }

    // MARK: The folded to-fix rows are in the same list

    private func risky(_ name: String, in folder: String = "Names") -> RiskyName {
        RiskyName(id: "/root/\(folder)/\(name)", relativePath: "\(folder)/\(name)",
                  currentName: name, sanitizedName: name.replacingOccurrences(of: ":", with: "-"),
                  reason: "Colons break sync", isDirectory: false)
    }

    /// A risky name answers the same query the plans do. The backlog draws the folded Names lens as
    /// its leading "to fix" section, and the query is free text over the names a row is about, so
    /// both halves must filter or the list answers one query two ways.
    @Test("A to-fix name is findable by its name, its safe name, and its folder")
    func matchesRiskyNames() {
        let r = risky("Q1:report.pdf", in: "Finance/Statements")
        #expect(RenameBacklogSearch.matches("", r))              // an empty query keeps everything
        #expect(RenameBacklogSearch.matches("   ", r))
        #expect(RenameBacklogSearch.matches("Q1", r))            // the name as it stands
        #expect(RenameBacklogSearch.matches("q1:report", r))     // case-insensitive
        #expect(RenameBacklogSearch.matches("Q1-report", r))     // the name it would become
        #expect(RenameBacklogSearch.matches("Statements", r))    // where it lives
        #expect(!RenameBacklogSearch.matches("Vodafone", r))
    }

    /// The `reason` is not matched, by decision: the plan half doesn't match its steps' reasons
    /// either, and one list must not find rows by explanation in one half only.
    @Test("A to-fix row is not findable by the reason printed beside it")
    func doesNotMatchTheReason() {
        let r = risky("Q1:report.pdf")
        #expect(!RenameBacklogSearch.matches("Colons", r))
        // The plan half, for the symmetry this is claiming.
        #expect(!RenameBacklogSearch.matches("Padded",
                                             plan("Home/X/2021", current: "1. Jan 2021.pdf")))
    }
}
