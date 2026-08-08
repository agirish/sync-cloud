import Foundation
import Sync
import Testing
@testable import FileExplorer

/// Searching the rename backlog.
///
/// The backlog rides `.filing`'s lens, and before this existed it rode its *search* too: typing
/// filtered the filing queue, which is not the list on screen, while the backlog sat underneath
/// unfiltered and the trailing readout counted the queue. So these assert the two things that were
/// wrong — that a query reaches this list at all, and that it reaches it by folder AND by file name.
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
        // The reason this searches names at all: 129 folders is a lot to scroll, and what you
        // remember is the file — `9829custbill…` — not the folder it landed in.
        let p = plan("Home/Utilities/X/2023", current: "9829custbill07182023.pdf",
                     proposed: "07. Jul 2023.pdf", skip: "Interest Certificate.pdf")
        #expect(RenameBacklogSearch.matches("custbill", p))
        #expect(RenameBacklogSearch.matches("07. Jul", p))            // the proposed name
        #expect(RenameBacklogSearch.matches("Interest", p))           // and a file left alone
        #expect(!RenameBacklogSearch.matches("Vodafone", p))
    }
}
