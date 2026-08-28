import Testing
import SwiftUI
@testable import FileExplorer
@testable import Sync

/// §5.1's card rules — the kind tag, the subtitle, the blast radius, the scaffold line and the
/// crowding strip's words — asserted as values, the way `cleanTitle`/`revealTitle` already are.
@Suite struct RestructureLensKindTests {

    /// Every kind has a label and a verb, and no two kinds share a label — a mixed list is
    /// sorted by eye, and two kinds wearing one word would read as one.
    @Test func everyKindHasADistinctLabelAndAVerb() {
        var labels = Set<String>()
        for kind in FindingKind.allCases {
            let label = RestructureLens.kindLabel(kind)
            #expect(!label.isEmpty)
            #expect(labels.insert(label).inserted, "\(kind.rawValue) shares a label")
            #expect(!RestructureLens.kindVerb(kind).isEmpty)
        }
    }

    /// The blast radius states the honest cost, and the two shape sentences are the two §5.1
    /// names: renames-only for a one-to-one family, merges for the flagship's.
    @Test func theShapeBlastRadiusTellsRenamesFromMerges() {
        let oneToOne = StructureFinding(
            family: "F",
            schemes: [.init(vocabulary: ["application"], members: ["2016", "2019"]),
                      .init(vocabulary: ["petition"], members: ["2021", "2024"])])
        #expect(RestructureLens.blastRadius(for: oneToOne)
            == "A plan here is folder renames — no file would move.")

        let unequal = StructureFinding(
            family: "F",
            schemes: [.init(vocabulary: ["federal", "state"], members: ["2013", "2014"]),
                      .init(vocabulary: ["forms", "reference", "refund"], members: ["2016", "2017"])])
        #expect(RestructureLens.blastRadius(for: unequal)
            == "Converging these shapes needs merges — files would move.")

        // A scheme with NO shared vocabulary cannot promise a bijection, whatever the sizes say.
        let hollow = StructureFinding(
            family: "F",
            schemes: [.init(vocabulary: [], members: ["2016", "2017"]),
                      .init(vocabulary: [], members: ["2013", "2014"])])
        #expect(RestructureLens.blastRadius(for: hollow)
            == "Converging these shapes needs merges — files would move.")
    }

    @Test func theShadowAxisSentencesFollowWhetherTheYearExists() {
        let merge = StructureFinding(kind: .shadowAxis, family: "Tax", subject: "Tax/IRS Docs - 2023",
                                     detail: .shadowAxis(target: "2023", targetExists: true))
        #expect(RestructureLens.subtitle(for: merge)
            == "hides the year 2023, which exists beside it")
        #expect(RestructureLens.blastRadius(for: merge)?.contains("merge") == true)

        let rename = StructureFinding(kind: .shadowAxis, family: "T", subject: "T/2023 (Family)",
                                      detail: .shadowAxis(target: "2023", targetExists: false))
        #expect(RestructureLens.blastRadius(for: rename)?.contains("rename") == true)
        #expect(RestructureLens.blastRadius(for: rename)?.contains("no file would move") == true)
    }

    /// The scaffold line is honest in both directions: what it would create, or that there is
    /// nothing to copy — and an empty scaffold never claims "creates folders only".
    @Test func theScaffoldLineSaysWhatItWouldCreateOrThatItCannot() {
        let scaffolded = StructureFinding(kind: .backlog, family: "H", subject: "H/2025",
                                          detail: .backlog(scaffold: ["Claims", "Statements"],
                                                           looseFiles: 2))
        let line = RestructureLens.scaffoldLine(for: scaffolded)
        #expect(line?.members == "Claims, Statements")
        #expect(RestructureLens.blastRadius(for: scaffolded)?.contains("Creates folders only") == true)

        let bare = StructureFinding(kind: .backlog, family: "H", subject: "H/2025",
                                    detail: .backlog(scaffold: [], looseFiles: 2))
        #expect(RestructureLens.scaffoldLine(for: bare)?.note.contains("no shared shape") == true)
        #expect(RestructureLens.blastRadius(for: bare) == nil)

        #expect(RestructureLens.scaffoldLine(for: StructureFinding(family: "F", schemes: [])) == nil)
    }

    @Test func theEchoSubtitleNamesTheCounterpartAndItsRelation() {
        let sibling = StructureFinding(kind: .echoName, family: "Forms", subject: "Forms/Form W2",
                                       detail: .echoName(counterpart: "Forms/Form W-2",
                                                         relation: .sibling))
        #expect(RestructureLens.subtitle(for: sibling) == "echoes Form W-2 beside it")

        let parent = StructureFinding(kind: .echoName, family: "Utilities/ACI",
                                      subject: "Utilities/ACI/ACI",
                                      detail: .echoName(counterpart: "Utilities/ACI",
                                                        relation: .parentChild))
        #expect(RestructureLens.subtitle(for: parent) == "echoes its parent, ACI")
    }

    /// The crowding strip's words: counts in the chips, reasons in the help — and the two
    /// report-only classes say WHY there is no button, because a number beside a silent refusal
    /// is an unanswered question in the header.
    @Test func theCrowdingStripSaysWhyOnlyEmptiesGetAnAction() {
        #expect(RestructureLens.crowdingLabel(.passThrough, count: 86) == "86 pass-through")
        #expect(RestructureLens.crowdingLabel(.singleFileLeaf, count: 503) == "503 single-file")
        #expect(RestructureLens.crowdingLabel(.empty, count: 20) == "20 empty")

        #expect(RestructureLens.crowdingHelp(.passThrough).contains("Report-only"))
        #expect(RestructureLens.crowdingHelp(.singleFileLeaf).contains("Report-only"))
        #expect(RestructureLens.crowdingHelp(.empty).contains("Trash"))
    }

    /// The subtitle counts the family on both drop paths — §5.1's 11 → 17, as a rule rather
    /// than a screenshot.
    @Test func theShapeSubtitleCountsTheWholeFamily() {
        let finding = StructureFinding(
            family: "F",
            schemes: [.init(vocabulary: ["a"], members: ["1", "2"]),
                      .init(vocabulary: ["b"], members: ["3", "4"])],
            drift: ["5"], shapeless: ["6"])
        #expect(RestructureLens.subtitle(for: finding) == "6 folders, 2 internal shapes")
    }
}
