import Testing
import AppKit
import SwiftUI
@testable import Sync
@testable import FileExplorer

/// Every card kind and the crowding strip, actually laid out — the cheapest guard against the
/// failure a rule test cannot see: a card body that traps at render (a @MainActor static read
/// off the main actor is signal 5 with no message; a ForEach over colliding ids renders one row
/// twice). No pixel reads, so it runs on any machine.
@MainActor
@Suite struct RestructureLensRenderSmokeTests {

    private static var oneOfEachKind: [StructureFinding] {
        [
            StructureFinding(family: "Finance/US/Income Tax",
                             schemes: [.init(vocabulary: ["forms"], members: ["2016", "2017"]),
                                       .init(vocabulary: ["federal tax"], members: ["2013", "2014"])],
                             drift: ["2025"], shapeless: ["CA State"]),
            StructureFinding(kind: .backlog, family: "Health/Dental",
                             subject: "Health/Dental/2025",
                             detail: .backlog(scaffold: ["Claims"], looseFiles: 2)),
            StructureFinding(kind: .backlog, family: "Work/Benefits",
                             subject: "Work/Benefits/2026",
                             detail: .backlog(scaffold: [], looseFiles: 5)),
            StructureFinding(kind: .shadowAxis, family: "Finance/US/Income Tax",
                             subject: "Finance/US/Income Tax/IRS Docs - 2023",
                             detail: .shadowAxis(target: "2023", targetExists: true)),
            StructureFinding(kind: .echoName, family: "Forms", subject: "Forms/Form W2",
                             detail: .echoName(counterpart: "Forms/Form W-2",
                                               relation: .sibling)),
            StructureFinding(kind: .mirroredInbox, family: "Health/TODO",
                             subject: "Health/TODO/Dental",
                             detail: .mirroredInbox(destination: "Health/Dental")),
            StructureFinding(kind: .looseAboveSeries, family: "Fidelity/Statements",
                             subject: "Fidelity/Statements",
                             detail: .looseAboveSeries(looseFiles: 22, seriesFolders: 4)),
            StructureFinding(kind: .looseBesideContainer, family: "Home",
                             subject: "Home/ATT Bill",
                             detail: .looseBesideContainer(container: "Home/ATT")),
        ]
    }

    @Test func everyCardKindAndTheStripLayOut() throws {
        let lens = RestructureLens(
            findings: Self.oneOfEachKind,
            aboutAncestor: [Self.oneOfEachKind[0]],
            hasProfile: true,
            folderCount: 3013,
            deadWeight: ["A": .passThrough, "B": .singleFileLeaf, "C": .empty],
            accent: .blue,
            onReveal: { _ in },
            onSuppress: { _ in },
            onScaffold: { _ in },
            onHandOff: { _ in },
            scaffoldedSubjects: ["Work/Benefits/2026"],
            hasReviewed: true)
        // An ink floor over the magenta backdrop, not a width — an offscreen host rasterizes
        // transparent, and against a transparent ground a blank render and a drawn one read the
        // same. This is the difference between "every card kind laid out" and "nothing trapped".
        let rep = try #require(RestructureRender.raster(lens, width: 640, height: 900))
        #expect(RestructureRender.inkedPixels(rep) > 5000, "every card kind drew")

        // The clean state with a non-empty strip — the roadmap's open question, settled by
        // rendering: the strip must lay out above the seal.
        let clean = RestructureLens(
            findings: [], hasProfile: true, folderCount: 10,
            deadWeight: ["C": .empty], accent: .blue,
            onReveal: { _ in }, hasReviewed: true)
        let cleanRep = try #require(RestructureRender.raster(clean, width: 640, height: 400))
        #expect(RestructureRender.inkedPixels(cleanRep) > 1000,
                "the strip and the seal both drew in the clean state")
    }
}
